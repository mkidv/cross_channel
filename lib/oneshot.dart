import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';

/// One-shot channel for delivering a single value.
///
/// - If `consumeOnce == true`: the first receiver consumes the value and the
///   channel disconnects immediately.
/// - If `consumeOnce == false`: all current/future receivers observe the same
///   value (no disconnection until explicitly treated by higher layers).
///
class OneShot {
  static (OneShotSender<T>, OneShotReceiver<T>) channel<T>({
    bool consumeOnce = false,
  }) {
    final core = _OneShotCore<T>(consumeOnce: consumeOnce);
    final tx = core.attachSender((c) => OneShotSender<T>._(c));
    final rx = core.attachReceiver((c) => OneShotReceiver<T>._(c));
    return (tx, rx);
  }
}

final class _OneShotCore<T> extends ChannelCore<T, _OneShotCore<T>> {
  _OneShotCore({required bool consumeOnce})
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
  bool get recvDisconnected => (buf.hasConsumed && buf.isEmpty);
}

final class OneShotSender<T> implements Sender<T> {
  OneShotSender._(this._core);
  final _OneShotCore<T> _core;

  @pragma('vm:prefer-inline')
  @override
  bool get isDisconnected => _core.sendDisconnected;

  @override
  Future<SendResult> send(T value) async => _core.send(value);

  @pragma('vm:prefer-inline')
  @override
  SendResult trySend(T value) => _core.trySend(value);
}

final class OneShotReceiver<T> implements Receiver<T> {
  OneShotReceiver._(this._core);
  final _OneShotCore<T> _core;

  @pragma('vm:prefer-inline')
  @override
  bool get isDisconnected => _core.recvDisconnected;

  @override
  Future<RecvResult<T>> recv() => _core.recv();

  @pragma('vm:prefer-inline')
  @override
  RecvResult<T> tryRecv() => _core.tryRecv();

  @override
  (Future<RecvResult<T>>, void Function()) recvCancelable() =>
      _core.recvCancelable();
}
