import 'dart:async';

import 'package:cross_channel/broadcast.dart';
import 'package:test/test.dart';

void main() {
  group('Broadcast Channel', () {
    test('Basic Pub/Sub - All subscribers receive all messages', () async {
      final (tx, broadcast) = Broadcast.channel<int>(16);

      final sub1 = broadcast.subscribe();
      final sub2 = broadcast.subscribe();

      unawaited(tx.send(1));
      unawaited(tx.send(2));
      unawaited(tx.send(3));

      expect(await sub1.stream().take(3).toList(), [1, 2, 3]);
      expect(await sub2.stream().take(3).toList(), [1, 2, 3]);

      sub1.close();
      sub2.close();
      tx.close();
    });

    test('Late subscriber sees future messages by default', () async {
      final (tx, broadcast) = Broadcast.channel<int>(16);

      unawaited(tx.send(1));
      unawaited(tx.send(2));

      final sub = broadcast.subscribe(); // Should start at 3
      unawaited(tx.send(3));
      unawaited(tx.send(4));

      expect(await sub.stream().take(2).toList(), [3, 4]);
      tx.close();
    });

    test('Late subscriber with replay sees history', () async {
      final (tx, broadcast) = Broadcast.channel<int>(16);

      unawaited(tx.send(10));
      unawaited(tx.send(20));
      unawaited(tx.send(30));

      // Replay last 2
      final sub = broadcast.subscribe(replay: 2);

      unawaited(tx.send(40));

      expect(await sub.stream().take(3).toList(), [20, 30, 40]);
      tx.close();
    });

    test('Replay clamps to capacity if requested more than available',
        () async {
      final (tx, broadcast) = Broadcast.channel<int>(4); // Cap 4

      // Fill with 0..9.
      // Ring state: [6, 7, 8, 9] (assuming overwrite)
      // Actually overwrite logic:
      // Writes 0,1,2,3 -> [0,1,2,3]. _writeSeq=4
      // Writes 4 -> overwrites 0. _writeSeq=5. Valid window: [1..4] for cap=4?
      // Buffer capacity is power of 2. cap=4.
      // Valid window is typically [writeSeq-cap, writeSeq-1]

      for (var i = 0; i < 10; i++) {
        unawaited(tx.send(i));
      }

      // Current tail is at 10-4 = 6. Items available: 6, 7, 8, 9.

      // Request replay 100
      final sub = broadcast.subscribe(replay: 100);

      expect(await sub.stream().take(4).toList(), [6, 7, 8, 9]);
      tx.close();
    });

    test('Slow subscriber Lag Detection (Skip)', () async {
      final (tx, broadcast) = Broadcast.channel<int>(4);

      final sub = broadcast.subscribe();

      // Fill buffer and overflow
      // Cap 4.
      // Send 0..4 (5 items). Item 0 is overwritten by Item 4.
      // Valid: 1, 2, 3, 4.
      for (var i = 0; i < 6; i++) {
        unawaited(tx.send(i));
      }
      // Sent: 0,1,2,3,4,5
      // Valid in buffer: 2, 3, 4, 5

      // Sub was at 0. It lagged.
      // Expect jump to 2.

      expect(await sub.recv().then((r) => r.valueOrNull), 2);
      expect(await sub.recv().then((r) => r.valueOrNull), 3);

      tx.close();
    });
  });
}
