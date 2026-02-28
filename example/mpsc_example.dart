import 'package:cross_channel/mpsc.dart';

Future<void> main() async {
  // 1. Create an MPSC channel for N:1 communication
  final (eventTx, eventRx) = Mpsc.unbounded<String>();

  // 2. Multiple Producers (we clone the sender)
  final userTx = eventTx.clone();
  final networkTx = eventTx.clone();

  // Send from different sources concurrently
  await userTx.send('User clicked button');
  await networkTx.send('Data downloaded');

  // Close when done
  userTx.close();
  networkTx.close();
  eventTx.close(); // Close base sender

  // 3. Single Event Loop (Consumer)
  await for (final event in eventRx.stream()) {
    print('Processed Event: $event');
  }
}
