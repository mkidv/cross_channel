import 'dart:isolate';

import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/metrics.dart';
import 'package:cross_channel/src/result.dart';

// class Stats {
//   final String name;
//   final int iters;
//   final Duration elapsed;
//   final int maxLatencyNs;
//   final String? notes;
//   Stats(this.name, this.iters, this.elapsed, this.maxLatencyNs, {this.notes});

//   @override
//   String toString() {
//     final ns = elapsed.inMicroseconds * 1000;
//     final nsPerOp = ns / iters;
//     final opsPerSec = iters / (elapsed.inMicroseconds / 1e6);
//     final mops = opsPerSec / 1e6;
//     final maxUs = maxLatencyNs / 1000.0;

//     return '${name.padRight(50)}'
//         '${mops.toStringAsFixed(2)} Mops/s   '
//         '${nsPerOp.toStringAsFixed(1)} ns/op   '
//         'max recv latency ~ ${maxUs.toStringAsFixed(1)} µs'
//         '${notes != null ? '\n${''.padLeft(50)}${notes!}' : ''}';
//   }

//   String toCsv({
//     required String suite,
//     String? caseName,
//   }) {
//     final ns = elapsed.inMicroseconds * 1000;
//     final nsPerOp = ns / iters;
//     final opsPerSec = iters / (elapsed.inMicroseconds / 1e6);
//     final mops = opsPerSec / 1e6;
//     final maxUs = maxLatencyNs / 1000.0;

//     final caseLabel = caseName ?? name;

//     return '$suite,"$caseLabel",${mops.toStringAsFixed(2)},'
//         '${nsPerOp.toStringAsFixed(1)},${maxUs.toStringAsFixed(1)}';
//   }
// }

(int iters, bool csv, bool experimental) parseArgs(List<String> args) {
  final iters = args.isNotEmpty && !args[0].contains('--') ? int.parse(args[0]) : 500_000;
  var csv = false;
  var exp = false;
  for (final a in args) {
    if (a.startsWith('--csv')) csv = true;
    if (a.startsWith('--exp')) exp = true;
  }

  return (iters, csv, exp);
}

extension IntBytesX on int {
  String bytesToPrettyString() {
    if (this < 1024) return '${this}B';
    if (this < 1024 * 1024) return '${(this / 1024).toStringAsFixed(1)}KB';
    return '${(this / (1024 * 1024)).toStringAsFixed(2)}MB';
  }
}

/// ping-pong strict. Round-trip N times.
Future<void> benchPingPong(Channel<int> chA, Channel<int> chB, int iters) async {
  final (txAB, rxAB) = chA;
  final (txBA, rxBA) = chB;

  final pong = () async {
    while (true) {
      final r = await rxAB.recv();
      if (!r.hasValue || rxAB.recvDisconnected) break;
      await txBA.send(1);
    }
    if (rxBA is Closeable) (rxBA as Closeable).close();
  }();

  final ping = () async {
    for (var i = 0; i < iters; i++) {
      await txAB.send(i);
      final ack = await rxBA.recv();
      if (!ack.hasValue || rxBA.recvDisconnected) break;
    }
    if (rxAB is Closeable) (rxAB as Closeable).close();
  }();

  await Future.wait([ping, pong]);
}

/// producer pushes N, consumer drains N.
Future<void> benchPipeline(Channel<int> ch, int iters) async {
  final (tx, rx) = ch;

  var received = 0;

  final r = () async {
    while (received < iters) {
      final v = await rx.recv();
      if (!v.hasValue || rx.recvDisconnected) break;
      received++;
    }
    if (rx is Closeable) (rx as Closeable).close();
  }();

  final s = () async {
    for (var i = 0; i < iters; i++) {
      await tx.send(i);
    }
    if (tx is Closeable) (tx as Closeable).close();
  }();

  await Future.wait([r, s]);
}

/// N producers pushes N, consumer drains N.
Future<void> benchMultiPipeline(
  Channel<int> ch,
  int iters,
  int prods,
  int cons,
) async {
  if (prods <= 0 || cons <= 0) return;

  final (tx0, rx0) = ch;

  final senders = <Sender<int>>[tx0];

  if (tx0 is CloneableSender) {
    for (var i = 1; i < prods; i++) {
      final s = tx0 as CloneableSender<int>;
      senders.add(s.clone());
    }
  }

  final receivers = <Receiver<int>>[rx0];

  if (tx0 is CloneableReceiver) {
    for (var i = 1; i < cons; i++) {
      final r = rx0 as CloneableReceiver<int>;
      receivers.add(r.clone());
    }
  }

  final itersByProd = iters / prods;
  var received = 0;

  final rt = <Future<void>>[];
  for (final rx in receivers) {
    rt.add(() async {
      while (received < iters) {
        final v = await rx.recv();
        if (!v.hasValue || rx.recvDisconnected) break;
        received++;
      }
      if (rx is Closeable) (rx as Closeable).close();
    }());
  }

  final st = <Future<void>>[];
  for (final tx in senders) {
    st.add(() async {
      for (var k = 0; k < itersByProd; k++) {
        await tx.send(k);
      }
      if (tx is Closeable) (tx as Closeable).close();
    }());
  }

  await Future.wait([...rt, ...st]);
}

/// Cross-Isolate Pipeline: Isolate A (sender) → Isolate B (receiver)
/// Both sender and receiver run in separate isolates, communicating through the channel.
Future<void> benchCrossIsolatePipeline(Channel<int> ch, int iters) async {
  final (tx, rx) = ch;

  final receiverDone = ReceivePort();
  final senderDone = ReceivePort();

  // Spawn receiver isolate
  await Isolate.spawn((SendPort port) async {
    MetricsConfig.enabled = true;
    MetricsConfig.sampleLatency = true;
    MetricsConfig.sampleRate = 1.0;
    var received = 0;
    while (received < iters) {
      final v = await rx.recv();
      if (!v.hasValue || rx.recvDisconnected) break;
      received++;
    }
    if (rx is Closeable) (rx as Closeable).close();
    port.send((received, MetricsRegistry().snapshot()));
  }, receiverDone.sendPort);

  // Give receiver time to set up handshake
  await Future<void>.delayed(const Duration(milliseconds: 500));

  // Spawn sender isolate
  await Isolate.spawn((SendPort port) async {
    MetricsConfig.enabled = true;
    MetricsConfig.sampleLatency = true;
    MetricsConfig.sampleRate = 1.0;
    try {
      for (var i = 0; i < iters; i++) {
        await tx.send(i);
      }
      if (tx is Closeable) (tx as Closeable).close();
      port.send((iters, MetricsRegistry().snapshot()));
    } catch (e, s) {
      print('CRITICAL ERROR IN SENDER ISOLATE: $e\n$s');
      port.send((-1, MetricsRegistry().snapshot())); // Signal error
    }
  }, senderDone.sendPort);

  // Wait for both to finish
  final results = await Future.wait([receiverDone.first, senderDone.first]);
  for (final res in results) {
    if (res is (int, GlobalMetrics)) {
      MetricsRegistry().merge(res.$2);
    }
  }
  receiverDone.close();
  senderDone.close();
}

/// Cross-Isolate Ping-Pong: Isolate A ↔ Isolate B (round-trip)
/// Two distinct isolates exchange messages through two channels.
Future<void> benchCrossIsolatePingPong(Channel<int> chAB, Channel<int> chBA, int iters) async {
  final (txAB, rxAB) = chAB;
  final (txBA, rxBA) = chBA;

  final isolateADone = ReceivePort();
  final isolateBDone = ReceivePort();

  // Isolate B: receives from A, sends back to A
  await Isolate.spawn((SendPort port) async {
    MetricsConfig.enabled = true;
    MetricsConfig.sampleLatency = true;
    MetricsConfig.sampleRate = 1.0;
    var count = 0;
    while (count < iters) {
      final v = await rxAB.recv();
      if (!v.hasValue || rxAB.recvDisconnected) break;
      await txBA.send(1);
      count++;
    }
    if (rxAB is Closeable) (rxAB as Closeable).close();
    if (txBA is Closeable) (txBA as Closeable).close();
    port.send((count, MetricsRegistry().snapshot()));
  }, isolateBDone.sendPort);

  // Give B time to set up
  await Future<void>.delayed(const Duration(milliseconds: 500));

  // Isolate A: sends to B, receives ack from B
  await Isolate.spawn((SendPort port) async {
    MetricsConfig.enabled = true;
    MetricsConfig.sampleLatency = true;
    MetricsConfig.sampleRate = 1.0;
    var count = 0;
    for (var i = 0; i < iters; i++) {
      await txAB.send(i);
      final ack = await rxBA.recv();
      if (!ack.hasValue || rxBA.recvDisconnected) break;
      count++;
    }
    if (txAB is Closeable) (txAB as Closeable).close();
    if (rxBA is Closeable) (rxBA as Closeable).close();
    port.send((count, MetricsRegistry().snapshot()));
  }, isolateADone.sendPort);

  // Wait for both to finish
  final results = await Future.wait([isolateADone.first, isolateBDone.first]);
  for (final res in results) {
    if (res is (int, GlobalMetrics)) {
      MetricsRegistry().merge(res.$2);
    }
  }
  isolateADone.close();
  isolateBDone.close();
}
