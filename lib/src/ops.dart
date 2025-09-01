import 'package:cross_channel/src/buffer.dart';
import 'package:cross_channel/src/result.dart';

/// High-level channel operations backed by a `ChannelBuffer<T>`.
///
/// Implements the fast/slow paths (`trySendNow`, `waitSendPermit`,
/// `addRecvWaiter`) and disconnection checks. Provides `try*` and async
/// variants for both send and recv.
///
mixin ChannelOps<T> {
  ChannelBuffer<T> get buf;
  bool get sendDisconnected;
  bool get recvDisconnected;

  Future<SendResult<T>> send(T value) async {
    if (sendDisconnected) return SendErrorDisconnected<T>();

    final r0 = buf.trySendNow(value);
    if (r0.ok) return r0;

    while (true) {
      await buf.waitSendPermit();
      try {
        if (sendDisconnected) return SendErrorDisconnected<T>();
        final r1 = buf.trySendNow(value);
        if (r1.ok) return r1;
      } finally {
        buf.consumePermitIfAny();
      }
    }
  }

  @pragma('vm:prefer-inline')
  SendResult<T> trySend(T value) {
    if (sendDisconnected) return SendErrorDisconnected<T>();
    return buf.trySendNow(value);
  }

  Future<RecvResult<T>> recv() async {
    final v = buf.tryPop();
    if (v != null) return RecvOk<T>(v);
    if (recvDisconnected) return RecvErrorDisconnected<T>();

    final c = buf.addRecvWaiter();
    try {
      final v1 = await c.future;
      return RecvOk<T>(v1);
    } catch (_) {
      return RecvErrorDisconnected<T>();
    }
  }

  @pragma('vm:prefer-inline')
  RecvResult<T> tryRecv() {
    final v = buf.tryPop();
    if (v != null) return RecvOk<T>(v);
    if (recvDisconnected) return RecvErrorDisconnected<T>();
    return RecvErrorEmpty<T>();
  }

  @pragma('vm:prefer-inline')
  (Future<RecvResult<T>>, void Function()) recvCancelable() {
    final v = buf.tryPop();
    if (v != null) {
      return (Future.value(RecvOk<T>(v)), () {});
    }
    if (recvDisconnected) {
      return (Future.value(RecvErrorDisconnected<T>()), () {});
    }

    final c = buf.addRecvWaiter();
    bool cancelled = false;

    final Future<RecvResult<T>> fut = c.future
        .then<RecvResult<T>>((v1) => RecvOk<T>(v1))
        .catchError((_) => RecvErrorDisconnected<T>());

    void cancel() {
      if (cancelled) return;
      cancelled = true;
      final removed = buf.removeRecvWaiter(c);
      if (removed) {
        c.completeError(RecvErrorDisconnected<T>());
      }
    }

    return (fut, cancel);
  }
}
