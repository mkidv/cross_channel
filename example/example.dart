import 'dart:async';
import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  // MPSC task queue
  final (mpscTx, mpscRx) = XChannel.mpsc<String>(capacity: 4);

  // MPMC worker pool (2 consumers)
  final (mpmcTx, mpmcRx0) = XChannel.mpmc<int>(capacity: 4);
  final mpmcRx1 = mpmcRx0.clone();

  // SPSC hot path
  final (spscTx, spscRx) = XChannel.spsc<double>(capacity: 8);

  // OneShot single reply (consume once)
  final (osTx, osRx) = XChannel.oneshot<String>(consumeOnce: true);

  // Latest-only (progress style)
  final (latestTx, latestRx) = XChannel.mpscLatest<double>();

  // Notify (control-plane wakeups)
  final notify = Notify();

  unawaited(() async {
    for (var i = 0; i < 5; i++) {
      await mpscTx.send('task ${i + 1}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    mpscTx.close();
  }());

  unawaited(() async {
    for (var i = 0; i < 10; i++) {
      await mpmcTx.send(i);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    mpmcTx.close();
  }());

  unawaited(() async {
    for (var i = 0; i < 5; i++) {
      await spscTx.send(i * 0.1);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    spscTx.close();
  }());

  unawaited(() async {
    for (var i = 0; i <= 100; i += 20) {
      latestTx.trySend(i / 100);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    latestTx.close();
  }());

  unawaited(Future<void>.delayed(
    const Duration(milliseconds: 50),
    () => osTx.send('hello'),
  ));

  // Simulate control-plane signals via Notify:
  // - first a single wakeup (config reload)…
  unawaited(Future<void>.delayed(
    const Duration(milliseconds: 120),
    () => notify.notifyOne(),
  ));
  // - then a broadcast wakeup (e.g., shutdown) that wakes all waiters
  unawaited(Future<void>.delayed(
    const Duration(milliseconds: 240),
    () => notify.notifyAll(),
  ));

  // A second independent waiter to demonstrate notifyAll waking multiple tasks
  unawaited(() async {
    final (f, _) = notify.notified();
    await f;
    print('maintenance: received broadcast notify (flush/shutdown hook)');
  }());

  // --- select loop ----------------------------------------------------------
  print('--- cross_channel example ---');

  var aliveMpsc = true,
      aliveMpmc0 = true,
      aliveMpmc1 = true,
      aliveSpsc = true,
      aliveLatest = true;

  bool allDone() =>
      !(aliveMpsc || aliveMpmc0 || aliveMpmc1 || aliveSpsc || aliveLatest);

  // Arm a Notify waiter; we’ll re-arm each time it fires.
  var (notifyFuture, cancelNotify) = notify.notified();

  while (true) {
    final shouldBreak = await XSelect.run<bool>((s) => s
      ..onTick(const Duration(milliseconds: 10), () {
        print('heartbeat…');
        return allDone();
      })
      // Notify: control-plane wakeups (no payload)
      ..onFuture<void>(notifyFuture, (_) {
        print('Notify: wakeup (config/shutdown signal)');
        // Re-arm for the next signal
        final pair = notify.notified();
        notifyFuture = pair.$1;
        cancelNotify = pair.$2;
        return false;
      })
      ..onRecvValue<String>(osRx, (v) {
        print('OneShot reply: $v');
        return false;
      })
      ..onRecvValue<String>(mpscRx, (msg) {
        print('MPSC got $msg');
        return false;
      }, onDisconnected: () {
        if (aliveMpsc) {
          aliveMpsc = false;
          print('MPSC disconnected');
        }
        return allDone();
      })
      ..onRecvValue<int>(mpmcRx0, (v) {
        print('MPMC0 got $v');
        return false;
      }, onDisconnected: () {
        if (aliveMpmc0) {
          aliveMpmc0 = false;
          print('MPMC0 disconnected');
        }
        return allDone();
      })
      ..onRecvValue<int>(mpmcRx1, (v) {
        print('MPMC1 got $v');
        return false;
      }, onDisconnected: () {
        if (aliveMpmc1) {
          aliveMpmc1 = false;
          print('MPMC1 disconnected');
        }
        return allDone();
      })
      ..onRecvValue<double>(spscRx, (v) {
        print('SPSC got $v');
        return false;
      }, onDisconnected: () {
        if (aliveSpsc) {
          aliveSpsc = false;
          print('SPSC disconnected');
        }
        return allDone();
      })
      ..onRecvValue<double>(latestRx, (p) {
        print('LatestOnly progress: ${(p * 100).round()}%');
        return false;
      }, onDisconnected: () {
        if (aliveLatest) {
          aliveLatest = false;
          print('LatestOnly disconnected');
        }
        return allDone();
      })
      ..onTimeout(const Duration(milliseconds: 50), () {
        print('timeout');
        return true;
      }));

    // print(
    //     "($aliveMpsc || $aliveMpmc0 || $aliveMpmc1 || $aliveSpsc || $aliveLatest)");
    if (shouldBreak) break;
  }

  // Cleanup Notify waiter if still pending
  cancelNotify();
  notify.close();

  print('--- example complete ---');
}
