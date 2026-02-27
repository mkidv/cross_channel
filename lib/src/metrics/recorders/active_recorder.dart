part of '../recorders.dart';

final class ActiveMetricsRecorder implements MetricsRecorder {
  final ChannelMetrics m;
  int _rng = 0x9E3779B9; // LCG 32-bit

  ActiveMetricsRecorder(this.m);

  @pragma('vm:prefer-inline')
  bool _shouldSample() {
    if (!MetricsConfig.sampleLatency) return false;
    final sr = MetricsConfig.sampleRate.clamp(0.0, 1.0);
    _rng = 1664525 * _rng + 1013904223; // LCG
    final r24 = (_rng >>> 8) & 0xFFFFFF;
    return r24 < (sr * 0xFFFFFF);
  }

  @override
  @pragma('vm:prefer-inline')
  int startSendTimer() => _shouldSample() ? _nowNs() : 0;

  @override
  @pragma('vm:prefer-inline')
  int startRecvTimer() => _shouldSample() ? _nowNs() : 0;

  @override
  @pragma('vm:prefer-inline')
  void sendOk(int t0) {
    m.sent++;
    if (t0 != 0) {
      final now = _nowNs();
      m.sendLatency.insert((now - t0).toDouble());
      m.markSendNowNs(now);
    }
  }

  @override
  @pragma('vm:prefer-inline')
  void recvOk(int t0) {
    m.recv++;
    if (t0 != 0) {
      final now = _nowNs();
      m.recvLatency.insert((now - t0).toDouble());
      m.markRecvNowNs(now);
    }
  }

  @override
  @pragma('vm:prefer-inline')
  void trySendOk(int t0) {
    m.trySendOk++;
    if (t0 != 0) {
      final now = _nowNs();
      m.sendLatency.insert((now - t0).toDouble());
      m.markSendNowNs(now);
    }
  }

  @override
  @pragma('vm:prefer-inline')
  void trySendFail() {
    m.trySendFail++;
  }

  @override
  @pragma('vm:prefer-inline')
  void tryRecvOk(int t0) {
    m.tryRecvOk++;
    if (t0 != 0) {
      final now = _nowNs();
      m.recvLatency.insert((now - t0).toDouble());
      m.markRecvNowNs(now);
    }
  }

  @override
  @pragma('vm:prefer-inline')
  void tryRecvEmpty() {
    m.tryRecvEmpty++;
  }

  @override
  @pragma('vm:prefer-inline')
  void markWakeOne() {
    m.wakeOne++;
  }

  @override
  @pragma('vm:prefer-inline')
  void markWakeAll() {
    m.wakeAll++;
  }

  @override
  @pragma('vm:prefer-inline')
  void markDropOldest() {
    m.dropOldest++;
  }

  @override
  @pragma('vm:prefer-inline')
  void markDropNewest() {
    m.dropNewest++;
  }

  @override
  @pragma('vm:prefer-inline')
  void markDropBlockTimeout() {
    m.dropBlockTimeout++;
  }

  @override
  @pragma('vm:prefer-inline')
  void markClosed() {
    m.closed++;
  }
}
