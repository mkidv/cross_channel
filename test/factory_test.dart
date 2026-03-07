import 'package:cross_channel/cross_channel.dart';
import 'package:test/test.dart';

void main() {
  group('XChannel Factory', () {
    test('mpsc creates mpsc channel', () {
      final (tx, rx) = XChannel.mpsc<int>();
      expect(tx, isA<MpscSender<int>>());
      expect(rx, isA<MpscReceiver<int>>());
    });

    test('mpmc creates mpmc channel', () {
      final (tx, rx) = XChannel.mpmc<int>();
      expect(tx, isA<MpmcSender<int>>());
      expect(rx, isA<MpmcReceiver<int>>());
    });

    test('oneshot creates oneshot channel', () {
      final (tx, rx) = XChannel.oneshot<int>();
      expect(tx, isA<OneShotSender<int>>());
      expect(rx, isA<OneShotReceiver<int>>());
    });

    test('spsc creates spsc channel', () {
      final (tx, rx) = XChannel.spsc<int>(capacity: 16);
      expect(tx, isA<SpscSender<int>>());
      expect(rx, isA<SpscReceiver<int>>());
    });

    test('mpscLatest creates latest-only mpsc', () {
      final (tx, rx) = XChannel.mpscLatest<int>();
      expect(tx, isA<MpscSender<int>>());
      expect(rx, isA<MpscReceiver<int>>());
      // Check it drops old values
      tx.trySend(1);
      tx.trySend(2);
      final r = rx.tryRecv();
      expect((r as RecvOk<int>).value, 2);
    });

    test('mpmcLatest creates latest-only mpmc', () {
      final (tx, rx) = XChannel.mpmcLatest<int>();
      expect(tx, isA<MpmcSender<int>>());
      expect(rx, isA<MpmcReceiver<int>>());
      tx.trySend(1);
      tx.trySend(2);
      final r = rx.tryRecv();
      expect((r as RecvOk<int>).value, 2);
    });

    test('broadcast creates broadcast channel', () {
      final (tx, at) = XChannel.broadcast<int>(capacity: 16);
      expect(tx, isA<BroadcastSender<int>>());
      expect(at, isA<Broadcast<int>>());
    });
  });
}
