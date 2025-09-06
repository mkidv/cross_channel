import 'dart:async';
import 'package:test/test.dart';

import 'package:cross_channel/cross_channel.dart';

void main() {
  group('XSelect.run', () {
    test('tick stream vs MPSC messages; breaks on receiver disconnect',
        () async {
      final (tx, rx) = XChannel.mpsc<int>(capacity: 8);

      unawaited(Future(() async {
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 6));
          tx.trySend(i);
        }
        tx.close();
      }));

      final tickStream =
          Stream.periodic(const Duration(milliseconds: 5), (_) => 'tick')
              .asBroadcastStream();

      var tickCount = 0;
      var msgCount = 0;

      while (!rx.isDisconnected) {
        await XSelect.run<bool>((s) => s
          ..onStream<String>(
            tickStream,
            (t) {
              tickCount++;
              return false;
            },
            tag: 'tick',
          )
          ..onRecvValue<int>(
            rx,
            (msg) async {
              msgCount++;
              return false;
            },
            onDisconnected: () async {
              return true;
            },
            tag: 'rx',
          ));
      }

      expect(msgCount, equals(3));
      expect(tickCount, greaterThan(0));
    });

    test('message not lost when cancelled', () async {
      final (tx, rx) = XChannel.mpsc<int>(capacity: 1);
      final stop = Completer<void>();

      unawaited(Future<void>.delayed(const Duration(milliseconds: 5), () {
        if (!stop.isCompleted) stop.complete();
      }));

      unawaited(
          Future<void>.delayed(const Duration(milliseconds: 10), () async {
        await tx.send(42);
        tx.close();
      }));

      final breakLoop = await XSelect.run<bool>((s) => s
        ..onRecvValue<int>(
          rx,
          (msg) async => false,
          onDisconnected: () async => true,
          tag: 'rx',
        )
        ..onFuture<void>(
          stop.future,
          (_) async => true,
          tag: 'stop',
        ));

      expect(breakLoop, isTrue);

      final r = await rx.recv();
      expect(r.hasValue, isTrue);
      expect(r.valueOrNull, equals(42));

      final r2 = await rx.recv();
      expect(r2.isDisconnected, isTrue);
    });

    test('withTimeout resolves when all branches are pending (fallback global)',
        () async {
      var timedOut = false;

      final never = Completer<void>().future;
      final broke = await XSelect.run<bool>((s) => s
        ..onFuture<void>(never, (_) => false)
        ..timeout(const Duration(milliseconds: 12), () {
          timedOut = true;
          return true;
        }));

      expect(timedOut, isTrue);
      expect(broke, isTrue);
    });

    test('one-shot tick using Ticker', () async {
      final t = Ticker.every(const Duration(milliseconds: 10));
      var ticked = false;

      final broke = await XSelect.run<bool>((s) => s.onTick(t, () {
            ticked = true;
            return true;
          }));

      expect(ticked, isTrue);
      expect(broke, isTrue);
    });
  });

  group('XSelect.syncRun', () {
    test('returns null when no immediate branch', () {
      final t = Ticker.every(const Duration(milliseconds: 50));
      final hit = XSelect.syncRun<bool>((s) => s.onTick(t, () => true));
      expect(hit, isNull);
    });

    test('returns value when an immediate branch exists (Ticker immediate)',
        () {
      final period = const Duration(milliseconds: 2);
      final t = Ticker.every(period);
      t.reset(startAt: DateTime.now().subtract(period));
      final hit = XSelect.syncRun<bool>((s) => s.onTick(t, () => true));
      expect(hit, isTrue);
    });
  });

  group('XSelect.race', () {
    test('first future wins', () async {
      final winner = await XSelect.race<String>([
        (b) => b.onFuture<String>(
              Future<String>.delayed(
                  const Duration(milliseconds: 30), () => 'A'),
              (v) => v,
            ),
        (b) => b.onFuture<String>(
              Future<String>.delayed(
                  const Duration(milliseconds: 20), () => 'B'),
              (v) => v,
            ),
        (b) => b.onFuture<String>(
              Future<String>.delayed(
                  const Duration(milliseconds: 10), () => 'C'),
              (v) => v,
            ),
      ]);
      expect(winner, equals('C'));
    });

    test('timeout wins if all slower', () async {
      final winner = await XSelect.race<String>(
        [
          (b) => b.onFuture<String>(
                Future<String>.delayed(
                    const Duration(milliseconds: 50), () => 'A'),
                (v) => v,
              ),
          (b) => b.onFuture<String>(
                Future<String>.delayed(
                    const Duration(milliseconds: 60), () => 'B'),
                (v) => v,
              ),
        ],
        timeout: const Duration(milliseconds: 10),
        onTimeout: () => 'timeout',
      );
      expect(winner, equals('timeout'));
    });
  });

  test('mixed competitors (future vs future): earliest wins', () async {
    final out = await XSelect.race<String>([
      (b) => b.onFuture<String>(
            Future<String>.delayed(const Duration(milliseconds: 8), () => 'A'),
            (v) => v,
          ),
      (b) => b.onFuture<String>(
            Future<String>.delayed(const Duration(milliseconds: 15), () => 'B'),
            (v) => v,
          ),
    ]);

    expect(out, equals('A'));
  });

  test('mixed competitors (recv + future + stream) — future fastest', () async {
    final (tx, rx) = XChannel.mpsc<int>(capacity: 4);
    unawaited(Future<void>.delayed(const Duration(milliseconds: 20), () async {
      await tx.send(1);
      tx.close();
    }));

    final stream =
        Stream<int>.periodic(const Duration(milliseconds: 25), (i) => i)
            .asBroadcastStream();

    final out = await XSelect.race<String>([
      (b) =>
          b.onRecvValue<int>(rx, (v) => 'rx:$v', onDisconnected: () => 'disc'),
      (b) => b.onStream<int>(stream, (v) => 'st:$v'),
      (b) => b.onFuture<String>(
            Future<String>.delayed(
                const Duration(milliseconds: 5), () => 'fast'),
            (v) => v,
          ),
    ]);

    expect(out, equals('fast'));

    final r = await rx.recv();
    expect(r.hasValue, isTrue);
    expect(r.valueOrNull, equals(1));
    final r2 = await rx.recv();
    expect(r2.isDisconnected, isTrue);
  });

  group('XSelect.syncRace', () {
    test('returns null when no competitor has an immediate branch', () {
      final t = Ticker.every(const Duration(milliseconds: 20));
      final out = XSelect.syncRace<String>([
        (b) => b.onTick(t, () => 'tick'),
      ]);
      expect(out, isNull);
    });

    test('returns value when a competitor exposes an immediate arm (Ticker)',
        () {
      final period = const Duration(milliseconds: 2);
      final t = Ticker.every(period);
      t.reset(startAt: DateTime.now().subtract(period));

      final out = XSelect.syncRace<String>([
        (b) => b.onTick(t, () => 'tick'),
        (b) => b.onFuture<String>(
              Future<String>.delayed(
                  const Duration(milliseconds: 10), () => 'late'),
              (v) => v,
            ),
      ]);
      expect(out, equals('tick'));
    });
  });
}
