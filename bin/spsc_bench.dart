import 'dart:async';
import 'package:cross_channel/spsc.dart';
import 'utils.dart';

Future<void> main(List<String> args) async {
  final iters = args.isNotEmpty && !args.contains('--csv')
      ? int.parse(args[0])
      : 2_000_000;

  final csv = args.contains('--csv');

  // Warmup
  await _benchPingPong(1024, 200_000, 'warmup');

  final results = <Stats>[];

  results.add(
      await _benchPingPong(1024, iters, 'spsc ping-pong pow2=1024 (1P/1C)'));
  results.add(
      await _benchPipeline(1024, iters, 'spsc pipeline pow2=1024 (1P/1C)'));
  results.add(
      await _benchPipeline(4096, iters, 'spsc pipeline pow2=4096 (1P/1C)'));

  if (csv) {
    print('suite,case,mops,ns_per_op,max_latency_us,notes');
    for (final r in results) {
      print(r.toCsv(suite: 'SPSC'));
    }
    return;
  }

  print('\n=== SPSC Bench (Dart VM) ===');
  for (final r in results) {
    print(r.toString());
  }
}

/// ping-pong strict (cap pow2). Round-trip N times.
Future<Stats> _benchPingPong(int pow2, int iters, String label) async {
  final (tx, rx) = Spsc.channel<int>(pow2);

  var remaining = iters;
  var maxLatencyNs = 0;

  final swAll = Stopwatch()..start();
  final recvLoop = () async {
    while (remaining > 0) {
      final t0 = Stopwatch()..start();
      final r = await rx.recv();
      final t = t0.elapsedMicroseconds * 1000;
      if (r.ok) {
        if (t > maxLatencyNs) maxLatencyNs = t;
        remaining--;
      }
    }
  }();

  final sendLoop = () async {
    for (var i = 0; i < iters; i++) {
      await tx.send(i);
    }
  }();

  await Future.wait([recvLoop, sendLoop]);
  final elapsed = swAll.elapsed;

  return Stats(label, iters, elapsed, maxLatencyNs);
}

/// producer pushes N, consumer drains N.
Future<Stats> _benchPipeline(int pow2, int iters, String label) async {
  final (tx, rx) = Spsc.channel<int>(pow2);

  var received = 0;
  var maxLatencyNs = 0;

  final swAll = Stopwatch()..start();

  final recvLoop = () async {
    while (received < iters) {
      final t0 = Stopwatch()..start();
      final r = await rx.recv();
      final t = t0.elapsedMicroseconds * 1000;
      if (r.ok) {
        if (t > maxLatencyNs) maxLatencyNs = t;
        received++;
      }
    }
  }();

  final sendLoop = () async {
    for (var i = 0; i < iters; i++) {
      await tx.send(i);
    }
  }();

  await Future.wait([recvLoop, sendLoop]);
  final elapsed = swAll.elapsed;

  return Stats(label, iters, elapsed, maxLatencyNs);
}
