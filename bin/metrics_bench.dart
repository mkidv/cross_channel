import 'dart:async';
import 'dart:io';

import 'package:cross_channel/spsc.dart';
import 'package:cross_channel/src/metrics.dart';

Future<void> main() async {
  const iters = 1000000;

  print('--- NO METRICS ---');
  MetricsConfig.enabled = false;
  await runBench(iters);

  print('\n--- METRICS ENABLED (No sampling) ---');
  MetricsConfig.enabled = true;
  MetricsConfig.sampleLatency = false;
  await runBench(iters);

  print('\n--- METRICS ENABLED (1% sampling) ---');
  MetricsConfig.enabled = true;
  MetricsConfig.sampleLatency = true;
  MetricsConfig.sampleRate = 0.01;
  await runBench(iters);

  print('\n--- TRY SEND/RECV (No metrics, sync) ---');
  MetricsConfig.enabled = false;
  await runBenchSync(iters);

  exit(0);
}

Future<void> runBenchSync(int iters) async {
  final (tx, rx) = Spsc.channel<int>(1000000); // large buffer to avoid full

  final sw = Stopwatch()..start();

  int received = 0;
  for (var i = 0; i < iters; i++) {
    tx.trySend(i);
    final r = rx.tryRecv();
    if (r.hasValue) received++;
  }

  sw.stop();
  final ns = sw.elapsedMicroseconds * 1000;
  final nsPerOp = ns / iters;
  final mops = iters / sw.elapsedMicroseconds;

  print(
      'Result: ${mops.toStringAsFixed(2)} Mops/s, ${nsPerOp.toStringAsFixed(1)} ns/op (received: $received)');
}

Future<void> runBench(int iters) async {
  final (tx, rx) = Spsc.channel<int>(1024);

  final sw = Stopwatch()..start();

  final r = () async {
    for (var i = 0; i < iters; i++) {
      await rx.recv();
    }
  }();

  final s = () async {
    for (var i = 0; i < iters; i++) {
      await tx.send(i);
    }
  }();

  await Future.wait([r, s]);
  sw.stop();

  final ns = sw.elapsedMicroseconds * 1000;
  final nsPerOp = ns / iters;
  final mops = iters / sw.elapsedMicroseconds;

  print(
      'Result: ${mops.toStringAsFixed(2)} Mops/s, ${nsPerOp.toStringAsFixed(1)} ns/op');
}
