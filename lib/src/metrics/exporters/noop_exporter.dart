part of '../exporters.dart';

final class NoopExporter extends MetricsExporter {
  const NoopExporter();
  @override
  void exportSnapshot(GlobalMetrics _) {}

  @override
  void exportChannel(String _, ChannelSnapshot __) {}
}
