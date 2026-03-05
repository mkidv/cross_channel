import 'package:cross_channel/cross_channel.dart';
import 'package:cross_channel/metrics.dart';

Future<void> main() async {
  // 1. Enable metrics globally
  MetricsConfig.enabled = true;
  MetricsConfig.sampleLatency = true;

  // 2. Configure exporter (Standard output)
  MetricsConfig.exporter = StdExporter();

  // 3. Create channels with metrics
  final (tx, rx) = XChannel.mpsc<String>(
    capacity: 100,
    metricsId: 'data_pipeline',
  );

  // 4. Metrics collected automatically
  await tx.send('performance data');
  await rx.recv();

  // 5. Access snapshots (advanced)
  final snapshot = MetricsRegistry().snapshot();
  print('Total messages: ${snapshot.sent}');
}
