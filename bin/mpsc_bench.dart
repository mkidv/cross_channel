import 'dart:async';
import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/src/metrics.dart';
import 'utils.dart';

Future<void> main(List<String> args) async {
  final (iters, csv, _) = parseArgs(args);

  MetricsConfig.enabled = true;
  MetricsConfig.sampleLatency = true;
  MetricsConfig.exporter = csv ? CsvExporter() : StdExporter();

  // Warmup
  await benchPipeline(Mpsc.bounded<int>(1, metricsId: 'warmup'), 200_000);

  await benchPingPong(
      Mpsc.bounded<int>(1, metricsId: 'ping-pong cap=1 AB (1P/1C)'),
      Mpsc.bounded<int>(1, metricsId: 'ping-pong cap=1 BA (1P/1C)'),
      iters);

  await benchPipeline(
      Mpsc.bounded<int>(1024, metricsId: 'pipeline cap=1024 (1P/1C)'), iters);

  await benchPipeline(
      Mpsc.unbounded<int>(
          chunked: false, metricsId: 'pipeline unbounded (1P/1C)'),
      iters);

  await benchPipeline(
      Mpsc.unbounded<int>(metricsId: 'pipeline unbounded chunked (1P/1C)'),
      iters);

  await benchMultiPipeline(
      Mpsc.bounded<int>(1024, metricsId: 'multi-producers cap=1024 (4P/1C)'),
      iters,
      4,
      1);

  await benchPipeline(
      Mpsc.bounded<int>(0, metricsId: 'pipeline rendezvous cap=0 (1P/1C)'),
      iters);

  await benchPipeline(
      Mpsc.channel<int>(
          capacity: 1024,
          policy: DropPolicy.oldest,
          metricsId: 'sliding oldest cap=1024 (1P/1C)'),
      iters);

  await benchPipeline(
      Mpsc.channel<int>(
          capacity: 1024,
          policy: DropPolicy.newest,
          metricsId: 'sliding newest cap=1024 (1P/1C)'),
      iters);

  await benchPipeline(Mpsc.latest<int>(metricsId: 'latestOnly (1P/1C)'), iters);

  MetricsRegistry().export();
}
