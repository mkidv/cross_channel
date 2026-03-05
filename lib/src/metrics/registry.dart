import 'package:cross_channel/src/metrics/config.dart';
import 'package:cross_channel/src/metrics/core.dart';

class MetricsRegistry {
  static final MetricsRegistry _i = MetricsRegistry._();
  MetricsRegistry._();
  factory MetricsRegistry() => _i;

  final Map<String, ChannelMetrics> _map = {};
  final Map<String, Map<String, ChannelSnapshot>> _externals = {};
  final String originId =
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
          (0x1000000 + (DateTime.now().hashCode % 0xFFFFFF)).toRadixString(16);

  ChannelMetrics attach(String id) => _map[id] ??= ChannelMetrics();

  ChannelSnapshot? channelSnapshot(String id) {
    if (!kMetrics || !MetricsConfig.enabled) return null;
    final m = _map[id];
    if (m == null) return null;
    return ChannelSnapshot(
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
  }

  void merge(String originId, String metricsId, ChannelSnapshot snap) {
    if (!kMetrics || !MetricsConfig.enabled) return;
    (_externals[originId] ??= {})[metricsId] = snap;
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
    for (final isolateSnaps in _externals.values) {
      snap = snap.merge(GlobalMetrics(snap.ts, isolateSnaps));
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
