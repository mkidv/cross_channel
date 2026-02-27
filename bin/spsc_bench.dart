import 'dart:async';
import 'dart:io';

import 'package:cross_channel/spsc.dart';
import 'package:cross_channel/src/metrics.dart';

import 'utils.dart';

Future<void> main(List<String> args) async {
  final (iters, csv, _) = parseArgs(args);

  MetricsConfig.enabled = true;
  MetricsConfig.sampleLatency = true;
  MetricsConfig.exporter = csv ? CsvExporter() : StdExporter();

  // Warmup
  await benchPipeline(Spsc.channel<int>(1, metricsId: 'warmup'), 200_000);

  await benchPingPong(Spsc.channel<int>(1, metricsId: 'ping-pong 1:AB'),
      Spsc.channel<int>(1, metricsId: 'ping-pong 1:BA'), iters);

  await benchPipeline(
    Spsc.channel<int>(1024, metricsId: 'pipeline 1024'),
    iters,
  );

  await benchPipeline(
    Spsc.channel<int>(4096, metricsId: 'pipeline 4096'),
    iters,
  );

  await benchCrossIsolatePipeline(
      Spsc.channel<int>(1024, metricsId: 'spsc_cross_iso'), iters);

  MetricsRegistry().export();
  exit(0);
}
