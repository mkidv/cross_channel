import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/result.dart';

export 'src/buffers.dart' show DropPolicy, OnDrop;
export 'src/extensions.dart';
export 'src/result.dart';

/// A tuple representing a Broadcast channel (Sender, SubscriberFactory).
///
/// This is the **low-level** flavor of Broadcast channels.
/// Use [XChannel.broadcast] for a higher-level factory API.
typedef BroadcastChannel<T> = (BroadcastSender<T>, Broadcast<T>);

/// **Broadcast (Single-Producer Multi-Consumer) Ring Channel**
///
/// Features:
/// - **Pub/Sub**: All subscribers see all messages (subject to capacity).
/// - **Ring Buffer**: Fixed capacity power-of-two buffer. Oldest messages are overwritten.
/// - **Lag Detection**: Slow subscribers detect gaps and can skip lost data.
/// - **Replay**: New subscribers can "replay" history by starting from the tail.
///
/// Best suited for:
/// - High-frequency local event buses (UI events, telemetry).
/// - Scenarios where slow consumers should not block the producer.
///
/// ## Example
/// {@tool snippet example/broadcast_example.dart}
/// {@end-tool}
final class Broadcast<T> {
  final BroadcastRing<T> _buffer;
  final int _channelId;

  Broadcast._(this._buffer, this._channelId);

  /// Creates a Broadcast channel with a fixed [capacity] (must be power-of-two).
  ///
  /// Returns a tuple `(sender, broadcast)`. Use `broadcast.subscribe()` to create receivers.
  static BroadcastChannel<T> channel<T>(int capacity, {String? metricsId}) {
    final buffer = BroadcastRing<T>(capacity);
    final core = StandardChannelCore<T>(
      buffer,
      allowMultiSenders: false,
      allowMultiReceivers: true,
      metricsId: metricsId,
    );
    final tx = core.attachSender(
        (c) => BroadcastSender<T>._(c.id, c.createRemotePort(), metricsId: c.metricsId));
    final broadcast = Broadcast<T>._(buffer, core.id);
    return (tx, broadcast);
  }

  /// Creates a new subscriber.
  ///
  /// If [replay] is 0 (default), the subscriber starts reading from the *next* message sent.
  /// If [replay] > 0, the subscriber attempts to read up to [replay] past messages (if still available).
  BroadcastReceiver<T> subscribe({int replay = 0}) {
    final core = ChannelRegistry.get(_channelId)! as StandardChannelCore<T>;
    return core.attachReceiver((c) => BroadcastReceiver<T>._(
        c.id, c.createRemotePort(), _buffer, replay,
        metricsId: c.metricsId));
  }
}

final class BroadcastSender<T> extends Sender<T> implements KeepAliveSender<T> {
  BroadcastSender._(this.channelId, this.remotePort, {this.metricsId});

  /// Reconstructs a remote-only sender from a transferable representation.
  factory BroadcastSender.fromTransferable(Map<String, Object?> data) =>
      BroadcastSender._(-1, unpackPort(data['port']!), metricsId: data['metricsId'] as String?);

  @override
  final int channelId;
  @override
  final PlatformPort remotePort;
  @override
  final String? metricsId;

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
      if (local.buf is BroadcastRing<T>) {
        (local.buf as BroadcastRing<T>).close();
      }
      local.dropSender();
    } else {
      // Remote close
      remoteConnection?.close();
    }
  }
}

final class BroadcastReceiver<T> extends Receiver<T> implements KeepAliveReceiver<T> {
  BroadcastReceiver._(this.channelId, this.remotePort, BroadcastRing<T> buffer, int replay,
      {this.metricsId}) {
    // Initialize cursor in the buffer.
    // Note: We don't store [buffer] to allow BroadcastReceiver to be sent across Isolates.
    // Ideally, the cursor itself should be sendable (it is).
    _cursor = buffer.addSubscriber(replay);
  }

  /// Reconstructs a remote-only receiver from a transferable representation.
  ///
  /// The receiver connects via the remote path and receives messages through
  /// the proxy loop on the [ChannelCore] side.
  BroadcastReceiver._remote(this.channelId, this.remotePort, {this.metricsId});

  /// Reconstructs a remote-only receiver from a transferable representation.
  factory BroadcastReceiver.fromTransferable(Map<String, Object?> data) =>
      BroadcastReceiver._remote(-1, unpackPort(data['port']!),
          metricsId: data['metricsId'] as String?);

  @override
  final int channelId;
  @override
  final PlatformPort remotePort;
  @override
  final String? metricsId;

  /// Opaque cursor handle managed by the buffer.
  /// Null for remote-only receivers (no local buffer).
  Object? _cursor;

  bool _closed = false;

  @pragma('vm:prefer-inline')
  @override
  bool get isRecvClosed => _closed;

  @override
  Stream<T> stream() async* {
    while (true) {
      switch (await recv()) {
        case RecvOk<T>(value: final v):
          yield v;
        case RecvError(isDisconnected: true):
          return;
        default:
          // Ignore other errors (like empty/timeout if they were to happen)
          break;
      }
    }
  }

  /// Tries to receive the next item from the subscription.
  ///
  /// Returns [RecvOk] on success.
  /// Returns [RecvError] if disconnected.
  // Note: Broadcast receivers typically don't fail, but can be disconnected if the sender closes.
  @override
  Future<RecvResult<T>> recv() async {
    final lc = localRecvChannel;
    if (lc != null) {
      // Local fast path: access buffer directly
      final ring = lc.buf as BroadcastRing<T>;
      final t0 = mx.startRecvTimer();
      final res = await ring.receive(_cursor!);
      if (res.hasValue) {
        mx.recvOk(t0);
      }
      return res;
    }
    // Remote path
    return super.recv();
  }

  @override
  RecvResult<T> tryRecv() {
    final lc = localRecvChannel;
    if (lc != null) {
      final ring = lc.buf as BroadcastRing<T>;
      final t0 = mx.startRecvTimer();
      final res = ring.tryReceive(_cursor!);
      if (res.hasValue) {
        mx.tryRecvOk(t0);
      } else if (res.isEmpty) {
        mx.tryRecvEmpty();
      }
      return res;
    }
    return super.tryRecv();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;

    final lc = localRecvChannel;
    if (lc != null) {
      (lc.buf as BroadcastRing<T>).removeSubscriber(_cursor!);
    }

    closeRemote();
    final local = ChannelRegistry.get(channelId);
    if (local != null) {
      local.dropReceiver();
    }
  }
}
