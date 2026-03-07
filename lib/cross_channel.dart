import 'package:cross_channel/broadcast.dart';
import 'package:cross_channel/mpmc.dart';
import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/oneshot.dart';
import 'package:cross_channel/spsc.dart';

export 'broadcast.dart';
export 'mpmc.dart';
export 'mpsc.dart';
export 'notify.dart';
export 'oneshot.dart';
export 'select.dart';
export 'spsc.dart';
export 'src/buffers.dart' show DropPolicy, OnDrop;
export 'src/extensions.dart';
export 'src/result.dart';

/// High-level factory for creating channels with Rust-style concurrency primitives.
///
/// [XChannel] provides a unified API for creating different types of channels:
/// - **MPSC**: Multi-producer, single-consumer (task queues)
/// - **MPMC**: Multi-producer, multi-consumer (work-sharing pools)
/// - **SPSC**: Single-producer, single-consumer (ultra-low latency)
/// - **OneShot**: Single-value delivery (request/reply patterns)
/// - **Broadcast**: One-to-many communication (event bus)
///
/// **Usage:**
/// ```dart
/// import 'package:cross_channel/cross_channel.dart';
///
/// Future<void> main() async {
///   // 1. MPSC (Multi-Producer Single-Consumer)
///   final (mpscTx, _) = XChannel.mpsc<String>(capacity: 100);
///   await mpscTx.send('task');
///
///   // 2. MPMC (Multi-Producer Multi-Consumer) - cloned receivers
///   final (mpmcTx, mpmcRx0) = XChannel.mpmc<String>(capacity: 10);
///   final mpmcRx1 = mpmcRx0.clone();
///   print('Consumers: $mpmcRx0, $mpmcRx1');
///   await mpmcTx.send('work');
///
///   // 3. OneShot
///   final (oneTx, oneRx) = XChannel.oneshot<String>();
///   await oneTx.send('reply');
///   await oneRx.recv();
///
///   // 4. SPSC (Single-Producer Single-Consumer)
///   final (spscTx, _) = XChannel.spsc<int>(capacity: 1024);
///   await spscTx.send(42);
///
///   // 5. Broadcast
///   final (bcTx, bcAt) = XChannel.broadcast<String>(capacity: 128);
///   final sub = bcAt.subscribe(replay: 5);
///   print('Subscriber created: $sub');
///   await bcTx.send('announcement');
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
  /// - [policy]: Behavior when buffer is full (bounded channels only)
  /// - [onDrop]: Optional callback invoked when items are dropped
  /// - [chunked]: Use optimized chunked buffer for hot paths (default: `true`)
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (mpscTx, _) = XChannel.mpsc<String>(capacity: 100);
  ///   await mpscTx.send('task');
  /// }
  /// ```
  ///
  /// **See also:**
  /// - [XChannel.mpmc] for multi-consumer work distribution
  /// - [XChannel.spsc] for efficient single-producer scenarios
  /// - [XChannel.mpscLatest] for latest-only progress updates
  /// - [Mpsc.channel], [Mpsc.unbounded], [Mpsc.bounded] for low-level api
  static MpscChannel<T> mpsc<T>(
          {int? capacity,
          DropPolicy policy = DropPolicy.block,
          OnDrop<T>? onDrop,
          bool chunked = true,
          String? metricsId}) =>
      Mpsc.channel<T>(
          capacity: capacity,
          policy: policy,
          onDrop: onDrop,
          chunked: chunked,
          metricsId: metricsId);

  /// Creates an MPMC (Multi-Producer Multi-Consumer) channel.
  ///
  /// Perfect for work-sharing pools where multiple producers send work
  /// and multiple consumers compete to process it (work-stealing pattern).
  /// **Note**: This is not a broadcast - each message is consumed by exactly one receiver.
  ///
  /// **Parameters:**
  /// - [capacity]: Buffer size. `null` = unbounded, `0` = rendezvous, `>0` = bounded
  /// - [policy]: Behavior when buffer is full (bounded channels only)
  /// - [onDrop]: Optional callback invoked when items are dropped
  /// - [chunked]: Use optimized chunked buffer for hot paths (default: `true`)
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (mpmcTx, mpmcRx0) = XChannel.mpmc<String>(capacity: 10);
  ///   final mpmcRx1 = mpmcRx0.clone();
  ///   print('Consumers: $mpmcRx0, $mpmcRx1');
  ///   await mpmcTx.send('work');
  /// }
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
  static MpmcChannel<T> mpmc<T>(
          {int? capacity,
          DropPolicy policy = DropPolicy.block,
          OnDrop<T>? onDrop,
          bool chunked = true,
          String? metricsId}) =>
      Mpmc.channel<T>(
          capacity: capacity,
          policy: policy,
          onDrop: onDrop,
          chunked: chunked,
          metricsId: metricsId);

  /// Creates a OneShot channel for single-value delivery patterns.
  ///
  /// Perfect for request/reply, promise-like behavior, and once-only signaling.
  /// Unlike other channels, OneShot is designed to carry exactly one value.
  ///
  /// **Parameters:**
  /// - [consumeOnce]: If `true`, first receiver consumes and disconnects others.
  ///   If `false`, all receivers observe the same value.
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (oneTx, oneRx) = XChannel.oneshot<String>();
  ///   await oneTx.send('reply');
  ///   await oneRx.recv();
  /// }
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
  static OneShotChannel<T> oneshot<T>(
      {bool consumeOnce = false, String? metricsId}) {
    return OneShot.channel<T>(consumeOnce: consumeOnce, metricsId: metricsId);
  }

  /// Creates an SPSC (Single-Producer Single-Consumer) channel.
  ///
  /// Efficient channel using ring buffer design. Good for performance-sensitive
  /// scenarios where exactly one producer communicates with one consumer.
  /// **Capacity is automatically rounded up to the next power of 2.**
  ///
  /// **Parameters:**
  /// - [capacity]: Ring buffer size (will be rounded to next power of 2)
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (spscTx, _) = XChannel.spsc<int>(capacity: 1024);
  ///   await spscTx.send(42);
  /// }
  /// ```
  ///
  /// **Performance Notes:**
  /// - High-performance channel type (~1.76-1.80 Mops/s, see benchmarks)
  /// - Efficient implementation optimized for 1:1 communication
  /// - Requires exactly one producer and one consumer
  /// - Good for inter-isolate communication
  ///
  /// **See also:**
  /// - [XChannel.mpsc] for multiple producers
  /// - [XChannel.mpmc] for multiple consumers
  /// - [Spsc.channel] for low-level api
  static SpscChannel<T> spsc<T>({required int capacity, String? metricsId}) {
    return Spsc.channel<T>(capacity, metricsId: metricsId);
  }

  /// Creates a latest-only MPSC channel that coalesces values.
  ///
  /// Perfect for progress updates, sensor data, and UI signals where only
  /// the most recent value matters. New sends overwrite older ones.
  /// **Performance: ~135 Mops/s** - extremely fast due to coalescing.
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (tx, rx) = XChannel.mpscLatest<double>();
  ///
  ///   // New values overwrite pending ones
  ///   tx.trySend(0.5);
  ///   tx.trySend(1.0); // 0.5 is dropped if not yet received
  ///
  ///   final result = await rx.recv();
  ///   print('Latest progress: $result'); // Likely 1.0
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
  static MpscChannel<T> mpscLatest<T>({String? metricsId}) =>
      Mpsc.latest<T>(metricsId: metricsId);

  /// Creates a latest-only MPMC channel with competitive consumption.
  ///
  /// Multiple consumers compete for the latest value. Unlike broadcast,
  /// only **one** consumer receives each update. Perfect for load balancing
  /// latest-only work across multiple workers.
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (tx, rx0) = XChannel.mpmcLatest<String>();
  ///   final rx1 = rx0.clone();
  ///
  ///   tx.trySend('task');
  ///   // Only one of rx0 or rx1 will receive 'task'
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
  static MpmcChannel<T> mpmcLatest<T>({String? metricsId}) =>
      Mpmc.latest<T>(metricsId: metricsId);

  /// Creates a Broadcast channel for one-to-many communication.
  ///
  /// All subscribers receive all messages (if they keep up).
  /// Features **Ring Buffer** design with lag detection and **History Replay**.
  ///
  /// **Parameters:**
  /// - [capacity]: Buffer size (fixed, power of 2).
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (bcTx, bcAt) = XChannel.broadcast<String>(capacity: 128);
  ///   final sub = bcAt.subscribe(replay: 5);
  ///   print('Subscriber created: $sub');
  ///   await bcTx.send('announcement');
  /// }
  /// ```
  static BroadcastChannel<T> broadcast<T>(
      {required int capacity, String? metricsId}) {
    return Broadcast.channel<T>(capacity, metricsId: metricsId);
  }
}
