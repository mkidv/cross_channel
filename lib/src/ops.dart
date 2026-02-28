import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/metrics/recorders.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/remote.dart';
import 'package:cross_channel/src/result.dart';

/// High-level channel operations backed by a `ChannelBuffer<T>`.
///
/// Implements the fast/slow paths (`trySendNow`, `waitSendPermit`,
/// `addRecvWaiter`) and disconnection checks. Provides `try*` and async
/// variants for both send and recv.
///
/// Operations for sending values backed by a [ChannelBuffer].
mixin ChannelSendOps<T> {
  int get channelId;

  /// The buffer implementation. May be null if utilizing [remotePort] exclusively.
  ChannelBuffer<T>? get buf;

  MetricsRecorder get mx;

  /// Fast path: resolve local channel if in same isolate.
  /// Returns null if this IS the local channel or if remote.
  @pragma('vm:prefer-inline')
  ChannelCore<T, Object>? get localSendChannel {
    final local = ChannelRegistry.get(channelId);
    return (local != null && !identical(local, this))
        ? local as ChannelCore<T, Object>
        : null;
  }

  /// Whether the channel's send side is disconnected.
  bool get sendDisconnected {
    if (isSendClosed) return true;
    if (remoteConnection?.isClosed ?? false) return true;
    if (localSendChannel case final lc?) return lc.sendDisconnected;
    return false;
  }

  /// Whether this handle is closed for sending.
  bool get isSendClosed;

  PlatformPort? get remotePort => null;
  FlowControlledRemoteConnection<T>? get remoteConnection => null;

  Future<SendResult> send(T value) async {
    if (localSendChannel case final lc?) return lc.send(value);

    if (isSendClosed) return const SendErrorDisconnected();
    final t0 = mx.startSendTimer();

    // Remote path with backpressure
    final rc = remoteConnection;
    if (rc != null) {
      await rc.send(value);
      mx.sendOk(t0);
      return const SendOk();
    }

    // Legacy remote path (fire-and-forget)
    final rp = remotePort;
    if (rp != null) {
      rp.send(value);
      mx.sendOk(t0);
      return const SendOk();
    }

    // Local buffer path
    final b = buf;
    if (b != null) {
      // fast path
      if (b.tryPush(value)) {
        mx.sendOk(t0);
        return const SendOk();
      }

      // slow path
      while (true) {
        await b.waitNotFull();

        if (isSendClosed) {
          b.consumePushPermit();
          return const SendErrorDisconnected();
        }

        if (b.tryPush(value)) {
          b.consumePushPermit();
          mx.sendOk(t0);
          return const SendOk();
        }
        // Loop if we acquired permit but failed to push (race condition)
        b.consumePushPermit();
      }
    }

    throw StateError('ChannelSendOps: neither remotePort nor buf available');
  }

  @pragma('vm:prefer-inline')
  SendResult trySend(T value) {
    if (localSendChannel case final lc?) return lc.trySend(value);

    if (isSendClosed) return const SendErrorDisconnected();
    final t0 = mx.startSendTimer();

    // Remote path with backpressure
    final rc = remoteConnection;
    if (rc != null) {
      if (rc.trySend(value)) {
        mx.trySendOk(t0);
        return const SendOk();
      }
      mx.trySendFail();
      return SendErrorFull();
    }

    // Legacy remote path
    final rp = remotePort;
    if (rp != null) {
      rp.send(value);
      mx.trySendOk(t0);
      return const SendOk();
    }

    // Local buffer path
    final b = buf;
    if (b != null) {
      if (b.tryPush(value)) {
        mx.trySendOk(t0);
        return const SendOk();
      }
      mx.trySendFail();
      return SendErrorFull();
    }

    throw StateError('ChannelSendOps: neither remotePort nor buf available');
  }
}

/// Operations for receiving values backed by a [ChannelBuffer].
mixin ChannelRecvOps<T> {
  int get channelId;
  ChannelBuffer<T> get buf;
  MetricsRecorder get mx;

  /// Fast path: resolve local channel if in same isolate.
  @pragma('vm:prefer-inline')
  ChannelCore<T, Object>? get localRecvChannel {
    final local = ChannelRegistry.get(channelId);
    return (local != null && !identical(local, this))
        ? local as ChannelCore<T, Object>
        : null;
  }

  FlowControlledRemoteConnection<T>? get remoteConnection => null;

  /// Whether the channel's receive side is disconnected.
  bool get recvDisconnected {
    if (isRecvClosed) return true;
    if (localRecvChannel case final lc?) return lc.recvDisconnected;
    if (remoteConnection?.isClosed ?? false) return buf.isEmpty;
    return false;
  }

  /// Whether this handle is closed for receiving.
  bool get isRecvClosed;

  // ignore: prefer_function_declarations_over_variables
  static final void Function() _noop = () {};

  Future<RecvResult<T>> recv() async {
    if (localRecvChannel case final lc?) return lc.recv();

    if (isRecvClosed) return const RecvErrorDisconnected();
    final t0 = mx.startRecvTimer();

    final v0 = buf.tryPop();
    if (v0 != null) {
      mx.recvOk(t0);
      return RecvOk<T>(v0);
    }

    if (recvDisconnected) return const RecvErrorDisconnected();

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
    if (localRecvChannel case final lc?) return lc.tryRecv();

    if (isRecvClosed) return const RecvErrorDisconnected();
    final t0 = mx.startRecvTimer();

    final v0 = buf.tryPop();
    if (v0 != null) {
      mx.tryRecvOk(t0);
      return RecvOk<T>(v0);
    }

    if (recvDisconnected) return const RecvErrorDisconnected();

    mx.tryRecvEmpty();
    return const RecvErrorEmpty();
  }

  @pragma('vm:prefer-inline')
  (Future<RecvResult<T>>, void Function()) recvCancelable() {
    if (localRecvChannel case final lc?) return lc.recvCancelable();

    final v0 = buf.tryPop();
    if (v0 != null) {
      return (Future.value(RecvOk<T>(v0)), _noop);
    }
    if (recvDisconnected) {
      return (Future.value(const RecvErrorDisconnected()), _noop);
    }

    final t0 = mx.startRecvTimer();

    final c = buf.addPopWaiter();
    var canceled = false;

    // Double check
    final v1 = buf.tryPop();
    if (v1 != null) {
      buf.removePopWaiter(c);
      return (Future<RecvResult<T>>.value(RecvOk<T>(v1)), _noop);
    }

    final fut = c.future.then<RecvResult<T>>((v2) {
      if (canceled) return const RecvErrorCanceled();
      mx.recvOk(t0);
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
