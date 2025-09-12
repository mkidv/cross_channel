import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';

/// One-shot channels - Promise-like single-value delivery with advanced semantics.
///
/// Specialized channels for delivering exactly one value, similar to futures but
/// with more flexible consumption patterns. Perfect for request-response scenarios,
/// async initialization, and promise-like patterns.
///
/// ## Core Features
/// - **Single-value semantics**: Exactly one value can be sent
/// - **Flexible consumption**: Choose between consume-once or multi-reader patterns
/// - **Promise-like behavior**: Similar to futures but with channel semantics
/// - **Type-safe results**: Explicit success/failure handling
/// - **Zero buffering**: Direct producer-to-consumer handoff
///
/// ## Consumption Modes
///
/// ### `consumeOnce: true` (Default Promise Behavior)
/// - First receiver gets the value and consumes it
/// - Channel disconnects immediately after consumption
/// - Subsequent receivers get `RecvErrorDisconnected`
/// - Perfect for request-response patterns
///
/// ### `consumeOnce: false` (Broadcast Promise)
/// - All receivers (current and future) get the same value
/// - Value remains available until explicitly handled
/// - Multiple receivers can read the same result
/// - Perfect for initialization values or shared results
///
/// ## When to Use OneShot
/// - **Request-response patterns**: Client sends request, waits for single response
/// - **Async initialization**: Wait for setup completion across multiple components
/// - **Result broadcasting**: Share a computed result with multiple consumers
/// - **Promise coordination**: Advanced promise-like patterns with explicit control
/// - **Resource resolution**: Resolve a resource once, use many times
/// - **Configuration loading**: Load config once, access from multiple places
///
/// ## Performance Characteristics
/// - **Lightweight**: Minimal memory footprint (single value storage)
/// - **Efficient delivery**: Direct value handoff for single-value scenarios
/// - **Good performance**: ~381-390ns per operation (see benchmarks)
/// - **Simple storage**: Single memory location for value storage
///
/// ## Usage Patterns
///
/// **Request-response (consumeOnce: true):**
/// ```dart
/// // Client-server request pattern
/// Future<ApiResponse> makeRequest(ApiRequest request) async {
///   final (responseTx, responseRx) = OneShot.channel<ApiResponse>(consumeOnce: true);
///
///   // Send request with response channel
///   await requestChannel.send(RequestWithResponse(request, responseTx));
///
///   // Wait for single response
///   final result = await responseRx.recv();
///   return switch (result) {
///     RecvOk(value: final response) => response,
///     RecvErrorDisconnected() => throw TimeoutException('Server disconnected'),
///     _ => throw StateError('Unexpected result: $result'),
///   };
/// }
///
/// // Server side
/// await for (final requestWithResponse in requestChannel.stream()) {
///   final response = await processRequest(requestWithResponse.request);
///   await requestWithResponse.responseTx.send(response); // Consumed by one client
/// }
/// ```
///
/// **Shared initialization (consumeOnce: false):**
/// ```dart
/// // Global configuration initialization
/// class ConfigManager {
///   static final (configTx, configRx) = OneShot.channel<AppConfig>(consumeOnce: false);
///   static bool _initialized = false;
///
///   static Future<void> initialize() async {
///     if (_initialized) return;
///     _initialized = true;
///
///     final config = await loadConfigFromServer();
///     await configTx.send(config); // Available to all readers
///   }
///
///   static Future<AppConfig> getConfig() async {
///     final result = await configRx.recv();
///     return result.valueOrNull!; // Same config for all callers
///   }
/// }
///
/// // Multiple components can access the same config
/// final userConfig = await ConfigManager.getConfig();
/// final dbConfig = await ConfigManager.getConfig(); // Same instance
/// ```
///
/// **Resource resolution pattern:**
/// ```dart
/// // Database connection pool initialization
/// class DatabasePool {
///   final (poolTx, poolRx) = OneShot.channel<ConnectionPool>(consumeOnce: false);
///
///   Future<void> initializePool() async {
///     final pool = await ConnectionPool.create(
///       maxConnections: 10,
///       connectionString: connectionString,
///     );
///     await poolTx.send(pool); // Available to all consumers
///   }
///
///   Future<Connection> getConnection() async {
///     final result = await poolRx.recv();
///     final pool = result.valueOrNull!;
///     return await pool.getConnection();
///   }
/// }
/// ```
///
/// **Advanced promise coordination:**
/// ```dart
/// // Coordinated async operations
/// class AsyncOperationCoordinator {
///   final operations = <String, OneShot>{};
///
///   (OneShotSender<T>, OneShotReceiver<T>) createOperation<T>(String name, {bool shared = false}) {
///     final (tx, rx) = OneShot.channel<T>(consumeOnce: !shared);
///     operations[name] = (tx, rx);
///     return (tx, rx);
///   }
///
///   Future<T> waitForOperation<T>(String name) async {
///     final (_, rx) = operations[name] as (OneShotSender<T>, OneShotReceiver<T>);
///     final result = await rx.recv();
///     return result.valueOrNull!;
///   }
/// }
/// ```
class OneShot {
  /// Creates a one-shot channel for single-value delivery.
  ///
  /// **Parameters:**
  /// - [consumeOnce]: If `true`, first receiver consumes and disconnects channel.
  ///                 If `false`, all receivers get the same value (broadcast).
  ///
  /// **Returns:** Tuple of (sender, receiver) for promise-like communication
  ///
  /// **Consumption behaviors:**
  /// - `consumeOnce: false` (default): All receivers get the value
  /// - `consumeOnce: true`: Only first receiver gets the value, others disconnected
  ///
  /// **Example - Request-response:**
  /// ```dart
  /// final (responseTx, responseRx) = OneShot.channel<String>(consumeOnce: true);
  ///
  /// // Send single response
  /// await responseTx.send('Operation completed');
  ///
  /// // Only one receiver gets it
  /// final result = await responseRx.recv();
  /// print(result.valueOrNull); // 'Operation completed'
  /// ```
  ///
  /// **Example - Shared resource:**
  /// ```dart
  /// final (configTx, configRx) = OneShot.channel<Config>(consumeOnce: false);
  ///
  /// // Initialize once
  /// await configTx.send(loadedConfig);
  ///
  /// // Multiple consumers can access
  /// final config1 = (await configRx.recv()).valueOrNull;
  /// final config2 = (await configRx.recv()).valueOrNull; // Same config
  /// ```
  static (OneShotSender<T>, OneShotReceiver<T>) channel<T>(
      {bool consumeOnce = false, String? metricsId}) {
    final core =
        _OneShotCore<T>(consumeOnce: consumeOnce, metricsId: metricsId);
    final tx = core.attachSender((c) => OneShotSender<T>._(c));
    final rx = core.attachReceiver((c) => OneShotReceiver<T>._(c));
    return (tx, rx);
  }
}

final class _OneShotCore<T> extends ChannelCore<T, _OneShotCore<T>> {
  _OneShotCore({required bool consumeOnce, super.metricsId})
      : buf = PromiseBuffer<T>(consumeOnce: consumeOnce);

  @override
  final PromiseBuffer<T> buf;

  @override
  bool get allowMultiSenders => false;
  @override
  bool get allowMultiReceivers => false;

  @override
  bool get sendDisconnected => buf.hasConsumed || !buf.isEmpty;
  @override
  bool get recvDisconnected => (buf.hasConsumed && buf.isEmpty);
}

/// Promise-like sender for one-shot channels.
///
/// Can send exactly one value, after which the channel becomes unavailable
/// for further sends. Perfect for promise resolution patterns.
///
/// **Characteristics:**
/// - **Single-send**: Only one [send] call succeeds
/// - **Direct delivery**: Value delivered to waiting receivers
/// - **Auto-disconnect**: Channel disconnects after successful send
/// - **Type-safe**: Compile-time guarantees about value delivery
///
/// **Example:**
/// ```dart
/// final (promiseTx, promiseRx) = OneShot.channel<Result>();
///
/// // Promise resolution
/// Future<void> resolvePromise() async {
///   final result = await computeExpensiveResult();
///
///   // This succeeds
///   final sendResult = await promiseTx.send(result);
///   assert(sendResult is SendOk);
///
///   // This fails - already sent
///   final secondSend = promiseTx.trySend(anotherResult);
///   assert(secondSend is SendErrorDisconnected);
/// }
/// ```
final class OneShotSender<T> implements Sender<T> {
  OneShotSender._(this._core);
  final _OneShotCore<T> _core;

  @pragma('vm:prefer-inline')
  @override
  bool get isDisconnected => _core.sendDisconnected;

  @override
  Future<SendResult> send(T value) async => _core.send(value);

  @pragma('vm:prefer-inline')
  @override
  SendResult trySend(T value) => _core.trySend(value);
}

/// Promise-like receiver for one-shot channels.
///
/// Receives exactly one value based on the channel's consumption mode.
/// Provides promise-like waiting semantics with explicit result types.
///
/// **Consumption modes:**
/// - **consumeOnce: true**: First recv() gets value, subsequent calls get disconnected
/// - **consumeOnce: false**: All recv() calls get the same value
///
/// **Example - Single consumption:**
/// ```dart
/// final (tx, rx) = OneShot.channel<String>(consumeOnce: true);
/// await tx.send('hello');
///
/// final result1 = await rx.recv(); // Gets 'hello'
/// final result2 = await rx.recv(); // Gets RecvErrorDisconnected
/// ```
///
/// **Example - Multiple consumption:**
/// ```dart
/// final (tx, rx) = OneShot.channel<Config>(consumeOnce: false);
/// await tx.send(config);
///
/// final config1 = await rx.recv(); // Gets config
/// final config2 = await rx.recv(); // Gets same config
/// ```
final class OneShotReceiver<T> implements Receiver<T> {
  OneShotReceiver._(this._core);
  final _OneShotCore<T> _core;

  @pragma('vm:prefer-inline')
  @override
  bool get isDisconnected => _core.recvDisconnected;

  @override
  Future<RecvResult<T>> recv() => _core.recv();

  @pragma('vm:prefer-inline')
  @override
  RecvResult<T> tryRecv() => _core.tryRecv();

  @override
  (Future<RecvResult<T>>, void Function()) recvCancelable() =>
      _core.recvCancelable();
}
