@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:cross_channel/mpmc.dart';
import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/spsc.dart';
import 'package:test/test.dart';

import 'utils.dart';

void main() {
  group('toTransferable / fromTransferable', () {
    group('SPSC', () {
      test('Sender round-trip via Isolate', () async {
        final (tx, rx) = Spsc.channel<String>(64);

        // Serialize and reconstruct in another isolate
        final transferable = tx.toTransferable();

        final handshake = ReceivePort();
        await Isolate.spawn((SendPort reply) async {
          final remoteTx = SpscSender<String>.fromTransferable(transferable);
          await remoteTx.send('hello from isolate');
          reply.send(true);
        }, handshake.sendPort);

        final result = await rx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'hello from isolate');

        await handshake.first;
        handshake.close();
      });

      test('Receiver round-trip via Isolate', () async {
        final (tx, rx) = Spsc.channel<String>(64);

        // Serialize and reconstruct in another isolate
        final transferable = rx.toTransferable();

        final handshake = ReceivePort();
        await Isolate.spawn((SendPort reply) async {
          final remoteRx = SpscReceiver<String>.fromTransferable(transferable);
          final result = await remoteRx.recv();
          reply.send(result.valueOrNull);
        }, handshake.sendPort);

        // Give isolate time to set up the remote connection
        await tick();
        unawaited(tx.send('hello to isolate'));

        final got = await handshake.first as String?;
        handshake.close();
        expect(got, 'hello to isolate');
      });

      test('channelId is -1 on reconstructed handles', () {
        final (tx, rx) = Spsc.channel<int>(8);
        final txData = tx.toTransferable();
        final rxData = rx.toTransferable();

        final remoteTx = SpscSender<int>.fromTransferable(txData);
        final remoteRx = SpscReceiver<int>.fromTransferable(rxData);

        expect(remoteTx.channelId, -1);
        expect(remoteRx.channelId, -1);
      });
    });

    group('MPSC', () {
      test('Sender round-trip via Isolate', () async {
        final (tx, rx) = Mpsc.unbounded<String>(metricsId: 'test.mpsc');

        final transferable = tx.toTransferable();
        expect(transferable['metricsId'], 'test.mpsc');

        final handshake = ReceivePort();
        await Isolate.spawn((SendPort reply) async {
          final remoteTx = MpscSender<String>.fromTransferable(transferable);
          await remoteTx.send('mpsc hello');
          reply.send(true);
        }, handshake.sendPort);

        final result = await rx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'mpsc hello');

        await handshake.first;
        handshake.close();
      });

      test('Receiver round-trip via Isolate', () async {
        final (tx, rx) = Mpsc.unbounded<String>();

        final transferable = rx.toTransferable();

        final handshake = ReceivePort();
        await Isolate.spawn((SendPort reply) async {
          final remoteRx = MpscReceiver<String>.fromTransferable(transferable);
          final result = await remoteRx.recv();
          reply.send(result.valueOrNull);
        }, handshake.sendPort);

        await tick();
        unawaited(tx.send('mpsc to isolate'));

        final got = await handshake.first as String?;
        handshake.close();
        expect(got, 'mpsc to isolate');
      });

      test('metricsId preserved through round-trip', () {
        final (tx, rx) = Mpsc.unbounded<int>(metricsId: 'test.metrics');

        final txData = tx.toTransferable();
        final rxData = rx.toTransferable();

        expect(txData['metricsId'], 'test.metrics');
        expect(rxData['metricsId'], 'test.metrics');

        final remoteTx = MpscSender<int>.fromTransferable(txData);
        final remoteRx = MpscReceiver<int>.fromTransferable(rxData);

        expect(remoteTx.channelId, -1);
        expect(remoteRx.channelId, -1);
      });
    });

    group('MPMC', () {
      test('Sender round-trip via Isolate', () async {
        final (tx, rx) = Mpmc.unbounded<String>();

        final transferable = tx.toTransferable();

        final handshake = ReceivePort();
        await Isolate.spawn((SendPort reply) async {
          final remoteTx = MpmcSender<String>.fromTransferable(transferable);
          await remoteTx.send('mpmc hello');
          reply.send(true);
        }, handshake.sendPort);

        final result = await rx.recv();
        expect(result.hasValue, isTrue);
        expect(result.valueOrNull, 'mpmc hello');

        await handshake.first;
        handshake.close();
      });

      test('channelId is -1 on reconstructed handles', () {
        final (tx, rx) = Mpmc.unbounded<int>();
        final txData = tx.toTransferable();
        final rxData = rx.toTransferable();

        final remoteTx = MpmcSender<int>.fromTransferable(txData);
        final remoteRx = MpmcReceiver<int>.fromTransferable(rxData);

        expect(remoteTx.channelId, -1);
        expect(remoteRx.channelId, -1);
      });
    });
  });
}
