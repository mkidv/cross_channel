import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/lifecycle.dart';
import 'package:cross_channel/src/ops.dart';
import 'package:cross_channel/src/result.dart';

/// Core channel traits: lifecycle + send/recv ops binding.
///
/// `ChannelCore<T, Self>` ties a buffer implementation to lifecycle
/// (attach/drop senders/receivers, disconnection semantics) and exposes the
/// high-level send/recv operations via `ChannelOps<T>`.
///
abstract class ChannelCore<T, Self extends Object>
    with ChannelLifecycle<T, Self>, ChannelOps<T> {
  @override
  ChannelBuffer<T> get buf;
  @override
  bool get sendDisconnected;
  @override
  bool get recvDisconnected;
}

abstract class Closeable {
  void close();
}

abstract class Clones<Self> {
  Self clone();
}

abstract class Sender<T> {
  bool get isDisconnected;
  Future<SendResult> send(T value);
  SendResult trySend(T value);
}

abstract class Receiver<T> {
  bool get isDisconnected;
  Future<RecvResult<T>> recv();
  RecvResult<T> tryRecv();
  (Future<RecvResult<T>>, void Function()) recvCancelable();
}

abstract class KeepAliveSender<T> extends Sender<T> implements Closeable {}

abstract class KeepAliveReceiver<T> extends Receiver<T> implements Closeable {
  Stream<T> stream();
}

abstract class CloneableSender<T> extends KeepAliveSender<T>
    implements Clones<CloneableSender<T>> {}

abstract class CloneableReceiver<T> extends KeepAliveReceiver<T>
    implements Clones<CloneableReceiver<T>> {}

extension SenderTimeoutX<T> on Sender<T> {
  Future<SendResult> sendTimeout(T v, Duration d) async {
    try {
      return await send(v).timeout(
        d,
        onTimeout: () => SendErrorTimeout(d),
      );
    } catch (e) {
      return SendErrorFailed(e);
    }
  }
}

extension ReceiverTimeoutX<T> on Receiver<T> {
  Future<RecvResult<T>> recvTimeout(Duration d) {
    if (this is KeepAliveReceiver<T>) {
      final (fut, cancel) = (this as KeepAliveReceiver<T>).recvCancelable();
      return fut.timeout(d, onTimeout: () {
        cancel();
        return RecvErrorTimeout(d);
      });
    }
    return recv().timeout(d, onTimeout: () => RecvErrorTimeout(d));
  }
}

extension SenderBatchX<T> on Sender<T> {
  Future<void> trySendAll(Iterable<T> it) async {
    for (final v in it) {
      trySend(v);
    }
  }

  Future<void> sendAll(Iterable<T> it) async {
    for (final v in it) {
      final r = trySend(v);
      if (r.isFull) {
        await send(v);
      } else if (r.isDisconnected) {
        break;
      }
    }
  }
}

extension ReceiverDrainX<T> on Receiver<T> {
  Iterable<T> tryRecvAll({int? max}) {
    final out = <T>[];
    final limit = max ?? 0x7fffffff;
    while (out.length < limit) {
      final r = tryRecv();
      if (r is RecvOk<T>) {
        out.add(r.value);
      } else {
        break;
      }
    }
    return out;
  }

  Future<Iterable<T>> recvAll({Duration idle = Duration.zero, int? max}) async {
    final out = <T>[];
    final limit = max ?? 0x7fffffff;

    out.addAll(tryRecvAll(max: limit));
    if (out.length >= limit || idle == Duration.zero) return out;

    while (out.length < limit) {
      final next = await recvTimeout(idle);

      if (next is RecvOk<T>) {
        out.add(next.value);
        if (out.length < limit) {
          final remaining = limit - out.length;
          final burst = tryRecvAll(max: remaining);
          if (burst.isNotEmpty) out.addAll(burst);
        }
      } else {
        break;
      }
    }
    return out;
  }
}
