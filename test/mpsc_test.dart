import 'dart:async';
import 'package:cross_channel/mpsc.dart';
import 'package:test/test.dart';

import 'utils.dart';

void main() {
  group('MPSC - unbounded channel', () {
    test('basic send/recv (FIFO order)', () async {
      final (tx, rx) = Mpsc.unbounded<int>();

      expect((await tx.send(1)).hasSend, isTrue);
      expect((await tx.send(2)).hasSend, isTrue);
      expect((await tx.send(3)).hasSend, isTrue);

      final r1 = await rx.recv();
      final r2 = await rx.recv();
      final r3 = await rx.recv();

      expect(r1.hasValue, isTrue);
      expect(r2.hasValue, isTrue);
      expect(r3.hasValue, isTrue);

      expect(r1.valueOrNull, 1);
      expect(r2.valueOrNull, 2);
      expect(r3.valueOrNull, 3);

      tx.close();

      final r4 = await rx.recv();
      expect(r4.isDisconnected, isTrue);
    });

    test('send before receiver attached -> buffered then delivered', () async {
      final (tx, rx) = Mpsc.unbounded<int>();

      expect((await tx.send(10)).hasSend, isTrue);
      expect((await tx.send(11)).hasSend, isTrue);

      // On attache le receiver après coup : on doit tout récupérer
      expect((await rx.recv()).valueOrNull, 10);
      expect((await rx.recv()).valueOrNull, 11);

      tx.close();
      expect((await rx.recv()).isDisconnected, isTrue);
    });

    test('tryRecv: empty vs disconnected', () async {
      final (tx, rx) = Mpsc.unbounded<int>();

      final e1 = rx.tryRecv();
      expect(e1.isEmpty, isTrue);

      tx.close();

      final e2 = rx.tryRecv();
      expect(e2.isDisconnected, isTrue);
    });

    test(
      'stream() drains then completes (single-subscription per handle)',
      () async {
        final (tx, rx) = Mpsc.unbounded<int>();
        for (var i = 0; i < 5; i++) {
          expect((await tx.send(i)).hasSend, isTrue);
        }
        tx.close();

        final seen = <int>[];
        await for (final v in rx.stream()) {
          seen.add(v);
        }
        expect(seen, [0, 1, 2, 3, 4]);

        expect(
          () => rx.stream().listen((_) {}).asFuture<void>(),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'multi-producers: interleaving OK, global arrival order respected',
      () async {
        final (tx0, rx) = Mpsc.unbounded<int>();
        final tx1 = tx0.clone();

        final p0 = () async {
          await tx0.sendAll(List<int>.generate(5, (i) => i));
        }();

        final p1 = () async {
          await tx1.sendAll(List<int>.generate(5, (i) => i + 5));
        }();

        await Future.wait([p0, p1]);
        tx0.close();
        tx1.close();

        final got = <int>[];
        await for (final v in rx.stream()) {
          got.add(v);
        }
        expect(got.length, 10);
        expect(got.toSet(), {0, 1, 2, 3, 4, 5, 6, 7, 8, 9});
      },
    );

    test(
      'send after close -> SendErrorDisconnected (Rust-like semantics)',
      () async {
        final (tx, rx) = Mpsc.unbounded<int>();
        tx.close();

        final s = await tx.send(42);
        expect(s.isDisconnected, isTrue);

        final r = await rx.recv();
        expect(r.isDisconnected, isTrue);
      },
    );

    test(
      'receiver.close() clears buffer and producers see disconnected',
      () async {
        final (tx, rx) = Mpsc.unbounded<int>();
        expect((await tx.send(1)).hasSend, isTrue);
        expect((await tx.send(2)).hasSend, isTrue);

        rx.close();

        expect(tx.trySend(3).isDisconnected, isTrue);
        expect((await tx.send(4)).isDisconnected, isTrue);

        final r = await rx.recv();
        expect(r.isDisconnected, isTrue);
      },
    );
  });

  group('MPSC - bounded channel', () {
    test('trySend: full vs disconnected', () async {
      final (tx, rx) = Mpsc.bounded<String>(2);

      expect(tx.trySend('a').hasSend, isTrue);
      expect(tx.trySend('b').hasSend, isTrue);

      final f = tx.trySend('c');
      expect(f.isFull, isTrue);

      final r1 = await rx.recv();
      expect(r1.hasValue, isTrue);
      expect(r1.valueOrNull, 'a');

      expect(tx.trySend('c').hasSend, isTrue);

      tx.close();

      final r2 = await rx.recv();
      final r3 = await rx.recv();
      expect(r2.valueOrNull, 'b');
      expect(r3.valueOrNull, 'c');

      final r4 = await rx.recv();
      expect(r4.isDisconnected, isTrue);

      final (tx2, rx2) = Mpsc.bounded<int>(1);
      tx2.close();
      expect(tx2.trySend(1).isDisconnected, isTrue);

      final r5 = await rx2.recv();
      expect(r5.isDisconnected, isTrue);
    });

    test(
      'send() blocks when full, then unblocks when space is freed',
      () async {
        final (tx, rx) = Mpsc.bounded<int>(1);

        expect((await tx.send(1)).hasSend, isTrue);

        var secondCompleted = false;
        final f2 = tx.send(2).then((res) {
          expect(res.hasSend, isTrue);
          secondCompleted = true;
        });

        await tick(2);
        expect(secondCompleted, isFalse);

        final r1 = await rx.recv();
        expect(r1.valueOrNull, 1);

        await tick(2);
        expect(secondCompleted, isTrue);

        tx.close();
        final r2 = await rx.recv();
        expect(r2.valueOrNull, 2);

        final end = await rx.recv();
        expect(end.isDisconnected, isTrue);

        await f2;
      },
    );

    test(
      'recv() waits when empty and is immediately woken by a send()',
      () async {
        final (tx, rx) = Mpsc.bounded<int>(2);

        final c = Completer<RecvResult<int>>();
        unawaited(() async {
          final v = await rx.recv();
          c.complete(v);
        }());

        await tick(2);
        expect(c.isCompleted, isFalse);

        expect((await tx.send(99)).hasSend, isTrue);

        final r = await c.future;
        expect(r.valueOrNull, 99);

        tx.close();
        final end = await rx.recv();
        expect(end.isDisconnected, isTrue);
      },
    );

    test(
      'FIFO order preserved with mix of pending recv() and buffered items',
      () async {
        final (tx, rx) = Mpsc.bounded<int>(2);

        expect(tx.trySend(1).hasSend, isTrue);
        expect(tx.trySend(2).hasSend, isTrue);

        final seen = <int>[];
        final t = () async {
          for (var i = 0; i < 4; i++) {
            final r = await rx.recv();
            expect(r.hasValue, isTrue);
            seen.add(r.valueOrNull!);
          }
        }();

        await tick();

        expect((await tx.send(3)).hasSend, isTrue);
        expect((await tx.send(4)).hasSend, isTrue);
        tx.close();

        await t;
        expect(seen, [1, 2, 3, 4]);

        final end = await rx.recv();
        expect(end.isDisconnected, isTrue);
      },
    );

    test(
      'receiver.close() -> producers see disconnected and buffer is cleared',
      () async {
        final (tx, rx) = Mpsc.bounded<int>(2);
        expect(tx.trySend(1).hasSend, isTrue);
        expect(tx.trySend(2).hasSend, isTrue);

        rx.close();

        expect(tx.trySend(3).isDisconnected, isTrue);
        final s = await tx.send(4);
        expect(s.isDisconnected, isTrue);

        final r = await rx.recv();
        expect(r.isDisconnected, isTrue);
      },
    );

    test(
      'multi-senders via clone(): disconnected only after the last sender is closed',
      () async {
        final (tx0, rx) = Mpsc.bounded<int>(4);
        final tx1 = tx0.clone();

        expect((await tx0.send(1)).hasSend, isTrue);
        expect((await tx1.send(2)).hasSend, isTrue);

        tx0.close();

        expect((await tx1.send(3)).hasSend, isTrue);
        expect((await rx.recv()).valueOrNull, 1);
        expect((await rx.recv()).valueOrNull, 2);
        expect((await rx.recv()).valueOrNull, 3);

        tx1.close();
        final end = await rx.recv();
        expect(end.isDisconnected, isTrue);
      },
    );

    test('clone() after sender closed -> StateError', () async {
      final (tx, _) = Mpsc.unbounded<int>();
      tx.close();
      expect(() => tx.clone(), throwsA(isA<StateError>()));
    });
  });

  group('MPSC - rendezvous channel', () {
    test('ping-pong', () async {
      final (tx, rx) = Mpsc.bounded<int>(0);
      const n = 1000;

      final prod = () async {
        for (var i = 0; i < n; i++) {
          final s = await tx.send(i);
          expect(s.hasSend, isTrue);
        }
        tx.close();
      }();

      final cons = () async {
        for (var i = 0; i < n; i++) {
          final r = await rx.recv();
          expect(r.hasValue, isTrue);
          expect(r.valueOrNull, i);
        }
      }();

      await Future.wait([prod, cons]);
    });

    test('send pending after complete when recv', () async {
      final (tx, rx) = Mpsc.bounded<int>(0);
      final s = tx.send(42);

      final r = await rx.recv();
      expect(r.hasValue, isTrue);
      expect(r.valueOrNull, 42);

      expect(await s, isA<SendOk>());
    });

    test('trySend returns Full if no receiver is ready', () {
      final (tx, rx) = Mpsc.bounded<int>(0);
      final s = tx.trySend(1);
      expect(s.isFull, isTrue);

      final r = rx.recv();
      final s1 = tx.trySend(2);
      expect(s1.hasSend, isTrue);
      expect(r, completion(isA<RecvOk<int>>()));
    });

    test('trySend ok if receiver exist', () async {
      final (tx, rx) = Mpsc.bounded<int>(0);
      final r = rx.recv();
      final s = tx.trySend(7);
      expect(s.hasSend, isTrue);
      expect((await r).valueOrNull, 7);
    });

    test('close sender disconnect receiver', () async {
      final (tx, rx) = Mpsc.bounded<int>(0);
      tx.close();
      final r = await rx.recv();
      expect(r.isDisconnected, isTrue);
    });
  });
}
