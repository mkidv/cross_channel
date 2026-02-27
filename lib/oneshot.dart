import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/result.dart';

export 'src/extensions.dart';
export 'src/result.dart';

/// A tuple representing a OneShot channel (Sender, Receiver).
typedef OneShotChannel<T> = (OneShotSender<T>, OneShotReceiver<T>);

/// One-shot channels
class OneShot {
  static OneShotChannel<T> channel<T>({
    bool consumeOnce = false,
    String? metricsId,
  }) {
    final core =
        _OneShotCore<T>(consumeOnce: consumeOnce, metricsId: metricsId);
    final tx = core.attachSender((c) => OneShotSender<T>._(c.id, c.sendPort));
    final rx =
        core.attachReceiver((c) => OneShotReceiver<T>._(c.id, c.sendPort));
    return (tx, rx);
  }
}

final class _OneShotCore<T> extends ChannelCore<T, _OneShotCore<T>> {
  _OneShotCore({required bool consumeOnce, super.metricsId})
      : buf = PromiseBuffer<T>(consumeOnce: consumeOnce);

  @override
  final PromiseBuffer<T> buf;

  @override
  bool get allowMultiSenders => false;
  @override
  bool get allowMultiReceivers => false;

  @override
  bool get sendDisconnected => buf.hasConsumed || !buf.isEmpty;
  @override
  bool get recvDisconnected => buf.hasConsumed && buf.isEmpty;

  @override
  bool get isSendClosed => sendDisconnected;
  @override
  bool get isRecvClosed => recvDisconnected;
}

final class OneShotSender<T> extends Sender<T> {
  OneShotSender._(this.channelId, this.remotePort);

  @override
  final int channelId;

  @override
  final PlatformPort remotePort;

  @override
  Future<SendResult> send(T value) async {
    if (localSendChannel case final lc?) return lc.send(value);

    // OneShot doesn't need backpressure, use fire-and-forget to avoid overhead
    remotePort.send(value);
    return const SendOk();
  }

  @override
  SendResult trySend(T value) {
    if (localSendChannel case final lc?) return lc.trySend(value);

    remotePort.send(value);
    return const SendOk();
  }
}

final class OneShotReceiver<T> extends Receiver<T> {
  OneShotReceiver._(this.channelId, this.remotePort);

  @override
  final int channelId;
  @override
  final PlatformPort remotePort;
}
