import 'package:cross_channel/src/metrics/p2.dart';

const bool kMetrics = bool.fromEnvironment('CROSS_CHANNEL_METRICS', defaultValue: true);

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

  ChannelSnapshot merge(ChannelSnapshot other) {
    return ChannelSnapshot(
      sent: sent + other.sent,
      recv: recv + other.recv,
      dropped: dropped + other.dropped,
      closed: closed + other.closed,
      trySendOk: trySendOk + other.trySendOk,
      trySendFail: trySendFail + other.trySendFail,
      tryRecvOk: tryRecvOk + other.tryRecvOk,
      tryRecvEmpty: tryRecvEmpty + other.tryRecvEmpty,
      sendP50: _pick(sendP50, other.sendP50),
      sendP95: _pick(sendP95, other.sendP95),
      sendP99: _pick(sendP99, other.sendP99),
      recvP50: _pick(recvP50, other.recvP50),
      recvP95: _pick(recvP95, other.recvP95),
      recvP99: _pick(recvP99, other.recvP99),
      recvFirstNs: _min(recvFirstNs, other.recvFirstNs),
      recvLastNs: _max(recvLastNs, other.recvLastNs),
      sendFirstNs: _min(sendFirstNs, other.sendFirstNs),
      sendLastNs: _max(sendLastNs, other.sendLastNs),
    );
  }

  static double? _pick(double? a, double? b) {
    if (a == null || a == 0) return b;
    if (b == null || b == 0) return a;
    return (a + b) / 2; // Simple average if both have data
  }

  static int _min(int a, int b) {
    if (a == 0) return b;
    if (b == 0) return a;
    return a < b ? a : b;
  }

  static int _max(int a, int b) {
    return a > b ? a : b;
  }

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

  double? get sendAvgLatency => sent == 0 ? null : (sendLastNs - sendFirstNs) / sent;

  double? get recvAvgLatency => recv == 0 ? null : (recvLastNs - recvFirstNs) / recv;

  double get trySendFailureRate =>
      trySendOk + trySendFail == 0 ? 0 : trySendFail / (trySendOk + trySendFail);

  double get tryRecvEmptyRate =>
      tryRecvOk + tryRecvEmpty == 0 ? 0 : tryRecvEmpty / (tryRecvOk + tryRecvEmpty);

  double get dropRate => sent == 0 ? 0 : dropped / sent;
}

final class GlobalMetrics {
  final DateTime ts;
  final Map<String, ChannelSnapshot> channels;

  const GlobalMetrics(this.ts, this.channels);

  GlobalMetrics merge(GlobalMetrics other) {
    final mergedChannels = Map<String, ChannelSnapshot>.from(channels);
    other.channels.forEach((id, snap) {
      final existing = mergedChannels[id];
      if (existing == null) {
        mergedChannels[id] = snap;
      } else {
        mergedChannels[id] = existing.merge(snap);
      }
    });
    return GlobalMetrics(ts, mergedChannels);
  }

  int get sent => channels.values.fold(0, (a, v) => a + v.sent);
  int get recv => channels.values.fold(0, (a, v) => a + v.recv);
  int get dropped => channels.values.fold(0, (a, v) => a + v.dropped);
  int get closed => channels.values.fold(0, (a, v) => a + v.closed);
  int get trySendOk => channels.values.fold(0, (a, v) => a + v.trySendOk);
  int get trySendFail => channels.values.fold(0, (a, v) => a + v.trySendFail);
  int get tryRecvOk => channels.values.fold(0, (a, v) => a + v.tryRecvOk);
  int get tryRecvEmpty => channels.values.fold(0, (a, v) => a + v.tryRecvEmpty);
}
