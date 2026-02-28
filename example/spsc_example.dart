import 'dart:async';

import 'package:cross_channel/spsc.dart';

Future<void> main() async {
  // 1. Create a bounded SPSC channel for 1:1 communication
  final (tx, rx) = Spsc.channel<int>(1024);

  // 2. Producer
  Future<void> produceEvents() async {
    for (int i = 0; i < 5; i++) {
      await tx.send(i);
      print('SPSC Sent: $i');
    }
    tx.close(); // Graceful shutdown
  }

  unawaited(produceEvents());

  // 3. Single Consumer
  await for (final value in rx.stream()) {
    print('SPSC Received: $value');
  }
}
