import 'dart:isolate';

import 'package:cross_channel/broadcast.dart';

void main() async {
  print('Creating broadcast channel...');
  final (tx, b) = Broadcast.channel<int>(1024);
  final rx = b.subscribe();

  final p = ReceivePort();
  print('Spawning isolate...');
  try {
    await Isolate.spawn(_worker, [rx, p.sendPort]);
    print('Spawn successful');

    // Give time for worker to connect
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // Send data
    for (var i = 0; i < 10; i++) {
      await tx.send(i);
    }
    tx.close();

    await p.first;
    print('Done');
  } catch (e) {
    print('Error: $e');
  }
}

Future<void> _worker(List<dynamic> args) async {
  final rx = args[0] as BroadcastReceiver<int>;
  final p = args[1] as SendPort;

  print('Worker started recv');
  await for (var msg in rx.stream()) {
    print('Worker got: $msg');
  }
  print('Worker finished');
  p.send(true);
}
