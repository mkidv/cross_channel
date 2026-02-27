import 'dart:async';

import 'package:cross_channel/spsc.dart';
import 'package:test/test.dart';

void main() {
  group('SPSC - channel', () {
    test('ping-pong delivers in order', () async {
      const N = 10_000;
      final (tx, rx) = Spsc.channel<int>(1024);

      final prod = () async {
        for (var i = 0; i < N; i++) {
          final r = await tx.send(i);
          expect(r.hasSend, isTrue);
        }
      }();

      for (var i = 0; i < N; i++) {
        final r = await rx.recv();
        expect(r.hasValue, isTrue);
        expect(r.valueOrNull, i);
      }
      await prod;
    });

    test('trySend returns full when buffer is full, then recovers', () async {
      // Note: SpscRingBuffer uses one empty slot sentinel, so with pow2=8,
      // the usable capacity is 7 before becoming full.
      final (tx, rx) = Spsc.channel<int>(8);

      for (var i = 0; i < 7; i++) {
        final r = tx.trySend(i);
        expect(r.hasSend, isTrue, reason: 'trySend($i) should be Ok');
      }
      final rFull = tx.trySend(7);
      expect(rFull.isFull, isTrue, reason: '8th trySend should be Full');

      final rr = await rx.recv();
      expect(rr.hasValue, isTrue);
      expect(rr.valueOrNull, 0);

      final rOk = tx.trySend(7);
      expect(rOk.hasSend, isTrue, reason: 'trySend should succeed after a pop');
    });

    test('backpressure: send awaits when consumer is slow', () async {
      final (tx, rx) = Spsc.channel<int>(8);

      final sent = <int>[];
      final producer = () async {
        for (var i = 0; i < 20; i++) {
          await tx.send(i);
          sent.add(i);
        }
      }();

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final received = <int>[];
      for (var i = 0; i < 20; i++) {
        final r = await rx.recv();
        expect(r.hasValue, isTrue);
        received.add(r.valueOrNull!);
        if ((i & 3) == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }

      await producer;
      expect(received, orderedEquals(List.generate(20, (i) => i)));
      expect(sent.length, 20);
    });

    test('closing receiver disconnects sender', () async {
      final (tx, rx) = Spsc.channel<int>(8);

      // Start a pending receive so we exercise the cancel path
      rx.recvCancelable();
      rx.close();

      final r = await tx.send(42);
      expect(r.isDisconnected, isTrue);
    });

    test('closing sender then draining yields RecvErrorDisconnected', () async {
      final (tx, rx) = Spsc.channel<int>(8);

      expect((await tx.send(1)).hasSend, isTrue);
      expect((await tx.send(2)).hasSend, isTrue);
      await tx.send(3);
      tx.close();
      // Drain with a tiny idle window
      final got = await rx.recvAll(idle: const Duration(milliseconds: 1));
      expect(got, isNotEmpty);

      final end = await rx.recv();
      expect(end.isDisconnected, isTrue);
    });
  });
}
