import 'dart:async';

import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/result.dart';

/// Timeout operations for [Sender].
///
/// Prevents indefinite blocking by adding timeouts to send operations.
/// Essential for building robust systems with predictable behavior.
///
/// **Usage:**
/// ```dart
/// import 'package:cross_channel/cross_channel.dart';
///
/// Future<void> main() async {
///   final (tx, _) = XChannel.mpsc<String>(capacity: 1);
///
///   // Fill the channel
///   tx.trySend('first');
///
///   // Next send will block and then timeout
///   final result = await tx.sendTimeout('second', const Duration(seconds: 2));
///
///   if (result.isTimeout) {
///     print('Send timed out!');
///   }
/// }
/// ```
extension SenderTimeoutX<T> on Sender<T> {
  /// Send a value with a timeout to prevent indefinite blocking.
  ///
  /// Returns [SendErrorTimeout] if the operation doesn't complete within
  /// the specified [d]. Useful for implementing deadlock-free systems.
  ///
  /// **Parameters:**
  /// - [v]: The value to send
  /// - [d]: Maximum time to wait for the send to complete
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (tx, _) = XChannel.mpsc<String>(capacity: 1);
  ///
  ///   // Fill the channel
  ///   tx.trySend('first');
  ///
  ///   // Next send will block and then timeout
  ///   final result = await tx.sendTimeout('second', const Duration(seconds: 2));
  ///
  ///   if (result.isTimeout) {
  ///     print('Send timed out!');
  ///   }
  /// }
  /// ```
  Future<SendResult> sendTimeout(T v, Duration d) async {
    try {
      return await send(v).timeout(
        d,
        onTimeout: () => SendErrorTimeout(d),
      );
    } catch (e) {
      return SendErrorFailed(e);
    }
  }
}

/// Timeout operations for [Receiver].
///
/// Prevents indefinite blocking by adding timeouts to receive operations.
/// Critical for building responsive applications that don't hang waiting for data.
///
/// **Usage:**
/// ```dart
/// import 'package:cross_channel/cross_channel.dart';
///
/// Future<void> main() async {
///   final (_, rx) = XChannel.mpsc<String>();
///
///   // No data arrives
///   final result = await rx.recvTimeout(const Duration(seconds: 2));
///
///   if (result.isTimeout) {
///     print('No data in 2s!');
///   }
/// }
/// ```
extension ReceiverTimeoutX<T> on Receiver<T> {
  /// Receive a value with a timeout to prevent indefinite waiting.
  ///
  /// Returns [RecvErrorTimeout] if no value arrives within the specified
  /// [d]. For cancelable receivers, properly cancels the operation.
  ///
  /// **Parameters:**
  /// - [d]: Maximum time to wait for a value
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (_, rx) = XChannel.mpsc<String>();
  ///
  ///   // No data arrives
  ///   final result = await rx.recvTimeout(const Duration(seconds: 2));
  ///
  ///   if (result.isTimeout) {
  ///     print('No data in 2s!');
  ///   }
  /// }
  /// ```
  Future<RecvResult<T>> recvTimeout(Duration d) {
    if (this is KeepAliveReceiver<T>) {
      final (fut, cancel) = (this as KeepAliveReceiver<T>).recvCancelable();
      return fut.timeout(d, onTimeout: () {
        cancel();
        return RecvErrorTimeout(d);
      });
    }
    return recv().timeout(d, onTimeout: () => RecvErrorTimeout(d));
  }
}

/// Batch sending operations for [Sender].
///
/// Efficiently send multiple values in sequence with different strategies
/// for handling backpressure and disconnection.
///
/// **Usage:**
/// ```dart
/// import 'package:cross_channel/cross_channel.dart';
///
/// Future<void> main() async {
///   final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
///   final items = ['batch 1', 'batch 2', 'batch 3'];
///
///   // 1. Batch sending
///   await tx.sendAll(items);
///   await tx.trySendAll(['fast 1', 'fast 2']);
///
///   // 2. Batch receiving (with 100ms idle timeout)
///   final batch = await rx.recvAll(
///     idle: const Duration(milliseconds: 100),
///     max: 10,
///   );
///   print('Received batch: $batch');
///
///   // 3. Immediate drain
///   final available = rx.tryRecvAll(max: 5);
///   print('Immediately available: $available');
/// }
/// ```
extension SenderBatchX<T> on Sender<T> {
  /// Send all items using [trySend] without waiting (best-effort).
  ///
  /// If the channel becomes full, items are silently dropped. Use this when
  /// you want maximum throughput and can tolerate data loss.
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
  ///   final items = ['batch 1', 'batch 2', 'batch 3'];
  ///
  ///   // 1. Batch sending
  ///   await tx.sendAll(items);
  ///   await tx.trySendAll(['fast 1', 'fast 2']);
  ///
  ///   // 2. Batch receiving (with 100ms idle timeout)
  ///   final batch = await rx.recvAll(
  ///     idle: const Duration(milliseconds: 100),
  ///     max: 10,
  ///   );
  ///   print('Received batch: $batch');
  ///
  ///   // 3. Immediate drain
  ///   final available = rx.tryRecvAll(max: 5);
  ///   print('Immediately available: $available');
  /// }
  /// ```
  Future<void> trySendAll(Iterable<T> it) async {
    for (final v in it) {
      trySend(v);
    }
  }

  /// Send all items with backpressure handling.
  ///
  /// Uses [trySend] first for speed, then falls back to [send] if the channel
  /// is full. Stops immediately if the channel becomes disconnected.
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
  ///   final items = ['batch 1', 'batch 2', 'batch 3'];
  ///
  ///   // 1. Batch sending
  ///   await tx.sendAll(items);
  ///   await tx.trySendAll(['fast 1', 'fast 2']);
  ///
  ///   // 2. Batch receiving (with 100ms idle timeout)
  ///   final batch = await rx.recvAll(
  ///     idle: const Duration(milliseconds: 100),
  ///     max: 10,
  ///   );
  ///   print('Received batch: $batch');
  ///
  ///   // 3. Immediate drain
  ///   final available = rx.tryRecvAll(max: 5);
  ///   print('Immediately available: $available');
  /// }
  /// ```
  Future<void> sendAll(Iterable<T> it) async {
    for (final v in it) {
      final r = trySend(v);
      if (r.isFull) {
        await send(v);
      } else if (r.isDisconnected) {
        break;
      }
    }
  }
}

typedef _TrySend<T> = SendResult Function(T value);
typedef _Send<T> = Future<SendResult> Function(T value);

Future<void> _forwardFromReceiver<T>(
  Receiver<T> source, {
  required _TrySend<T> trySend,
  required _Send<T> send,
  required bool Function() targetDisconnected,
  required bool dropWhenFull,
}) async {
  while (true) {
    final r = await source.recv();
    if (r is! RecvOk<T>) {
      break;
    }

    final fast = trySend(r.value);
    if (fast.hasSend) continue;
    if (fast.isDisconnected || targetDisconnected()) break;
    if (dropWhenFull) continue;

    final slow = await send(r.value);
    if (slow.isDisconnected) break;
  }
}

/// Forward values from a [Receiver] to another endpoint.
extension ReceiverForward<T> on Receiver<T> {
  /// Forwards all values from this receiver to [target].
  ///
  /// Stops when the source disconnects or when the target disconnects.
  Future<void> pipeTo(
    Sender<T> target, {
    bool dropWhenFull = false,
    bool closeTargetOnDone = false,
    bool closeSourceOnDone = false,
  }) async {
    try {
      await _forwardFromReceiver<T>(
        this,
        trySend: target.trySend,
        send: target.send,
        targetDisconnected: () => target.sendDisconnected,
        dropWhenFull: dropWhenFull,
      );
    } finally {
      if (closeSourceOnDone && this is Closeable) {
        (this as Closeable).close();
      }
      if (closeTargetOnDone && target is Closeable) {
        (target as Closeable).close();
      }
    }
  }

  /// Forwards all values from this receiver to [target].
  ///
  /// This method requires [target] to be local. For remote targets, use
  /// [pipeTo] with an explicit sender handle.
  Future<void> pipeToReceiver(
    Receiver<T> target, {
    bool dropWhenFull = false,
    bool closeTargetOnDone = false,
    bool closeSourceOnDone = false,
  }) async {
    final local = target.localRecvChannel;
    if (local == null) {
      throw UnsupportedError(
        'pipeToReceiver requires a local receiver target. '
        'Use pipeTo with a Sender instead.',
      );
    }

    try {
      await _forwardFromReceiver<T>(
        this,
        trySend: local.trySend,
        send: local.send,
        targetDisconnected: () => local.sendDisconnected,
        dropWhenFull: dropWhenFull,
      );
    } finally {
      if (closeSourceOnDone && this is Closeable) {
        (this as Closeable).close();
      }
      if (closeTargetOnDone && target is Closeable) {
        (target as Closeable).close();
      }
    }
  }
}

/// Forward values to this [Sender] from another [Receiver].
extension SenderForward<T> on Sender<T> {
  /// Pulls from [source] and forwards every value into this sender.
  Future<void> pipeFrom(
    Receiver<T> source, {
    bool dropWhenFull = false,
    bool closeTargetOnDone = false,
    bool closeSourceOnDone = false,
  }) {
    return source.pipeTo(
      this,
      dropWhenFull: dropWhenFull,
      closeTargetOnDone: closeTargetOnDone,
      closeSourceOnDone: closeSourceOnDone,
    );
  }
}

/// Bridge between channels and Dart's Stream ecosystem.
extension StreamReceiverX<T> on KeepAliveReceiver<T> {
  /// Convert a channel receiver to a broadcast stream for multiple listeners.
  Stream<T> broadcastStream({
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
          if (closeReceiverOnDone && !recvDisconnected) close();
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

  Stream<R> mapBroadcast<R>(R Function(T) f) => broadcastStream().map(f);
}

/// Bridge from Dart Streams to channel senders.
extension SenderStreamX<T> on Stream<T> {
  /// Redirect all stream data into a channel sender.
  Future<void> pipeTo(
    KeepAliveSender<T> tx, {
    bool dropWhenFull = false,
    bool closeSenderOnDone = true,
  }) async {
    try {
      await for (final v in this) {
        final r = tx.trySend(v);
        if (r.hasSend) continue;
        if (r.isDisconnected) break;
        if (dropWhenFull) continue;

        final r1 = await tx.send(v);
        if (r1.isDisconnected) break;
      }
    } finally {
      if (closeSenderOnDone && !tx.sendDisconnected) {
        tx.close();
      }
    }
  }
}

/// Bulk receiving operations for [Receiver].
///
/// Efficiently drain multiple values from channels with different strategies
/// for handling timeouts and limits. Essential for batch processing.
///
/// **Usage:**
/// ```dart
/// import 'package:cross_channel/cross_channel.dart';
///
/// Future<void> main() async {
///   final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
///   final items = ['batch 1', 'batch 2', 'batch 3'];
///
///   // 1. Batch sending
///   await tx.sendAll(items);
///   await tx.trySendAll(['fast 1', 'fast 2']);
///
///   // 2. Batch receiving (with 100ms idle timeout)
///   final batch = await rx.recvAll(
///     idle: const Duration(milliseconds: 100),
///     max: 10,
///   );
///   print('Received batch: $batch');
///
///   // 3. Immediate drain
///   final available = rx.tryRecvAll(max: 5);
///   print('Immediately available: $available');
/// }
/// ```
extension ReceiverDrainX<T> on Receiver<T> {
  /// Drain all immediately available values without waiting.
  ///
  /// Uses [tryRecv] internally, so it never blocks. Perfect for burst
  /// processing when you want to consume everything that's ready.
  ///
  /// **Parameters:**
  /// - [max]: Maximum number of items to receive (default: unlimited)
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
  ///   final items = ['batch 1', 'batch 2', 'batch 3'];
  ///
  ///   // 1. Batch sending
  ///   await tx.sendAll(items);
  ///   await tx.trySendAll(['fast 1', 'fast 2']);
  ///
  ///   // 2. Batch receiving (with 100ms idle timeout)
  ///   final batch = await rx.recvAll(
  ///     idle: const Duration(milliseconds: 100),
  ///     max: 10,
  ///   );
  ///   print('Received batch: $batch');
  ///
  ///   // 3. Immediate drain
  ///   final available = rx.tryRecvAll(max: 5);
  ///   print('Immediately available: $available');
  /// }
  /// ```
  Iterable<T> tryRecvAll({int? max}) {
    final out = <T>[];
    final limit = max ?? 0x7fffffff;
    while (out.length < limit) {
      final r = tryRecv();
      if (r is RecvOk<T>) {
        out.add(r.value);
      } else {
        break;
      }
    }
    return out;
  }

  /// Receive multiple values with batching and idle timeout.
  ///
  /// First drains immediately available values, then waits up to [idle]
  /// duration for additional values. Perfect for efficient batch processing.
  ///
  /// **Parameters:**
  /// - [idle]: Maximum time to wait for additional values after receiving one
  /// - [max]: Maximum number of items to receive (default: unlimited)
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
  ///   final items = ['batch 1', 'batch 2', 'batch 3'];
  ///
  ///   // 1. Batch sending
  ///   await tx.sendAll(items);
  ///   await tx.trySendAll(['fast 1', 'fast 2']);
  ///
  ///   // 2. Batch receiving (with 100ms idle timeout)
  ///   final batch = await rx.recvAll(
  ///     idle: const Duration(milliseconds: 100),
  ///     max: 10,
  ///   );
  ///   print('Received batch: $batch');
  ///
  ///   // 3. Immediate drain
  ///   final available = rx.tryRecvAll(max: 5);
  ///   print('Immediately available: $available');
  /// }
  /// ```
  Future<Iterable<T>> recvAll({Duration idle = Duration.zero, int? max}) async {
    final out = <T>[];
    final limit = max ?? 0x7fffffff;

    out.addAll(tryRecvAll(max: limit));
    if (out.length >= limit || idle == Duration.zero) return out;

    while (out.length < limit) {
      final next = await recvTimeout(idle);

      if (next is RecvOk<T>) {
        out.add(next.value);
        if (out.length < limit) {
          final remaining = limit - out.length;
          final burst = tryRecvAll(max: remaining);
          if (burst.isNotEmpty) out.addAll(burst);
        }
      } else {
        break;
      }
    }
    return out;
  }
}

/// Rate-limiting operations for [Sender].
extension SenderRateLimitX<T> on Sender<T> {
  /// Returns a sender that limits the rate of events to at most one every [duration].
  ///
  /// Events sent during the "cooldown" period are **dropped**.
  /// The first event is sent immediately, then the cooldown starts.
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (tx, rx) = XChannel.mpsc<String>();
  ///
  ///   // 1. Throttle (max 1 event per 100ms)
  ///   final throttledTx = tx.throttle(const Duration(milliseconds: 100));
  ///   await throttledTx.send('event 1'); // Sent
  ///   await throttledTx.send('event 2'); // Dropped (too soon)
  ///
  ///   // 2. Debounce (wait 500ms of silence)
  ///   final debouncedTx = tx.debounce(const Duration(milliseconds: 500));
  ///   await debouncedTx.send('search 1'); // Scheduled
  ///   await debouncedTx.send('search 2'); // search 1 cancelled, search 2 scheduled
  /// }
  /// ```
  Sender<T> throttle(Duration duration) {
    return _ThrottleSender(this, duration, metricsId: metricsId);
  }

  /// Returns a sender that delays events until [duration] has passed since the last event.
  ///
  /// Useful for search inputs or bursty events where only the final resting state matters.
  /// unique per [send] call.
  ///
  /// **Usage:**
  /// ```dart
  /// import 'package:cross_channel/cross_channel.dart';
  ///
  /// Future<void> main() async {
  ///   final (tx, rx) = XChannel.mpsc<String>();
  ///
  ///   // 1. Throttle (max 1 event per 100ms)
  ///   final throttledTx = tx.throttle(const Duration(milliseconds: 100));
  ///   await throttledTx.send('event 1'); // Sent
  ///   await throttledTx.send('event 2'); // Dropped (too soon)
  ///
  ///   // 2. Debounce (wait 500ms of silence)
  ///   final debouncedTx = tx.debounce(const Duration(milliseconds: 500));
  ///   await debouncedTx.send('search 1'); // Scheduled
  ///   await debouncedTx.send('search 2'); // search 1 cancelled, search 2 scheduled
  /// }
  /// ```
  Sender<T> debounce(Duration duration) {
    return _DebounceSender(this, duration, metricsId: metricsId);
  }
}

final class _ThrottleSender<T> extends Sender<T> implements Closeable {
  _ThrottleSender(this._inner, this._duration, {this.metricsId});

  final Sender<T> _inner;
  final Duration _duration;
  @override
  final String? metricsId;

  int _lastSend = 0;

  @override
  int get channelId => _inner.channelId;

  @override
  PlatformPort get remotePort => _inner.remotePort;

  @override
  bool get isSendClosed => _inner.isSendClosed;

  @override
  Future<SendResult> send(T value) {
    if (_inner.isSendClosed) return Future.value(const SendErrorDisconnected());

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSend >= _duration.inMilliseconds) {
      _lastSend = now;
      return _inner.send(value);
    }
    // Dropped
    mx.markDropOldest();
    return Future.value(const SendOk());
  }

  @override
  SendResult trySend(T value) {
    if (_inner.isSendClosed) return const SendErrorDisconnected();

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSend >= _duration.inMilliseconds) {
      _lastSend = now;
      return _inner.trySend(value);
    }
    mx.markDropOldest();
    return const SendOk();
  }

  @override
  void close() {
    if (_inner is Closeable) (_inner as Closeable).close();
  }
}

final class _DebounceSender<T> extends Sender<T> implements Closeable {
  _DebounceSender(this._inner, this._duration, {this.metricsId});

  final Sender<T> _inner;
  final Duration _duration;
  @override
  final String? metricsId;

  Timer? _timer;

  @override
  int get channelId => _inner.channelId;

  @override
  PlatformPort get remotePort => _inner.remotePort;

  @override
  bool get isSendClosed => _inner.isSendClosed;

  @override
  Future<SendResult> send(T value) {
    if (_inner.isSendClosed) return Future.value(const SendErrorDisconnected());

    if (_timer != null) {
      mx.markDropOldest();
      _timer!.cancel();
    }
    _timer = Timer(_duration, () {
      _timer = null;
      // Best-effort send.
      _inner.send(value);
    });

    return Future.value(const SendOk());
  }

  @override
  SendResult trySend(T value) {
    if (_inner.isSendClosed) return const SendErrorDisconnected();
    // Debounce implies waiting, so trySend (sync) acts same as send (schedule timer).
    if (_timer != null) {
      mx.markDropOldest();
      _timer!.cancel();
    }
    _timer = Timer(_duration, () {
      _timer = null;
      _inner.send(value);
    });
    return const SendOk();
  }

  @override
  void close() {
    _timer?.cancel();
    if (_inner is Closeable) (_inner as Closeable).close();
  }
}
