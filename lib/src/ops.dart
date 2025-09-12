import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/metrics/recorders.dart';
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

  @pragma('vm:prefer-inline')
  MetricsRecorder get mx;

  // ignore: prefer_function_declarations_over_variables
  static final void Function() _noop = () {};

  Future<SendResult> send(T value) async {
    if (sendDisconnected) return const SendErrorDisconnected();
    // latence send
    final t0 = mx.startSendTimer();
    // fast path
    final ok0 = buf.tryPush(value);
    if (ok0) {
      mx.sendOk(t0);
      return SendOk();
    }

    // slow path
    while (true) {
      await buf.waitNotFull();

      if (sendDisconnected) {
        buf.consumePushPermit();
        return const SendErrorDisconnected();
      }

      final ok1 = buf.tryPush(value);
      buf.consumePushPermit();
      if (ok1) {
        mx.sendOk(t0);
        return SendOk();
      }
    }
  }

  @pragma('vm:prefer-inline')
  SendResult trySend(T value) {
    if (sendDisconnected) return const SendErrorDisconnected();
    final t0 = mx.startSendTimer();

    final ok = buf.tryPush(value);
    if (ok) {
      mx.trySendOk(t0);
      return SendOk();
    }
    mx.trySendFail();
    return SendErrorFull();
  }

  Future<RecvResult<T>> recv() async {
    if (recvDisconnected) return const RecvErrorDisconnected();
    // latence recv
    final t0 = mx.startRecvTimer();

    final v0 = buf.tryPop();
    if (v0 != null) {
      mx.recvOk(t0);
      return RecvOk<T>(v0);
    }

    while (true) {
      final c = buf.addPopWaiter();
      if (recvDisconnected) {
        buf.removePopWaiter(c);
        return const RecvErrorDisconnected();
      }
      try {
        final v1 = await c.future;
        mx.recvOk(t0);
        return RecvOk<T>(v1);
      } catch (e) {
        return (e is RecvError) ? e : RecvErrorFailed(e);
      }
    }
  }

  @pragma('vm:prefer-inline')
  RecvResult<T> tryRecv() {
    if (recvDisconnected) return const RecvErrorDisconnected();
    final t0 = mx.startRecvTimer();

    final v0 = buf.tryPop();
    if (v0 != null) {
      mx.tryRecvOk(t0);
      return RecvOk<T>(v0);
    }
    mx.tryRecvEmpty();
    return const RecvErrorEmpty();
  }

  @pragma('vm:prefer-inline')
  (Future<RecvResult<T>>, void Function()) recvCancelable() {
    final v0 = buf.tryPop();
    if (v0 != null) {
      return (Future.value(RecvOk<T>(v0)), _noop);
    }
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
