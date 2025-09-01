import 'dart:async';
import 'package:test/test.dart';
import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/mpmc.dart';

import 'utils.dart';

void main() {
  group('STRESS – MPSC', () {
    test(
      'unbounded: 4 producers → 1 consumer, 0 loss, 0 dup',
      () async {
        final (tx0, rx) = Mpsc.unbounded<int>();
        final total = 400_000;
        final producers = 4;
        final perProd = (total / producers).round();

        final senders = <MpscSender<int>>[tx0];
        for (var i = 1; i < producers; i++) {
          senders.add(senders.first.clone());
        }

        final got = <int>[];
        final recvF = () async {
          while (got.length < total) {
            final r = await rx.recv();
            if (r.ok) {
              got.add(r.valueOrNull!);
            } else if (r.disconnected) {
              break;
            }
          }
        }();

        final tasks = <Future<void>>[];
        for (var i = 0; i < producers; i++) {
          final s = senders[i];
          tasks.add(() async {
            for (var k = 0; k < perProd; k++) {
              final res = await s.send(i << 28 | k); // tag producer
              if (res.disconnected) break;
            }
            s.close();
          }());
        }

        await Future.wait([...tasks, recvF]);

        expect(got.length, total);
        expect(got.toSet().length, total, reason: 'duplicates detected');
      },
      timeout: Timeout(Duration(seconds: 15)),
    );

    test(
      'bounded cap=128: 4P → 4C, 0 loss, fairness (each ≥1)',
      () async {
        final cap = 128;
        final (tx0, rx0) = Mpmc.bounded<int>(cap);

        final producers = 4, consumers = 4;
        final total = 200_000;
        final perProd = (total / producers).round();

        final senders = <MpmcSender<int>>[tx0];
        for (var i = 1; i < producers; i++) {
          senders.add(senders.first.clone());
        }

        final receivers = <MpmcReceiver<int>>[rx0];
        for (var i = 1; i < consumers; i++) {
          receivers.add(rx0.clone());
        }

        final seenBy = List<int>.filled(consumers, 0);
        final got = <int>{};
        final consF = <Future<void>>[];

        for (var idx = 0; idx < consumers; idx++) {
          final rx = receivers[idx];
          consF.add(() async {
            await for (final v in rx.stream()) {
              got.add(v);
              seenBy[idx]++;
            }
          }());
        }

        final prodF = <Future<void>>[];
        for (var p = 0; p < producers; p++) {
          final s = senders[p];
          prodF.add(() async {
            for (var k = 0; k < perProd; k++) {
              final res = await s.send(p << 28 | k);
              if (res.disconnected) break;
            }
            s.close();
          }());
        }

        await Future.wait([...prodF]);
        await Future.wait([...consF]);

        expect(got.length, total);
        for (final c in seenBy) {
          expect(c, greaterThan(0), reason: 'consumer starved');
        }
      },
      timeout: Timeout(Duration(seconds: 15)),
    );

    test(
      'permit no-leak: send() blocked then close() -> fast disconnected',
      () async {
        final (tx, rx) = Mpsc.bounded<int>(1);

        expect((await tx.send(1)).ok, isTrue);

        final f2 = tx.send(2);
        await tick(2);
        tx.close();

        final res = await f2.timeout(const Duration(seconds: 2));
        expect(res.disconnected, isTrue);

        expect((await rx.recv()).valueOrNull, 1);
        expect((await rx.recv()).disconnected, isTrue);
      },
      timeout: Timeout(Duration(seconds: 20)),
    );

    test(
      'rendezvous cap=0: 2P/2C ping flood (no deadlock, 0 loss)',
      () async {
        final (tx, rx0) = Mpsc.bounded<int>(0);
        final total = 100_000;

        final rx1 = rx0;
        final pDone = Completer<void>();
        final cDone = Completer<void>();

        var recvCount = 0;

        final cons = () async {
          while (recvCount < total) {
            final r = await rx1.recv();
            if (r.ok) {
              recvCount++;
            } else if (r.disconnected) {
              break;
            }
          }
          cDone.complete();
        }();

        final prod = () async {
          for (var i = 0; i < total; i++) {
            final s = await tx.send(i);
            if (s.disconnected) break;
          }
          tx.close();
          pDone.complete();
        }();

        await Future.wait([pDone.future, cDone.future, cons, prod]);

        expect(recvCount, total);
      },
      timeout: Timeout(Duration(seconds: 15)),
    );
  });

  group('STRESS – MPMC', () {
    test(
      'unbounded: 4P → 4C, 0 loss, 0 dup, fairness >=1 each',
      () async {
        final (tx0, rx0) = Mpmc.unbounded<int>();
        final producers = 4, consumers = 4;
        final total = 250_000;
        final perProd = (total / producers).round();

        final senders = <MpmcSender<int>>[tx0];
        for (var i = 1; i < producers; i++) {
          senders.add(senders.first.clone());
        }

        final receivers = <MpmcReceiver<int>>[rx0];
        for (var i = 1; i < consumers; i++) {
          receivers.add(rx0.clone());
        }

        final got = <int>{};
        final seenBy = List<int>.filled(consumers, 0);

        final consF = <Future<void>>[];
        for (var i = 0; i < consumers; i++) {
          final rx = receivers[i];
          consF.add(() async {
            await for (final v in rx.stream()) {
              got.add(v);
              seenBy[i]++;
            }
          }());
        }

        final prodF = <Future<void>>[];
        for (var p = 0; p < producers; p++) {
          final s = senders[p];
          prodF.add(() async {
            for (var k = 0; k < perProd; k++) {
              final res = await s.send(p << 28 | k);
              if (res.disconnected) break;
            }
            s.close();
          }());
        }

        await Future.wait(prodF);
        await Future.wait(consF);

        expect(got.length, total);
        for (final c in seenBy) {
          expect(c, greaterThan(0), reason: 'consumer starved');
        }
      },
      timeout: Timeout(Duration(seconds: 15)),
    );

    test(
      'permit no-leak (bounded): send() blocked + close() -> fast disconnected',
      () async {
        final (tx, rx) = Mpmc.bounded<int>(1);

        expect((await tx.send(1)).ok, isTrue);
        final blocked = tx.send(2);
        await tick(2);

        rx.close();

        final s2 = await blocked.timeout(const Duration(seconds: 2));
        expect(s2.disconnected, isTrue);
      },
      timeout: Timeout(Duration(seconds: 20)),
    );
  });

  group('STRESS – Sliding policies', () {
    test(
      'DropPolicy.oldest: no receiver, keep last',
      () async {
        final cap = 8;
        final (tx, rx) = Mpmc.channel<int>(
          capacity: cap,
          policy: DropPolicy.oldest,
        );

        final n = 20_000;
        for (var i = 0; i < n; i++) {
          expect((await tx.send(i)).ok, isTrue);
        }
        tx.close();

        final drained = <int>[];
        while (true) {
          final r = await rx.recv();
          if (!r.ok) break;
          drained.add(r.valueOrNull!);
        }

        final expected = [for (var i = n - cap; i < n; i++) i];
        expect(drained, expected);
      },
      timeout: Timeout(Duration(seconds: 15)),
    );

    test(
      'DropPolicy.newest: no receiver, keep first',
      () async {
        final cap = 8;
        final (tx, rx) = Mpmc.channel<int>(
          capacity: cap,
          policy: DropPolicy.newest,
        );

        final n = 20_000;
        for (var i = 0; i < n; i++) {
          expect((await tx.send(i)).ok, isTrue);
        }
        tx.close();

        final drained = <int>[];
        while (true) {
          final r = await rx.recv();
          if (!r.ok) break;
          drained.add(r.valueOrNull!);
        }

        final expected = [for (var i = 0; i < cap; i++) i];
        expect(drained, expected);
      },
      timeout: Timeout(Duration(seconds: 15)),
    );
  });
}
