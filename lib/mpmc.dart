import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';
export 'src/buffers.dart' show DropPolicy, OnDrop;

/// MPMC (Multiple-Producer Multiple-Consumer) channels - Maximum flexibility for complex patterns.
///
/// The most general channel type supporting concurrent producers AND consumers.
/// Messages are distributed among consumers using competitive consumption - each
/// message is received by exactly one consumer (no broadcasting).
///
/// ## Core Characteristics
/// - **Multiple producers**: Thread-safe concurrent sending
/// - **Multiple consumers**: Competitive message consumption (not broadcast)
/// - **FIFO ordering**: Messages maintain send order across all consumers
/// - **Load balancing**: Work automatically distributed among available consumers
/// - **Full cloning**: Both senders and receivers can be cloned
/// - **Fair scheduling**: Consumers compete fairly for messages
///
/// ## When to Use MPMC
/// - **Worker pools**: Multiple producers → multiple worker consumers
/// - **Load balancing**: Distribute work across multiple processors
/// - **Pipeline stages**: Multi-stage processing with multiple workers per stage
/// - **Distributed systems**: Multiple clients → multiple servers
/// - **Parallel processing**: Fan-out work distribution patterns
/// - **Resource pools**: Multiple requesters → multiple resource providers
///
/// ## Important: Competitive Consumption
/// Unlike broadcast channels, each message goes to **exactly one consumer**.
/// This enables load balancing but means consumers compete for messages.
///
/// ## Performance Considerations
/// - **Coordination overhead**: Higher than MPSC due to consumer coordination
/// - **Producer throughput**: ~300-600ns per send (with consumer contention)
/// - **Consumer throughput**: ~100-300ns per receive (with coordination)
/// - **Scalability**: Performance may degrade with many consumers
/// - **Memory efficiency**: Shared buffer across all consumers
///
/// ## Usage Patterns
///
/// **Worker pool architecture:**
/// ```dart
/// // Create work distribution system
/// final (workTx, workRx) = Mpmc.bounded<Task>(capacity: 1000);
///
/// // Multiple job producers
/// final producers = <MpmcSender<Task>>[];
/// for (int i = 0; i < clientCount; i++) {
///   producers.add(workTx.clone());
/// }
///
/// // Multiple worker consumers
/// final workers = <MpmcReceiver<Task>>[];
/// for (int i = 0; i < workerCount; i++) {
///   workers.add(workRx.clone());
/// }
///
/// // Each producer submits work
/// for (final producer in producers) {
///   producer.send(Task('Process data $i'));
/// }
///
/// // Each worker competes for tasks
/// for (int i = 0; i < workerCount; i++) {
///   final worker = workers[i];
///   Thread.run(() async {
///     await for (final task in worker.stream()) {
///       await processTask(task); // Each task processed once
///     }
///   });
/// }
/// ```
///
/// **Pipeline with parallel stages:**
/// ```dart
/// // Stage 1: Data ingestion (1 producer → multiple preprocessors)
/// final (dataTx, dataRx) = Mpmc.unbounded<RawData>();
///
/// // Stage 2: Preprocessing (multiple → multiple)
/// final (processedTx, processedRx) = Mpmc.bounded<ProcessedData>(capacity: 500);
///
/// // Stage 3: Output (multiple → 1)
/// final (outputTx, outputRx) = Mpmc.latest<Result>();
///
/// // Multiple preprocessors compete for raw data
/// for (int i = 0; i < preprocessorCount; i++) {
///   final dataWorker = dataRx.clone();
///   final processedProducer = processedTx.clone();
///
///   Thread.run(() async {
///     await for (final raw in dataWorker.stream()) {
///       final processed = await preprocess(raw);
///       await processedProducer.send(processed);
///     }
///   });
/// }
///
/// // Multiple final processors compete for processed data
/// for (int i = 0; i < finalizerCount; i++) {
///   final processedWorker = processedRx.clone();
///   final resultProducer = outputTx.clone();
///
///   Thread.run(() async {
///     await for (final processed in processedWorker.stream()) {
///       final result = await finalize(processed);
///       await resultProducer.send(result);
///     }
///   });
/// }
/// ```
///
/// **Distributed request processing:**
/// ```dart
/// // Request distribution system
/// final (requestTx, requestRx) = Mpmc.channel<Request>(
///   capacity: 2000,
///   policy: DropPolicy.oldest, // Handle overload gracefully
/// );
///
/// // Multiple clients sending requests
/// for (final client in clients) {
///   final clientTx = requestTx.clone();
///   client.setRequestSender(clientTx);
/// }
///
/// // Multiple server instances processing requests
/// for (int i = 0; i < serverCount; i++) {
///   final serverRx = requestRx.clone();
///   servers[i] = RequestServer(serverRx);
///
///   Thread.run(() async {
///     await for (final request in serverRx.stream()) {
///       final response = await servers[i].handle(request);
///       await request.responseChannel.send(response);
///     }
///   });
/// }
/// ```
final class Mpmc {
  /// Creates an unbounded MPMC channel with unlimited capacity.
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
  /// final (eventTx, eventRx) = Mpmc.unbounded<LogEvent>();
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
  /// // Multiple consumer processes all events
  /// final eventRx0 = eventRx.clone();
  /// await for (final event in eventRx.stream()) {
  ///   await writeToLog(event);
  /// }
  /// ```
  static (MpmcSender<T>, MpmcReceiver<T>) unbounded<T>({bool chunked = true}) {
    final buf = chunked ? ChunkedBuffer<T>() : UnboundedBuffer<T>();
    final core = _MpmcCore<T>(buf);
    final tx = core.attachSender((c) => MpmcSender<T>._(c));
    final rx = core.attachReceiver((c) => MpmcReceiver._(c));
    return (tx, rx);
  }

  /// Creates a bounded MPMC channel with fixed capacity.
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
  /// final (taskTx, taskRx) = Mpmc.bounded<WorkItem>(capacity: 1000);
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
  /// final (tx, rx) = Mpmc.bounded<Message>(capacity: 0);
  ///
  /// // Producer waits for consumer to be ready
  /// await tx.send(message); // Blocks until consumer calls recv()
  /// ```
  static (MpmcSender<T>, MpmcReceiver<T>) bounded<T>(int capacity) {
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be >= 0');
    }

    final buf = (capacity == 0)
        ? RendezvousBuffer<T>()
        : BoundedBuffer<T>(capacity: capacity);
    final core = _MpmcCore<T>(buf);
    final tx = core.attachSender((c) => MpmcSender<T>._(c));
    final rx = core.attachReceiver((c) => MpmcReceiver._(c));
    return (tx, rx);
  }

  /// Creates an MPMC channel with advanced drop policies for backpressure handling.
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
  /// final (logTx, logRx) = Mpmc.channel<LogEntry>(
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
  /// final (dataTx, dataRx) = Mpmc.channel<SensorReading>(
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
  static (MpmcSender<T>, MpmcReceiver<T>) channel<T>({
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
    final core = _MpmcCore<T>(buf);
    final tx = core.attachSender((c) => MpmcSender<T>._(c));
    final rx = core.attachReceiver((c) => MpmcReceiver<T>._(c));
    return (tx, rx);
  }

  /// Creates a latest-only MPMC channel with competitive consumption.
  ///
  /// Only retains the most recent message, but with MPMC semantics:
  /// **exactly one consumer** will receive each update. This is competitive
  /// consumption, not broadcasting - multiple consumers compete for the latest value.
  ///
  /// **Important: This is NOT a broadcast cache!**
  /// Each update goes to exactly one consumer. If you need broadcasting,
  /// use multiple MPSC channels or implement your own broadcast layer.
  ///
  /// **Characteristics:**
  /// - **Latest-only storage**: Only the most recent value is kept
  /// - **Competitive consumption**: First consumer to recv() gets the value
  /// - **No queuing**: Rapid updates automatically coalesce
  /// - **Multi-producer**: Multiple threads can send concurrently
  /// - **Multi-consumer**: Multiple consumers compete for messages
  ///
  /// **Example - Distributed state updates:**
  /// ```dart
  /// final (statusTx, statusRx) = Mpmc.latest<SystemStatus>();
  ///
  /// // Multiple monitoring threads update status
  /// statusTx.send(SystemStatus(cpu: 45, memory: 60));
  /// statusTx.send(SystemStatus(cpu: 50, memory: 65)); // Overwrites previous
  ///
  /// // Multiple consumers compete for updates
  /// final consumer1 = statusRx.clone();
  /// final consumer2 = statusRx.clone();
  ///
  /// // Only ONE of these will get the latest status
  /// final status1Future = consumer1.recv(); // May get the value
  /// final status2Future = consumer2.recv(); // May get disconnected
  /// ```
  ///
  /// **Example - Load balancer with latest config:**
  /// ```dart
  /// final (configTx, configRx) = Mpmc.latest<LoadBalancerConfig>();
  ///
  /// // Config updates from admin
  /// configTx.send(LoadBalancerConfig(servers: newServerList));
  ///
  /// // Multiple load balancer instances compete for config
  /// for (int i = 0; i < balancerCount; i++) {
  ///   final balancerRx = configRx.clone();
  ///   Thread.run(() async {
  ///     await for (final config in balancerRx.stream()) {
  ///       // Only one balancer gets each config update
  ///       await updateBalancerConfig(config);
  ///     }
  ///   });
  /// }
  /// ```
  static (MpmcSender<T>, MpmcReceiver<T>) latest<T>() {
    final core = _MpmcCore<T>(LatestOnlyBuffer<T>());
    final tx = core.attachSender((c) => MpmcSender<T>._(c));
    final rx = core.attachReceiver((c) => MpmcReceiver<T>._(c));
    return (tx, rx);
  }
}

final class _MpmcCore<T> extends ChannelCore<T, _MpmcCore<T>> {
  _MpmcCore(this.buf);

  @override
  final ChannelBuffer<T> buf;

  @override
  bool get allowMultiSenders => true;
  @override
  bool get allowMultiReceivers => true;
}

/// Thread-safe sender for MPMC channels with full cloning support.
///
/// Enables multiple producers to send concurrently to multiple competing consumers.
/// Unlike MPSC senders, MPMC senders must coordinate with consumer competition,
/// which introduces additional overhead but enables more flexible architectures.
///
/// ## Thread Safety & Coordination
/// - **Multi-producer safe**: Multiple threads can send simultaneously
/// - **Consumer coordination**: Handles competition between multiple consumers
/// - **Clone safety**: [clone] creates independent sender handles safely
/// - **Reference counting**: Channel remains open while any sender exists
/// - **Fair sending**: No producer starvation under load
///
/// ## Performance Characteristics
/// - **Higher overhead**: More coordination than MPSC due to consumer competition
/// - **Scalable sending**: Performance degrades gracefully with producer count
/// - **Consumer contention**: Performance affected by number of competing consumers
/// - **Batching friendly**: Works well with batch sending extensions
///
/// **Example - Distributed request processing:**
/// ```dart
/// final (requestTx, requestRx) = Mpmc.bounded<WorkRequest>(capacity: 1000);
///
/// // Multiple client threads (producers)
/// final clientSenders = <MpmcSender<WorkRequest>>[];
/// for (int i = 0; i < clientThreads; i++) {
///   clientSenders.add(requestTx.clone());
/// }
/// requestTx.close(); // Close original handle
///
/// // Each client thread sends requests
/// for (int i = 0; i < clientThreads; i++) {
///   final clientId = i;
///   final sender = clientSenders[i];
///
///   Thread.run(() async {
///     while (clientActive[clientId]) {
///       final request = generateClientRequest(clientId);
///       await sender.send(request); // Thread-safe concurrent sending
///     }
///     sender.close(); // Client finished
///   });
/// }
/// ```
///
/// **Example - Multi-stage pipeline:**
/// ```dart
/// // Stage 1 → Stage 2 (multiple producers → multiple consumers)
/// final (stage2Tx, stage2Rx) = Mpmc.unbounded<IntermediateData>();
///
/// // Multiple stage-1 processors become stage-2 producers
/// final stage1Processors = <Thread>[];
/// for (int i = 0; i < stage1Count; i++) {
///   final producerTx = stage2Tx.clone();
///
///   stage1Processors.add(Thread(() async {
///     await for (final rawData in stage1Sources[i].stream()) {
///       final processed = await processStage1(rawData);
///       await producerTx.send(processed); // Feeds competing stage-2 consumers
///     }
///     producerTx.close();
///   }));
/// }
/// ```
final class MpmcSender<T> implements CloneableSender<T> {
  MpmcSender._(this._core);
  final _MpmcCore<T> _core;
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
  MpmcSender<T> clone() {
    if (_closed) throw StateError('Sender closed');
    return _core.attachSender((c) => MpmcSender<T>._(c));
  }
}

/// Multi-consumer receiver with competitive message consumption.
///
/// Competes with other receivers for messages in a fair, load-balancing manner.
/// Each message goes to exactly one consumer - this enables natural work distribution
/// but requires careful coordination between consumers.
///
/// ## Competitive Consumption Semantics
/// - **One winner per message**: Each message received by exactly one consumer
/// - **Fair competition**: No consumer starvation under normal conditions
/// - **Load balancing**: Work automatically distributed among active consumers
/// - **Clone independence**: Each cloned receiver competes independently
/// - **Stream single-use**: Each receiver's [stream] can only be used once
///
/// ## Coordination Overhead
/// - **Consumer synchronization**: Additional overhead compared to MPSC
/// - **Fair scheduling**: Prevents any single consumer from monopolizing
/// - **Graceful degradation**: Performance scales reasonably with consumer count
/// - **Memory efficiency**: Shared buffer across all competing consumers
///
/// ## Usage Guidelines
/// - **Worker pools**: Perfect for distributing work among multiple workers
/// - **Load balancing**: Natural distribution without explicit load balancer
/// - **Parallel processing**: Scale processing by adding more consumer instances
/// - **Resource pooling**: Multiple consumers can serve different resource types
///
/// **Example - Worker pool with competitive consumption:**
/// ```dart
/// final (workTx, workRx) = Mpmc.bounded<Task>(capacity: 1000);
///
/// // Create worker pool with competing consumers
/// final workers = <MpmcReceiver<Task>>[];
/// for (int i = 0; i < workerCount; i++) {
///   workers.add(workRx.clone());
/// }
/// workRx.close(); // Close original handle
///
/// // Each worker competes for tasks
/// for (int workerId = 0; workerId < workerCount; workerId++) {
///   final worker = workers[workerId];
///
///   Thread.run(() async {
///     await for (final task in worker.stream()) {
///       // Only this worker processes this task
///       final result = await processTask(task, workerId);
///       await task.resultChannel.send(result);
///     }
///   });
/// }
///
/// // Producers send work - automatically load balanced
/// for (final task in taskList) {
///   await workTx.send(task); // Goes to one available worker
/// }
/// ```
///
/// **Example - Multi-tier processing pipeline:**
/// ```dart
/// // Tier 2: Multiple consumers compete for processed data
/// final (tier2Tx, tier2Rx) = Mpmc.channel<ProcessedData>(capacity: 500);
///
/// // Multiple tier-2 processors (competing consumers)
/// final tier2Consumers = <MpmcReceiver<ProcessedData>>[];
/// for (int i = 0; i < tier2ProcessorCount; i++) {
///   tier2Consumers.add(tier2Rx.clone());
/// }
///
/// // Each tier-2 processor handles different data
/// for (int i = 0; i < tier2ProcessorCount; i++) {
///   final consumer = tier2Consumers[i];
///   final processorId = i;
///
///   Thread.run(() async {
///     await for (final data in consumer.stream()) {
///       // Competitive consumption - each data goes to one processor
///       final result = await processTier2(data, processorId);
///       await tier3Channel.send(result);
///     }
///   });
/// }
/// ```
///
/// **Example - Request handling with failover:**
/// ```dart
/// final (requestTx, requestRx) = Mpmc.unbounded<Request>();
///
/// // Multiple server instances (competing consumers)
/// final serverInstances = <ServerInstance>[];
/// for (int i = 0; i < serverCount; i++) {
///   final serverRx = requestRx.clone();
///   serverInstances.add(ServerInstance(serverRx, serverId: i));
///
///   Thread.run(() async {
///     try {
///       await for (final request in serverRx.stream()) {
///         // Only one server handles each request
///         final response = await serverInstances[i].handle(request);
///         await request.responseChannel.send(response);
///       }
///     } catch (e) {
///       // This server failed - others continue competing
///       logger.error('Server $i failed: $e');
///       serverRx.close();
///     }
///   });
/// }
/// ```
final class MpmcReceiver<T> implements CloneableReceiver<T> {
  MpmcReceiver._(this._core);
  final _MpmcCore<T> _core;
  bool _closed = false;
  bool _consumed = false;

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

  @pragma('vm:prefer-inline')
  @override
  MpmcReceiver<T> clone() {
    if (_closed) {
      throw StateError('Receiver closed');
    }
    return _core.attachReceiver((c) => MpmcReceiver._(c));
  }
}
