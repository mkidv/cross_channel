import 'dart:async';

import 'package:cross_channel/cross_channel.dart';
import 'package:cross_channel/src/core.dart';
import 'package:test/test.dart';

import 'utils.dart';

void main() {
  group('Extensions', () {
    group('Timeouts', () {
      test('Sender.sendTimeout', () async {
        final (tx, _) = XChannel.mpsc<int>(capacity: 1);
        tx.trySend(1); // Fill it
        final res = await tx.sendTimeout(2, const Duration(milliseconds: 10));
        expect(res.isTimeout, isTrue);
      });

      test('Receiver.recvTimeout', () async {
        final (_, rx) = XChannel.mpsc<int>();
        final res = await rx.recvTimeout(const Duration(milliseconds: 10));
        expect(res.isTimeout, isTrue);
      });
    });

    group('Batching', () {
      test('Sender.sendAll and trySendAll', () async {
        final (tx, rx) = XChannel.mpsc<int>(capacity: 10);
        await tx.trySendAll([1, 2]);
        await tx.sendAll([3, 4]);
        final got = rx.tryRecvAll();
        expect(got, [1, 2, 3, 4]);
      });

      test('Receiver.recvAll', () async {
        final (tx, rx) = XChannel.mpsc<int>(capacity: 10);
        tx.trySend(1);
        tx.trySend(2);
        final got = await rx.recvAll(max: 2);
        expect(got, [1, 2]);
      });

      test('Receiver.recvAll with idle timeout', () async {
        final (tx, rx) = XChannel.mpsc<int>();
        tx.trySend(1);
        Timer(const Duration(milliseconds: 50), () => tx.trySend(2));
        final got =
            await rx.recvAll(idle: const Duration(milliseconds: 100), max: 2);
        expect(got, [1, 2]);
      });
    });

    group('Forwarding', () {
      test('pipeTo', () async {
        final (tx1, rx1) = XChannel.mpsc<int>();
        final (tx2, rx2) = XChannel.mpsc<int>();

        tx1.trySend(1);
        tx1.trySend(2);
        tx1.close();

        await rx1.pipeTo(tx2, closeTargetOnDone: true);
        final got = await rx2.stream().toList();
        expect(got, [1, 2]);
      });

      test('pipeToReceiver', () async {
        final (tx1, rx1) = XChannel.mpsc<int>();
        final (tx2, rx2) = XChannel.mpsc<int>();

        tx1.trySend(1);
        tx1.close();

        await rx1.pipeToReceiver(rx2);
        tx2.close();
        final got = await rx2.stream().toList();
        expect(got, [1]);
      });
    });

    group('Rate Limiting', () {
      test('Throttle', () async {
        final (tx, rx) = XChannel.mpsc<int>();
        final throttled = tx.throttle(const Duration(milliseconds: 100));

        throttled.trySend(1);
        throttled.trySend(2); // Dropped
        await Future<void>.delayed(const Duration(milliseconds: 150));
        throttled.trySend(3);

        tx.close();
        final got = await rx.stream().toList();
        expect(got, [1, 3]);
      });

      test('Debounce', () async {
        final (tx, rx) = XChannel.mpsc<int>();
        final debounced = tx.debounce(const Duration(milliseconds: 100));

        debounced.trySend(1);
        debounced.trySend(2);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        tx.close();
        final got = await rx.stream().toList();
        expect(got, [2]);
      });
    });

    group('Streams', () {
      test('broadcastStream basic', () async {
        final (tx, rx) = XChannel.mpsc<int>();
        final bstream = rx.broadcastStream();

        final list1 = bstream.take(1).toList();
        final list2 = bstream.take(1).toList();

        tx.trySend(42);

        expect(await list1, [42]);
        expect(await list2, [42]);
      });

      test(
          'broadcastStream duplicates to multiple listeners and closes properly',
          () async {
        final (tx, rx) = XChannel.mpsc<int>();
        final b = rx.broadcastStream();

        final a = <int>[];
        final c = <int>[];

        final sub1 = b.listen(a.add);
        final sub2 = b.listen(c.add);

        await tx.sendAll(List<int>.generate(10, (i) => i));
        tx.close();

        await Future.wait<void>([sub1.asFuture<void>(), sub2.asFuture<void>()]);

        expect(a, List<int>.generate(10, (i) => i));
        expect(c, List<int>.generate(10, (i) => i));
      });

      test('COLD (waitForListeners=true): does not drain before subscription',
          () async {
        final (tx, rx) = XChannel.mpsc<int>();
        await tx.sendAll(List<int>.generate(5, (i) => i));

        final b = rx.broadcastStream(waitForListeners: true);

        final got = <int>[];
        final sub = b.listen(got.add);

        tx.close();
        await sub.asFuture<void>();

        expect(got, List<int>.generate(5, (i) => i));
      });

      test(
          'HOT (waitForListeners=false): drops events without listener (broadcast)',
          () async {
        final (tx, rx) = XChannel.mpsc<int>();
        final b = rx.broadcastStream();

        await tx.sendAll(List<int>.generate(5, (i) => i));
        await tick();

        final got = <int>[];
        final sub = b.listen(got.add);

        await tx.sendAll(List<int>.generate(5, (i) => i + 5));
        tx.close();

        await sub.asFuture<void>();

        expect(got, List<int>.generate(5, (i) => i + 5));
      });

      test(
          'stopWhenNoListeners=true: pauses drain when no listener, then resumes',
          () async {
        final (tx, rx) = XChannel.mpsc<int>();

        final b = rx.broadcastStream(
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
      });

      test('closeOnDone=true: closes the receiver at the end of the stream',
          () async {
        final (tx, rx) = XChannel.mpsc<int>();
        final b = rx.broadcastStream(
          waitForListeners: true,
          closeReceiverOnDone: true,
        );

        final got = <int>[];
        final sub = b.listen(got.add);

        await tx.sendAll(List<int>.generate(3, (i) => i));
        tx.close();

        await sub.asFuture<void>();
        expect(got, [0, 1, 2]);

        expect(rx.recvDisconnected, isTrue);
      });

      test('mapBroadcast', () async {
        final (tx, rx) = XChannel.mpsc<int>();
        final bstream = rx.mapBroadcast((v) => 'val: $v');

        final list = bstream.take(1).toList();
        tx.trySend(42);
        expect(await list, ['val: 42']);
      });

      test('Stream.pipeTo with dropWhenFull', () async {
        final (tx, rx) = XChannel.mpsc<int>(capacity: 1);
        tx.trySend(1); // Full

        final stream = Stream.fromIterable([2, 3]);
        // Should drop 2 and 3 if dropWhenFull is true
        await stream.pipeTo(tx, dropWhenFull: true, closeSenderOnDone: true);

        final got = await rx.stream().toList();
        expect(got, [1]);
      });

      test('Sender.pipeFrom closing', () async {
        final (tx1, rx1) = XChannel.mpsc<int>();
        final (tx2, rx2) = XChannel.mpsc<int>();

        tx1.trySend(1);
        tx1.close();

        await tx2.pipeFrom(rx1, closeTargetOnDone: true);
        expect(tx2.sendDisconnected, isTrue);
        expect(await rx2.stream().toList(), [1]);
      });
    });

    group('Rate Limiting Extras', () {
      test('Throttle close', () async {
        final (tx, _) = XChannel.mpsc<int>();
        final throttled =
            tx.throttle(const Duration(milliseconds: 100)) as Closeable;
        throttled.close();
        expect(tx.sendDisconnected, isTrue);
      });

      test('Debounce close', () async {
        final (tx, _) = XChannel.mpsc<int>();
        final debounced =
            tx.debounce(const Duration(milliseconds: 100)) as Closeable;
        debounced.close();
        expect(tx.sendDisconnected, isTrue);
      });
    });
  });
}
