import 'dart:async';

import 'package:cross_channel/cross_channel.dart';
import 'package:test/test.dart';

import 'utils.dart';

void main() {
  group('XSelect.run', () {
    test('recv vs tick(stream) — stops on receiver disconnect', () async {
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

      while (!rx.recvDisconnected) {
        await XSelect.run<bool>((s) => s
          ..onStream<String>(tickStream, (t) {
            tickCount++;
            return false;
          }, tag: 'tick')
          ..onRecvValue<int>(rx, (msg) async {
            msgCount++;
            return false;
          }, onError: (e) async => true, tag: 'rx'));
      }

      expect(msgCount, equals(3));
      expect(tickCount, greaterThan(0));
    });

    test('recv message is not lost when a competing branch wins (cancel safe)',
        () async {
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

      final broke = await XSelect.run<bool>((s) => s
        ..onRecvValue<int>(rx, (msg) async => false,
            onError: (e) async => true, tag: 'rx')
        ..onFuture<void>(stop.future, (_) async => true, tag: 'stop'));

      expect(broke, isTrue);

      final r = await rx.recv();
      expect(r.hasValue, isTrue);
      expect(r.valueOrNull, equals(42));

      final r2 = await rx.recv();
      expect(r2.isDisconnected, isTrue);
    });
  });

  group('XSelect.syncRun', () {
    test('returns null when no immediate branch exists', () {
      final hit = XSelect.syncRun<bool>(
          (s) => s.onTick(const Duration(milliseconds: 50), () => true));
      expect(hit, isNull);
    });

    test('returns value when tick is immediate (Duration.zero)', () {
      final hit =
          XSelect.syncRun<bool>((s) => s.onTick(Duration.zero, () => true));
      expect(hit, isTrue);
    });

    test('fast-path recv resolves synchronously when value is ready', () async {
      final (tx, rx) = XChannel.mpsc<int>(capacity: 4);
      expect(tx.trySend(7), isA<SendOk>());

      final res = await XSelect.run<int>((s) => s
        ..onRecvValue<int>(rx, (v) => v, tag: 'rx')
        ..onTimeout(const Duration(milliseconds: 10), () => -1));

      expect(res, equals(7));
    });

    test('loser stream is canceled when future wins', () async {
      var canceled = false;
      final controller = StreamController<int>(
        onCancel: () {
          canceled = true;
        },
      );

      final out = await XSelect.run<String>((s) => s
        ..onStream<int>(controller.stream, (_) => 'stream') // sera perdant
        ..onFuture<String>(
          Future<String>.delayed(
              const Duration(milliseconds: 1), () => 'future'),
          (v) => v,
        ));

      expect(out, equals('future'));

      await tick();
      expect(canceled, isTrue);

      await controller.close();
    });
  });

  group('XSelect.race', () {
    test('first future to resolve wins', () async {
      final winner = await XSelect.race<String>([
        (b) => b.onFuture<String>(
            Future<String>.delayed(const Duration(milliseconds: 30), () => 'A'),
            (v) => v),
        (b) => b.onFuture<String>(
            Future<String>.delayed(const Duration(milliseconds: 20), () => 'B'),
            (v) => v),
        (b) => b.onFuture<String>(
            Future<String>.delayed(const Duration(milliseconds: 10), () => 'C'),
            (v) => v),
      ]);
      expect(winner, equals('C'));
    });

    test('timeout wins when all futures are slower', () async {
      final winner = await XSelect.race<String>([
        (b) => b
          ..onFuture<String>(
              Future<String>.delayed(
                  const Duration(milliseconds: 50), () => 'A'),
              (v) => v)
          ..onFuture<String>(
              Future<String>.delayed(
                  const Duration(milliseconds: 60), () => 'B'),
              (v) => v),
        (b) => b.onTimeout(const Duration(milliseconds: 10), () => 'timeout'),
      ]);
      expect(winner, equals('timeout'));
    });

    test('mixed (recv+future+stream) — the fastest future wins', () async {
      final (tx, rx) = XChannel.mpsc<int>(capacity: 4);
      unawaited(
          Future<void>.delayed(const Duration(milliseconds: 20), () async {
        await tx.send(1);
        tx.close();
      }));

      final stream =
          Stream<int>.periodic(const Duration(milliseconds: 25), (i) => i)
              .asBroadcastStream();

      final out = await XSelect.race<String>([
        (b) => b.onRecvValue<int>(rx, (v) => 'rx:$v', onError: (e) => 'disc'),
        (b) => b.onStream<int>(stream, (v) => 'st:$v'),
        (b) => b.onFuture<String>(
            Future<String>.delayed(
                const Duration(milliseconds: 5), () => 'fast'),
            (v) => v),
      ]);

      expect(out, equals('fast'));

      final r = await rx.recv();
      expect(r.hasValue, isTrue);
      expect(r.valueOrNull, equals(1));
      final r2 = await rx.recv();
      expect(r2.isDisconnected, isTrue);
    });

    test('future vs future — earliest wins', () async {
      final out = await XSelect.race<String>([
        (b) => b.onFuture<String>(
            Future<String>.delayed(const Duration(milliseconds: 8), () => 'A'),
            (v) => v),
        (b) => b.onFuture<String>(
            Future<String>.delayed(const Duration(milliseconds: 15), () => 'B'),
            (v) => v),
      ]);
      expect(out, equals('A'));
    });
  });

  group('XSelect.onTimeout/onTick', () {
    test('onTimeout resolves when all branches are pending', () async {
      var timedOut = false;
      final never = Completer<void>().future;

      final broke = await XSelect.run<bool>((s) => s
        ..onFuture<void>(never, (_) => false)
        ..onTimeout(const Duration(milliseconds: 12), () {
          timedOut = true;
          return true;
        }));

      expect(timedOut, isTrue);
      expect(broke, isTrue);
    });

    test('one-shot tick using onTick', () async {
      var ticked = false;

      final broke = await XSelect.run<bool>((s) => s
        ..onTick(const Duration(milliseconds: 10), () {
          ticked = true;
          return true;
        }));

      expect(ticked, isTrue);
      expect(broke, isTrue);
    });

    test('syncRun immediate tick with Duration.zero', () {
      final out = XSelect.syncRace<String>([
        (b) => b.onTick(Duration.zero, () => 'tick'),
        (b) => b.onFuture<String>(
            Future<String>.delayed(
                const Duration(milliseconds: 10), () => 'late'),
            (v) => v),
      ]);
      expect(out, equals('tick'));
    });

    test('syncRun returns null when no immediate tick', () {
      final out = XSelect.syncRace<String>(
        [(b) => b.onTick(const Duration(milliseconds: 20), () => 'tick')],
      );
      expect(out, isNull);
    });
  });

  group('XSelect.onNotify', () {
    test('onNotify fires and returns value when triggered', () async {
      final sig = Notify();

      unawaited(
          Future<void>.delayed(const Duration(milliseconds: 5), sig.notifyOne));

      final out = await XSelect.run<String>(
          (s) => s..onNotify(sig, () => 'fired', tag: 'n'));

      expect(out, equals('fired'));
    });

    test('onNotify is canceled cleanly if another arm wins', () async {
      final sig = Notify();

      unawaited(Future<void>.delayed(
          const Duration(milliseconds: 10), sig.notifyAll));

      final out = await XSelect.run<String>((s) => s
        ..onNotify(sig, () => 'notify', tag: 'n')
        ..onFuture<void>(
          Future<void>.delayed(const Duration(milliseconds: 1)),
          (_) => 'fast',
          tag: 'fast',
        ));

      expect(out, equals('fast'));

      final maybe = await XSelect.run<bool>((s) => s
        ..onNotify(sig, () => true, tag: 'n2')
        ..onTimeout(const Duration(milliseconds: 20), () => false));
      expect(maybe, isTrue);
    });

    test('onNotifyOnce: gate one-shot handling across a user loop', () async {
      final sig = Notify();

      unawaited(
          Future<void>.delayed(const Duration(milliseconds: 2), sig.notifyAll));
      unawaited(
          Future<void>.delayed(const Duration(milliseconds: 5), sig.notifyAll));

      var handledOnce = false;
      var running = true;

      while (running) {
        final broke = await XSelect.run<bool>((s) => s
          ..onNotify(sig, () {
            handledOnce = true;
            return false;
          }, if_: () => !handledOnce, tag: 'notify-once')
          ..onDelay(const Duration(milliseconds: 10), () => true,
              tag: 'idle')).timeout(const Duration(milliseconds: 15));

        if (broke == true) running = false;
      }

      expect(handledOnce, isTrue);
    });
  });
}
