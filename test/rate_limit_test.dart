import 'dart:async';

import 'package:cross_channel/cross_channel.dart';
import 'package:test/test.dart';

void main() {
  group('Sender Rate Limits', () {
    test('Throttle: Drops events during cooldown', () async {
      final (tx, rx) = XChannel.mpsc<int>();

      // Throttle 100ms
      final throttled = tx.throttle(const Duration(milliseconds: 100));

      unawaited(throttled.send(1)); // Sent (t=0)
      unawaited(throttled.send(2)); // Dropped (t=0)
      unawaited(throttled.send(3)); // Dropped (t=0)

      await Future<void>.delayed(const Duration(milliseconds: 150));

      unawaited(throttled.send(4)); // Sent (t=150 > 100)

      expect(await rx.stream().take(2).toList(), [1, 4]);
      // 2 and 3 should be missing

      tx.close();
    });

    test('Debounce: Only last event is sent after silence', () async {
      final (tx, rx) = XChannel.mpsc<int>();

      // Debounce 100ms
      final debounced = tx.debounce(const Duration(milliseconds: 100));

      unawaited(debounced.send(1));
      unawaited(debounced.send(2));
      unawaited(debounced.send(3));

      // 1, 2 should be cancelled. 3 scheduled.

      await Future<void>.delayed(const Duration(milliseconds: 150));

      // 3 should have arrived.

      unawaited(debounced.send(4));
      // Wait but interrupt with 5
      await Future<void>.delayed(const Duration(milliseconds: 50));
      unawaited(debounced.send(5)); // 4 Cancelled, 5 scheduled.

      await Future<void>.delayed(const Duration(milliseconds: 150));
      // 5 Should have arrived.

      expect(await rx.stream().take(2).toList(), [3, 5]);

      tx.close();
    });
  });
}
