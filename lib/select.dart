import 'dart:async';

import 'package:cross_channel/cross_channel.dart';
import 'package:cross_channel/src/branches.dart';
import 'package:cross_channel/src/core.dart';

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
///   ..onTimeout(Duration(seconds: 30), () => 'timeout_reached')
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
///     ..onTimeout(Duration(seconds: 5), () => Config.defaultConfig())
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
  /// - [onTimeout]: Optional global timeout for the entire selection
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
  ///         ..onTimeout(Duration(minutes: 5), () => 'idle_timeout')
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
    bool ordered = false,
  }) async {
    final b = SelectBuilder<R>();
    build(b);
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
    bool ordered = false,
  }) =>
      run<R>((b) {
        for (final c in competitors) {
          c(b);
        }
      }, ordered: ordered);

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
/// - [onTimeout] - Add timeout to the entire selection
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
///     ..onTick(Duration(days: 5), () => ProcessorAction.maintenance())
///
///     // API health checks
///     ..onFuture(healthCheck(), (status) => ProcessorAction.healthUpdate(status))
///
///     // Graceful shutdown on idle
///     ..onTimeout(Duration(minutes: 10), () => ProcessorAction.shutdown())
///   );
///
///   await processor.handleAction(action);
/// }
/// ```
class SelectBuilder<R> {
  final List<(SelectBranch<R> b, bool Function()? guard)> _branches = [];
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
  ///   ..onTimeout(Duration(seconds: 5), () => 'timeout')
  /// );
  /// ```
  /// **See also:**
  /// - [onFutureValue] - Only handle value
  /// - [onFutureError] - Only handle error
  SelectBuilder<R> onFuture<T>(Future<T> fut, FutureOr<R> Function(T) body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((FutureBranch<T, R>(fut, body, tag: tag), if_));
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
  /// **See also:**
  /// - [onFuture] - Parent
  /// - [onFutureError] - Only handle error
  SelectBuilder<R> onFutureValue<T>(Future<T> fut, FutureOr<R> Function(T) body,
      {Object? tag, bool Function()? if_}) {
    return onFuture<T>(fut.then((value) => value), body, tag: tag, if_: if_);
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
  ///   ..onTimeout(Duration(seconds: 30), () => 'timeout')
  /// );
  /// ```
  /// **See also:**
  /// - [onFuture] - Parent
  /// - [onFutureValue] - Only handle value
  SelectBuilder<R> onFutureError<T>(Future<T> fut, FutureOr<R> Function(Object error) body,
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
  ///   ..onTimeout(Duration(seconds: 30), () => 'No user activity')
  /// );
  /// ```
  /// **See also:**
  /// - [onStreamDone] - Only handle completion
  SelectBuilder<R> onStream<T>(Stream<T> stream, FutureOr<R> Function(T) body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((StreamBranch<T, R>(stream, body, tag: tag), if_));
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
  ///   ..onTimeout(Duration(minutes: 5), () => 'Stream timeout')
  /// );
  /// ```
  /// **See also:**
  /// - [onStream] - Handle full stream
  SelectBuilder<R> onStreamDone<T>(Stream<T> stream, FutureOr<R> Function() body,
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
  ///   ..onTimeout(Duration(minutes: 1), () => 'Task timeout')
  /// );
  /// ```
  ///
  /// **See also:**
  /// - [onRecvValue] - Only handle successful result
  /// - [onRecvError] - Only handle error result
  SelectBuilder<R> onRecv<T>(
    Receiver<T> rx,
    FutureOr<R> Function(RecvResult<T>) body, {
    Object? tag,
    bool Function()? if_,
  }) {
    _branches.add((RecvBranch<T, R>(rx, body, tag: tag), if_));
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
  ///   ..onTimeout(Duration(seconds: 10), () => 'No activity')
  /// );
  /// ```
  ///
  /// **See also:**
  /// - [onRecv] - Parent
  /// - [onRecvError] - Only handle error result
  SelectBuilder<R> onRecvValue<T>(Receiver<T> rx, FutureOr<R> Function(T) body,
      {Object? tag,
      FutureOr<R> Function(RecvError e)? onError,
      FutureOr<R> Function()? onDisconnected,
      bool Function()? if_}) {
    return onRecv<T>(rx, (result) {
      if (result.hasValue) {
        return body(result.value);
      }
      if (result.isDisconnected && onDisconnected != null) {
        return onDisconnected();
      }
      if (result.hasError && onError != null) {
        return onError(result.error);
      }
      return Future<R>.error(StateError('Unexpected RecvResult: $result'));
    }, tag: tag, if_: if_ ?? () => !rx.recvDisconnected);
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
  ///   ..onTimeout(Duration(minutes: 1), () => 'All systems normal')
  /// );
  /// ```
  ///
  /// **See also:**
  /// - [onRecv] - Parent
  /// - [onRecvValue] - Only handle successful result
  SelectBuilder<R> onRecvError<T>(Receiver<T> rx, FutureOr<R> Function(RecvError error) body,
      {Object? tag, bool Function()? if_}) {
    return onRecv<T>(rx, (result) {
      if (result.hasError) {
        return body(result.error);
      }
      return Future<R>.error(StateError('Unexpected RecvResult: $result'));
    }, tag: tag, if_: if_ ?? () => !rx.recvDisconnected);
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
  ///   ..onTimeout(Duration(seconds: 10), () => 'Send timeout')
  /// );
  /// ```
  SelectBuilder<R> onSend<T>(Sender<T> sender, T value, FutureOr<R> Function() body,
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
  /// - [onTimeout] - Global timeout for the entire selection
  /// - [onTick] - For recurring timer events
  SelectBuilder<R> onDelay(Duration d, FutureOr<R> Function() body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((TimerBranch<R>.once(d, body, tag: tag), if_));
    return this;
  }

  /// Wait for a ticker to fire.
  ///
  /// Tickers provide recurring timer events. Use this for periodic operations,
  /// heartbeats, or any regular interval-based processing.
  ///
  /// **Parameters:**
  /// - [d]: Duration period
  /// - [body]: Function to call when the ticker fires
  /// - [tag]: Optional tag for debugging
  /// - [if_]: Optional guard condition
  ///
  /// **Example:**
  /// ```dart
  ///
  /// while (server.isRunning) {
  ///   final action = await XSelect.run<ServerAction>((s) => s
  ///     ..onRecvValue(requests, (req) => ServerAction.handleRequest(req))
  ///     ..onTick(Duration(seconds: 5), () => ServerAction.heartbeat())
  ///     ..onTick(Duration(minutes: 1), () => ServerAction.healthCheck())
  ///     ..timeout(Duration(minutes: 30), () => ServerAction.idleShutdown())
  ///   );
  ///
  ///   await server.processAction(action);
  /// }
  /// ```
  ///
  /// **See also:**
  /// - [onDelay] - For fixed delayed branch
  SelectBuilder<R> onTick(
    Duration d,
    FutureOr<R> Function() body, {
    Object? tag,
    bool Function()? if_,
  }) {
    _branches.add((TimerBranch<R>.period(d, body, tag: tag), if_));
    return this;
  }

  /// Adds a branch that becomes ready when the given [Notify] is triggered.
  ///
  /// This is a **single-shot** arm: `XSelect.run` will wait until one branch
  /// fires, then return the callback result. If another branch wins the race,
  /// this arm is canceled and the internal waiter is torn down, so there are no
  /// stale subscriptions.
  ///
  /// Usage (single-shot select, re-armed by your own loop):
  /// ```dart
  /// final stop = Notify();
  /// var running = true;
  /// while (running) {
  ///   final broke = await XSelect.run<bool>((s) => s
  ///     ..onNotify(stop, () {
  ///       // handle signal
  ///       return true; // end this select round
  ///     })
  ///     ..onTick<void>(Duration(milliseconds : 100), (_) => false) // any other arms...
  ///   );
  ///   if (broke == true) running = false; // you decide outside the select
  /// }
  /// ```
  /// **See also:**
  /// - [onFuture] - Parent
  SelectBuilder<R> onNotify(
    Notify notify,
    FutureOr<R> Function() action, {
    Object? tag,
    bool Function()? if_,
  }) {
    return onFuture<void>(
      // Arm with a fresh waiter for this single-shot select round.
      notify.notified().$1,
      (_) => action(),
      tag: tag,
      if_: if_,
    );
  }

  /// Adds a branch that listens to [Notify] but only **once** in the lifetime
  /// of this builder instance (useful for one-shot shutdown signals).
  ///
  /// Note: since `XSelect.run` is single-shot, “once” here simply gates
  /// arming when you re-create the builder in a loop; after the first trigger,
  /// the arm won’t be armed again (until you reset your own flag).
  ///
  /// **See also:**
  /// - [onNotify] - Parent
  SelectBuilder<R> onNotifyOnce(
    Notify notify,
    FutureOr<R> Function() action, {
    Object? tag,
    bool Function()? if_,
  }) {
    var consumed = false;
    return onNotify(
      notify,
      () {
        // Mark consumed on first trigger.
        consumed = true;
        return action();
      },
      tag: tag,
      if_: () {
        if (consumed) return false; // do not arm again
        return if_ == null ? true : if_();
      },
    );
  }

  /// Add a global timeout to the entire selection.
  ///
  /// Unlike [onDelay], this applies to the entire selection.
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
  ///   ..onTimeout(Duration(seconds: 30), () => ApiResponse.timeout())
  /// );
  /// ```
  SelectBuilder<R> onTimeout(Duration d, FutureOr<R> Function() body) {
    _branches.add((TimerBranch<R>.once(d, body, tag: 'timeout'), null));
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
    final active = <SelectBranch<R>>[];
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
        final rotated = <SelectBranch<R>>[
          ...active.skip(offset),
          ...active.take(offset),
        ];
        active
          ..clear()
          ..addAll(rotated);
      }
    }

    // Fast path sync
    for (var i = 0; i < active.length; i++) {
      final hit = active[i].attachSync(resolve: resolve, index: i);
      if (hit && resolved) return completer.future;
    }

    // Attach branches
    for (var i = 0; i < active.length; i++) {
      active[i].attach(
        resolve: resolve,
        registerCanceller: registerCanceller,
        index: i,
      );
      if (resolved) return completer.future;
    }

    return completer.future;
  }

  /// Synchronous fast-path over attachSync only.
  R? syncRun() {
    if (_branches.isEmpty) {
      throw StateError('Select requires at least one branch');
    }

    // Filtrer guards
    final active = <SelectBranch<R>>[];
    for (final (b, g) in _branches) {
      if (g?.call() != false) active.add(b);
    }
    if (active.isEmpty) return null;

    // Fairness
    if (!_ordered && active.length > 1) {
      final n = active.length;
      final offset = DateTime.now().microsecondsSinceEpoch % n;
      final rotated = <SelectBranch<R>>[...active.skip(offset), ...active.take(offset)];
      active
        ..clear()
        ..addAll(rotated);
    }

    R? out;
    var done = false;

    void resolve(int i, Object? tag, FutureOr<R> v) {
      if (done) return;
      if (v is Future) return;
      done = true;
      out = v;
    }

    for (var i = 0; i < active.length; i++) {
      if (active[i].attachSync(resolve: resolve, index: i) && done) {
        return out;
      }
    }

    return null;
  }
}
