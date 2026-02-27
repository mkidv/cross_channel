import 'dart:async';
import 'dart:io';

import 'package:cross_channel/broadcast.dart';
import 'package:cross_channel/src/metrics.dart';

import 'utils.dart';

Future<void> main(List<String> args) async {
  final (iters, csv, _) = parseArgs(args);

  MetricsConfig.enabled = true;
  MetricsConfig.sampleLatency = true;
  MetricsConfig.exporter = csv ? CsvExporter() : StdExporter();

  // Warmup
  await runBroadcastBench('warmup', iters: 200_000, subs: 1);

  await runBroadcastBench('broadcast pipeline (1P/1C)', iters: iters, subs: 1);

  await runBroadcastBench('broadcast pipeline (1P/4C)', iters: iters, subs: 4);

  await runBroadcastBench('broadcast pipeline (1P/8C)', iters: iters, subs: 8);

  // Cross-Isolate
  final (tx, b) = Broadcast.channel<int>(65536,
      metricsId: 'broadcast cross-isolate (IsoA→IsoB)');
  await benchCrossIsolatePipeline((tx, b.subscribe()), iters);

  MetricsRegistry().export();
  exit(0);
}

Future<void> runBroadcastBench(String name,
    {required int iters, required int subs}) async {
  final (tx, broadcast) = Broadcast.channel<int>(1024, metricsId: name);
  final receivers = List.generate(subs, (_) => broadcast.subscribe());

  final rt = <Future<int>>[];
  for (final rx in receivers) {
    rt.add(() async {
      var received = 0;
      while (true) {
        final res = await rx.recv();
        if (res.isDisconnected) break;
        received++;
      }
      return received;
    }());
  }

  final st = () async {
    for (var i = 0; i < iters; i++) {
      // Broadcast send is always non-blocking Ring overwrite,
      // but we use await to match standard bench pipeline style.
      await tx.send(i);
    }
    tx.close();
  }();

  await Future.wait([st, ...rt]);
}
