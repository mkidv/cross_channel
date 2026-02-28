import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/result.dart';

export 'src/buffers.dart' show DropPolicy, OnDrop;
export 'src/extensions.dart';
export 'src/result.dart';

/// A tuple representing an MPSC channel (Sender, Receiver).
typedef MpscChannel<T> = (MpscSender<T>, MpscReceiver<T>);

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
/// - **Event aggregation**: Multiple event sources ↔ single event loop
/// - **Task queues**: Multiple workers ↔ single dispatcher
/// - **Logging systems**: Multiple threads ↔ single log writer
/// - **UI updates**: Multiple components ↔ single UI thread
/// - **Data collection**: Multiple sensors ↔ single processor
/// - **Request handling**: Multiple clients ↔ single server
///
/// ## Performance Characteristics
/// - **Good throughput**: ~535-950ns per operation
/// - **Latest-only mode**: Extremely fast ~7ns per operation for coalescing buffers
/// - **Memory efficient**: Chunked buffers available for unbounded channels
/// - **Scalable**: Designed to handle multiple concurrent producers
/// - **Efficient design**: Optimized for producer-consumer scenarios
///
/// ## Example
/// {@tool snippet example/mpsc_example.dart}
/// {@end-tool}
class Mpsc {
  static MpscChannel<T> unbounded<T>({
    bool chunked = true,
    String? metricsId,
  }) {
    final buf = chunked ? ChunkedBuffer<T>() : UnboundedBuffer<T>();
    final core = StandardChannelCore<T>(
      buf,
      allowMultiSenders: true,
      allowMultiReceivers: false,
      metricsId: metricsId,
    );
    final tx = core
        .attachSender((c) => MpscSender<T>._(c.id, c.createRemotePort(), metricsId: c.metricsId));
    final rx = core.attachReceiver(
        (c) => MpscReceiver<T>._(c.id, c.createRemotePort(), metricsId: c.metricsId));
    return (tx, rx);
  }

  static MpscChannel<T> bounded<T>(int capacity, {String? metricsId}) {
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be >= 0');
    }

    final buf = (capacity == 0) ? RendezvousBuffer<T>() : BoundedBuffer<T>(capacity: capacity);
    final core = StandardChannelCore<T>(
      buf,
      allowMultiSenders: true,
      allowMultiReceivers: false,
      metricsId: metricsId,
    );
    final tx = core
        .attachSender((c) => MpscSender<T>._(c.id, c.createRemotePort(), metricsId: c.metricsId));
    final rx = core.attachReceiver(
        (c) => MpscReceiver<T>._(c.id, c.createRemotePort(), metricsId: c.metricsId));
    return (tx, rx);
  }

  static MpscChannel<T> channel<T>({
    int? capacity,
    DropPolicy policy = DropPolicy.block,
    OnDrop<T>? onDrop,
    bool chunked = true,
    String? metricsId,
  }) {
    final inner = capacity == null
        ? chunked
            ? ChunkedBuffer<T>()
            : UnboundedBuffer<T>()
        : (capacity == 0)
            ? RendezvousBuffer<T>()
            : BoundedBuffer<T>(capacity: capacity);
    final bool usePolicy = capacity != null && capacity > 0 && policy != DropPolicy.block;
    final ChannelBuffer<T> buf =
        usePolicy ? PolicyBufferWrapper<T>(inner, policy: policy, onDrop: onDrop) : inner;
    final core = StandardChannelCore<T>(
      buf,
      allowMultiSenders: true,
      allowMultiReceivers: false,
      metricsId: metricsId,
    );
    final tx = core
        .attachSender((c) => MpscSender<T>._(c.id, c.createRemotePort(), metricsId: c.metricsId));
    final rx = core.attachReceiver(
        (c) => MpscReceiver<T>._(c.id, c.createRemotePort(), metricsId: c.metricsId));
    return (tx, rx);
  }

  static MpscChannel<T> latest<T>({String? metricsId}) {
    final buf = LatestOnlyBuffer<T>();
    final core = StandardChannelCore<T>(
      buf,
      allowMultiSenders: true,
      allowMultiReceivers: false,
      metricsId: metricsId,
    );
    final tx = core
        .attachSender((c) => MpscSender<T>._(c.id, c.createRemotePort(), metricsId: c.metricsId));
    final rx = core.attachReceiver(
        (c) => MpscReceiver<T>._(c.id, c.createRemotePort(), metricsId: c.metricsId));
    return (tx, rx);
  }
}

final class MpscSender<T> extends Sender<T> implements CloneableSender<T> {
  MpscSender._(this.channelId, this.remotePort, {this.metricsId});

  /// Reconstructs a remote-only sender from a transferable representation.
  ///
  /// Use with [toTransferable] to transfer a sender across Web Workers
  /// or Isolates. The reconstructed sender always uses the remote path.
  factory MpscSender.fromTransferable(Map<String, Object?> data) =>
      MpscSender._(-1, unpackPort(data['port']!), metricsId: data['metricsId'] as String?);

  @override
  final String? metricsId;

  @override
  final int channelId;
  @override
  final PlatformPort remotePort;

  @pragma('vm:prefer-inline')
  @override
  bool get isSendClosed => _closed;

  bool _closed = false;

  @override
  void close() {
    if (_closed) return;
    _closed = true;

    final local = ChannelRegistry.get(channelId);
    if (local != null) {
      local.dropSender();
    } else {
      // Remote close via Expando
      final conn = remoteConnection;
      conn?.close();
    }
  }

  @pragma('vm:prefer-inline')
  @override
  MpscSender<T> clone() {
    if (_closed) throw StateError('Sender closed');
    final local = ChannelRegistry.get(channelId);
    if (local is StandardChannelCore<T>) {
      return local
          .attachSender((c) => MpscSender<T>._(c.id, c.createRemotePort(), metricsId: c.metricsId));
    }
    return MpscSender<T>._(channelId, remotePort, metricsId: metricsId);
  }
}

final class MpscReceiver<T> extends Receiver<T> implements KeepAliveReceiver<T> {
  MpscReceiver._(this.channelId, this.remotePort, {this.metricsId});

  /// Reconstructs a remote-only receiver from a transferable representation.
  ///
  /// Use with [toTransferable] to transfer a receiver across Web Workers
  /// or Isolates. The reconstructed receiver always uses the remote path.
  factory MpscReceiver.fromTransferable(Map<String, Object?> data) =>
      MpscReceiver._(-1, unpackPort(data['port']!), metricsId: data['metricsId'] as String?);

  @override
  final String? metricsId;

  @override
  final int channelId;
  @override
  final PlatformPort remotePort;

  bool _consumed = false;
  bool _closed = false;

  @pragma('vm:prefer-inline')
  @override
  bool get isRecvClosed => _closed;

  @override
  Stream<T> stream() async* {
    if (_consumed) throw StateError('stream is single-subscription');
    _consumed = true;

    while (true) {
      switch (await recv()) {
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
    closeRemote();
    final local = ChannelRegistry.get(channelId);
    if (local != null) {
      local.dropReceiver();
    }
  }
}
