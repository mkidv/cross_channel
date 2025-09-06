import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'utils.dart';

/// "Raw" worker:
void rawWorker(SendPort handshake) {
  final rp = ReceivePort();
  handshake.send(rp.sendPort);

  SendPort? status;

  rp.listen((msg) {
    // raw ping-pong: [SendPort reply, int x]
    if (msg is List && msg.length == 2 && msg[0] is SendPort && msg[1] is int) {
      final reply = msg[0] as SendPort;
      reply.send(msg[1]);
      return;
    }

    if (msg is Map) {
      if (msg['setStatus'] is SendPort) {
        status = msg['setStatus'] as SendPort;
        return;
      }
      if (msg['burst'] is int) {
        final n = msg['burst'] as int;
        for (var i = 0; i < n; i++) {
          status?.send(i);
        }
        return;
      }
      if (msg['echoBytes'] is Uint8List && msg['reply'] is SendPort) {
        (msg['reply'] as SendPort).send(msg['echoBytes']);
        return;
      }
      if (msg['quit'] == true) {
        rp.close();
        Isolate.exit();
      }
    }
  });
}

Future<void> main(List<String> args) async {
  final (iters, csv, _) = parseArgs(args);

  final payloadIters = 10_000;
  final payloadBytes = 16_384; // 16 KB

  final handshake = ReceivePort();
  final iso = await Isolate.spawn(rawWorker, handshake.sendPort);
  final cmd = await handshake.first as SendPort;
  handshake.close();

  final status = ReceivePort();
  cmd.send({'setStatus': status.sendPort});

  // Warmup
  await _benchPingPongRaw(cmd, 1000, 'warmup');
  await _benchPayloadRoundtrip(cmd, 100, 1024, 'warmup');

  final results = <Stats>[];

  results.add(await _benchPingPongRaw(
    cmd,
    iters,
    'raw SendPort ping-pong (int)',
  ));

  results.add(await _benchPayloadRoundtrip(
    cmd,
    payloadIters,
    payloadBytes,
    'SendPort roundtrip Uint8List (${payloadBytes.bytesToPrettyString()})',
  ));

  results.add(await _benchRawBurst(
    cmd,
    status,
    500_000,
    'raw event drain (int)',
  ));

  // cleanup
  cmd.send({'quit': true});
  await Future<void>.delayed(const Duration(milliseconds: 10));
  status.close();
  iso.kill(priority: Isolate.immediate);

  if (csv) {
    print('suite,case,mops,ns_per_op,max_latency_us,notes');
    for (final r in results) {
      print(r.toCsv(suite: 'INTER-ISOLATE'));
    }
    return;
  }

  print('\n=== INTER-ISOLATE Bench (Dart VM) ===');
  for (final r in results) {
    print(r.toString());
  }
}

/// ping-pong SendPort loop N times, send [reply, i] and wait for i.
Future<Stats> _benchPingPongRaw(SendPort cmd, int iters, String label) async {
  var maxNs = 0;
  final sw = Stopwatch()..start();

  for (var i = 0; i < iters; i++) {
    final reply = ReceivePort();
    final t0 = Stopwatch()..start();
    cmd.send([reply.sendPort, i]);
    final got = await reply.first as int;
    final dt = t0.elapsedMicroseconds * 1000;
    if (dt > maxNs) maxNs = dt;
    if (got != i) throw StateError('bad echo for $i');
    reply.close();
  }

  sw.stop();
  return Stats(label, iters, sw.elapsed, maxNs);
}

/// binary payload round-trip to estimate serialization/copy cost.
Future<Stats> _benchPayloadRoundtrip(
  SendPort cmd,
  int iters,
  int bytes,
  String label,
) async {
  final payload = Uint8List(bytes);
  for (var i = 0; i < payload.length; i++) {
    payload[i] = i & 0xFF;
  }

  var maxNs = 0;
  final sw = Stopwatch()..start();

  for (var i = 0; i < iters; i++) {
    final reply = ReceivePort();
    final t0 = Stopwatch()..start();
    cmd.send({'echoBytes': payload, 'reply': reply.sendPort});
    final back = await reply.first as Uint8List;
    final dt = t0.elapsedMicroseconds * 1000;
    if (dt > maxNs) maxNs = dt;
    if (back.lengthInBytes != payload.lengthInBytes) {
      throw StateError('bad payload length');
    }
    reply.close();
  }

  sw.stop();
  return Stats(label, iters, sw.elapsed, maxNs);
}

/// drain of integer events without MPSC (raw baseline).
Future<Stats> _benchRawBurst(
  SendPort cmd,
  ReceivePort status,
  int n,
  String label,
) async {
  var seen = 0;
  final completer = Completer<void>();

  final sub = status.listen((msg) {
    if (msg is int) {
      if (++seen == n && !completer.isCompleted) completer.complete();
    }
  });

  final sw = Stopwatch()..start();
  cmd.send({'burst': n});
  await completer.future;
  sw.stop();
  await sub.cancel();

  return Stats(label, n, sw.elapsed, 0);
}
