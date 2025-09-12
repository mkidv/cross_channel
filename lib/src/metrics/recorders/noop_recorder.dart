part of '../recorders.dart';

final class NoopMetricsRecorder implements MetricsRecorder {
  const NoopMetricsRecorder();
  
  @override
  @pragma('vm:prefer-inline')
  int startSendTimer() => 0;

  @override
  @pragma('vm:prefer-inline')
  int startRecvTimer() => 0;

  @override
  @pragma('vm:prefer-inline')
  void sendOk(int _) {}

  @override
  @pragma('vm:prefer-inline')
  void recvOk(int _) {}

  @override
  @pragma('vm:prefer-inline')
  void trySendOk(int _) {}

  @override
  @pragma('vm:prefer-inline')
  void trySendFail() {}

  @override
  @pragma('vm:prefer-inline')
  void tryRecvOk(int _) {}

  @override
  @pragma('vm:prefer-inline')
  void tryRecvEmpty() {}

  @override
  @pragma('vm:prefer-inline')
  void markWakeOne() {}

  @override
  @pragma('vm:prefer-inline')
  void markWakeAll() {}

  @override
  @pragma('vm:prefer-inline')
  void markDropOldest() {}

  @override
  @pragma('vm:prefer-inline')
  void markDropNewest() {}

  @override
  @pragma('vm:prefer-inline')
  void markDropBlockTimeout() {}

  @override
  @pragma('vm:prefer-inline')
  void markClosed() {}
}

