import 'dart:async';
import 'dart:isolate';
import 'package:cross_channel/isolate_extension.dart';
import 'package:cross_channel/mpmc.dart';
import 'package:cross_channel/src/core.dart';
import 'package:test/test.dart';

import 'utils.dart';

// Simple echo worker used across the tests
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
      case 'exit':
        status?.send({'type': 'bye'});
        cmd.close();
        Isolate.exit();
    }
  });
}

void main() {
  group('Isolate bridge', () {
    test('oneshot RPC + bounded events via mpscFromReceivePort', () async {
      final handshake = ReceivePort();
      final isolate = await Isolate.spawn(echoWorker, handshake.sendPort);
      final cmd = await handshake.first as SendPort;

      final statusPort = ReceivePort();
      final (_, statusRx) =
          statusPort.toMpsc<Map<String, dynamic>>(capacity: 64);

      cmd.sendCmd('init', data: {'status': statusPort.sendPort});

      // expect a 'ready' within 1s
      final first = (await statusRx.recvTimeout(
        const Duration(seconds: 1),
      ))
          .valueOrNull;
      expect(first?['type'], 'log');

      // RPC echo
      final echo = await cmd.request<String>('echo', data: {'text': 'x'});
      expect(echo, 'echo:x');

      // Collect briefly using recvAll with a small idle window (no subscription juggling)
      cmd.sendCmd('burst', data: {'n': 2000});
      final got = await statusRx.recvAll(idle: const Duration(milliseconds: 1));
      // we should have at least one tick, but not necessarily 2000 (cap/drops)
      expect(got.any((e) => e['type'] == 'tick'), isTrue);

      // clean
      cmd.sendCmd('exit');
      await tick();
      statusPort.close();
      isolate.kill(priority: Isolate.immediate);
    });

    test('oneshotCall times out on unknown/ignored command', () async {
      final handshake = ReceivePort();
      final isolate = await Isolate.spawn(echoWorker, handshake.sendPort);
      final cmd = await handshake.first as SendPort;

      // send an unhandled RPC (worker ignores anything but "echo")
      expect(
        () => cmd.request<String>(
          'unknown_command',
          data: {'foo': 'bar'},
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );

      // cleanup
      cmd.sendCmd('exit');
      await tick();
      isolate.kill(priority: Isolate.immediate);
    });

    test(
      'mpmcFromReceivePort: work-sharing across multiple local consumers',
      () async {
        final handshake = ReceivePort();
        final isolate = await Isolate.spawn(echoWorker, handshake.sendPort);
        final cmd = await handshake.first as SendPort;

        final statusPort = ReceivePort();
        final (mpmcTx, mpmcRx0) =
            statusPort.toMpmc<Map<String, dynamic>>(capacity: 64);
        // clone two more local consumers
        final mpmcRx1 = mpmcRx0.clone();
        final mpmcRx2 = mpmcRx0.clone();

        // init
        cmd.sendCmd('init', data: {'status': statusPort.sendPort});
        final first =
            (await mpmcRx0.recvTimeout(const Duration(seconds: 1))).valueOrNull;
        expect(first?['type'], 'log');

        // start three workers sharing the same queue
        final seen = <int>{};
        Future<void> worker(MpmcReceiver<Map<String, dynamic>> rx) async {
          await for (final ev in rx.stream()) {
            if (ev['type'] == 'tick') {
              seen.add(ev['i'] as int);
            }
          }
        }

        final w0 = worker(mpmcRx0);
        final w1 = worker(mpmcRx1);
        final w2 = worker(mpmcRx2);

        // trigger a burst; capacity may cause drops, that's fine
        cmd.sendCmd('burst', data: {'n': 500});
        await tick(2);

        // we should have consumed at least some items, without duplicates (set)
        expect(seen.isNotEmpty, isTrue);

        // exit
        cmd.sendCmd('exit');
        await tick();

        // tear down
        statusPort.close();
        mpmcRx0.close();
        mpmcRx1.close();
        mpmcRx2.close();
        mpmcTx.close();
        await Future.wait([
          w0,
          w1,
          w2,
        ]).timeout(const Duration(milliseconds: 50));
        isolate.kill(priority: Isolate.immediate);
      },
    );
  });
}
