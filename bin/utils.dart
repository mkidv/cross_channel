import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

class Stats {
  final String name;
  final int iters;
  final Duration elapsed;
  final int maxLatencyNs;
  final String? notes;
  Stats(this.name, this.iters, this.elapsed, this.maxLatencyNs, {this.notes});

  @override
  String toString() {
    final ns = elapsed.inMicroseconds * 1000;
    final nsPerOp = ns / iters;
    final opsPerSec = iters / (elapsed.inMicroseconds / 1e6);
    final mops = opsPerSec / 1e6;
    final maxUs = maxLatencyNs / 1000.0;

    return '${name.padRight(50)}'
        '${mops.toStringAsFixed(2)} Mops/s   '
        '${nsPerOp.toStringAsFixed(1)} ns/op   '
        'max recv latency ~ ${maxUs.toStringAsFixed(1)} µs'
        '${notes != null ? '\n${''.padLeft(50)}${notes!}' : ''}';
  }

  String toCsv({
    required String suite,
    String? caseName,
  }) {
    final ns = elapsed.inMicroseconds * 1000;
    final nsPerOp = ns / iters;
    final opsPerSec = iters / (elapsed.inMicroseconds / 1e6);
    final mops = opsPerSec / 1e6;
    final maxUs = maxLatencyNs / 1000.0;

    final caseLabel = caseName ?? name;

    return '$suite,"$caseLabel",${mops.toStringAsFixed(2)},'
        '${nsPerOp.toStringAsFixed(1)},${maxUs.toStringAsFixed(1)}';
  }
}

(int iters, bool csv, bool experimental) parseArgs(List<String> args) {
  final iters =
      args.isNotEmpty && !args[0].contains('--') ? int.parse(args[0]) : 500_000;
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
Future<void> benchPingPong(
    Channel<int> chA, Channel<int> chB, int iters) async {
  final (txAB, rxAB) = chA;
  final (txBA, rxBA) = chB;

  final pong = () async {
    while (true) {
      final r = await rxAB.recv();
      if (!r.hasValue || rxAB.isDisconnected) break;
      await txBA.send(1);
    }
    if (rxBA is Closeable) (rxBA as Closeable).close();
  }();

  final ping = () async {
    for (var i = 0; i < iters; i++) {
      await txAB.send(i);
      final ack = await rxBA.recv();
      if (!ack.hasValue || rxBA.isDisconnected) break;
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
      if (!v.hasValue || rx.isDisconnected) break;
      received++;
      // if ((received & 0x3FF) == 0) { var x = 0; for (int i = 0; i < 64; i++) x ^= i*i; }
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
        if (!v.hasValue || rx.isDisconnected) break;
        received++;
        // if ((received & 0x3FF) == 0) { var x = 0; for (int i = 0; i < 64; i++) x ^= i*i; }
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
