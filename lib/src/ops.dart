import 'package:cross_channel/src/buffers.dart';
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

  // ignore: prefer_function_declarations_over_variables
  static final void Function() _noop = () {};

  Future<SendResult> send(T value) async {
    if (sendDisconnected) return const SendErrorDisconnected();

    final r0 = buf.tryPush(value);
    if (r0) return SendOk();

    while (true) {
      await buf.waitNotFull();

      if (sendDisconnected) {
        buf.consumePushPermit();
        return const SendErrorDisconnected();
      }

      final r1 = buf.tryPush(value);
      buf.consumePushPermit();
      if (r1) return SendOk();
    }
  }

  @pragma('vm:prefer-inline')
  SendResult trySend(T value) {
    if (sendDisconnected) return const SendErrorDisconnected();
    return buf.tryPush(value) ? SendOk() : SendErrorFull();
  }

  Future<RecvResult<T>> recv() async {
    while (true) {
      final v0 = buf.tryPop();
      if (v0 != null) return RecvOk<T>(v0);
      if (recvDisconnected) return const RecvErrorDisconnected();

      final c = buf.addPopWaiter();

      try {
        final v1 = await c.future;
        return RecvOk<T>(v1);
      } catch (e) {
        return (e is RecvError) ? e : RecvErrorFailed(e);
      }
    }
  }

  @pragma('vm:prefer-inline')
  RecvResult<T> tryRecv() {
    final v = buf.tryPop();
    if (v != null) return RecvOk<T>(v);
    if (recvDisconnected) return const RecvErrorDisconnected();
    return const RecvErrorEmpty();
  }

  @pragma('vm:prefer-inline')
  (Future<RecvResult<T>>, void Function()) recvCancelable() {
    final v = buf.tryPop();
    if (v != null) return (Future.value(RecvOk<T>(v)), _noop);
    if (recvDisconnected) {
      return (Future.value(const RecvErrorDisconnected()), _noop);
    }

    final c = buf.addPopWaiter();
    var canceled = false;

    final v1 = buf.tryPop();
    if (v1 != null) {
      buf.removePopWaiter(c);
      return (Future<RecvResult<T>>.value(RecvOk<T>(v1)), _noop);
    }

    final fut = c.future.then<RecvResult<T>>((v2) {
      if (canceled) return const RecvErrorCanceled();
      return RecvOk<T>(v2);
    }).catchError((Object e) {
      if (e is RecvError) return e;
      return RecvErrorFailed(e);
    });

    @pragma('vm:prefer-inline')
    void cancel() {
      if (canceled) return;
      canceled = true;

      final removed = buf.removePopWaiter(c);
      if (removed) {
        c.completeError(const RecvErrorCanceled());
      }
    }

    return (fut, cancel);
  }
}
