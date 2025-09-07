import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';

/// SPSC (Single-Producer Single-Consumer) channels - Efficient direct communication.
///
/// A high-performance channel type in cross_channel. Optimized for scenarios
/// where exactly one producer communicates with exactly one consumer. Uses efficient
/// algorithms and data structures to minimize overhead.
///
/// ## Performance Characteristics
/// - **Good performance**: Efficient message passing, typically ~550-570ns per operation (see benchmarks)
/// - **Minimal allocations**: Optimized to reduce garbage collection pressure
/// - **Efficient design**: Designed to avoid contention in the hot path
/// - **Ring buffer**: Uses power-of-two sized SRSW (Single-Reader Single-Writer) ring buffer
///
/// ## When to Use SPSC
/// - Performance-sensitive producer-consumer scenarios
/// - Data streaming between two components
/// - Game logic (e.g., main thread ↔ render thread communication)
/// - Sensor data processing
/// - Any scenario requiring efficient 1:1 communication
///
/// ## Constraints
/// **EXACTLY one producer and one consumer required**
/// - Violation leads to undefined behavior and potential data corruption
/// - Use [XChannel.mpsc] for multiple producers
/// - Use [XChannel.mpmc] for multiple producers and consumers
///
/// ## Usage Patterns
///
/// **High-frequency data streaming:**
/// ```dart
/// // Audio processing pipeline
/// final (tx, rx) = Spsc.channel<AudioSample>(capacity: 4096);
///
/// // Producer (audio thread)
/// void audioCallback(AudioSample sample) {
///   final result = tx.trySend(sample);
///   if (result is SendErrorFull) {
///     // Buffer overrun - critical!
///     handleBufferOverrun();
///   }
/// }
///
/// // Consumer (processing thread)
/// await for (final sample in rx.stream()) {
///   processAudioSample(sample);
/// }
/// ```
///
/// **Game engine messaging:**
/// ```dart
/// // Main thread → Render thread
/// final (renderCommands, renderRx) = Spsc.channel<RenderCommand>(capacity: 1024);
///
/// // Main thread
/// void updateGame() {
///   final cmd = RenderCommand.drawSprite(sprite, position);
///   await renderCommands.send(cmd);
/// }
///
/// // Render thread
/// while (engine.running) {
///   switch (await renderRx.recv()) {
///     case RecvOk(value: final cmd):
///       executeRenderCommand(cmd);
///     case RecvErrorDisconnected():
///       break; // Shutdown
///   }
/// }
/// ```
///
/// **IoT sensor pipeline:**
/// ```dart
/// // Sensor → Processing
/// final (sensorTx, sensorRx) = Spsc.channel<SensorReading>(capacity: 2048);
///
/// // High-frequency sensor (producer)
/// Timer.periodic(Duration(microseconds: 100), (timer) {
///   final reading = SensorReading.now();
///   sensorTx.trySend(reading); // Non-blocking
/// });
///
/// // Batch processor (consumer)
/// final batch = <SensorReading>[];
/// await for (final reading in sensorRx.stream()) {
///   batch.add(reading);
///   if (batch.length >= 100) {
///     await processBatch(batch);
///     batch.clear();
///   }
/// }
/// ```
final class Spsc {
  /// Creates an SPSC channel with the specified buffer capacity.
  ///
  /// **Parameters:**
  /// - [capacity]: Buffer size (rounded up to next power-of-two internally)
  ///
  /// **Returns:** A tuple of (sender, receiver) for 1:1 communication
  ///
  /// **Performance Notes:**
  /// - Capacity should be a power-of-two for optimal performance
  /// - Larger buffers reduce contention but increase memory usage
  /// - Typical values: 256-8192 for high-frequency scenarios
  ///
  /// **Example:**
  /// ```dart
  /// final (tx, rx) = Spsc.channel<int>(capacity: 1024);
  ///
  /// // Producer
  /// for (int i = 0; i < 1000000; i++) {
  ///   await tx.send(i);
  /// }
  ///
  /// // Consumer
  /// await for (final value in rx.stream()) {
  ///   print('Received: $value');
  /// }
  /// ```
  static (SpscSender<T>, SpscReceiver<T>) channel<T>(int capacity) {
    final core = _SpscCore<T>(SrswBuffer<T>(capacity));
    final tx = core.attachSender((c) => SpscSender<T>._(c));
    final rx = core.attachReceiver((c) => SpscReceiver<T>._(c));
    return (tx, rx);
  }
}

final class _SpscCore<T> extends ChannelCore<T, _SpscCore<T>> {
  _SpscCore(this.buf);
  @override
  final ChannelBuffer<T> buf;

  @override
  bool get allowMultiSenders => false;
  @override
  bool get allowMultiReceivers => false;
}

/// Efficient sender for SPSC channels.
///
/// Provides optimized message sending for single-producer scenarios.
/// Designed for good performance and throughput.
///
/// ## Performance Optimizations
/// - **Efficient operations**: Optimized communication path
/// - **Memory-friendly design**: Minimizes unnecessary overheads
/// - **Optimized paths**: Core operations streamlined for performance
///
/// ## Usage Guidelines
/// - **Only ONE thread** should use this sender instance
/// - Use [trySend] for non-blocking operations in time-critical paths
/// - Use [send] when you can afford to wait for buffer space
/// - Monitor [isDisconnected] for graceful shutdown detection
///
/// **Example - High-frequency producer:**
/// ```dart
/// final (tx, rx) = Spsc.channel<double>(capacity: 8192);
///
/// // Time-critical producer loop
/// void produceData() {
///   while (running) {
///     final data = generateData();
///
///     // Non-blocking send for real-time systems
///     final result = tx.trySend(data);
///     if (result is SendErrorFull) {
///       // Handle backpressure - critical decision point
///       onBufferFull(data);
///     }
///   }
/// }
/// ```
final class SpscSender<T> implements KeepAliveSender<T> {
  SpscSender._(this._core);
  final _SpscCore<T> _core;
  bool _closed = false;

  @pragma('vm:prefer-inline')
  @override
  bool get isDisconnected => _core.sendDisconnected || _closed;

  @override
  Future<SendResult> send(T v) =>
      _closed ? Future.value(const SendErrorDisconnected()) : _core.send(v);

  @override
  SendResult trySend(T v) =>
      _closed ? const SendErrorDisconnected() : _core.trySend(v);

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _core.dropSender();
  }
}

/// Efficient receiver for SPSC channels.
///
/// Provides optimized message receiving for single-consumer scenarios.
/// Designed for good performance and throughput.
///
/// ## Performance Optimizations
/// - **Efficient operations**: Optimized communication path
/// - **Memory-friendly design**: Minimizes unnecessary overheads
/// - **Single-subscription streams**: No overhead from multi-consumer coordination
///
/// ## Usage Guidelines
/// - **Only ONE thread** should use this receiver instance
/// - Use [tryRecv] for polling in time-critical scenarios
/// - Use [recv] for blocking receives when timing is flexible
/// - Use [stream] for convenient async iteration (single-use only)
/// - Monitor [isDisconnected] for end-of-stream detection
///
/// **Example - High-frequency consumer:**
/// ```dart
/// final (tx, rx) = Spsc.channel<DataPoint>(capacity: 4096);
///
/// // Low-latency consumer loop
/// void consumeData() async {
///   while (running) {
///     switch (await rx.recv()) {
///       case RecvOk(value: final data):
///         // Process immediately - no queuing
///         await processDataPoint(data);
///
///       case RecvErrorDisconnected():
///         print('Producer finished');
///         return;
///
///       case RecvErrorEmpty():
///         // Impossible with recv() - only from tryRecv()
///         break;
///     }
///   }
/// }
///
/// // Alternative: Stream-based consumption
/// await for (final data in rx.stream()) {
///   await processDataPoint(data);
/// }
/// ```
final class SpscReceiver<T> implements KeepAliveReceiver<T> {
  SpscReceiver._(this._core);
  final _SpscCore<T> _core;
  bool _closed = false;
  bool _consumed = false;

  @pragma('vm:prefer-inline')
  @override
  bool get isDisconnected => _core.recvDisconnected || _closed;

  @override
  Future<RecvResult<T>> recv() =>
      _closed ? Future.value(const RecvErrorDisconnected()) : _core.recv();

  @override
  RecvResult<T> tryRecv() =>
      _closed ? const RecvErrorDisconnected() : _core.tryRecv();

  @override
  (Future<RecvResult<T>>, void Function()) recvCancelable() => _closed
      ? (Future.value(const RecvErrorDisconnected()), () => {})
      : _core.recvCancelable();

  @override
  Stream<T> stream() async* {
    if (_consumed) throw StateError('Receiver.stream() is single-subscription');
    _consumed = true;
    while (true) {
      switch (await _core.recv()) {
        case RecvOk<T>(value: final v):
          yield v;
        case RecvError():
          return;
      }
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _core.dropReceiver();
  }
}
