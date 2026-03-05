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
/// {@tool snippet example/send_timeout_example.dart}
/// {@end-tool}
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
  /// {@tool snippet example/send_timeout_example.dart}
  /// {@end-tool}
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
/// {@tool snippet example/recv_timeout_example.dart}
/// {@end-tool}
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
  /// {@tool snippet example/recv_timeout_example.dart}
  /// {@end-tool}
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
/// {@tool snippet example/batch_example.dart}
/// {@end-tool}
extension SenderBatchX<T> on Sender<T> {
  /// Send all items using [trySend] without waiting (best-effort).
  ///
  /// If the channel becomes full, items are silently dropped. Use this when
  /// you want maximum throughput and can tolerate data loss.
  ///
  /// **Usage:**
  /// {@tool snippet example/batch_example.dart}
  /// {@end-tool}
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
  /// {@tool snippet example/batch_example.dart}
  /// {@end-tool}
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

/// Bulk receiving operations for [Receiver].
///
/// Efficiently drain multiple values from channels with different strategies
/// for handling timeouts and limits. Essential for batch processing.
///
/// **Usage:**
/// {@tool snippet example/batch_example.dart}
/// {@end-tool}
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
  /// {@tool snippet example/batch_example.dart}
  /// {@end-tool}
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
  /// {@tool snippet example/batch_example.dart}
  /// {@end-tool}
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
  /// {@tool snippet example/rate_limit_example.dart}
  /// {@end-tool}
  Sender<T> throttle(Duration duration) {
    return _ThrottleSender(this, duration, metricsId: metricsId);
  }

  /// Returns a sender that delays events until [duration] has passed since the last event.
  ///
  /// Useful for search inputs or bursty events where only the final resting state matters.
  /// unique per [send] call.
  ///
  /// **Usage:**
  /// {@tool snippet example/rate_limit_example.dart}
  /// {@end-tool}
  Sender<T> debounce(Duration duration) {
    return _DebounceSender(this, duration, metricsId: metricsId);
  }
}

final class _ThrottleSender<T> extends Sender<T> implements Closeable {
  final Sender<T> _inner;
  final Duration _duration;
  @override
  final String? metricsId;

  _ThrottleSender(this._inner, this._duration, {this.metricsId});

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
  final Sender<T> _inner;
  final Duration _duration;
  @override
  final String? metricsId;

  _DebounceSender(this._inner, this._duration, {this.metricsId});

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
