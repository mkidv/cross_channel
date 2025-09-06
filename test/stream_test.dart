import 'dart:async';
import 'package:test/test.dart';
import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/stream_extension.dart';

import 'utils.dart';

void main() {
  group('Stream bridge', () {
    test(
      'rx.toBroadcastStream(): duplicates to multiple listeners and closes properly',
      () async {
        final (tx, rx) = Mpsc.unbounded<int>();
        final b = rx.toBroadcastStream();

        final a = <int>[];
        final c = <int>[];

        final sub1 = b.listen(a.add);
        final sub2 = b.listen(c.add);

        await tx.sendAll(List<int>.generate(10, (i) => i));
        tx.close();

        await Future.wait([sub1.asFuture<void>(), sub2.asFuture<void>()]);

        expect(a, List<int>.generate(10, (i) => i));
        expect(c, List<int>.generate(10, (i) => i));
      },
    );

    test(
      'COLD (waitForListeners=true): does not drain before subscription',
      () async {
        final (tx, rx) = Mpsc.unbounded<int>();
        await tx.sendAll(List<int>.generate(5, (i) => i));

        final b = rx.toBroadcastStream(waitForListeners: true);

        final got = <int>[];
        final sub = b.listen(got.add);

        tx.close();
        await sub.asFuture<void>();

        expect(got, List<int>.generate(5, (i) => i));
      },
    );

    test(
      'HOT (waitForListeners=false): drops events without listener (broadcast)',
      () async {
        final (tx, rx) = Mpsc.unbounded<int>();
        final b = rx.toBroadcastStream();

        await tx.sendAll(List<int>.generate(5, (i) => i));
        await tick();

        final got = <int>[];
        final sub = b.listen(got.add);

        await tx.sendAll(List<int>.generate(5, (i) => i + 5));
        tx.close();

        await sub.asFuture<void>();

        expect(got, List<int>.generate(5, (i) => i + 5));
      },
    );

    test(
      'stopWhenNoListeners=true: pauses drain when no listener, then resumes',
      () async {
        final (tx, rx) = Mpsc.unbounded<int>();

        final b = rx.toBroadcastStream(
          waitForListeners: true,
          stopWhenNoListeners: true,
        );

        final got = <int>[];
        var sub = b.listen(got.add);

        await tx.sendAll(List<int>.generate(3, (i) => i));
        await tick();

        await sub.cancel();

        await tx.sendAll(List<int>.generate(3, (i) => i + 3));

        sub = b.listen(got.add);

        await tx.sendAll(List<int>.generate(3, (i) => i + 6));
        tx.close();

        await sub.asFuture<void>();

        expect(got, List<int>.generate(9, (i) => i));
      },
    );

    test(
      'closeOnDone=true: closes the receiver at the end of the stream',
      () async {
        final (tx, rx) = Mpsc.unbounded<int>();
        final b = rx.toBroadcastStream(
          waitForListeners: true,
          closeReceiverOnDone: true,
        );

        final got = <int>[];
        final sub = b.listen(got.add);

        await tx.sendAll(List<int>.generate(3, (i) => i));
        tx.close();

        await sub.asFuture<void>();
        expect(got, [0, 1, 2]);

        expect(rx.isDisconnected, isTrue);
      },
    );

    test(
      'redirectTo(backpressure): all received elements, order preserved',
      () async {
        final (tx, rx) = Mpsc.bounded<int>(8);

        Stream<int> src() async* {
          for (var i = 0; i < 200; i++) {
            yield i;
          }
        }

        final got = <int>[];
        final drain = () async {
          await for (final v in rx.stream()) {
            got.add(v);
          }
        }();

        await src().redirectToSender(tx, dropWhenFull: false);

        await drain;

        expect(got.length, 200);
        expect(got, List<int>.generate(200, (i) => i));
      },
    );

    test(
      'redirectTo(dropWhenFull=true): may lose elements under pressure',
      () async {
        final (tx, rx) = Mpsc.bounded<int>(8);

        Stream<int> src() async* {
          for (var i = 0; i < 500; i++) {
            yield i;
          }
        }

        final redir = src().redirectToSender(tx, dropWhenFull: true);

        await redir;

        final got = <int>[];
        await for (final v in rx.stream()) {
          got.add(v);
        }

        expect(got.length, inExclusiveRange(1, 500));
      },
    );

    test('redirectTo(closeOnDone=false): sender remains open', () async {
      final (tx, rx) = Mpsc.unbounded<int>();

      Stream<int> src() async* {
        yield 1;
        yield 2;
      }

      await src().redirectToSender(tx, closeSenderOnDone: false);
      expect(tx.isDisconnected, isFalse);

      tx.close();

      final got = <int>[];
      await for (final v in rx.stream()) {
        got.add(v);
      }
      expect(got, [1, 2]);
    });
  });
}
