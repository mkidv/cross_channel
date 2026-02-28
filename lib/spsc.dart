import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/result.dart';

export 'src/buffers.dart' show DropPolicy, OnDrop;
export 'src/extensions.dart';
export 'src/result.dart';

/// A tuple representing an SPSC channel (Sender, Receiver).
typedef SpscChannel<T> = (SpscSender<T>, SpscReceiver<T>);

/// SPSC (Single-Producer Single-Consumer) channels - Efficient direct communication.
///
/// A high-performance channel type in cross_channel. Optimized for scenarios
/// where exactly one producer communicates with exactly one consumer. Uses efficient
/// algorithms and data structures to minimize overhead.
///
/// ## Performance Characteristics
/// - **Good performance**: Efficient message passing, typically ~550-570ns per operation
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
/// ## Example
/// {@tool snippet example/spsc_example.dart}
/// {@end-tool}
final class Spsc {
  static (SpscSender<T>, SpscReceiver<T>) unbounded<T>({
    bool chunked = true,
    String? metricsId,
  }) {
    final buf = chunked ? ChunkedBuffer<T>() : UnboundedBuffer<T>();
    final core = StandardChannelCore<T>(
      buf,
      allowMultiSenders: false,
      allowMultiReceivers: false,
      metricsId: metricsId,
    );
    final tx = core.attachSender((c) => SpscSender<T>._(c.id, c.createRemotePort()));
    final rx = core.attachReceiver((c) => SpscReceiver<T>._(c.id, c.createRemotePort()));
    return (tx, rx);
  }

  static (SpscSender<T>, SpscReceiver<T>) bounded<T>(int capacity, {String? metricsId}) {
    final core = StandardChannelCore<T>(
      SrswBuffer<T>(capacity),
      allowMultiSenders: false,
      allowMultiReceivers: false,
      metricsId: metricsId,
    );
    final tx = core.attachSender((c) => SpscSender<T>._(c.id, c.createRemotePort()));
    final rx = core.attachReceiver((c) => SpscReceiver<T>._(c.id, c.createRemotePort()));
    return (tx, rx);
  }

  static SpscChannel<T> channel<T>(int capacity, {String? metricsId}) {
    final core = StandardChannelCore<T>(
      SrswBuffer<T>(capacity),
      allowMultiSenders: false,
      allowMultiReceivers: false,
      metricsId: metricsId,
    );
    final tx = core.attachSender((c) => SpscSender<T>._(c.id, c.createRemotePort()));
    final rx = core.attachReceiver((c) => SpscReceiver<T>._(c.id, c.createRemotePort()));
    return (tx, rx);
  }
}

final class SpscSender<T> extends Sender<T> implements KeepAliveSender<T> {
  SpscSender._(this.channelId, this.remotePort);

  /// Reconstructs a remote-only sender from a transferable representation.
  ///
  /// Use with [toTransferable] to transfer a sender across Web Workers
  /// or Isolates. The reconstructed sender always uses the remote path.
  factory SpscSender.fromTransferable(Map<String, Object?> data) =>
      SpscSender._(-1, unpackPort(data['port']!));

  @override
  final int channelId;
  @override
  final PlatformPort remotePort;

  bool _closed = false;

  @pragma('vm:prefer-inline')
  @override
  bool get isSendClosed => _closed;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final local = ChannelRegistry.get(channelId);
    if (local != null) {
      local.dropSender();
    } else {
      remoteConnection?.close();
    }
  }
}

final class SpscReceiver<T> extends Receiver<T> implements KeepAliveReceiver<T> {
  SpscReceiver._(this.channelId, this.remotePort);

  /// Reconstructs a remote-only receiver from a transferable representation.
  ///
  /// Use with [toTransferable] to transfer a receiver across Web Workers
  /// or Isolates. The reconstructed receiver always uses the remote path.
  factory SpscReceiver.fromTransferable(Map<String, Object?> data) =>
      SpscReceiver._(-1, unpackPort(data['port']!));

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
    if (_consumed) throw StateError('Receiver.stream() is single-subscription');
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
