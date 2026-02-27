import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/result.dart';

export 'src/buffers.dart' show DropPolicy, OnDrop;
export 'src/extensions.dart';
export 'src/result.dart';

/// A tuple representing an MPMC channel (Sender, Receiver).
typedef MpmcChannel<T> = (MpmcSender<T>, MpmcReceiver<T>);

/// MPMC (Multiple-Producer Multiple-Consumer) channels
class Mpmc {
  static MpmcChannel<T> unbounded<T>({
    bool chunked = true,
    String? metricsId,
  }) {
    final buf = chunked ? ChunkedBuffer<T>() : UnboundedBuffer<T>();
    final core = StandardChannelCore<T>(
      buf,
      allowMultiSenders: true,
      allowMultiReceivers: true,
      metricsId: metricsId,
    );
    final tx = core.attachSender((c) => MpmcSender<T>._(c.id, c.sendPort, metricsId: c.metricsId));
    final rx =
        core.attachReceiver((c) => MpmcReceiver<T>._(c.id, c.sendPort, metricsId: c.metricsId));
    return (tx, rx);
  }

  static MpmcChannel<T> bounded<T>(int capacity, {String? metricsId}) {
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be >= 0');
    }

    final buf = (capacity == 0) ? RendezvousBuffer<T>() : BoundedBuffer<T>(capacity: capacity);
    final core = StandardChannelCore<T>(
      buf,
      allowMultiSenders: true,
      allowMultiReceivers: true,
      metricsId: metricsId,
    );
    final tx = core.attachSender((c) => MpmcSender<T>._(c.id, c.sendPort, metricsId: c.metricsId));
    final rx =
        core.attachReceiver((c) => MpmcReceiver<T>._(c.id, c.sendPort, metricsId: c.metricsId));
    return (tx, rx);
  }

  static MpmcChannel<T> channel<T>({
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
      allowMultiReceivers: true,
      metricsId: metricsId,
    );
    final tx = core.attachSender((c) => MpmcSender<T>._(c.id, c.sendPort, metricsId: c.metricsId));
    final rx =
        core.attachReceiver((c) => MpmcReceiver<T>._(c.id, c.sendPort, metricsId: c.metricsId));
    return (tx, rx);
  }

  static MpmcChannel<T> latest<T>({String? metricsId}) {
    final buf = LatestOnlyBuffer<T>();
    final core = StandardChannelCore<T>(
      buf,
      allowMultiSenders: true,
      allowMultiReceivers: true,
      metricsId: metricsId,
    );
    final tx = core.attachSender((c) => MpmcSender<T>._(c.id, c.sendPort, metricsId: c.metricsId));
    final rx =
        core.attachReceiver((c) => MpmcReceiver<T>._(c.id, c.sendPort, metricsId: c.metricsId));
    return (tx, rx);
  }
}

final class MpmcSender<T> extends Sender<T> implements CloneableSender<T> {
  MpmcSender._(this.channelId, this.remotePort, {this.metricsId});

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
      remoteConnection?.close();
    }
  }

  @pragma('vm:prefer-inline')
  @override
  MpmcSender<T> clone() {
    if (_closed) throw StateError('Sender closed');
    final local = ChannelRegistry.get(channelId);
    if (local is StandardChannelCore<T>) {
      return local.attachSender((c) => MpmcSender<T>._(c.id, c.sendPort, metricsId: c.metricsId));
    }
    return MpmcSender<T>._(channelId, remotePort, metricsId: metricsId);
  }
}

final class MpmcReceiver<T> extends Receiver<T> implements CloneableReceiver<T> {
  MpmcReceiver._(this.channelId, this.remotePort, {this.metricsId});

  @override
  final String? metricsId;

  @override
  final int channelId;
  @override
  final PlatformPort remotePort;

  bool _closed = false;
  bool _consumed = false;

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

  @pragma('vm:prefer-inline')
  @override
  MpmcReceiver<T> clone() {
    if (_closed) {
      throw StateError('Receiver closed');
    }
    final local = ChannelRegistry.get(channelId);
    if (local is StandardChannelCore<T>) {
      return local
          .attachReceiver((c) => MpmcReceiver<T>._(c.id, c.sendPort, metricsId: c.metricsId));
    }
    return MpmcReceiver<T>._(channelId, remotePort, metricsId: metricsId);
  }
}
