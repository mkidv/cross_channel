import 'dart:async';

import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

extension StreamReceiverX<T> on KeepAliveReceiver<T> {
  /// Bridge utilities between channels and broadcast streams.
  ///
  /// `KeepAliveReceiver.toBroadcastStream(...)` turns a single-subscription
  /// receiver into a `StreamController.broadcast`. When `waitForListeners` and
  /// `stopWhenNoListeners` are both true, the underlying subscription is paused
  /// while there are no listeners. Note: broadcast streams do not support
  /// `onPause/onResume` callbacks; only `onListen/onCancel` are used here.
  ///
  Stream<T> toBroadcastStream({
    bool waitForListeners = false,
    bool stopWhenNoListeners = true,
    bool closeReceiverOnDone = false,
    bool sync = false,
  }) {
    final source = stream();
    StreamSubscription<T>? sub;
    late final StreamController<T> ctrl;

    final bool shouldPause = waitForListeners && stopWhenNoListeners;

    void startIfNeeded() {
      if (sub != null) return;
      sub = source.listen(
        (v) => ctrl.add(v),
        onError: ctrl.addError,
        onDone: () async {
          if (closeReceiverOnDone && !isClosed) close();
          await ctrl.close();
        },
        cancelOnError: false,
      );
      if (shouldPause && !ctrl.hasListener) {
        sub!.pause();
      }
    }

    Future<void> pauseIfNeeded() async {
      final s = sub;
      if (s != null && !s.isPaused) s.pause();
    }

    Future<void> resumeIfNeeded() async {
      final s = sub;
      if (s != null && s.isPaused) s.resume();
    }

    ctrl = StreamController<T>.broadcast(
      sync: sync,
      onListen: () {
        startIfNeeded();
        if (shouldPause) resumeIfNeeded();
      },
      onCancel: () async {
        if (shouldPause && !ctrl.hasListener) {
          return pauseIfNeeded();
        }
        return;
      },
    );

    if (!waitForListeners) {
      startIfNeeded();
    }

    return ctrl.stream;
  }
}

extension SenderStreamX<T> on Stream<T> {
  /// Pushes all items from this stream into `KeepAliveSender<T>`.
  /// If the channel is full and `dropWhenFull == true`, values are dropped.
  /// Closes the sender when the stream completes if `closeSenderOnDone == true`.
  ///
  Future<void> redirectToSender(
    KeepAliveSender<T> tx, {
    bool dropWhenFull = false,
    bool closeSenderOnDone = true,
  }) async {
    try {
      await for (final v in this) {
        final r = tx.trySend(v);
        if (r.ok) continue;
        if (r.disconnected) break;
        if (dropWhenFull) continue;

        final r1 = await tx.send(v);
        if (r1.disconnected) break;
      }
    } finally {
      if (closeSenderOnDone && !tx.isClosed) {
        tx.close();
      }
    }
  }
}
