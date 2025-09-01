import 'dart:async';
import 'package:test/test.dart';
import 'package:cross_channel/mpmc.dart';

import 'utils.dart';

void main() {
  group('MPMC - unbounded channel', () {
    test('basic send/recv (global FIFO by arrival)', () async {
      final (tx, rx) = Mpmc.unbounded<int>();

      expect((await tx.send(1)).ok, isTrue);
      expect((await tx.send(2)).ok, isTrue);
      expect((await tx.send(3)).ok, isTrue);

      final r1 = await rx.recv();
      final r2 = await rx.recv();
      final r3 = await rx.recv();
      expect(r1.ok, isTrue);
      expect(r2.ok, isTrue);
      expect(r3.ok, isTrue);
      expect(r1.valueOrNull, 1);
      expect(r2.valueOrNull, 2);
      expect(r3.valueOrNull, 3);

      tx.close();

      final r4 = await rx.recv();
      expect(r4.disconnected, isTrue);
    });

    test(
      'send without any receiver attached -> disconnected (policy)',
      () async {
        // Ici on valide la policy MPMC: pas d’envoi si aucun receiver vivant.
        final (tx, rx) = Mpmc.unbounded<int>();
        // Ferme les receivers pour simuler "aucun receiver"
        rx.close();

        final s1 = await tx.send(99);
        expect(s1.disconnected, isTrue);
        expect(tx.trySend(100).disconnected, isTrue);
      },
    );

    test(
      'multi-consumers: each message seen exactly once (work-queue)',
      () async {
        final (tx, rx0) = Mpmc.unbounded<int>();
        final rx1 = rx0.clone();
        final rx2 = rx0.clone();

        const N = 300;
        final seen = <int>[];

        Future<void> worker(MpmcReceiver<int> rx) async {
          await for (final v in rx.stream()) {
            seen.add(v);
          }
        }

        final w0 = worker(rx0);
        final w1 = worker(rx1);
        final w2 = worker(rx2);

        await tx.sendAll(Iterable<int>.generate(N));

        tx.close();

        await Future.wait([w0, w1, w2]);

        expect(seen.length, N);
        expect(seen.toSet().length, N);
        expect(seen.toSet(), {for (var i = 0; i < N; i++) i});
      },
    );

    test(
      'stream() is single-subscription per handle (clone() allowed)',
      () async {
        final (tx, rx) = Mpmc.unbounded<int>();
        expect((await tx.send(1)).ok, isTrue);
        tx.close();

        final values = <int>[];
        await for (final v in rx.stream()) {
          values.add(v);
        }
        expect(values, [1]);

        expect(
          () => rx.stream().listen((_) {}).asFuture<void>(),
          throwsA(isA<StateError>()),
        );

        final (tx2, rx2) = Mpmc.unbounded<int>();
        rx2.clone();
        expect((await tx2.send(7)).ok, isTrue);
        expect((await tx2.send(8)).ok, isTrue);
        tx2.close();

        final out = <int>[];
        await for (final v in rx2.stream()) {
          out.add(v);
        }
        expect(out.toSet(), {7, 8});
      },
    );

    test(
      'partial drop of receivers keeps channel alive; dropping all => send() disconnected',
      () async {
        final (tx, rx0) = Mpmc.unbounded<int>();
        final rx1 = rx0.clone();

        rx1.close();

        expect((await tx.send(10)).ok, isTrue);
        expect((await rx0.recv()).valueOrNull, 10);

        rx0.close();

        expect((await tx.send(1)).disconnected, isTrue);
        expect(tx.trySend(2).disconnected, isTrue);
      },
    );

    test(
      'receiver.close() -> producers see disconnected and buffer is cleared',
      () async {
        final (tx, rx) = Mpmc.unbounded<int>();
        expect((await tx.send(1)).ok, isTrue);
        expect((await tx.send(2)).ok, isTrue);

        rx.close();

        expect(tx.trySend(3).disconnected, isTrue);
        final s = await tx.send(4);
        expect(s.disconnected, isTrue);

        final r = await rx.recv();
        expect(r.disconnected, isTrue);
      },
    );

    test('tryRecv: empty vs disconnected', () async {
      final (tx, rx) = Mpmc.unbounded<int>();

      final e1 = rx.tryRecv();
      expect(e1.empty, isTrue);

      tx.close();

      final e2 = rx.tryRecv();
      expect(e2.disconnected, isTrue);
    });

    test('sender.clone() after all receivers dropped -> StateError', () async {
      final (tx, rx) = Mpmc.unbounded<int>();
      rx.close();
      expect(() => tx.clone(), throwsA(isA<StateError>()));
    });
  });

  group('MPMC - bounded channel', () {
    test('trySend: full vs disconnected', () async {
      final (tx, rx) = Mpmc.bounded<String>(2);
      expect(tx.trySend('a').ok, isTrue);
      expect(tx.trySend('b').ok, isTrue);

      expect(tx.trySend('c').full, isTrue);

      final r1 = await rx.recv();
      expect(r1.ok, isTrue);
      expect(r1.valueOrNull, 'a');

      expect(tx.trySend('c').ok, isTrue);

      rx.close();
      expect(tx.trySend('Z').disconnected, isTrue);
    });

    test(
      'send() blocks when full, then unblocks when a slot is freed',
      () async {
        final (tx, rx) = Mpmc.bounded<int>(1);

        expect((await tx.send(1)).ok, isTrue);

        var secondCompleted = false;
        final f2 = tx.send(2).then((res) {
          expect(res.ok, isTrue);
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
        expect(end.disconnected, isTrue);

        await f2;
      },
    );

    test('FIFO preserved with pending recv + buffered items', () async {
      final (tx, rx) = Mpmc.bounded<int>(2);

      expect(tx.trySend(1).ok, isTrue);
      expect(tx.trySend(2).ok, isTrue);

      final seen = <int>[];
      final t = () async {
        for (var i = 0; i < 4; i++) {
          final r = await rx.recv();
          expect(r.ok, isTrue);
          seen.add(r.valueOrNull!);
        }
      }();

      await tick();

      expect((await tx.send(3)).ok, isTrue);
      expect((await tx.send(4)).ok, isTrue);
      tx.close();

      await t;
      expect(seen, [1, 2, 3, 4]);

      final end = await rx.recv();
      expect(end.disconnected, isTrue);
    });

    test(
      'bounded multi-consumers: work sharing + backpressure respected',
      () async {
        final (tx, rx0) = Mpmc.bounded<int>(8);
        final rx1 = rx0.clone();
        final rx2 = rx0.clone();

        final seen = <int>[];
        Future<void> w(MpmcReceiver<int> rx) async {
          await for (final v in rx.stream()) {
            seen.add(v);
          }
        }

        final w0 = w(rx0);
        final w1 = w(rx1);
        final w2 = w(rx2);

        await tx.sendAll(List<int>.generate(100, (i) => i));
        tx.close();

        await Future.wait([w0, w1, w2]);

        expect(seen.length, 100);
        expect(seen.toSet().length, 100);
        expect(seen.toSet(), {for (var i = 0; i < 100; i++) i});
      },
    );

    test(
      'send without any receiver attached -> disconnected (policy)',
      () async {
        final (tx, rx) = Mpmc.bounded<int>(2);
        rx.close(); // aucun receiver vivant

        expect(tx.trySend(1).disconnected, isTrue);
        expect((await tx.send(2)).disconnected, isTrue);
      },
    );
  });

  group('Sliding - channel', () {
    test('dropNewest: overflow drops the newest', () async {
      final (tx, rx) = Mpmc.channel<int>(
        capacity: 2,
        policy: DropPolicy.newest,
      );
      await tx.send(0);
      await tx.send(1);

      final a = <int>[];
      a.add((await rx.recv() as RecvOk<int>).value);
      a.add((await rx.recv() as RecvOk<int>).value);

      expect(a, [0, 1]);
    });

    test('dropOldest: overflow drops the oldest', () async {
      final (tx, rx) = Mpmc.channel<int>(
        capacity: 2,
        policy: DropPolicy.oldest,
      );
      await tx.send(0);
      await tx.send(1);
      await tx.send(2);

      final a = <int>[];
      a.add((await rx.recv() as RecvOk<int>).value);
      a.add((await rx.recv() as RecvOk<int>).value);

      expect(a, [1, 2]);
    });

    test('receiver waiting → no drop, direct delivery', () async {
      final (tx, rx) = Mpmc.channel<int>(
        capacity: 1,
        policy: DropPolicy.newest,
      );

      final fr = rx.recv();
      await tx.send(7);
      final r = await fr;
      expect((r as RecvOk<int>).value, 7);
    });

    test('close sender when buffer empty → recv disconnected', () async {
      final (tx, rx) = Mpmc.channel<int>(capacity: 2);
      tx.close();
      final r = await rx.recv();
      expect(r.disconnected, isTrue);
    });
  });
}
