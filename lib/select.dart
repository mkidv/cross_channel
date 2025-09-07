import 'dart:async';

import 'package:cross_channel/cross_channel.dart';
import 'package:cross_channel/src/core.dart';

typedef Canceller = void Function();
typedef RegisterCanceller = void Function(Canceller);
typedef Resolve<R> = FutureOr<void> Function(
  int index,
  Object? tag,
  FutureOr<R> result,
);

/// Contract for a selectable branch: attach to a source and call `resolve` when it fires.
/// Returns `true` if it resolved *synchronously* during attach (only possible for Arm.immediate).
abstract class _Branch<R> {
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  });
}

/// Small ADT representing either an immediate value or a pending future with a canceller.
/// Use this to model sources that may have a fast-path (e.g. tryPop) for sync selection.
sealed class Arm<T> {
  const Arm();
  factory Arm.immediate(T value) = _ArmImmediate<T>;
  factory Arm.pending(Future<T> future, Canceller cancel) = _ArmPending<T>;
}

class _ArmImmediate<T> implements Arm<T> {
  const _ArmImmediate(this.value);
  final T value;
}

class _ArmPending<T> implements Arm<T> {
  const _ArmPending(this.future, this.cancel);
  final Future<T> future;
  final Canceller cancel;
}

class _FutureBranch<T, R> implements _Branch<R> {
  const _FutureBranch(this.future, this.body, {this.tag});

  final Future<T> future;
  final FutureOr<R> Function(T) body;
  final Object? tag;

  @override
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  }) {
    var canceled = false;
    void cancel() => canceled = true;
    registerCanceller(cancel);

    future.then((u) {
      if (canceled) return;
      try {
        resolve(index, tag, body(u));
      } catch (e, st) {
        Zone.current.handleUncaughtError(e, st);
      }
    }, onError: (Object e, StackTrace? st) {
      if (canceled) return;
      resolve(index, tag, Future<R>.error(e, st));
    });
    return false;
  }
}

class _StreamBranch<T, R> implements _Branch<R> {
  const _StreamBranch(this.stream, this.body, {this.tag});

  final Stream<T> stream;
  final FutureOr<R> Function(T) body;
  final Object? tag;

  @override
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  }) {
    var canceled = false;
    StreamSubscription<T>? sub;

    void cancel() {
      canceled = true;
      sub?.cancel();
      sub = null;
    }

    registerCanceller(cancel);
    sub = stream.listen((u) {
      if (canceled) return;
      resolve(index, tag, body(u));
    }, onError: (Object e, StackTrace? st) {
      if (canceled) return;
      resolve(index, tag, Future<R>.error(e, st));
    }, onDone: () {
      cancel();
    }, cancelOnError: false);

    return false;
  }
}

class _TimerBranch<R> implements _Branch<R> {
  const _TimerBranch(this.delay, this.body, {this.tag});

  final Duration delay;
  final FutureOr<R> Function() body;
  final Object? tag;

  @override
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  }) {
    final t = Timer(delay, () => resolve(index, tag, body()));
    registerCanceller(() {
      if (t.isActive) t.cancel();
    });
    return false;
  }
}

class ArmBranch<T, R> implements _Branch<R> {
  const ArmBranch(this.armFactory, this.body, {this.tag});

  final Arm<T> Function() armFactory;
  final FutureOr<R> Function(T) body;
  final Object? tag;

  @override
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  }) {
    final a = armFactory();
    switch (a) {
      case _ArmImmediate<T>():
        resolve(index, tag, body(a.value));
        return true;
      case _ArmPending<T>():
        registerCanceller(a.cancel);
        a.future.then((u) {
          resolve(index, tag, body(u));
        }, onError: (Object e, StackTrace? st) {
          resolve(index, tag, Future<R>.error(e, st));
        });
        return false;
    }
  }
}

class _ReceiverBranch<T, R> implements _Branch<R> {
  const _ReceiverBranch(this.rx, this.body, {this.tag});

  final Receiver<T> rx;
  final FutureOr<R> Function(RecvResult<T>) body;
  final Object? tag;

  @override
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  }) {
    final (fut, cancel) = rx.recvCancelable();
    registerCanceller(cancel);
    fut.then((res) {
      if (res is RecvErrorCanceled) return;
      resolve(index, tag, body(res));
    }, onError: (Object e, StackTrace? st) {
      if (e is RecvErrorCanceled) return;
      resolve(index, tag, Future<R>.error(e, st));
    });
    return false;
  }
}

/// Async multiplexing - race multiple operations with automatic cancellation.
///
/// The cornerstone of reactive, event-driven applications. Race channels,
/// timers, futures, and streams with automatic cleanup of losers. Essential
/// for building responsive UIs and efficient event processing systems.
///
/// ## Core Concepts
/// - **First wins**: The first operation to complete wins, all others are canceled
/// - **Automatic cleanup**: Losing operations are properly canceled to prevent leaks
/// - **Type-safe**: Each branch can return different types, unified by the result type
/// - **Composable**: Easily combine different async sources in a single select
///
/// ## Usage Patterns
///
/// **Responsive UI with timeout:**
/// ```dart
/// final result = await XSelect.run<String>((s) => s
///   ..onRecvValue(dataChannel, (data) => 'got_data: $data')
///   ..onTick(Ticker.every(Duration(seconds: 1)), () => 'heartbeat')
///   ..timeout(Duration(seconds: 30), () => 'timeout_reached')
/// );
///
/// switch (result) {
///   case 'timeout_reached':
///     showTimeoutMessage();
///   case String data when data.startsWith('got_data'):
///     processData(data);
///   case 'heartbeat':
///     updateHeartbeat();
/// }
/// ```
///
/// **Multi-source event aggregation:**
/// ```dart
/// final event = await XSelect.run<AppEvent>((s) => s
///   ..onStream(userInteractions, (e) => AppEvent.user(e))
///   ..onStream(networkEvents, (e) => AppEvent.network(e))
///   ..onRecvValue(backgroundTasks, (t) => AppEvent.background(t))
///   ..onFuture(systemCheck(), (r) => AppEvent.system(r))
/// );
///
/// handleEvent(event);
/// ```
///
/// **Configuration reload with graceful fallback:**
/// ```dart
/// Future<Config> loadConfigWithFallback() async {
///   return await XSelect.run<Config>((s) => s
///     ..onFuture(loadFromServer(), (c) => c)
///     ..onFuture(loadFromCache(), (c) => c)
///     ..timeout(Duration(seconds: 5), () => Config.defaultConfig())
///   );
/// }
/// ```
class XSelect {
  /// Race multiple async operations - first to complete wins.
  ///
  /// Build a selection of async operations using the builder pattern.
  /// The first operation to complete determines the result, and all
  /// other operations are automatically canceled.
  ///
  /// **Parameters:**
  /// - [build]: Builder function to configure the selection branches
  /// - [timeout]: Optional global timeout for the entire selection
  /// - [onTimeout]: Function to call if the global timeout is reached
  /// - [ordered]: If `true`, evaluates branches in order; if `false`, uses fairness rotation
  ///
  /// **Example - Event-driven architecture:**
  /// ```dart
  /// // WebSocket server with graceful shutdown and health checks
  /// class WebSocketManager {
  ///   final _commands = XChannel.mpsc<ServerCommand>(capacity: 100);
  ///   final _health = Ticker.every(Duration(seconds: 30));
  ///
  ///   Future<void> eventLoop() async {
  ///     while (true) {
  ///       final action = await XSelect.run<String>((s) => s
  ///         ..onRecvValue(_commands, (cmd) => _handleCommand(cmd))
  ///         ..onTick(_health, () => 'health_check')
  ///         ..onStream(websocketStream, (msg) => _handleWebSocket(msg))
  ///         ..timeout(Duration(minutes: 5), () => 'idle_timeout')
  ///       );
  ///
  ///       if (action == 'idle_timeout') break;
  ///       if (action == 'shutdown') break;
  ///       // Continue processing...
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// **See also:**
  /// - [SelectBuilder] for available operations
  /// - [Ticker] for timer-based operations
  /// - [XChannel] for channel-based communication
  static Future<R> run<R>(
    void Function(SelectBuilder<R>) build, {
    Duration? timeout,
    FutureOr<R> Function()? onTimeout,
    bool ordered = false,
  }) async {
    final b = SelectBuilder<R>();
    build(b);
    if (timeout != null && onTimeout != null) {
      b.timeout(timeout, onTimeout);
    }
    if (ordered) b.ordered();
    return b.run();
  }

  /// Non-blocking selection over *immediate* arms only (e.g. `Arm.immediate`).
  /// Returns `null` if no arm can fire synchronously.
  static R? syncRun<R>(
    void Function(SelectBuilder<R> s) build, {
    bool ordered = false,
  }) {
    final b = SelectBuilder<R>();
    build(b);
    if (ordered) b.ordered();
    return b.syncRun();
  }

  /// Compose several builders into a single race. Useful to keep related branches grouped.
  static Future<R> race<R>(
    Iterable<void Function(SelectBuilder<R> b)> competitors, {
    Duration? timeout,
    FutureOr<R> Function()? onTimeout,
    bool ordered = false,
  }) =>
      run<R>((b) {
        for (final c in competitors) {
          c(b);
        }
      }, timeout: timeout, onTimeout: onTimeout, ordered: ordered);

  /// Synchronous variant of [race]. Returns immediately if any competitor exposes
  /// an `Arm.immediate`; otherwise returns `null` without subscribing.
  static R? syncRace<R>(
    Iterable<void Function(SelectBuilder<R> b)> competitors, {
    bool ordered = false,
  }) =>
      syncRun<R>((b) {
        for (final c in competitors) {
          c(b);
        }
      }, ordered: ordered);
}

/// Builder for composing async selections with type-safe operations.
///
/// Provides a fluent DSL for racing multiple async operations. Each operation
/// type has specialized methods with automatic resource cleanup and cancellation.
///
/// ## Available Operations
///
/// **Channel Operations:**
/// - [onRecv] - Wait for any channel message (Success/Failure)
/// - [onRecvValue] - Wait only for successful channel messages
/// - [onRecvError] - Wait only for channel errors
///
/// **Future Operations:**
/// - [onFuture] - Race a Future with automatic cancellation
/// - [onFutureValue] - Race a Future, ignore errors
/// - [onFutureError] - Race a Future, only handle errors
///
/// **Stream Operations:**
/// - [onStream] - Wait for next stream event
/// - [onStreamDone] - Wait for stream completion
///
/// **Timer Operations:**
/// - [onTick] - Wait for timer tick
/// - [onDelay] - Add fixed delay branch
/// - [timeout] - Add timeout to the entire selection
///
/// **Example - Multi-source data processing:**
/// ```dart
/// final processor = DataProcessor();
///
/// while (processor.isRunning) {
///   final action = await XSelect.run<ProcessorAction>((s) => s
///     // High-priority user commands
///     ..onRecvValue(userCommands, (cmd) => ProcessorAction.userCommand(cmd))
///
///     // Background data processing
///     ..onStream(dataStream, (data) => ProcessorAction.processData(data))
///
///     // Periodic maintenance
///     ..onTick(maintenanceTicker, () => ProcessorAction.maintenance())
///
///     // API health checks
///     ..onFuture(healthCheck(), (status) => ProcessorAction.healthUpdate(status))
///
///     // Graceful shutdown on idle
///     ..timeout(Duration(minutes: 10), () => ProcessorAction.shutdown())
///   );
///
///   await processor.handleAction(action);
/// }
/// ```
class SelectBuilder<R> {
  final List<(_Branch<R> b, bool Function()? guard)> _branches = [];
  Duration? _timeout;
  FutureOr<R> Function()? _onTimeout;
  bool _ordered = false;

  /// Race a Future - handles both success and error cases.
  ///
  /// The future is automatically canceled if another branch wins the race.
  /// Use this when you need to handle both successful completion and errors.
  ///
  /// **Parameters:**
  /// - [fut]: Future to race
  /// - [body]: Function to call with the future's result
  /// - [tag]: Optional tag for debugging
  /// - [if_]: Optional guard condition
  ///
  /// **Example:**
  /// ```dart
  /// await XSelect.run<String>((s) => s
  ///   ..onFuture(apiCall(), (result) => 'API returned: $result')
  ///   ..onFuture(fallbackCall(), (result) => 'Fallback: $result')
  ///   ..timeout(Duration(seconds: 5), () => 'timeout')
  /// );
  /// ```
  SelectBuilder<R> onFuture<T>(Future<T> fut, FutureOr<R> Function(T) body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((_FutureBranch<T, R>(fut, body, tag: tag), if_));
    return this;
  }

  /// Race a Future, but only handle successful completion.
  ///
  /// Errors from the future are ignored. Use when you only care about
  /// successful results and want other branches to handle error cases.
  ///
  /// **Example:**
  /// ```dart
  /// await XSelect.run<String>((s) => s
  ///   ..onFutureValue(loadUserData(), (user) => 'User: ${user.name}')
  ///   ..onFutureValue(loadFallbackData(), (data) => 'Fallback: $data')
  ///   ..delay(Duration(seconds: 3), () => 'No data available')
  /// );
  /// ```
  SelectBuilder<R> onFutureValue<T>(Future<T> fut, FutureOr<R> Function(T) body,
      {Object? tag, bool Function()? if_}) {
    return onFuture<T>(fut, body, tag: tag, if_: if_);
  }

  /// Race a Future, but only handle errors.
  ///
  /// Successful completion is ignored. Use for error monitoring or
  /// when you want to react only to failure cases.
  ///
  /// **Example:**
  /// ```dart
  /// await XSelect.run<String>((s) => s
  ///   ..onStream(dataStream, (data) => 'Processing: $data')
  ///   ..onFutureError(backgroundTask(), (error) => 'Task failed: $error')
  ///   ..timeout(Duration(seconds: 30), () => 'timeout')
  /// );
  /// ```
  SelectBuilder<R> onFutureError<T>(
      Future<T> fut, FutureOr<R> Function(Object error) body,
      {Object? tag, bool Function()? if_}) {
    return onFuture<T>(fut.catchError((Object e) => throw e),
        (_) => throw StateError('onFutureError should not handle success'),
        tag: tag, if_: if_);
  }

  /// Race a Stream - waits for the next event.
  ///
  /// Automatically cancels the stream subscription if another branch wins.
  /// Use this when you want to react to the next event from a stream.
  ///
  /// **Parameters:**
  /// - [stream]: Stream to listen to
  /// - [body]: Function to call with the next stream event
  /// - [tag]: Optional tag for debugging
  /// - [if_]: Optional guard condition
  ///
  /// **Example:**
  /// ```dart
  /// await XSelect.run<String>((s) => s
  ///   ..onStream(userClicks, (click) => 'User clicked: $click')
  ///   ..onStream(keyboardEvents, (key) => 'Key pressed: $key')
  ///   ..onStream(networkEvents, (event) => 'Network: $event')
  ///   ..timeout(Duration(seconds: 30), () => 'No user activity')
  /// );
  /// ```
  SelectBuilder<R> onStream<T>(Stream<T> stream, FutureOr<R> Function(T) body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((_StreamBranch<T, R>(stream, body, tag: tag), if_));
    return this;
  }

  /// Race a Stream - waits for completion (done event).
  ///
  /// Triggers when the stream completes normally or with an error.
  /// Use this to react to stream lifecycle events.
  ///
  /// **Example:**
  /// ```dart
  /// await XSelect.run<String>((s) => s
  ///   ..onStream(dataStream, (data) => 'Data: $data')
  ///   ..onStreamDone(dataStream, () => 'Stream completed')
  ///   ..timeout(Duration(minutes: 5), () => 'Stream timeout')
  /// );
  /// ```
  SelectBuilder<R> onStreamDone<T>(
      Stream<T> stream, FutureOr<R> Function() body,
      {Object? tag, bool Function()? if_}) {
    return onFuture<void>(stream.drain(), (_) => body(), tag: tag, if_: if_);
  }

  /// Race a channel receiver - handles both success and error cases.
  ///
  /// Waits for any message from the channel (successful value or error).
  /// Use this when you need to handle both normal messages and channel errors.
  ///
  /// **Parameters:**
  /// - [rx]: Receiver to wait on
  /// - [body]: Function to call with the RecvResult
  /// - [tag]: Optional tag for debugging
  /// - [if_]: Optional guard condition
  ///
  /// **Example:**
  /// ```dart
  /// await XSelect.run<String>((s) => s
  ///   ..onRecv(taskResults, (result) => {
  ///       result.valueOrNull != null
  ///         ? 'Task completed: ${result.valueOrNull}'
  ///         : 'Task failed: ${result.errorOrNull}'
  ///     })
  ///   ..timeout(Duration(minutes: 1), () => 'Task timeout')
  /// );
  /// ```
  ///
  /// **See also:**
  /// - [onRecv] - Alias for this method
  /// - [onRecvValue] - Only handle successful messages
  /// - [onRecvError] - Only handle error messages
  SelectBuilder<R> onRecv<T>(
      Receiver<T> rx, FutureOr<R> Function(RecvResult<T>) body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((_ReceiverBranch<T, R>(rx, body, tag: tag), if_));
    return this;
  }

  /// Race a channel receiver - only handle successful messages.
  ///
  /// Waits for successful values from the channel, ignoring errors.
  /// Use when you only care about valid data and want other branches
  /// to handle error conditions.
  ///
  /// **Example:**
  /// ```dart
  /// await XSelect.run<String>((s) => s
  ///   ..onRecvValue(userInputs, (input) => 'User: $input')
  ///   ..onRecvValue(apiResponses, (response) => 'API: $response')
  ///   ..onRecvError(errorChannel, (error) => 'Error: $error')
  ///   ..timeout(Duration(seconds: 10), () => 'No activity')
  /// );
  /// ```
  SelectBuilder<R> onRecvValue<T>(Receiver<T> rx, FutureOr<R> Function(T) body,
      {Object? tag,
      FutureOr<R> Function()? onDisconnected,
      bool Function()? if_}) {
    return onRecv<T>(rx, (result) {
      if (result.hasValue) {
        return body(result.valueOrNull as T);
      }
      if (result.isDisconnected && onDisconnected != null) {
        return onDisconnected();
      }
      return Future<R>.error(StateError('Unexpected RecvResult: $result'));
    }, tag: tag, if_: if_ ?? () => !rx.isDisconnected);
  }

  /// Race a channel receiver - only handle error messages.
  ///
  /// Waits for error conditions from the channel, ignoring successful values.
  /// Use for error monitoring and handling failure conditions.
  ///
  /// **Example:**
  /// ```dart
  /// await XSelect.run<String>((s) => s
  ///   ..onStream(dataStream, (data) => 'Processing: $data')
  ///   ..onRecvError(errorChannel, (error) => 'Error detected: $error')
  ///   ..timeout(Duration(minutes: 1), () => 'All systems normal')
  /// );
  /// ```
  SelectBuilder<R> onRecvError<T>(
      Receiver<T> rx, FutureOr<R> Function(Object error) body,
      {Object? tag, bool Function()? if_}) {
    return onRecv<T>(rx, (result) {
      if (result.hasError) {
        return body(result);
      }
      return Future<R>.error(StateError('Unexpected RecvResult: $result'));
    }, tag: tag, if_: if_ ?? () => !rx.isDisconnected);
  }

  /// Wait for a channel send operation to complete.
  ///
  /// Races a send operation on a channel sender. Use this when you need to
  /// coordinate sending with other async operations or implement backpressure.
  ///
  /// **Parameters:**
  /// - [sender]: Sender to use for the send operation
  /// - [value]: Value to send
  /// - [body]: Function to call when send completes
  /// - [tag]: Optional tag for debugging
  /// - [if_]: Optional guard condition
  ///
  /// **Example:**
  /// ```dart
  /// // Producer with flow control
  /// await XSelect.run<String>((s) => s
  ///   ..onRecvValue(controlChannel, (cmd) => 'Command: $cmd')
  ///   ..onSend(outputChannel, processedData, () => 'Data sent')
  ///   ..timeout(Duration(seconds: 10), () => 'Send timeout')
  /// );
  /// ```
  SelectBuilder<R> onSend<T>(
      Sender<T> sender, T value, FutureOr<R> Function() body,
      {Object? tag, bool Function()? if_}) {
    return onFuture(sender.send(value), (_) => body(), tag: tag, if_: if_);
  }

  /// Add a fixed delay branch to the selection.
  ///
  /// Creates a timer that fires once after the specified duration.
  /// Use this for timeouts, periodic actions, or adding delays to processing.
  ///
  /// **Parameters:**
  /// - [d]: Duration to wait before firing
  /// - [body]: Function to call when the timer fires
  /// - [tag]: Optional tag for debugging
  /// - [if_]: Optional guard condition
  ///
  /// **Example:**
  /// ```dart
  /// await XSelect.run<String>((s) => s
  ///   ..onStream(fastStream, (data) => 'Fast: $data')
  ///   ..delay(Duration(milliseconds: 100), () => 'Throttled')
  ///   ..delay(Duration(seconds: 1), () => 'Periodic check')
  ///   ..delay(Duration(seconds: 30), () => 'Timeout reached')
  /// );
  /// ```
  ///
  /// **See also:**
  /// - [timeout] - Global timeout for the entire selection
  /// - [onTick] - For recurring timer events
  SelectBuilder<R> onDelay(Duration d, FutureOr<R> Function() body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((_TimerBranch<R>(d, body, tag: tag), if_));
    return this;
  }

  /// Generic "Arm" branch (enables sync selection & true immediacy).
  SelectBuilder<R> onArm<T>(
      Arm<T> Function() armFactory, FutureOr<R> Function(T) body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((ArmBranch<T, R>(armFactory, body, tag: tag), if_));
    return this;
  }

  /// Wait for a ticker to fire.
  ///
  /// Tickers provide recurring timer events. Use this for periodic operations,
  /// heartbeats, or any regular interval-based processing.
  ///
  /// **Parameters:**
  /// - [ticker]: Ticker instance to wait on
  /// - [body]: Function to call when the ticker fires
  /// - [tag]: Optional tag for debugging
  /// - [if_]: Optional guard condition
  ///
  /// **Example:**
  /// ```dart
  /// final heartbeat = Ticker.every(Duration(seconds: 5));
  /// final monitor = Ticker.every(Duration(minutes: 1));
  ///
  /// while (server.isRunning) {
  ///   final action = await XSelect.run<ServerAction>((s) => s
  ///     ..onRecvValue(requests, (req) => ServerAction.handleRequest(req))
  ///     ..onTick(heartbeat, () => ServerAction.heartbeat())
  ///     ..onTick(monitor, () => ServerAction.healthCheck())
  ///     ..timeout(Duration(minutes: 30), () => ServerAction.idleShutdown())
  ///   );
  ///
  ///   await server.processAction(action);
  /// }
  /// ```
  SelectBuilder<R> onTick(
    Ticker ticker,
    FutureOr<R> Function() body, {
    Object? tag,
    bool Function()? if_,
  }) {
    return onArm<void>(() => ticker.arm(), (_) => body(), tag: tag, if_: if_);
  }

  /// Add a global timeout to the entire selection.
  ///
  /// Unlike [delay] or [onDelay], this applies to the entire selection.
  /// If no other branch completes within the timeout duration, the timeout
  /// branch will fire and all other operations will be canceled.
  ///
  /// **Parameters:**
  /// - [d]: Duration before timeout
  /// - [body]: Function to call on timeout
  ///
  /// **Example:**
  /// ```dart
  /// // Network request with fallback
  /// final result = await XSelect.run<ApiResponse>((s) => s
  ///   ..onFuture(primaryApi(), (response) => response)
  ///   ..onFuture(secondaryApi(), (response) => response)
  ///   ..onFuture(cacheApi(), (response) => response)
  ///   ..timeout(Duration(seconds: 30), () => ApiResponse.timeout())
  /// );
  /// ```
  SelectBuilder<R> timeout(Duration d, FutureOr<R> Function() body) {
    _timeout = d;
    _onTimeout = body;
    return this;
  }

  /// Preserve declaration order instead of applying fairness rotation.
  ///
  /// By default, XSelect uses fairness rotation to prevent starvation.
  /// Call this method to evaluate branches in the order they were declared.
  ///
  /// **Example:**
  /// ```dart
  /// // Process high-priority channel first, then others
  /// await XSelect.run<String>((s) => s
  ///   ..onRecvValue(highPriority, (msg) => 'High: $msg')
  ///   ..onRecvValue(mediumPriority, (msg) => 'Medium: $msg')
  ///   ..onRecvValue(lowPriority, (msg) => 'Low: $msg')
  ///   ..ordered()  // Prioritize in declaration order
  /// );
  /// ```
  SelectBuilder<R> ordered() {
    _ordered = true;
    return this;
  }

  Future<R> run() {
    if (_branches.isEmpty) {
      throw StateError('Select requires at least one branch');
    }

    final completer = Completer<R>();
    final cancels = <Canceller>[];
    var resolved = false;

    void registerCanceller(Canceller c) => cancels.add(c);

    void resolve(int idx, Object? tag, FutureOr<R> res) {
      if (resolved) return;
      resolved = true;

      for (final cancel in cancels) {
        try {
          cancel();
        } catch (_) {}
      }

      Future.sync(() => res).then((v) {
        if (!completer.isCompleted) completer.complete(v);
      }).catchError((Object e, StackTrace? st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      });
    }

    // Apply optional guards
    final active = <_Branch<R>>[];
    for (final (b, guard) in _branches) {
      if (guard?.call() == false) continue;
      active.add(b);
    }

    if (active.isEmpty) {
      return Future.error(StateError('Select has no active branches'));
    }

    // Fairness: rotate starting offset unless ordered
    if (!_ordered && active.length > 1) {
      final n = active.length;
      final offset = DateTime.now().microsecondsSinceEpoch % n;
      if (offset != 0) {
        final rotated = <_Branch<R>>[
          ...active.skip(offset),
          ...active.take(offset),
        ];
        active
          ..clear()
          ..addAll(rotated);
      }
    }

    // Attach branches
    for (var i = 0; i < active.length; i++) {
      final immediate = active[i].attach(
        resolve: resolve,
        registerCanceller: registerCanceller,
        index: i,
      );
      if (immediate && resolved) return completer.future;
    }

    // Optional global timeout
    if (_timeout != null && _onTimeout != null) {
      final t = Timer(_timeout!, () => resolve(-1, 'timeout', _onTimeout!()));
      registerCanceller(() {
        if (t.isActive) t.cancel();
      });
    }

    return completer.future;
  }

  /// Synchronous fast-path over immediate arms only.
  R? syncRun() {
    if (_branches.isEmpty) {
      throw StateError('Select requires at least one branch');
    }

    for (final (b, guard) in _branches) {
      if (guard?.call() == false) continue;
      if (b is ArmBranch<dynamic, R>) {
        final a = b.armFactory();
        if (a is _ArmImmediate) {
          final v = (b.body)(a.value);
          // If the body returns a Future, this is not a true sync resolution.
          return v is Future ? null : v;
        }
      }
    }

    return null;
  }
}

/// Periodic ticker that exposes an `Arm<void>`:
/// - If `now >= nextAt` ⇒ `Arm.immediate` and `nextAt += period`.
/// - Otherwise ⇒ `Arm.pending` with a cancelable `Timer` until `nextAt`.
class Ticker {
  final Duration period;
  DateTime _nextAt;

  Ticker._(this.period, this._nextAt);

  /// Start a periodic ticker. By default the first tick is at `now + period`.
  factory Ticker.every(Duration period, {DateTime? startAt}) {
    final now = DateTime.now();
    return Ticker._(period, (startAt ?? now).add(period));
  }

  /// Return a selectable arm (immediate or pending).
  Arm<void> arm() {
    final now = DateTime.now();
    if (!now.isBefore(_nextAt)) {
      _nextAt = _nextAt.add(period);
      return Arm.immediate(null);
    }
    final delay = _nextAt.difference(now);
    final completer = Completer<void>();
    final t = Timer(delay, () {
      _nextAt = _nextAt.add(period);
      if (!completer.isCompleted) completer.complete();
    });
    return Arm.pending(completer.future, () {
      if (t.isActive) t.cancel();
    });
  }

  /// Reset the schedule (optional).
  void reset({DateTime? startAt}) {
    final now = DateTime.now();
    _nextAt = (startAt ?? now).add(period);
  }
}
