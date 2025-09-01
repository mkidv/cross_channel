import 'dart:async';
import 'package:cross_channel/oneshot.dart';
import 'package:test/test.dart';

void main() {
  group('Oneshot - channel', () {
    test('basic send/recv works once', () async {
      final (tx, rx) = OneShot.channel<int>();
      unawaited(() async {
        final s = await tx.send(42);
        expect(s.ok, isTrue);
      }());
      final r = await rx.recv();
      expect(r.ok, isTrue);
      expect(r.valueOrNull, 42);
    });

    test(
      'double send returns SendErrorDisconnected; tryRecv returns first value',
      () async {
        final (tx, rx) = OneShot.channel<int>();

        final s1 = await tx.send(1);
        expect(s1.ok, isTrue);

        final s2 = await tx.send(2);
        expect(s2.disconnected, isTrue);

        final r = rx.tryRecv();
        expect(r.ok, isTrue);
        expect(r.valueOrNull, 1);
      },
    );

    test('trySend after first send -> disconnected', () async {
      final (tx, rx) = OneShot.channel<int>();
      expect((await tx.send(9)).ok, isTrue);
      final s2 = tx.trySend(10);
      expect(s2.disconnected, isTrue);
      expect((await rx.recv()).valueOrNull, 9);
    });

    test('consumeOnce=true: one waiter gets value, others error', () async {
      final (tx, rx) = OneShot.channel<int>(consumeOnce: true);
      final f1 = rx.recv();
      final f2 = rx.recv(); // arrivera trop tard

      final s = await tx.send(7);
      expect(s.ok, isTrue);

      expect((await f1).ok, isTrue);
      expect((await f2).disconnected, isTrue);
    });

    test('consumeOnce=true: recv after consumed -> disconnected', () async {
      final (tx, rx) = OneShot.channel<String>(consumeOnce: true);
      await tx.send('X');
      expect((await rx.recv()).ok, isTrue);
      expect((await rx.recv()).disconnected, isTrue);
    });

    test('consumeOnce=false: multi reads allowed', () async {
      final (tx, rx) = OneShot.channel<int>();
      await tx.send(42);
      for (var i = 0; i < 3; i++) {
        final r = await rx.recv();
        expect(r.ok, isTrue);
        expect(r.valueOrNull, 42);
      }
    });
  });
}
