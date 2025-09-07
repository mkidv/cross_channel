import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';
export 'src/buffers.dart' show DropPolicy, OnDrop;

/// MPSC (Multiple-Producer Single-Consumer) channels - The workhorse of concurrent systems.
///
/// The most versatile channel type for fan-in patterns where multiple producers
/// send data to a single consumer. Combines thread-safety for concurrent producers
/// with single-consumer optimizations for maximum throughput.
///
/// ## Core Strengths
/// - **Thread-safe producers**: Multiple threads can send concurrently
/// - **Single-consumer optimization**: No consumer-side coordination overhead
/// - **Rich buffering strategies**: Unbounded, bounded, rendezvous, latest-only
/// - **Advanced drop policies**: Handle backpressure with oldest/newest dropping
/// - **Producer cloning**: Create multiple sender handles from one channel
/// - **Flexible capacity**: From 0 (rendezvous) to unlimited (unbounded)
///
/// ## When to Use MPSC
/// - **Event aggregation**: Multiple event sources → single event loop
/// - **Task queues**: Multiple workers → single dispatcher
/// - **Logging systems**: Multiple threads → single log writer
/// - **UI updates**: Multiple components → single UI thread
/// - **Data collection**: Multiple sensors → single processor
/// - **Request handling**: Multiple clients → single server
///
/// ## Performance Characteristics
/// - **Producer throughput**: ~200-500ns per send (multi-threaded)
/// - **Consumer throughput**: ~50-150ns per receive (single-threaded)
/// - **Memory efficient**: Chunked buffers for unbounded channels
/// - **Scalable**: Performance degrades gracefully with producer count
/// - **Cache-friendly**: Consumer-side optimizations for sequential access
///
/// ## Usage Patterns
///
/// **Event aggregation system:**
/// ```dart
/// // Multiple event sources feeding a single processor
/// final (eventTx, eventRx) = Mpsc.unbounded<AppEvent>();
///
/// // Multiple producers
/// final userTx = eventTx.clone();
/// final networkTx = eventTx.clone();
/// final systemTx = eventTx.clone();
///
/// // Producers
/// userTx.send(AppEvent.userClick(button));
/// networkTx.send(AppEvent.dataReceived(payload));
/// systemTx.send(AppEvent.lowMemory());
///
/// // Single event loop (consumer)
/// await for (final event in eventRx.stream()) {
///   await handleEvent(event);
/// }
/// ```
///
/// **High-throughput logging:**
/// ```dart
/// // Bounded with drop policy for reliability
/// final (logTx, logRx) = Mpsc.channel<LogEntry>(
///   capacity: 10000,
///   policy: DropPolicy.oldest, // Don't block on full buffer
///   onDrop: (entry) => _droppedLogs++,
/// );
///
/// // Multiple threads logging
/// logTx.send(LogEntry.info('Processing started'));
/// logTx.send(LogEntry.error('Database connection failed'));
///
/// // Single log writer
/// await for (final entry in logRx.stream()) {
///   await writeToFile(entry);
/// }
/// ```
///
/// **Real-time data processing:**
/// ```dart
/// // Latest-only for real-time updates
/// final (statusTx, statusRx) = Mpsc.latest<SystemStatus>();
///
/// // Multiple monitoring threads
/// statusTx.send(SystemStatus(cpu: 45, memory: 60));
/// statusTx.send(SystemStatus(cpu: 50, memory: 65)); // Overwrites previous
///
/// // UI updates (always gets latest state)
/// await for (final status in statusRx.stream()) {
///   updateUI(status);
/// }
/// ```
///
/// **Request-response pattern:**
/// ```dart
/// // Task queue with bounded capacity
/// final (taskTx, taskRx) = Mpsc.bounded<WorkItem>(capacity: 1000);
///
/// // Multiple client threads
/// for (int i = 0; i < clientCount; i++) {
///   final tx = taskTx.clone();
///   clients.add(Client(tx));
/// }
///
/// // Single worker thread
/// await for (final task in taskRx.stream()) {
///   final result = await processTask(task);
///   task.responseChannel.send(result);
/// }
/// ```
class Mpsc {
  /// Creates an unbounded MPSC channel with unlimited capacity.
  ///
  /// Producers never block - messages are queued indefinitely until consumed.
  /// Use when you need guaranteed delivery without backpressure.
  ///
  /// **Parameters:**
  /// - [chunked]: Use chunked buffer for better memory efficiency (recommended)
  ///
  /// **Memory characteristics:**
  /// - **Chunked buffer**: Allocates in 64-element chunks, cache-friendly
  /// - **Standard buffer**: Dynamic array with exponential growth
  /// - **Memory usage**: Grows with unconsumed message count
  ///
  /// **Example - Event collection:**
  /// ```dart
  /// final (eventTx, eventRx) = Mpsc.unbounded<LogEvent>();
  ///
  /// // Multiple threads can send without blocking
  /// void logInfo(String message) {
  ///   eventTx.send(LogEvent.info(message)); // Never blocks
  /// }
  ///
  /// void logError(String message, Object error) {
  ///   eventTx.send(LogEvent.error(message, error)); // Never blocks
  /// }
  ///
  /// // Single consumer processes all events
  /// await for (final event in eventRx.stream()) {
  ///   await writeToLog(event);
  /// }
  /// ```
  static (MpscSender<T>, MpscReceiver<T>) unbounded<T>({bool chunked = true}) {
    final buf = chunked ? ChunkedBuffer<T>() : UnboundedBuffer<T>();
    final core = _MpscCore<T>(buf);
    final tx = core.attachSender((c) => MpscSender<T>._(c));
    final rx = core.attachReceiver((c) => MpscReceiver<T>._(c));
    return (tx, rx);
  }

  /// Creates a bounded MPSC channel with fixed capacity.
  ///
  /// Producers may block when the buffer is full. Provides natural backpressure
  /// to prevent memory exhaustion in high-load scenarios.
  ///
  /// **Special cases:**
  /// - `capacity = 0`: Rendezvous channel (direct handoff)
  /// - `capacity > 0`: Fixed-size buffer with blocking on full
  ///
  /// **Parameters:**
  /// - [capacity]: Maximum number of messages to buffer (≥ 0)
  ///
  /// **Example - Task queue with backpressure:**
  /// ```dart
  /// // Limited work queue prevents memory exhaustion
  /// final (taskTx, taskRx) = Mpsc.bounded<WorkItem>(capacity: 1000);
  ///
  /// // Producers block when queue is full (natural backpressure)
  /// Future<void> submitTask(WorkItem task) async {
  ///   final result = await taskTx.send(task);
  ///   if (result is SendErrorDisconnected) {
  ///     throw StateError('Worker pool shut down');
  ///   }
  /// }
  ///
  /// // Consumer processes at sustainable rate
  /// await for (final task in taskRx.stream()) {
  ///   await processWorkItem(task);
  /// }
  /// ```
  ///
  /// **Example - Rendezvous (capacity = 0):**
  /// ```dart
  /// // Direct producer-consumer handoff
  /// final (tx, rx) = Mpsc.bounded<Message>(capacity: 0);
  ///
  /// // Producer waits for consumer to be ready
  /// await tx.send(message); // Blocks until consumer calls recv()
  /// ```
  static (MpscSender<T>, MpscReceiver<T>) bounded<T>(int capacity) {
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be >= 0');
    }

    final buf = (capacity == 0)
        ? RendezvousBuffer<T>()
        : BoundedBuffer<T>(capacity: capacity);
    final core = _MpscCore<T>(buf);
    final tx = core.attachSender((c) => MpscSender<T>._(c));
    final rx = core.attachReceiver((c) => MpscReceiver<T>._(c));
    return (tx, rx);
  }

  /// Creates an MPSC channel with advanced drop policies for backpressure handling.
  ///
  /// When the buffer fills up, different policies determine how to handle new messages:
  /// - `DropPolicy.block`: Block producers until space available (default)
  /// - `DropPolicy.oldest`: Drop oldest message to make room for new one
  /// - `DropPolicy.newest`: Drop incoming message (appears successful but discarded)
  ///
  /// **Parameters:**
  /// - [capacity]: Buffer size (null = unbounded, 0 = rendezvous)
  /// - [policy]: How to handle buffer overflow
  /// - [onDrop]: Optional callback when messages are dropped
  /// - [chunked]: Use chunked buffer for unbounded channels
  ///
  /// **Example - Reliable logging with overflow protection:**
  /// ```dart
  /// final (logTx, logRx) = Mpsc.channel<LogEntry>(
  ///   capacity: 10000,
  ///   policy: DropPolicy.oldest, // Keep recent logs
  ///   onDrop: (dropped) => print('Dropped log: ${dropped.message}'),
  /// );
  ///
  /// // High-volume logging won't block
  /// void logEvent(LogEntry entry) {
  ///   logTx.trySend(entry); // Never blocks, may drop oldest
  /// }
  ///
  /// // Log processor gets most recent entries
  /// await for (final entry in logRx.stream()) {
  ///   await persistLog(entry);
  /// }
  /// ```
  ///
  /// **Example - Real-time data with newest-drop:**
  /// ```dart
  /// final (dataTx, dataRx) = Mpsc.channel<SensorReading>(
  ///   capacity: 100,
  ///   policy: DropPolicy.newest, // Preserve existing data
  ///   onDrop: (reading) => _droppedCount++,
  /// );
  ///
  /// // Sensor updates won't block or disrupt processing
  /// void updateSensor(SensorReading reading) {
  ///   dataTx.trySend(reading); // May drop if consumer is slow
  /// }
  /// ```
  static (MpscSender<T>, MpscReceiver<T>) channel<T>({
    int? capacity,
    DropPolicy policy = DropPolicy.block,
    OnDrop<T>? onDrop,
    bool chunked = true,
  }) {
    final inner = capacity == null
        ? chunked
            ? ChunkedBuffer<T>()
            : UnboundedBuffer<T>()
        : (capacity == 0)
            ? RendezvousBuffer<T>()
            : BoundedBuffer<T>(capacity: capacity);
    final bool usePolicy =
        capacity != null && capacity > 0 && policy != DropPolicy.block;
    final ChannelBuffer<T> buf = usePolicy
        ? PolicyBufferWrapper<T>(inner, policy: policy, onDrop: onDrop)
        : inner;
    final core = _MpscCore<T>(buf);
    final tx = core.attachSender((c) => MpscSender<T>._(c));
    final rx = core.attachReceiver((c) => MpscReceiver<T>._(c));
    return (tx, rx);
  }

  /// Creates a latest-only MPSC channel for real-time state updates.
  ///
  /// Only retains the most recent message - each send overwrites the previous.
  /// Perfect for state updates, progress indicators, and real-time data where
  /// only the current value matters.
  ///
  /// **Characteristics:**
  /// - **Zero memory growth**: Buffer size is always 0 or 1
  /// - **No blocking**: Sends never block regardless of consumer speed
  /// - **Always current**: Consumer gets the latest state, never stale data
  /// - **Coalescing**: Rapid updates are automatically merged
  ///
  /// **Example - UI state updates:**
  /// ```dart
  /// final (statusTx, statusRx) = Mpsc.latest<AppState>();
  ///
  /// // Multiple components update state rapidly
  /// statusTx.send(AppState(loading: true));
  /// statusTx.send(AppState(loading: false, data: result)); // Overwrites previous
  /// statusTx.send(AppState(loading: false, data: newResult)); // Overwrites again
  ///
  /// // UI always gets current state, never outdated
  /// await for (final state in statusRx.stream()) {
  ///   rebuildUI(state); // Only called with latest state
  /// }
  /// ```
  ///
  /// **Example - Progress monitoring:**
  /// ```dart
  /// final (progressTx, progressRx) = Mpsc.latest<Progress>();
  ///
  /// // Background task reports progress frequently
  /// for (int i = 0; i <= 100; i++) {
  ///   await doWork();
  ///   progressTx.send(Progress(percent: i)); // Overwrites automatically
  /// }
  ///
  /// // UI shows smooth progress without lag
  /// await for (final progress in progressRx.stream()) {
  ///   updateProgressBar(progress.percent);
  /// }
  /// ```
  static (MpscSender<T>, MpscReceiver<T>) latest<T>() {
    final core = _MpscCore<T>(LatestOnlyBuffer<T>());
    final tx = core.attachSender((c) => MpscSender<T>._(c));
    final rx = core.attachReceiver((c) => MpscReceiver<T>._(c));
    return (tx, rx);
  }
}

final class _MpscCore<T> extends ChannelCore<T, _MpscCore<T>> {
  _MpscCore(this.buf);

  @override
  final ChannelBuffer<T> buf;

  @override
  bool get allowMultiSenders => true;
  @override
  bool get allowMultiReceivers => false;
}

/// Thread-safe sender for MPSC channels with cloning capability.
///
/// Allows multiple threads to send concurrently to a single consumer.
/// Senders can be cloned to create additional producer handles without
/// affecting the underlying channel.
///
/// ## Thread Safety
/// - **Concurrent sends**: Multiple threads can call [send] simultaneously
/// - **Clone safety**: [clone] can be called from any thread
/// - **Close coordination**: Channel disconnects when ALL senders close
/// - **State isolation**: Each sender tracks its own closed state
///
/// ## Lifecycle Management
/// - **Reference counting**: Channel stays open while any sender exists
/// - **Graceful shutdown**: Consumer receives [RecvErrorDisconnected] after last sender closes
/// - **Resource cleanup**: Automatic cleanup when all senders are dropped
///
/// **Example - Multi-threaded producer pool:**
/// ```dart
/// final (baseTx, rx) = Mpsc.unbounded<WorkItem>();
///
/// // Create producer pool
/// final producers = <MpscSender<WorkItem>>[];
/// for (int i = 0; i < threadCount; i++) {
///   producers.add(baseTx.clone());
/// }
/// baseTx.close(); // Close base sender
///
/// // Each thread gets its own sender
/// for (int i = 0; i < threadCount; i++) {
///   final tx = producers[i];
///   threads[i] = Thread(() async {
///     while (hasWork) {
///       await tx.send(generateWork());
///     }
///     tx.close(); // Each thread closes its sender
///   });
/// }
///
/// // Consumer receives from all producers
/// await for (final work in rx.stream()) {
///   await processWork(work);
/// } // Stream ends when all senders close
/// ```
final class MpscSender<T> implements CloneableSender<T> {
  MpscSender._(this._core);
  final _MpscCore<T> _core;
  bool _closed = false;

  @pragma('vm:prefer-inline')
  @override
  bool get isDisconnected => _core.sendDisconnected || _closed;

  @override
  Future<SendResult> send(T v) =>
      _closed ? Future.value(const SendErrorDisconnected()) : _core.send(v);

  @pragma('vm:prefer-inline')
  @override
  SendResult trySend(T v) =>
      _closed ? const SendErrorDisconnected() : _core.trySend(v);

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _core.dropSender();
  }

  @pragma('vm:prefer-inline')
  @override
  MpscSender<T> clone() {
    if (_closed) throw StateError('Sender closed');
    return _core.attachSender((c) => MpscSender<T>._(c));
  }
}

/// Single consumer for MPSC channels with optimized receive operations.
///
/// Receives messages from multiple producers in FIFO order. Optimized for
/// single-threaded consumption with minimal overhead.
///
/// ## Performance Characteristics
/// - **No consumer coordination**: Single consumer eliminates synchronization overhead
/// - **Sequential access**: Cache-friendly memory access patterns
/// - **Batching support**: [ReceiverDrainX] extensions for bulk operations
/// - **Stream integration**: Seamless async iteration support
///
/// ## Usage Guidelines
/// - **Single consumer only**: Only one thread should use this receiver
/// - **Single-subscription stream**: [stream] can only be called once
/// - **Graceful shutdown**: Monitor [isDisconnected] for end-of-data detection
/// - **Error handling**: Check [RecvResult] for different completion states
///
/// **Example - Event processing loop:**
/// ```dart
/// final (eventTx, eventRx) = Mpsc.unbounded<Event>();
///
/// // Event processing with different patterns
/// class EventProcessor {
///   Future<void> processEvents() async {
///     // Pattern 1: Stream-based (recommended)
///     await for (final event in eventRx.stream()) {
///       await handleEvent(event);
///     }
///
///     // Pattern 2: Manual loop with error handling
///     while (true) {
///       switch (await eventRx.recv()) {
///         case RecvOk(value: final event):
///           await handleEvent(event);
///         case RecvErrorDisconnected():
///           print('All producers finished');
///           return;
///         case RecvErrorTimeout():
///           print('Timeout waiting for events');
///           continue;
///       }
///     }
///   }
/// }
/// ```
///
/// **Example - Batch processing:**
/// ```dart
/// // Use drain extensions for efficient batch processing
/// final batch = <LogEntry>[];
/// await eventRx.drainInto(batch, maxItems: 100);
/// if (batch.isNotEmpty) {
///   await processBatch(batch);
/// }
/// ```
final class MpscReceiver<T> implements KeepAliveReceiver<T> {
  MpscReceiver._(this._core);
  final _MpscCore<T> _core;
  bool _consumed = false;
  bool _closed = false;

  @pragma('vm:prefer-inline')
  @override
  bool get isDisconnected => _core.recvDisconnected || _closed;

  @override
  Future<RecvResult<T>> recv() =>
      _closed ? Future.value(const RecvErrorDisconnected()) : _core.recv();

  @pragma('vm:prefer-inline')
  @override
  RecvResult<T> tryRecv() =>
      _closed ? const RecvErrorDisconnected() : _core.tryRecv();

  @override
  (Future<RecvResult<T>>, void Function()) recvCancelable() => _closed
      ? (Future.value(const RecvErrorDisconnected()), () => {})
      : _core.recvCancelable();

  @override
  Stream<T> stream() async* {
    if (_consumed) throw StateError('stream is single-subscription');
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
