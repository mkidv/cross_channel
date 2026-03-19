// ignore_for_file: avoid_print

import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  // 1. MPSC (Multi-Producer Single-Consumer)
  final (mpscTx, _) = XChannel.mpsc<String>(capacity: 100);
  await mpscTx.send('task');

  // 2. MPMC (Multi-Producer Multi-Consumer) - cloned receivers
  final (mpmcTx, mpmcRx0) = XChannel.mpmc<String>(capacity: 10);
  final mpmcRx1 = mpmcRx0.clone();
  print('Consumers: $mpmcRx0, $mpmcRx1');
  await mpmcTx.send('work');

  // 3. OneShot
  final (oneTx, oneRx) = XChannel.oneshot<String>();
  await oneTx.send('reply');
  await oneRx.recv();

  // 4. SPSC (Single-Producer Single-Consumer)
  final (spscTx, _) = XChannel.spsc<int>(capacity: 1024);
  await spscTx.send(42);

  // 5. Broadcast
  final (bcTx, bcAt) = XChannel.broadcast<String>(capacity: 128);
  final sub = bcAt.subscribe(replay: 5);
  print('Subscriber created: $sub');
  await bcTx.send('announcement');
}
