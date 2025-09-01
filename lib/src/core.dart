import 'dart:async';

import 'package:cross_channel/src/buffer.dart';
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
  bool get isClosed;
}

abstract class Clones<Self> {
  Self clone();
}

abstract class Sender<T> {
  Future<SendResult<T>> send(T value);
  SendResult<T> trySend(T value);
}

abstract class Receiver<T> {
  Future<RecvResult<T>> recv();
  RecvResult<T> tryRecv();
}

abstract class KeepAliveSender<T> extends Sender<T> implements Closeable {}

abstract class KeepAliveReceiver<T> extends Receiver<T> implements Closeable {
  (Future<RecvResult<T>>, void Function()) recvCancelable();
  Stream<T> stream();
}

abstract class CloneableSender<T> extends KeepAliveSender<T>
    implements Clones<CloneableSender<T>> {}

abstract class CloneableReceiver<T> extends KeepAliveReceiver<T>
    implements Clones<CloneableReceiver<T>> {}

extension SenderTimeoutX<T> on Sender<T> {
  Future<SendResult<T>> sendTimeout(T v, Duration d) =>
      send(v).timeout(d, onTimeout: () => SendErrorDisconnected<T>());
}

extension ReceiverTimeoutX<T> on Receiver<T> {
  Future<RecvResult<T>> recvTimeout(Duration d) {
    if (this is KeepAliveReceiver<T>) {
      final (fut, cancel) = (this as KeepAliveReceiver<T>).recvCancelable();
      return fut.timeout(d, onTimeout: () {
        cancel();
        return RecvErrorDisconnected<T>();
      });
    }
    return recv().timeout(d, onTimeout: () => RecvErrorDisconnected<T>());
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
      if (r.full) {
        await send(v);
      } else if (r.disconnected) {
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
      final next = await recv().timeout(
        idle,
        onTimeout: () => RecvErrorEmpty<T>(),
      );

      if (next is RecvOk<T>) {
        out.add(next.value);
        if (out.length < limit) {
          final remaining = limit - out.length;
          final burst = tryRecvAll(max: remaining);
          if (burst.isEmpty) {
          } else {
            out.addAll(burst);
          }
        }
      } else {
        break;
      }
    }
    return out;
  }
}
