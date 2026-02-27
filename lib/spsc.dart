import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/result.dart';

export 'src/buffers.dart' show DropPolicy, OnDrop;
export 'src/extensions.dart';
export 'src/result.dart';

/// A tuple representing an SPSC channel (Sender, Receiver).
typedef SpscChannel<T> = (SpscSender<T>, SpscReceiver<T>);

/// SPSC (Single-Producer Single-Consumer) channels
final class Spsc {
  static SpscChannel<T> channel<T>(int capacity, {String? metricsId}) {
    final core = StandardChannelCore<T>(
      SrswBuffer<T>(capacity),
      allowMultiSenders: false,
      allowMultiReceivers: false,
      metricsId: metricsId,
    );
    final tx = core.attachSender((c) => SpscSender<T>._(c.id, c.sendPort));
    final rx = core.attachReceiver((c) => SpscReceiver<T>._(c.id, c.sendPort));
    return (tx, rx);
  }
}

final class SpscSender<T> extends Sender<T> implements KeepAliveSender<T> {
  SpscSender._(this.channelId, this.remotePort);

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

final class SpscReceiver<T> extends Receiver<T>
    implements KeepAliveReceiver<T> {
  SpscReceiver._(this.channelId, this.remotePort);

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
