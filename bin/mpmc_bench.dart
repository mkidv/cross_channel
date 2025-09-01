import 'dart:async';
import 'package:cross_channel/mpmc.dart';
import 'utils.dart';

Future<void> main(List<String> args) async {
  final iters = args.isNotEmpty && !args[0].contains('--csv')
      ? int.parse(args[0])
      : 2_000_000;

  final csv = args.contains('--csv');

  // Warmup
  await _benchPingPong(1, 200_000, 'warmup');

  final results = <Stats>[];

  results.add(await _benchPingPong(1, iters, 'mpmc ping-pong cap=1 (1P/1C)'));

  results.add(
    await _benchPipeline(1024, iters, 'mpmc pipeline cap=1024 (1P/1C)'),
  );

  results.add(
    await _benchPipeline(null, iters, 'mpmc pipeline unbounded (1P/1C)'),
  );

  results.add(
    await _benchMultiProducers(
      4,
      1024,
      (iters / 4).round(),
      'mpmc producers x4 cap=1024 (1C)',
    ),
  );

  results.add(
    await _benchProducersConsumers(
      4,
      4,
      1024,
      (iters / 4).round(),
      'mpmc producers x4 / consumers x4 cap=1024',
    ),
  );

  results.add(
    await _benchPipeline(0, iters, 'mpmc pipeline rendezvous cap=0 (1P/1C)'),
  );

  results.add(
    await _benchSliding(
      DropPolicy.oldest,
      1024,
      iters,
      'mpmc sliding=oldest cap=1024 (1P/1C)',
    ),
  );

  results.add(
    await _benchSliding(
      DropPolicy.newest,
      1024,
      iters,
      'mpmc sliding=newest cap=1024 (1P/1C)',
    ),
  );

  results.add(
    await _benchLatestOnly1C(iters, 'mpmc latestOnly (coalesce) (1P/1C)'),
  );

  results.add(
    await _benchLatestOnly4C(
      iters,
      'mpmc latestOnly (coalesce) (1P/4C competitive)',
    ),
  );

  if (csv) {
    print('suite,case,mops,ns_per_op,max_latency_us,notes');
    for (final r in results) {
      print(r.toCsv(suite: 'MPMC'));
    }
    return;
  }

  print('\n=== MPMC Bench (Dart VM) $iters ===');
  for (final r in results) {
    print(r.toString());
  }
}

Future<Stats> _benchPingPong(int capacity, int iters, String label) async {
  final (tx, rx) = Mpmc.bounded<int>(capacity);

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

Future<Stats> _benchPipeline(int? capacity, int iters, String label) async {
  final (tx, rx) =
      capacity == null ? Mpmc.unbounded<int>() : Mpmc.bounded<int>(capacity);

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

Future<Stats> _benchMultiProducers(
  int producers,
  int capacity,
  int itersPerProducer,
  String label,
) async {
  final (tx0, rx) = Mpmc.bounded<int>(capacity);

  final senders = <MpmcSender<int>>[tx0];
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

/// Producteurs + consommateurs multiples qui se partagent la file (work-stealing style).
Future<Stats> _benchProducersConsumers(
  int producers,
  int consumers,
  int capacity,
  int itersPerProducer,
  String label,
) async {
  final (tx0, rx0) = Mpmc.bounded<int>(capacity);

  // Producers
  final senders = <MpmcSender<int>>[tx0];
  for (var i = 1; i < producers; i++) {
    senders.add(senders.first.clone());
  }

  // Consumers
  final receivers = <MpmcReceiver<int>>[rx0];
  for (var i = 1; i < consumers; i++) {
    receivers.add(rx0.clone());
  }

  final total = itersPerProducer * producers;
  var received = 0;
  var maxLatencyNs = 0;

  final swAll = Stopwatch()..start();

  final consumerTasks = <Future<void>>[];
  for (final rx in receivers) {
    consumerTasks.add(() async {
      while (true) {
        final t0 = Stopwatch()..start();
        final r = await rx.recv();
        final t = t0.elapsedMicroseconds * 1000;
        if (r.ok) {
          if (t > maxLatencyNs) maxLatencyNs = t;
          // atomique approximative: contention minime en bench mono-isolate
          received++;
          if (received >= total) break;
        } else if (r.disconnected) {
          break;
        }
      }
    }());
  }

  final producerTasks = <Future<void>>[];
  for (final s in senders) {
    producerTasks.add(() async {
      for (var k = 0; k < itersPerProducer; k++) {
        final res = await s.send(k);
        if (res.disconnected) break;
      }
      s.close();
    }());
  }

  await Future.wait([...producerTasks, ...consumerTasks]);
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

  final (tx, rx) = Mpmc.channel<int>(
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
      final res = tx.trySend(i);
      if (res.full) {
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

Future<Stats> _benchLatestOnly1C(int iters, String label) async {
  final (tx, rx) = Mpmc.latest<int>();

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
      tx.trySend(i); // coalesce
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

Future<Stats> _benchLatestOnly4C(int iters, String label) async {
  final (tx, rx0) = Mpmc.latest<int>();

  final r1 = rx0.clone();
  final r2 = rx0.clone();
  final r3 = rx0.clone();

  final counters = [0, 0, 0, 0];
  var maxLatencyNs = 0;

  final swAll = Stopwatch()..start();

  Future<void> runConsumer(int idx, MpmcReceiver<int> rx) async {
    while (true) {
      final t0 = Stopwatch()..start();
      final r = await rx.recv();
      final t = t0.elapsedMicroseconds * 1000;
      if (r.ok) {
        counters[idx]++;
        if (t > maxLatencyNs) maxLatencyNs = t;
        if (counters.fold<int>(0, (a, b) => a + b) >= iters) {
          break;
        }

        if ((counters[idx] & 0x3FF) == 0) {
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
  }

  final consumers = <Future<void>>[
    runConsumer(0, rx0),
    runConsumer(1, r1),
    runConsumer(2, r2),
    runConsumer(3, r3),
  ];

  final sendLoop = () async {
    for (var i = 0; i < iters; i++) {
      tx.trySend(i); // coalesce
    }
    tx.close();
  }();

  await Future.wait([sendLoop, ...consumers]);
  final elapsed = swAll.elapsed;

  final received = counters.fold<int>(0, (a, b) => a + b);
  final keepPct = (100.0 * received / iters).toStringAsFixed(1);

  return Stats(
    label,
    iters,
    elapsed,
    maxLatencyNs,
    notes: 'kept: $received / $iters  ($keepPct% observed)  '
        'split: ${counters[0]}/${counters[1]}/${counters[2]}/${counters[3]}',
  );
}
