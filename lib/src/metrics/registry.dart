import 'package:cross_channel/src/metrics/config.dart';
import 'package:cross_channel/src/metrics/core.dart';

class MetricsRegistry {
  static final MetricsRegistry _i = MetricsRegistry._();
  MetricsRegistry._();
  factory MetricsRegistry() => _i;

  final Map<String, ChannelMetrics> _map = {};
  final List<GlobalMetrics> _externals = [];

  ChannelMetrics attach(String id) => _map[id] ??= ChannelMetrics();

  void merge(GlobalMetrics other) {
    if (!kMetrics || !MetricsConfig.enabled) return;
    _externals.add(other);
  }

  GlobalMetrics snapshot() {
    final snaps = <String, ChannelSnapshot>{};
    _map.forEach((id, m) {
      snaps[id] = ChannelSnapshot(
        sent: m.sent,
        recv: m.recv,
        dropped: m.dropped,
        closed: m.closed,
        trySendOk: m.trySendOk,
        trySendFail: m.trySendFail,
        tryRecvOk: m.tryRecvOk,
        tryRecvEmpty: m.tryRecvEmpty,
        sendP50: m.sendLatency.p50,
        sendP95: m.sendLatency.p95,
        sendP99: m.sendLatency.p99,
        recvP50: m.recvLatency.p50,
        recvP95: m.recvLatency.p95,
        recvP99: m.recvLatency.p99,
        recvFirstNs: m.recvFirstNs,
        recvLastNs: m.recvLastNs,
        sendFirstNs: m.sendFirstNs,
        sendLastNs: m.sendLastNs,
      );
    });

    var snap = GlobalMetrics(DateTime.now(), snaps);
    for (final ext in _externals) {
      snap = snap.merge(ext);
    }
    return snap;
  }

  void export() {
    if (!kMetrics || !MetricsConfig.enabled) {
      return;
    }
    final snap = snapshot();
    MetricsConfig.exporter.exportSnapshot(snap);
    snap.channels.forEach((id, ch) {
      MetricsConfig.exporter.exportChannel(id, ch);
    });
  }
}
