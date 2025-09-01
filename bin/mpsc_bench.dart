import 'dart:async';
import 'package:cross_channel/mpsc.dart';
import 'utils.dart';

Future<void> main(List<String> args) async {
  final iters = args.isNotEmpty && !args.contains('--csv')
      ? int.parse(args[0])
      : 2_000_000;

  final csv = args.contains('--csv');

  // Quick warmup for JIT
  await _benchPingPong(1, 200_000, 'warmup');

  final results = <Stats>[];

  results.add(await _benchPingPong(1, iters, 'ping-pong cap=1 (1P/1C)'));

  results.add(await _benchPipeline(1024, iters, 'pipeline cap=1024 (1P/1C)'));

  results.add(await _benchPipeline(null, iters, 'pipeline unbounded (1P/1C)'));

  results.add(
    await _benchMultiProducers(
      4,
      1024,
      (iters / 4).round(),
      'multi-producers x4 cap=1024',
    ),
  );

  results.add(
    await _benchPipeline(0, iters, 'pipeline rendezvous cap=0 (1P/1C)'),
  );

  results.add(
    await _benchSliding(
      DropPolicy.oldest,
      1024,
      iters,
      'sliding=oldest cap=1024 (1P/1C)',
    ),
  );

  results.add(
    await _benchSliding(
      DropPolicy.newest,
      1024,
      iters,
      'sliding=newest cap=1024 (1P/1C)',
    ),
  );

  results.add(await _benchLatestOnly(iters, 'latestOnly (coalesce) (1P/1C)'));

  if (csv) {
    print('suite,case,mops,ns_per_op,max_latency_us,notes');
    for (final r in results) {
      print(r.toCsv(suite: 'MPSC'));
    }
    return;
  }

  print('\n=== MPSC Bench (Dart VM) ===');
  for (final r in results) {
    print(r.toString());
  }
}

// strict ping-pong (cap=1). Round-trip N times.
Future<Stats> _benchPingPong(int capacity, int iters, String label) async {
  final (tx, rx) = Mpsc.bounded<int>(capacity);

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
      } else if (r.disconnected) {
        break;
      }
    }
  }();

  final sendLoop = () async {
    for (var i = 0; i < iters; i++) {
      final s = await tx.send(i);
      if (s.disconnected) break;
    }
    tx.close();
  }();

  await Future.wait([recvLoop, sendLoop]);
  final elapsed = swAll.elapsed;

  return Stats(label, iters, elapsed, maxLatencyNs);
}

// pipeline (large or unbounded cap). Producer pushes N; consumer drains N.
Future<Stats> _benchPipeline(
  int? capacity, // null => unbounded
  int iters,
  String label,
) async {
  final (tx, rx) =
      capacity == null ? Mpsc.unbounded<int>() : Mpsc.bounded<int>(capacity);

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
      } else if (r.disconnected) {
        break;
      }
    }
  }();

  final sendLoop = () async {
    for (var i = 0; i < iters; i++) {
      final s = await tx.send(i);
      if (s.disconnected) break;
    }
    tx.close();
  }();

  await Future.wait([recvLoop, sendLoop]);
  final elapsed = swAll.elapsed;

  return Stats(label, iters, elapsed, maxLatencyNs);
}

// multi-producers via clone(), one consumer. Each producer sends itersPerProducer elements.
Future<Stats> _benchMultiProducers(
  int producers,
  int capacity,
  int itersPerProducer,
  String label,
) async {
  final (tx0, rx) = Mpsc.bounded<int>(capacity);

  // Clones
  final senders = <MpscSender<int>>[tx0];
  for (var i = 1; i < producers; i++) {
    senders.add(senders.first.clone());
  }

  final total = itersPerProducer * producers;
  var received = 0;
  var maxLatencyNs = 0;

  final swAll = Stopwatch()..start();

  final recvLoop = () async {
    while (received < total) {
      final t0 = Stopwatch()..start();
      final r = await rx.recv();
      final t = t0.elapsedMicroseconds * 1000;
      if (r.ok) {
        if (t > maxLatencyNs) maxLatencyNs = t;
        received++;
      } else if (r.disconnected) {
        break;
      }
    }
  }();

  final senderTasks = <Future<void>>[];
  for (var i = 0; i < producers; i++) {
    final s = senders[i];
    senderTasks.add(() async {
      for (var k = 0; k < itersPerProducer; k++) {
        final res = await s.send(k);
        if (res.disconnected) break;
      }
      s.close();
    }());
  }

  await Future.wait([recvLoop, ...senderTasks]);
  final elapsed = swAll.elapsed;

  return Stats(label, total, elapsed, maxLatencyNs);
}

Future<Stats> _benchSliding(
  DropPolicy policy,
  int capacity,
  int iters,
  String label,
) async {
  var dropped = 0;

  final (tx, rx) = Mpsc.channel<int>(
    capacity: capacity,
    policy: policy,
    onDrop: (_) => dropped++,
  );

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
      } else if (r.disconnected) {
        break;
      }
    }
  }();

  final sendLoop = () async {
    for (var i = 0; i < iters; i++) {
      // simulate producer faster than consumer to trigger drops
      final res = tx.trySend(i);
      if (res.full) {
        // back off a bit to avoid saturating the loop too unfairly
        await tx.send(i);
      }
    }
    tx.close();
  }();

  await Future.wait([recvLoop, sendLoop]);
  final elapsed = swAll.elapsed;

  return Stats(
    label,
    iters,
    elapsed,
    maxLatencyNs,
    notes:
        'drops: $dropped  delivered: $received (${(100.0 * received / (received + dropped)).toStringAsFixed(1)}% kept)',
  );
}

Future<Stats> _benchLatestOnly(int iters, String label) async {
  final (tx, rx) = Mpsc.latest<int>();

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

        if ((received & 0x3FF) == 0) {
          // ignore: unused_local_variable
          var x = 0;
          for (int i = 0; i < 64; i++) {
            x ^= i * i;
          }
        }
      } else if (r.disconnected) {
        break;
      }
    }
  }();

  final sendLoop = () async {
    for (var i = 0; i < iters; i++) {
      tx.trySend(i);
    }
    tx.close();
  }();

  await Future.wait([recvLoop, sendLoop]);
  final elapsed = swAll.elapsed;

  final keepPct = (100.0 * received / iters).toStringAsFixed(1);

  return Stats(
    label,
    iters,
    elapsed,
    maxLatencyNs,
    notes: 'kept: $received / $iters  ($keepPct% observed)',
  );
}
