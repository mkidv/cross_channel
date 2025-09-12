import 'package:cross_channel/src/metrics/p2.dart';

const bool kMetrics =
    bool.fromEnvironment('CROSS_CHANNEL_METRICS', defaultValue: true);

final class ChannelMetrics {
  int sent = 0, recv = 0, dropped = 0, closed = 0;
  int trySendOk = 0, trySendFail = 0, tryRecvOk = 0, tryRecvEmpty = 0;
  int wakeOne = 0, wakeAll = 0;
  int dropOldest = 0, dropNewest = 0, dropBlockTimeout = 0;

  final sendLatency = P2Quantiles([0.5, 0.95, 0.99]);
  final recvLatency = P2Quantiles([0.5, 0.95, 0.99]);

  int _recvFirstNs = 0, _recvLastNs = 0;
  int _sendFirstNs = 0, _sendLastNs = 0;

  int get recvFirstNs => _recvFirstNs;
  int get recvLastNs => _recvLastNs;
  int get sendFirstNs => _sendFirstNs;
  int get sendLastNs => _sendLastNs;

  bool get hasSent => sent > 0;
  bool get hasRecv => recv > 0;

  int get recvDurationNs => _recvLastNs - _recvFirstNs;
  int get sendDurationNs => _sendLastNs - _sendFirstNs;

  @pragma('vm:prefer-inline')
  void markRecvNowNs(int nowNs) {
    if (_recvFirstNs == 0) _recvFirstNs = nowNs;
    _recvLastNs = nowNs;
  }

  @pragma('vm:prefer-inline')
  void markSendNowNs(int nowNs) {
    if (_sendFirstNs == 0) _sendFirstNs = nowNs;
    _sendLastNs = nowNs;
  }
}

final class ChannelSnapshot {
  final int sent, recv, dropped, closed;
  final int trySendOk, trySendFail, tryRecvOk, tryRecvEmpty;
  final double? sendP50, sendP95, sendP99;
  final double? recvP50, recvP95, recvP99;
  final int recvFirstNs, recvLastNs;
  final int sendFirstNs, sendLastNs;
  const ChannelSnapshot({
    this.sent = 0,
    this.recv = 0,
    this.dropped = 0,
    this.closed = 0,
    this.trySendOk = 0,
    this.trySendFail = 0,
    this.tryRecvOk = 0,
    this.tryRecvEmpty = 0,
    this.sendP50,
    this.sendP95,
    this.sendP99,
    this.recvP50,
    this.recvP95,
    this.recvP99,
    this.recvFirstNs = 0,
    this.recvLastNs = 0,
    this.sendFirstNs = 0,
    this.sendLastNs = 0,
  });

  Duration get duration => Duration(
        microseconds: ((recvLastNs - recvFirstNs) / 1000).round(),
      );

  double get nsByOp {
    final dt = recvLastNs - recvFirstNs;
    if (recv <= 0 || dt <= 0) return 0;
    return dt / recv;
  }

  double get recvOpsPerSec {
    final dt = recvLastNs - recvFirstNs;
    if (recv <= 0 || dt <= 0) return 0;
    return recv / (dt / 1e9);
  }

  double get sendOpsPerSec {
    final dt = sendLastNs - sendFirstNs;
    if (sent <= 0 || dt <= 0) return 0;
    return sent / (dt / 1e9);
  }

  double? get sendAvgLatency =>
      sent == 0 ? null : (sendLastNs - sendFirstNs) / sent;

  double? get recvAvgLatency =>
      recv == 0 ? null : (recvLastNs - recvFirstNs) / recv;

  double get trySendFailureRate => trySendOk + trySendFail == 0
      ? 0
      : trySendFail / (trySendOk + trySendFail);

  double get tryRecvEmptyRate => tryRecvOk + tryRecvEmpty == 0
      ? 0
      : tryRecvEmpty / (tryRecvOk + tryRecvEmpty);

  double get dropRate => sent == 0 ? 0 : dropped / sent;
}

final class GlobalMetrics {
  final DateTime ts;
  final Map<String, ChannelSnapshot> channels;

  const GlobalMetrics(this.ts, this.channels);

  int get sent => channels.values.fold(0, (a, v) => a + v.sent);
  int get recv => channels.values.fold(0, (a, v) => a + v.recv);
  int get dropped => channels.values.fold(0, (a, v) => a + v.dropped);
  int get closed => channels.values.fold(0, (a, v) => a + v.closed);
  int get trySendOk => channels.values.fold(0, (a, v) => a + v.trySendOk);
  int get trySendFail => channels.values.fold(0, (a, v) => a + v.trySendFail);
  int get tryRecvOk => channels.values.fold(0, (a, v) => a + v.tryRecvOk);
  int get tryRecvEmpty => channels.values.fold(0, (a, v) => a + v.tryRecvEmpty);
}
