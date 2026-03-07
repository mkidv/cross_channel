import 'dart:async';

import 'package:cross_channel/cross_channel.dart';
import 'package:cross_channel/src/metrics/core.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelCore Remote Logic', () {
    test('createRemotePort and remote message handling', () async {
      final (tx, rx) = XChannel.mpsc<int>();
      final core = tx.localSendChannel!;

      final remotePort = core.createRemotePort();
      expect(remotePort, isA<PlatformPort>());

      // Sending directly to remotePort should push to local buffer
      remotePort.send(42);

      final res = await rx.recv();
      expect((res as RecvOk<int>).value, 42);
    });

    test('Remote message handling - disconnected', () {
      final (tx, rx) = XChannel.mpsc<int>();
      final core = tx.localSendChannel!;
      tx.close();
      rx.close();
      expect(core.isSendClosed, isTrue);
      expect(core.isRecvClosed, isTrue);
    });

    test('Flow control handshake (ConnectSenderRequest)', () async {
      final (tx, _) = XChannel.mpsc<int>(capacity: 10);
      final core = tx.localSendChannel!;
      final remotePort = core.createRemotePort();

      final replyRx = createReceiver();
      addTearDown(replyRx.close);

      // Simulate a remote sender connecting
      remotePort.send(ConnectSenderRequest(replyRx.sendPort).toTransferable());

      // Handshake: ChannelCore sends ConnectRecvRequest back to replyPort
      final handshake = await replyRx.messages.first as Map;
      expect(handshake['#cc'], 'ConnectRecvRequest');
    });

    test('Flow control handshake (ConnectRecvRequest)', () async {
      final (tx, _) = XChannel.mpsc<int>(capacity: 10);
      final core = tx.localSendChannel!;
      final remotePort = core.createRemotePort();

      final replyRx = createReceiver();
      addTearDown(replyRx.close);

      // Simulate a remote receiver connecting
      remotePort.send(ConnectRecvRequest(replyRx.sendPort, 5).toTransferable());

      // Handshake: ChannelCore starts proxy loop which sends ConnectSenderRequest
      final messages = replyRx.messages.asBroadcastStream();
      final handshake = await messages.first as Map;
      expect(handshake['#cc'], 'ConnectSenderRequest');

      tx.trySend(100);
      final first = await messages.first;
      expect(first, 100);
    });

    test('Metrics sync handling', () async {
      final (tx, _) = XChannel.mpsc<int>(metricsId: 'sync-test');
      final core = tx.localSendChannel!;
      final remotePort = core.createRemotePort();

      remotePort.send(MetricsSync(
        'sync-test',
        'remote-1',
        const ChannelSnapshot(sent: 10),
      ).toTransferable());

      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  });
}
