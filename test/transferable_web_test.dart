@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:cross_channel/broadcast.dart';
import 'package:cross_channel/mpmc.dart';
import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/oneshot.dart';
import 'package:cross_channel/spsc.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'utils.dart';

/// Simulates sending a transferable Map through postMessage and receiving it
/// on the other side, just like a Web Worker would. The raw MessagePort
/// is placed in the transfer list so ownership moves to the receiver.
Future<Map<String, Object?>> simulatePostMessageTransfer(
    Map<String, Object?> data) async {
  final mc = web.MessageChannel();
  final completer = Completer<Map<String, Object?>>();

  mc.port2.onmessage = ((web.MessageEvent e) {
    final raw = (e.data as JSObject).dartify()! as Map;
    final typed = raw.cast<String, Object?>();
    // The 'port' key is a raw MessagePort that survived the transfer
    completer.complete(typed);
  }).toJS;

  // Build a JS object from the data, extracting the MessagePort for transfer
  final port = data['port'] as web.MessagePort;
  final jsData = data.jsify() as JSObject;
  final transferList = [port].jsify() as JSArray;
  mc.port1.postMessage(jsData, transferList);

  final result = await completer.future;

  mc.port1.close();
  mc.port2.close();

  return result;
}

void main() {
  group('Web transferable round-trip via postMessage', () {
    group('SPSC', () {
      test('Sender survives postMessage transfer', () async {
        final (tx, rx) = Spsc.channel<String>(64);

        // Serialize, transfer through postMessage, reconstruct
        final data = tx.toTransferable();
        final received = await simulatePostMessageTransfer(data);
        final remoteTx = SpscSender<String>.fromTransferable(received);

        // Verify channelId = -1 (remote path)
        expect(remoteTx.channelId, -1);

        // Send through the transferred sender
        unawaited(remoteTx.send('hello from web worker'));

        await tick();

        final result = await rx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'hello from web worker');
      });

      test('Receiver survives postMessage transfer', () async {
        final (tx, rx) = Spsc.channel<String>(64);

        final data = rx.toTransferable();
        final received = await simulatePostMessageTransfer(data);
        final remoteRx = SpscReceiver<String>.fromTransferable(received);

        expect(remoteRx.channelId, -1);

        unawaited(tx.send('hello to web worker'));

        await tick(3);

        final result = await remoteRx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'hello to web worker');
      });
    });

    group('MPSC', () {
      test('Sender survives postMessage transfer', () async {
        final (tx, rx) = Mpsc.unbounded<String>(metricsId: 'test.mpsc.web');

        final data = tx.toTransferable();
        expect(data['metricsId'], 'test.mpsc.web');

        final received = await simulatePostMessageTransfer(data);
        final remoteTx = MpscSender<String>.fromTransferable(received);

        expect(remoteTx.channelId, -1);

        unawaited(remoteTx.send('mpsc web hello'));

        await tick();

        final result = await rx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'mpsc web hello');
      });

      test('Receiver survives postMessage transfer', () async {
        final (tx, rx) = Mpsc.unbounded<String>();

        final data = rx.toTransferable();
        final received = await simulatePostMessageTransfer(data);
        final remoteRx = MpscReceiver<String>.fromTransferable(received);

        expect(remoteRx.channelId, -1);

        unawaited(tx.send('mpsc to worker'));

        await tick(3);

        final result = await remoteRx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'mpsc to worker');
      });
    });

    group('MPMC', () {
      test('Sender survives postMessage transfer', () async {
        final (tx, rx) = Mpmc.unbounded<String>();

        final data = tx.toTransferable();
        final received = await simulatePostMessageTransfer(data);
        final remoteTx = MpmcSender<String>.fromTransferable(received);

        expect(remoteTx.channelId, -1);

        unawaited(remoteTx.send('mpmc web hello'));

        await tick();

        final result = await rx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'mpmc web hello');
      });

      test('Receiver survives postMessage transfer', () async {
        final (tx, rx) = Mpmc.unbounded<String>();

        final data = rx.toTransferable();
        final received = await simulatePostMessageTransfer(data);
        final remoteRx = MpmcReceiver<String>.fromTransferable(received);

        expect(remoteRx.channelId, -1);

        unawaited(tx.send('mpmc to worker'));

        await tick(3);

        final result = await remoteRx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'mpmc to worker');
      });
    });

    group('Broadcast', () {
      test('Sender survives postMessage transfer', () async {
        final (tx, broadcast) = Broadcast.channel<String>(16);
        final sub = broadcast.subscribe();

        final data = tx.toTransferable();
        final received = await simulatePostMessageTransfer(data);
        final remoteTx = BroadcastSender<String>.fromTransferable(received);

        expect(remoteTx.channelId, -1);

        unawaited(remoteTx.send('broadcast web hello'));

        await tick();

        final result = await sub.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'broadcast web hello');
      });
    });

    group('OneShot', () {
      test('Sender survives postMessage transfer', () async {
        final (tx, rx) = OneShot.channel<String>();

        final data = tx.toTransferable();
        final received = await simulatePostMessageTransfer(data);
        final remoteTx = OneShotSender<String>.fromTransferable(received);

        expect(remoteTx.channelId, -1);

        unawaited(remoteTx.send('oneshot web hello'));

        await tick();

        final result = await rx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'oneshot web hello');
      });

      test('Receiver survives postMessage transfer', () async {
        final (tx, rx) = OneShot.channel<String>();

        final data = rx.toTransferable();
        final received = await simulatePostMessageTransfer(data);
        final remoteRx = OneShotReceiver<String>.fromTransferable(received);

        expect(remoteRx.channelId, -1);

        unawaited(tx.send('oneshot to worker'));

        await tick(3);

        final result = await remoteRx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'oneshot to worker');
      });
    });

    group('Multiple transfers', () {
      test('Multiple senders from same channel survive transfer', () async {
        final (tx, rx) = Mpsc.unbounded<int>();

        // Clone + transfer two senders
        final tx2 = tx.clone();
        final data1 = tx.toTransferable();
        final data2 = tx2.toTransferable();

        final received1 = await simulatePostMessageTransfer(data1);
        final received2 = await simulatePostMessageTransfer(data2);

        final remote1 = MpscSender<int>.fromTransferable(received1);
        final remote2 = MpscSender<int>.fromTransferable(received2);

        unawaited(remote1.send(1));
        unawaited(remote2.send(2));

        await tick(2);

        final results = <int>[];
        final r1 = await rx.recv();
        if (r1.hasValue) results.add(r1.valueOrNull!);
        final r2 = await rx.recv();
        if (r2.hasValue) results.add(r2.valueOrNull!);

        expect(results..sort(), [1, 2]);
      });
    });

    group('Advanced Robustness', () {
      test('Nested Handle Transfer: Sender through another Sender', () async {
        final (tx1, rx1) = Spsc.channel<Map<Object?, Object?>>(64);
        final (tx2, rx2) = Mpsc.unbounded<String>();

        // Transfer tx1 to "worker"
        final data1 = tx1.toTransferable();
        final received1 = await simulatePostMessageTransfer(data1);
        final remoteTx1 =
            SpscSender<Map<Object?, Object?>>.fromTransferable(received1);

        // Through remoteTx1, send tx2 (serialized)
        final data2 = tx2.toTransferable();
        unawaited(remoteTx1.send(data2));

        // In main context, receive tx2's data from rx1
        final res = await rx1.recv();
        expect(res.hasValue, isTrue);
        final received2 = res.valueOrNull!.cast<String, Object?>();

        // Reconstruct tx2 and use it
        final remoteTx2 = MpscSender<String>.fromTransferable(
            received2.cast<String, Object?>());
        unawaited(remoteTx2.send('nested hello'));

        // rx2 should receive it
        final res2 = await rx2.recv();
        expect(res2.hasValue, isTrue);
        expect(res2.valueOrNull, 'nested hello');
      });

      test('Flow Control: Remote Sender blocks when buffer + burst is exceeded',
          () async {
        // We use a small bounded channel.
        // Initial burst is 32 credits.
        final (tx, rx) = Mpsc.bounded<int>(32);

        final data = tx.toTransferable();
        final received = await simulatePostMessageTransfer(data);
        final remoteTx = MpscSender<int>.fromTransferable(received);

        // Send 64 items (buffer capacity + network window limit)
        for (var i = 0; i < 64; i++) {
          await remoteTx.send(i);
        }

        // 65th send should block because credits=0 and buffer is full
        bool sixtyFifthSent = false;
        final fut = remoteTx.send(64).then((_) => sixtyFifthSent = true);

        await tick(10);
        expect(sixtyFifthSent, isFalse,
            reason: 'Sender should be blocked by flow control');

        // Drain several items to trigger a credit batch (16 items)
        for (var i = 0; i < 16; i++) {
          await rx.recv();
        }

        // Give time for FlowCredit to arrive and sender to unblock
        await tick(10);
        await fut;
        expect(sixtyFifthSent, isTrue,
            reason: 'Sender should unblock after receiving FlowCredit');
      });

      test(
          'Disconnection Propagation: Remote close triggers local disconnected',
          () async {
        final (tx, rx) = Spsc.channel<int>(64);

        final data = tx.toTransferable();
        final received = await simulatePostMessageTransfer(data);
        final remoteTx = SpscSender<int>.fromTransferable(received);

        expect(rx.isRecvClosed, isFalse);

        remoteTx.close();
        tx.close(); // Must drop the local anchor as well!
        await tick(5);

        // rx should eventually detect disconnection
        final res = await rx.recv();
        expect(res.isDisconnected, isTrue);
      });
    });
  });
}
