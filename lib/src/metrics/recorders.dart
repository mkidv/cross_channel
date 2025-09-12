import 'package:cross_channel/src/metrics/config.dart';
import 'package:cross_channel/src/metrics/core.dart';
import 'package:cross_channel/src/metrics/registry.dart';

part 'recorders/active_recorder.dart';
part 'recorders/noop_recorder.dart';

final Stopwatch _clock = Stopwatch()..start();

@pragma('vm:prefer-inline')
int _nowNs() => _clock.elapsedMicroseconds * 1000;

abstract interface class MetricsRecorder {
  int startSendTimer();
  int startRecvTimer();
  void sendOk(int t0);
  void recvOk(int t0);
  void trySendOk(int t0);
  void trySendFail();
  void tryRecvOk(int t0);
  void tryRecvEmpty();
  void markWakeOne();
  void markWakeAll();
  void markDropOldest();
  void markDropNewest();
  void markDropBlockTimeout();
  void markClosed();
}

@pragma('vm:prefer-inline')
MetricsRecorder buildMetricsRecorder(String? channelId) {
  if (!kMetrics ||
      !MetricsConfig.enabled ||
      channelId == null ||
      channelId.isEmpty) {
    return const NoopMetricsRecorder();
  }
  final m = MetricsRegistry().attach(channelId);
  return ActiveMetricsRecorder(m);
}
