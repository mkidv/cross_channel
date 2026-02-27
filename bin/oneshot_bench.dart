import 'dart:async';
import 'dart:io';

import 'package:cross_channel/oneshot.dart';
import 'package:cross_channel/src/metrics.dart';

import 'utils.dart';

Future<void> main(List<String> args) async {
  final (iters, csv, _) = parseArgs(args);

  MetricsConfig.enabled = true;
  MetricsConfig.sampleLatency = true;
  MetricsConfig.exporter = csv ? CsvExporter() : StdExporter();
  // Warmup
  await _benchSendRecvSamePair(50_000, 'warmup');

  await _benchSendRecvSamePair(
    iters,
    'send/receive',
  );

  _benchTrySendRecvSamePair(iters, 'try send/receive');

  await benchPipeline(OneShot.channel<int>(metricsId: 'pipeline'), iters);

  await benchCrossIsolatePipeline(
      OneShot.channel<int>(metricsId: 'cross-isolate pipeline (IsoA→IsoB)'), iters);

  MetricsRegistry().export();
  exit(0);
}

Future<void> _benchSendRecvSamePair(int iters, String label) async {
  final (tx, rx) = OneShot.channel<int>(metricsId: label);
  for (var i = 0; i < iters; i++) {
    final sf = tx.send(i);
    final r = await rx.recv();
    if (!r.hasValue) throw StateError('unexpected');
    await sf;
  }
}

void _benchTrySendRecvSamePair(int iters, String label) {
  final (tx, rx) = OneShot.channel<int>(metricsId: label);
  for (var i = 0; i < iters; i++) {
    final sf = tx.trySend(i);
    final r = rx.tryRecv();
    if (!r.hasValue) throw StateError('unexpected');
    sf;
  }
}
