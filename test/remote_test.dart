import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/protocol.dart';
import 'package:cross_channel/src/remote.dart';
import 'package:test/test.dart';

void main() {
  group('RemoteConnection', () {
    test('sender sets up correct port and sends data', () {
      final rx = createReceiver();
      final conn = RemoteConnection<int>.forSender(rx.sendPort);

      expect(conn.isClosed, isFalse);
      expect(conn.targetPort, isNotNull);

      conn.send(42);
      conn.sendBatch([1, 2, 3]);
      conn.sendBatch([4]);

      conn.close();
      expect(conn.isClosed, isTrue);
      conn.send(100); // ignored
      rx.close();
    });

    test('receiver initializes buffer and handles messages', () async {
      final ownerRx = createReceiver();
      final buf = UnboundedBuffer<int>();
      final conn =
          RemoteConnection<int>.forReceiver(ownerRx.sendPort, buffer: buf);

      // It should send a ConnectRecvRequest to ownerRx
      final req = await ownerRx.messages.first;
      expect(req, isA<Map<Object?, Object?>>());
      final ctrl = ControlMessage.fromTransferable(req) as ConnectRecvRequest;
      expect(ctrl.initialCredits,
          0); // UnboundedBuffer has no strict credits in base RemoteConnection

      // Simulate incoming messages to the receiver
      await conn.onMessage(42);
      expect(buf.tryPop(), 42);

      await conn.onMessage([1, 2, 3]);
      expect(buf.tryPop(), 1);
      expect(buf.tryPop(), 2);
      expect(buf.tryPop(), 3);

      await conn.onMessage(const BatchMessage<int>([4, 5]));
      expect(buf.tryPop(), 4);
      expect(buf.tryPop(), 5);

      // Simulate disconnect
      await conn.onMessage(const Disconnect());
      expect(conn.isClosed, isTrue);

      ownerRx.close();
    });

    test('receiver with Map message (transferable)', () async {
      final ownerRx = createReceiver();
      final buf = UnboundedBuffer<int>();
      final conn =
          RemoteConnection<int>.forReceiver(ownerRx.sendPort, buffer: buf);

      await conn.onMessage(const Disconnect().toTransferable());
      expect(conn.isClosed, isTrue);

      ownerRx.close();
    });
  });

  group('FlowControlledRemoteConnection', () {
    test('sender handles credits and messages', () async {
      final destRx = createReceiver();
      final senderConn =
          FlowControlledRemoteConnection<int>.forSender(destRx.sendPort);

      // ConnectSenderRequest is sent initially
      final req = await destRx.messages.first;
      final ctrl = ControlMessage.fromTransferable(req) as ConnectSenderRequest;
      final creditPort = ctrl.replyPort;

      expect(senderConn.credits, 0);
      expect(senderConn.trySend(1), isFalse);

      // Give it credits
      await senderConn.onMessage(const FlowCredit(2));
      expect(senderConn.credits, 2);

      expect(senderConn.trySend(1), isTrue);
      expect(senderConn.credits, 1);

      // send() without await should consume the remaining credit
      unawaited(senderConn.send(2));
      expect(senderConn.credits, 0);

      // sendBatch should only send what it can, and block for the rest
      bool blocked = false;
      unawaited(senderConn.sendBatch([3, 4]).then((_) => blocked = false));
      blocked = true;

      // Wait a bit to ensure it is blocked
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(blocked, isTrue);

      // Grant credits to unblock
      creditPort.send(const FlowCredit(5).toTransferable());
      await senderConn.onMessage(const FlowCredit(5));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(blocked, isFalse);

      // Check destRx received the messages
      senderConn.close();
      destRx.close();
    });

    test('receiver sends credits when consumed', () async {
      final ownerRx = createReceiver();
      final messages = <dynamic>[];
      final sub = ownerRx.messages.listen(messages.add);

      final buf = BoundedBuffer<int>(capacity: 10);
      final rxConn = FlowControlledRemoteConnection<int>.forReceiver(
        ownerRx.sendPort,
        buffer: buf,
        creditBatchSize: 2,
      );

      // Give it a tick to register
      await Future<void>.delayed(Duration.zero);
      expect(messages.isNotEmpty, isTrue);
      expect(ControlMessage.fromTransferable(messages[0]),
          isA<ConnectRecvRequest>());

      // Simulate a sender connecting
      await rxConn.onMessage(ConnectSenderRequest(ownerRx.sendPort));

      // Simulate receiving 5 items -> reaches batch size of 5 (capacity 10 ~/ 2), sends credits
      for (var i = 1; i <= 5; i++) {
        await rxConn.onMessage(i);
        expect(buf.tryPop(), i);
      }

      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (messages.length > 1) break;
      }
      expect(messages.length, greaterThan(1));

      final creditCtrl =
          ControlMessage.fromTransferable(messages[1]) as FlowCredit;
      expect(creditCtrl.credits, 5);

      await sub.cancel();
      rxConn.close();
      ownerRx.close();
    });

    test('receiver handles connect recv request', () async {
      final originRx = createReceiver();
      final conn =
          FlowControlledRemoteConnection<int>.forSender(originRx.sendPort);

      // Handle a ConnectRecvRequest
      final newRx = createReceiver();
      await conn.onMessage(ConnectRecvRequest(newRx.sendPort, 10));

      expect(conn.targetPort, isNotNull);
      expect(conn.credits, 10);

      newRx.close();
      originRx.close();
    });
  });
}
