import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/mpmc.dart';
import 'package:cross_channel/oneshot.dart';
import 'package:cross_channel/spsc.dart';

export 'notify.dart';
export 'select.dart';
export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';
export 'src/buffers.dart' show DropPolicy, OnDrop;
export 'src/channel_type.dart';

/// High-level factory for creating channels with Rust-style concurrency primitives.
///
/// [XChannel] provides a unified API for creating different types of channels:
/// - **MPSC**: Multi-producer, single-consumer (task queues)
/// - **MPMC**: Multi-producer, multi-consumer (work-sharing pools)
/// - **SPSC**: Single-producer, single-consumer (ultra-low latency)
/// - **OneShot**: Single-value delivery (request/reply patterns)
///
/// ## Quick Start
///
/// ```dart
/// import 'package:cross_channel/cross_channel.dart';
///
/// // Task queue with backpressure
/// final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
///
/// // Producer
/// await tx.send('task 1');
///
/// // Consumer
/// await for (final task in rx.stream()) {
///   print('Processing: $task');
/// }
/// ```
///
/// ## Capacity Rules
/// - `capacity: null` → Unbounded channel (producers never block)
/// - `capacity: 0` → Rendezvous channel (direct handoff)
/// - `capacity: > 0` → Bounded channel with backpressure
///
/// ## Drop Policies (bounded channels only)
/// - [DropPolicy.block] → Default, senders wait when full
/// - [DropPolicy.oldest] → Drop oldest item to make room
/// - [DropPolicy.newest] → Drop incoming item
///
/// See individual factory methods for detailed examples.
final class XChannel {
  /// Creates an MPSC (Multi-Producer Single-Consumer) channel.
  ///
  /// Perfect for task queues, event processing, and async pipelines where
  /// multiple producers send work to a single consumer.
  ///
  /// **Parameters:**
  /// - [capacity]: Buffer size. `null` = unbounded, `0` = rendezvous, `>0` = bounded
  /// - [dropPolicy]: Behavior when buffer is full (bounded channels only)
  /// - [onDrop]: Optional callback invoked when items are dropped
  /// - [chunked]: Use optimized chunked buffer for hot paths (default: `true`)
  ///
  /// **Examples:**
  ///
  /// ```dart
  /// // Unbounded task queue
  /// final (tx, rx) = XChannel.mpsc<String>();
  ///
  /// // Bounded with backpressure
  /// final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
  ///
  /// // Sliding window (drop oldest)
  /// final (tx, rx) = XChannel.mpsc<String>(
  ///   capacity: 50,
  ///   dropPolicy: DropPolicy.oldest,
  ///   onDrop: (task) => print('Dropped: $task'),
  /// );
  ///
  /// // Rendezvous (direct handoff)
  /// final (tx, rx) = XChannel.mpsc<String>(capacity: 0);
  /// ```
  ///
  /// **Usage Pattern:**
  /// ```dart
  /// // Multiple producers
  /// final producer1 = () async {
  ///   await tx.send('task from producer 1');
  /// };
  /// final producer2 = () async {
  ///   await tx.send('task from producer 2');
  /// };
  ///
  /// // Single consumer
  /// final consumer = () async {
  ///   await for (final task in rx.stream()) {
  ///     // Process task
  ///   }
  /// };
  /// ```
  ///
  /// **See also:**
  /// - [XChannel.mpmc] for multi-consumer work distribution
  /// - [XChannel.spsc] for ultra-low latency single-producer scenarios
  /// - [XChannel.mpscLatest] for latest-only progress updates
  /// - [Mpsc.channel], [Mpsc.unbounded], [Mpsc.bounded] for low-level api
  static (MpscSender<T>, MpscReceiver<T>) mpsc<T>({
    int? capacity,
    DropPolicy policy = DropPolicy.block,
    OnDrop<T>? onDrop,
    bool chunked = true,
  }) =>
      Mpsc.channel<T>(
          capacity: capacity, policy: policy, onDrop: onDrop, chunked: chunked);

  /// Creates an MPMC (Multi-Producer Multi-Consumer) channel.
  ///
  /// Perfect for work-sharing pools where multiple producers send work
  /// and multiple consumers compete to process it (work-stealing pattern).
  /// **Note**: This is not a broadcast - each message is consumed by exactly one receiver.
  ///
  /// **Parameters:**
  /// - [capacity]: Buffer size. `null` = unbounded, `0` = rendezvous, `>0` = bounded
  /// - [dropPolicy]: Behavior when buffer is full (bounded channels only)
  /// - [onDrop]: Optional callback invoked when items are dropped
  /// - [chunked]: Use optimized chunked buffer for hot paths (default: `true`)
  ///
  /// **Examples:**
  ///
  /// ```dart
  /// // Worker pool with 3 competing consumers
  /// final (tx, rx0) = XChannel.mpmc<Job>(capacity: 100);
  /// final rx1 = rx0.clone();
  /// final rx2 = rx0.clone();
  ///
  /// // Multiple workers processing jobs
  /// Future<void> worker(int id, MpmcReceiver<Job> rx) async {
  ///   await for (final job in rx.stream()) {
  ///     print('Worker $id processing job');
  ///     await job.process();
  ///   }
  /// }
  ///
  /// // Start workers
  /// final workers = [
  ///   worker(0, rx0),
  ///   worker(1, rx1),
  ///   worker(2, rx2),
  /// ];
  /// ```
  ///
  /// **Key Differences from MPSC:**
  /// - Multiple consumers compete for messages (work-stealing)
  /// - Use [MpmcReceiver.clone] to create additional consumers
  /// - Each message consumed by exactly one receiver
  /// - Better for CPU-intensive workloads with multiple cores
  ///
  /// **See also:**
  /// - [XChannel.mpsc] for single-consumer scenarios
  /// - [XChannel.mpmcLatest] for competitive latest-only consumption
  /// - [Mpmc.channel], [Mpmc.unbounded], [Mpmc.bounded] for low-level api
  static (MpmcSender<T>, MpmcReceiver<T>) mpmc<T>({
    int? capacity,
    DropPolicy policy = DropPolicy.block,
    OnDrop<T>? onDrop,
    bool chunked = true,
  }) =>
      Mpmc.channel<T>(
          capacity: capacity, policy: policy, onDrop: onDrop, chunked: chunked);

  /// Creates a OneShot channel for single-value delivery patterns.
  ///
  /// Perfect for request/reply, promise-like behavior, and once-only signaling.
  /// Unlike other channels, OneShot is designed to carry exactly one value.
  ///
  /// **Parameters:**
  /// - [consumeOnce]: If `true`, first receiver consumes and disconnects others.
  ///   If `false`, all receivers observe the same value.
  ///
  /// **Examples:**
  ///
  /// ```dart
  /// // Request/reply pattern (consume once)
  /// final (tx, rx) = XChannel.oneshot<String>(consumeOnce: true);
  ///
  /// // Send reply
  /// await tx.send('response data');
  ///
  /// // First receiver gets the value
  /// final result = await rx.recv();
  /// print(result.valueOrNull); // 'response data'
  ///
  /// // Subsequent receivers get disconnected
  /// final result2 = await rx.recv();
  /// print(result2.isDisconnected); // true
  /// ```
  ///
  /// ```dart
  /// // Broadcast signal (multiple observers)
  /// final (tx, rx) = XChannel.oneshot<bool>(consumeOnce: false);
  ///
  /// // Multiple listeners can observe the same value
  /// final listener1 = rx.recv();
  /// final listener2 = rx.recv();
  ///
  /// await tx.send(true);
  ///
  /// print(await listener1); // RecvOk(true)
  /// print(await listener2); // RecvOk(true)
  /// ```
  ///
  /// **Use Cases:**
  /// - HTTP request/response patterns
  /// - Configuration loaded signals
  /// - Initialization complete notifications
  /// - Future-like async computations
  ///
  /// **See also:**
  /// - [XChannel.mpsc] for multi-value streaming
  /// - [Notify] for payload-free signaling
  /// - [OneShot.channel] for low-level api
  static (OneShotSender<T>, OneShotReceiver<T>) oneshot<T>({
    bool consumeOnce = false,
  }) {
    return OneShot.channel<T>(consumeOnce: consumeOnce);
  }

  /// Creates an SPSC (Single-Producer Single-Consumer) channel.
  ///
  /// Ultra-low latency channel using lock-free ring buffer. Perfect for
  /// high-frequency trading, game loops, or any hot path where performance is critical.
  /// **Capacity is automatically rounded up to the next power of 2.**
  ///
  /// **Parameters:**
  /// - [capacity]: Ring buffer size (will be rounded to next power of 2)
  ///
  /// **Examples:**
  ///
  /// ```dart
  /// // High-frequency data stream
  /// final (tx, rx) = XChannel.spsc<double>(capacity: 1024);
  ///
  /// // Producer (single thread/isolate)
  /// for (var i = 0; i < 1000000; i++) {
  ///   await tx.send(i * 0.1);
  /// }
  ///
  /// // Consumer (single thread/isolate)
  /// await for (final value in rx.stream()) {
  ///   processHighFrequencyData(value);
  /// }
  /// ```
  ///
  /// **Performance Notes:**
  /// - Fastest channel type (~1.8 Mops/s)
  /// - Lock-free implementation
  /// - Requires exactly one producer and one consumer
  /// - Ideal for inter-isolate communication
  ///
  /// **See also:**
  /// - [XChannel.mpsc] for multiple producers
  /// - [XChannel.mpmc] for multiple consumers
  /// - [Spsc.channel] for low-level api
  static (SpscSender<T>, SpscReceiver<T>) spsc<T>({required int capacity}) {
    return Spsc.channel<T>(capacity);
  }

  /// Creates a latest-only MPSC channel that coalesces values.
  ///
  /// Perfect for progress updates, sensor data, and UI signals where only
  /// the most recent value matters. New sends overwrite older ones.
  /// **Performance: ~135 Mops/s** - extremely fast due to coalescing.
  ///
  /// **Examples:**
  ///
  /// ```dart
  /// // Progress updates
  /// final (tx, rx) = XChannel.mpscLatest<double>();
  ///
  /// // Rapid progress updates (only latest matters)
  /// for (var i = 0; i <= 100; i++) {
  ///   tx.trySend(i / 100.0); // Non-blocking
  ///   // Intermediate values may be coalesced
  /// }
  ///
  /// // UI updates with latest progress
  /// await for (final progress in rx.stream()) {
  ///   updateProgressBar(progress);
  /// }
  /// ```
  ///
  /// **Use Cases:**
  /// - Progress bars and loading indicators
  /// - Sensor readings (temperature, GPS, etc.)
  /// - Game state updates
  /// - Real-time metrics
  ///
  /// **See also:**
  /// - [XChannel.mpmcLatest] for competitive consumption
  /// - [Mpsc.latest] for low-level api
  static (MpscSender<T>, MpscReceiver<T>) mpscLatest<T>() => Mpsc.latest<T>();

  /// Creates a latest-only MPMC channel with competitive consumption.
  ///
  /// Multiple consumers compete for the latest value. Unlike broadcast,
  /// only **one** consumer receives each update. Perfect for load balancing
  /// latest-only work across multiple workers.
  ///
  /// **Examples:**
  ///
  /// ```dart
  /// // Latest price updates distributed to workers
  /// final (tx, rx0) = XChannel.mpmcLatest<PriceUpdate>();
  /// final rx1 = rx0.clone();
  /// final rx2 = rx0.clone();
  ///
  /// // Workers compete for latest price updates
  /// Future<void> priceWorker(int id, MpmcReceiver<PriceUpdate> rx) async {
  ///   await for (final update in rx.stream()) {
  ///     print('Worker $id processing latest price: ${update.price}');
  ///   }
  /// }
  /// ```
  ///
  /// **Key Points:**
  /// - Only one consumer gets each update (competitive, not broadcast)
  /// - Extremely fast due to coalescing
  /// - Use [MpmcReceiver.clone] for additional workers
  ///
  /// **See also:**
  /// - [XChannel.mpscLatest] for single consumer
  /// - [Mpmc.latest] for low-level api
  static (MpmcSender<T>, MpmcReceiver<T>) mpmcLatest<T>() => Mpmc.latest<T>();
}
