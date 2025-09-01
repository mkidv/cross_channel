import 'dart:async';
import 'dart:isolate';
import 'package:cross_channel/isolate_extension.dart';
import 'package:cross_channel/mpsc.dart';
import 'utils.dart';

/// "Simple" worker
void echoWorker(SendPort handshake) {
  final cmd = ReceivePort();
  handshake.send(cmd.sendPort);
  SendPort? status;
  cmd.listen((msg) {
    if (msg is! Map) return;
    switch (msg['command']) {
      case 'init':
        status = msg['status'] as SendPort;
        status?.send({'type': 'log', 'message': 'ready'});
        break;
      case 'echo':
        final reply = msg['reply'] as SendPort;
        reply.send('echo:${msg['text']}');
        break;
      case 'burst':
        final n = (msg['n'] as int?) ?? 1000;
        for (var i = 0; i < n; i++) {
          status?.send({'type': 'tick', 'i': i});
        }
        break;
      case 'quit':
        status?.send({'type': 'bye'});
        cmd.close();
        Isolate.exit();
    }
  });
}

Future<void> main(List<String> args) async {
  final iters = args.isNotEmpty && !args[0].contains('--csv')
      ? int.parse(args[0])
      : 20000;
  final ticks = args.length > 1 && !args[1].contains('--csv')
      ? int.parse(args[1])
      : 500000;

  final csv = args.contains('--csv');

  final handshake = ReceivePort();
  final iso = await Isolate.spawn(echoWorker, handshake.sendPort);
  final cmd = await handshake.first as SendPort;

  final statusPort = ReceivePort();
  final (_, statusRx) = statusPort.toMpsc<Map<String, dynamic>>(capacity: 2048);

  cmd.send({'command': 'init', 'status': statusPort.sendPort});

  final first =
      (await statusRx.recvTimeout(const Duration(seconds: 1))).valueOrNull;
  if (first?['type'] != 'log') {
    throw StateError('worker not ready');
  }

  // Warmups
  await cmd.request<String>('echo', data: {'text': 'warmup'});

  final results = <Stats>[];

  results.add(await _benchRpc(
    cmd,
    iters,
    'isolate request echo',
  ));

  results.add(await _benchBurst(
    cmd,
    statusRx,
    ticks,
    'isolate event drain',
  ));

  // clean
  cmd.send({'command': 'quit'});
  await Future<void>.delayed(const Duration(milliseconds: 20));
  statusPort.close();
  iso.kill(priority: Isolate.immediate);

  if (csv) {
    print('suite,case,mops,ns_per_op,max_latency_us,notes');
    for (final r in results) {
      print(r.toCsv(suite: 'ISOLATE'));
    }
    return;
  }

  print('\n=== ISOLATE Bench (Dart VM) ===');
  for (final r in results) {
    print(r.toString());
  }
}

/// echo
Future<Stats> _benchRpc(SendPort cmd, int iters, String label) async {
  var maxNs = 0;
  final sw = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    final t0 = Stopwatch()..start();
    final s = await cmd.request<String>('echo', data: {'text': i});
    final dt = t0.elapsedMicroseconds * 1000;
    if (dt > maxNs) maxNs = dt;
    if (s != 'echo:$i') throw StateError('bad echo');
  }
  sw.stop();
  return Stats(label, iters, sw.elapsed, maxNs);
}

/// event tick and measure drain
Future<Stats> _benchBurst(
  SendPort cmd,
  MpscReceiver<Map<String, dynamic>> statusRx,
  int ticks,
  String label,
) async {
  var seen = 0;
  final completer = Completer<void>();

  final sub = statusRx.stream().listen((ev) {
    if (ev['type'] == 'tick') {
      seen++;
      if (seen == ticks && !completer.isCompleted) completer.complete();
    }
  });

  final sw = Stopwatch()..start();
  cmd.send({'command': 'burst', 'n': ticks});
  await completer.future;
  sw.stop();
  await sub.cancel();

  return Stats(label, ticks, sw.elapsed, 0);
}
