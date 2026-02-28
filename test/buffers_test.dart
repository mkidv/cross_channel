import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:test/test.dart';

void main() {
  group('UnboundedBuffer', () {
    test('initial state', () {
      final buf = UnboundedBuffer<int>();
      expect(buf.isEmpty, isTrue);
    });

    test('tryPush and tryPop', () {
      final buf = UnboundedBuffer<int>();
      expect(buf.tryPush(1), isTrue);
      expect(buf.isEmpty, isFalse);

      expect(buf.tryPop(), 1);
      expect(buf.isEmpty, isTrue);
      expect(buf.tryPop(), isNull);
    });

    test('tryPopMany', () {
      final buf = UnboundedBuffer<int>();
      buf.tryPush(1);
      buf.tryPush(2);
      buf.tryPush(3);

      expect(buf.tryPopMany(2), [1, 2]);
      expect(buf.tryPopMany(5), [3]);
      expect(buf.tryPopMany(2), isEmpty);
    });

    test('addPopWaiter / removePopWaiter', () async {
      final buf = UnboundedBuffer<int>();
      final waiter = buf.addPopWaiter();
      expect(waiter.isCompleted, isFalse);
      buf.tryPush(42);
      expect(await waiter.future, 42);
    });

    test('waitNotEmpty', () async {
      final buf = UnboundedBuffer<int>();
      final future = buf.waitNotEmpty();
      buf.tryPush(1);
      await future; // should complete now
    });

    test('failAllPopWaiters', () async {
      final buf = UnboundedBuffer<int>();
      final waiter = buf.addPopWaiter();
      final errFuture = expectLater(waiter.future, throwsA('error'));
      buf.failAllPopWaiters('error');
      await errFuture;
    });

    test('clear', () {
      final buf = UnboundedBuffer<int>();
      final waiter = buf.addPopWaiter(); // will not complete until push
      buf.clear();
      expect(buf.isEmpty, isTrue);

      buf.tryPush(2);
      expect(waiter.isCompleted, isFalse);
    });
  });

  group('LatestOnlyBuffer', () {
    test('tryPush overwrites', () {
      final buf = LatestOnlyBuffer<int>();
      buf.tryPush(1);
      buf.tryPush(2);
      expect(buf.tryPop(), 2);
    });

    test('tryPopMany returns at most one', () {
      final buf = LatestOnlyBuffer<int>();
      buf.tryPush(1);
      expect(buf.tryPopMany(5), [1]);
      expect(buf.tryPopMany(5), isEmpty);
    });

    test('addPopWaiter completes if already has item otherwise waits',
        () async {
      final buf = LatestOnlyBuffer<int>();
      buf.tryPush(42);
      final w1 = buf.addPopWaiter();
      expect(w1.isCompleted, isTrue);

      final w2 = buf.addPopWaiter();
      expect(w2.isCompleted, isFalse);
      buf.tryPush(43);
      expect(await w2.future, 43);
    });

    test('failAllPopWaiters', () async {
      final buf = LatestOnlyBuffer<int>();
      final waiter = buf.addPopWaiter();
      final errFuture = expectLater(waiter.future, throwsA('error'));
      buf.failAllPopWaiters('error');
      await errFuture;
    });
  });

  group('PromiseBuffer', () {
    test('consumeOnce=true', () {
      final buf = PromiseBuffer<int>(consumeOnce: true);
      expect(buf.tryPush(1), isTrue);
      expect(buf.tryPush(2), isFalse); // already set

      expect(buf.tryPop(), 1);
      expect(buf.tryPop(), isNull); // consumed
      expect(buf.hasConsumed, isTrue);
    });

    test('consumeOnce=false (broadcast)', () {
      final buf = PromiseBuffer<int>();
      expect(buf.tryPush(1), isTrue);
      expect(buf.tryPush(2), isFalse);

      expect(buf.tryPop(), 1);
      expect(buf.tryPop(), 1); // still there
      expect(buf.tryPopMany(2), [1]);
    });

    test('waiters consumeOnce=true', () async {
      final buf = PromiseBuffer<int>(consumeOnce: true);
      final w1 = buf.addPopWaiter();
      final w2 = buf.addPopWaiter();

      final errFuture = expectLater(w2.future, throwsStateError);
      buf.tryPush(42);
      expect(await w1.future, 42); // first gets it
      await errFuture; // second gets error 'consumed'

      // further waiters get error
      final w3 = buf.addPopWaiter();
      await expectLater(w3.future, throwsStateError);
    });

    test('waiters consumeOnce=false', () async {
      final buf = PromiseBuffer<int>();
      final w1 = buf.addPopWaiter();
      final w2 = buf.addPopWaiter();
      buf.tryPush(42);
      expect(await w1.future, 42);
      expect(await w2.future, 42);

      // further gets it immediately
      final w3 = buf.addPopWaiter();
      expect(await w3.future, 42);
    });

    test('clear', () {
      final buf = PromiseBuffer<int>();
      buf.tryPush(1);
      buf.clear();
      expect(buf.isEmpty, isTrue);
      expect(buf.hasConsumed, isFalse);
    });
  });

  group('RendezvousBuffer', () {
    test('tryPush fails if no waiters', () {
      final buf = RendezvousBuffer<int>();
      expect(buf.tryPush(1), isFalse);
    });

    test('tryPush succeeds if waiter exists', () async {
      final buf = RendezvousBuffer<int>();
      final waiter = buf.addPopWaiter();
      expect(buf.tryPush(1), isTrue);
      expect(await waiter.future, 1);
    });

    test('waitNotEmpty and waitNotFull', () async {
      final buf = RendezvousBuffer<int>();
      bool notEmptyAwake = false;
      buf.waitNotEmpty().then((_) => notEmptyAwake = true);

      bool notFullAwake = false;
      buf.waitNotFull().then((_) => notFullAwake = true);

      final waiter = buf.addPopWaiter(); // A push waiter can now proceed
      await Future<void>.delayed(Duration.zero);
      expect(notFullAwake, isTrue); // waitNotFull should complete now
      expect(notEmptyAwake,
          isTrue); // waitNotEmpty completes because waitNotFull sets a push waiter

      buf.tryPush(1);
      expect(await waiter.future, 1);
    });
  });

  group('PolicyBufferWrapper', () {
    test('DropPolicy.block', () {
      // Simulate a buffer that gets full
      final inner = BoundedBuffer<int>(capacity: 1);
      final buf = PolicyBufferWrapper<int>(inner, policy: DropPolicy.block);

      expect(buf.tryPush(1), isTrue);
      expect(buf.tryPush(2), isFalse); // Blocks
    });

    test('DropPolicy.newest', () {
      final inner = BoundedBuffer<int>(capacity: 1);
      int? dropped;
      final buf = PolicyBufferWrapper<int>(
        inner,
        policy: DropPolicy.newest,
        onDrop: (x) => dropped = x,
      );

      expect(buf.tryPush(1), isTrue);
      expect(buf.tryPush(2), isTrue); // "Succeeds" but drops
      expect(dropped, 2);
    });

    test('DropPolicy.oldest', () {
      final inner = BoundedBuffer<int>(capacity: 1);
      int? dropped;
      final buf = PolicyBufferWrapper<int>(
        inner,
        policy: DropPolicy.oldest,
        onDrop: (x) => dropped = x,
      );

      expect(buf.tryPush(1), isTrue);
      expect(buf.tryPush(2), isTrue); // "Succeeds" but drops oldest (1)
      expect(dropped, 1);
      expect(buf.tryPop(), 2); // And pushes newest (2)
    });
  });
}
