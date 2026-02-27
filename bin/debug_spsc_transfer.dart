import 'dart:isolate';

import 'package:cross_channel/spsc.dart';
import 'package:cross_channel/src/core.dart';

void main() async {
  print('Creating SPSC channel...');
  final (tx, rx) = Spsc.channel<int>(1024);

  final pRx = ReceivePort();

  print('Spawning receiver isolate...');
  await Isolate.spawn(_workerRx, [rx, pRx.sendPort]);

  // Delay before sender to allow receiver to connect
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final pTx = ReceivePort();
  print('Spawning sender isolate...');
  await Isolate.spawn(_workerTx, [tx, pTx.sendPort]);

  print('Waiting for completion...');
  await Future.wait([pRx.first, pTx.first]);
  print('All done');
}

Future<void> _workerRx(List<dynamic> args) async {
  final receiver = args[0] as Receiver<int>;
  final p = args[1] as SendPort;

  print('Rx Worker started');
  int count = 0;
  while (count < 10) {
    final res = await receiver.recv();
    if (res.hasValue) {
      print('Rx got: ${res.value}');
      count++;
    } else if (res is RecvErrorDisconnected) {
      print('Rx Disconnected!');
      break;
    }
  }
  p.send('Rx Done');
}

Future<void> _workerTx(List<dynamic> args) async {
  final tx = args[0] as Sender<int>;
  final p = args[1] as SendPort;

  print('Tx Worker started');
  for (var i = 0; i < 10; i++) {
    final res = await tx.send(i);
    if (res is SendErrorDisconnected) {
      print('Tx Disconnected!');
      break;
    }
  }
  p.send('Tx Done');
}
