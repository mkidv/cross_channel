import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ControlMessage', () {
    test('ConnectRecvRequest toTransferable and fromTransferable', () {
      final rx = createReceiver();
      final req = ConnectRecvRequest(rx.sendPort, 1024);
      final map = req.toTransferable();

      expect(map['#cc'], 'ConnectRecvRequest');
      expect(map['initialCredits'], 1024);

      final decoded =
          ControlMessage.fromTransferable(map) as ConnectRecvRequest;
      expect(decoded.initialCredits, 1024);
      expect(decoded.replyPort, isNotNull);
      rx.close();
    });

    test('ConnectSenderRequest toTransferable and fromTransferable', () {
      final rx = createReceiver();
      final req = ConnectSenderRequest(rx.sendPort);
      final map = req.toTransferable();

      expect(map['#cc'], 'ConnectSenderRequest');

      final decoded =
          ControlMessage.fromTransferable(map) as ConnectSenderRequest;
      expect(decoded.replyPort, isNotNull);
      rx.close();
    });

    test('ConnectOk toTransferable and fromTransferable', () {
      const ok = ConnectOk();
      final map = ok.toTransferable();

      expect(map['#cc'], 'ConnectOk');

      final decoded = ControlMessage.fromTransferable(map);
      expect(decoded, isA<ConnectOk>());
    });

    test('Disconnect toTransferable and fromTransferable', () {
      const disc = Disconnect();
      final map = disc.toTransferable();

      expect(map['#cc'], 'Disconnect');

      final decoded = ControlMessage.fromTransferable(map);
      expect(decoded, isA<Disconnect>());
    });

    test('FlowCredit toTransferable and fromTransferable', () {
      const credit = FlowCredit(50);
      final map = credit.toTransferable();

      expect(map['#cc'], 'FlowCredit');
      expect(map['credits'], 50);

      final decoded = ControlMessage.fromTransferable(map) as FlowCredit;
      expect(decoded.credits, 50);
    });

    test('BatchMessage toTransferable and fromTransferable', () {
      final batch = BatchMessage<int>([1, 2, 3]);
      final map = batch.toTransferable();

      expect(map['#cc'], 'BatchMessage');
      expect(map['values'], [1, 2, 3]);

      final decoded = ControlMessage.fromTransferable(map) as BatchMessage;
      expect(decoded.values, [1, 2, 3]);
    });

    test('fromTransferable returns null for unknown data', () {
      expect(ControlMessage.fromTransferable(null), isNull);
      expect(ControlMessage.fromTransferable('string'), isNull);
      expect(ControlMessage.fromTransferable({'#cc': 'UnknownType'}), isNull);
    });
  });
}
