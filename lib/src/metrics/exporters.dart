import 'package:cross_channel/src/metrics/core.dart';

part 'exporters/csv_exporter.dart';
part 'exporters/noop_exporter.dart';
part 'exporters/std_exporter.dart';

sealed class MetricsExporter {
  const MetricsExporter();
  void exportSnapshot(GlobalMetrics gm);
  void exportChannel(String id, ChannelSnapshot snap);
}
