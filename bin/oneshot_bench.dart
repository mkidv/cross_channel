import 'dart:async';
import 'package:cross_channel/oneshot.dart';
import 'utils.dart';

Future<void> main(List<String> args) async {
  final iters = args.isNotEmpty && !args[0].contains('--csv')
      ? int.parse(args[0])
      : 2_000_000;

  final csv = args.contains('--csv');

  // Warmup
  await _benchCreateSendRecv(50_000, 'warmup');

  final results = <Stats>[];

  results.add(await _benchCreateSendRecv(
    iters,
    'oneshot create+send+recv',
  ));
  results.add(await _benchReuseSenderRecv(
    iters,
    'oneshot reuse sender (new rx)',
  ));

  if (csv) {
    print('suite,case,mops,ns_per_op,max_latency_us,notes');
    for (final r in results) {
      print(r.toCsv(suite: 'ONESHOT'));
    }
    return;
  }

  print('\n=== ONESHOT Bench (Dart VM) ===');
  for (final r in results) {
    print(r.toString());
  }
}

/// create N channels, send, receive, then let GC do its job.
Future<Stats> _benchCreateSendRecv(int iters, String label) async {
  var maxNs = 0;
  final sw = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    final (tx, rx) = OneShot.channel<int>();
    final sendFut = tx.send(i);
    final t0 = Stopwatch()..start();
    await rx.recv();
    final dt = t0.elapsedMicroseconds * 1000;
    if (dt > maxNs) maxNs = dt;
    // semantics: send returns immediately in our impl; just await to be fair
    await sendFut;
  }
  sw.stop();
  return Stats(label, iters, sw.elapsed, maxNs);
}

/// reuse the sender, only create a new receiver.
/// Useful to see the allocation cost of the pair.
Future<Stats> _benchReuseSenderRecv(int iters, String label) async {
  var maxNs = 0;
  final sw = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    // recreate the pair (no separate factory for RX only in the API),
    // but we still measure a second simple form.
    final (tx, rx) = OneShot.channel<int>();
    final _ = await tx.send(i);
    final t0 = Stopwatch()..start();
    final r = await rx.recv();
    final dt = t0.elapsedMicroseconds * 1000;
    if (dt > maxNs) maxNs = dt;
    if (!r.ok) throw StateError('unexpected recv error');
  }
  sw.stop();
  return Stats(label, iters, sw.elapsed, maxNs);
}
