import 'dart:async';

import 'package:cross_channel/notify.dart';

Future<void> main() async {
  final notify = Notify();

  // 1. Basic signaling
  unawaited(Future.microtask(() async {
    final (future, _) = notify.notified();
    await future;
    print('Worker 1: Received signal');
  }));

  notify.notifyOne();

  // 2. Broadcast signaling
  unawaited(Future.microtask(() async {
    final (future, _) = notify.notified();
    await future;
    print('Worker 2: Shutting down');
  }));

  unawaited(Future.microtask(() async {
    final (future, _) = notify.notified();
    await future;
    print('Worker 3: Shutting down');
  }));

  notify.notifyAll();
}
