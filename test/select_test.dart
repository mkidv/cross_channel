import 'dart:async';
import 'package:test/test.dart';

import 'package:cross_channel/cross_channel.dart';

void main() {
  group('Select.any', () {
    test('tick stream vs MPSC messages; breaks on receiver disconnect',
        () async {
      final (tx, rx) = XChannel.mpsc<int>(capacity: 8);

      unawaited(Future(() async {
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          tx.trySend(i);
        }
        tx.close();
      }));

      final tickStream =
          Stream.periodic(const Duration(milliseconds: 2), (_) => 'tick')
              .asBroadcastStream();

      var tickCount = 0;
      var msgCount = 0;

      while (true) {
        final breakLoop = await Select.any<bool>(
            (s) => s.onStream<String>(tickStream, (t) async {
                  tickCount++;
                  return false;
                }, tag: 'tick').onReceiver<int>(
                  rx,
                  ok: (msg) async {
                    msgCount++;
                    await Future<void>.delayed(const Duration(milliseconds: 1));
                    return false;
                  },
                  disconnected: () async {
                    return true;
                  },
                  tag: 'rx',
                )).run();

        if (breakLoop) break;
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

      final breakLoop = await Select.any<bool>((s) => s
          .onReceiver<int>(
            rx,
            ok: (msg) async {
              return false;
            },
            disconnected: () async => true,
            tag: 'rx',
          )
          .onFuture<void>(
            stop.future,
            (_) async => true,
            tag: 'stop',
          )).run();

      expect(breakLoop, isTrue);

      final r = await rx.recv();
      expect(r.ok, isTrue);
      expect(r.valueOrNull, equals(42));

      // Et le canal se termine ensuite proprement
      final r2 = await rx.recv();
      expect(r2.disconnected, isTrue);
    });

    test('timer arm = interval.tick() and explicit break', () async {
      var ticked = false;
      var breakLoop = false;

      breakLoop = await Select.any<bool>(
          (s) => s.onTimer(const Duration(milliseconds: 10), () async {
                ticked = true;
                return true;
              }, tag: 'timer')).run();

      expect(ticked, isTrue);
      expect(breakLoop, isTrue);
    });
  });
}
