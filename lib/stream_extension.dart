import 'dart:async';

import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

/// Bridge between channels and Dart's Stream ecosystem.
///
/// Essential for integrating channels with Flutter widgets, existing
/// stream-based APIs, and reactive programming patterns. Converts between
/// single-subscription channel streams and multi-listener broadcast streams.
extension StreamReceiverX<T> on KeepAliveReceiver<T> {
  /// Convert a channel receiver to a broadcast stream for multiple listeners.
  ///
  /// Perfect for integrating channels with Flutter widgets that expect
  /// broadcast streams, or when multiple components need to listen to
  /// the same channel data.
  ///
  /// **Parameters:**
  /// - [waitForListeners]: If `true`, doesn't start consuming until first listener
  /// - [stopWhenNoListeners]: If `true`, pauses consumption when no listeners
  /// - [closeReceiverOnDone]: If `true`, closes the receiver when stream ends
  /// - [sync]: If `true`, events are delivered synchronously
  ///
  /// **Flutter Integration:**
  /// ```dart
  /// // Progress updates in multiple widgets
  /// final (tx, rx) = XChannel.mpscLatest<double>();
  /// final broadcast = rx.toBroadcastStream();
  ///
  /// // Multiple StreamBuilders can listen
  /// StreamBuilder<double>(
  ///   stream: broadcast,
  ///   builder: (context, snap) => ProgressIndicator(value: snap.data),
  /// )
  ///
  /// StreamBuilder<double>(
  ///   stream: broadcast,
  ///   builder: (context, snap) => Text('Progress: ${(snap.data ?? 0) * 100}%'),
  /// )
  /// ```
  ///
  /// **Reactive Programming:**
  /// ```dart
  /// // Event processing with multiple subscribers
  /// final (tx, rx) = XChannel.mpsc<UserEvent>();
  /// final broadcast = rx.toBroadcastStream();
  ///
  /// // Analytics subscriber
  /// broadcast.listen((event) => analytics.track(event));
  ///
  /// // UI updates subscriber
  /// broadcast.listen((event) => updateUI(event));
  ///
  /// // Logging subscriber
  /// broadcast.listen((event) => logger.info('Event: $event'));
  /// ```
  ///
  /// **Resource Management:**
  /// ```dart
  /// // Efficient resource usage - pause when no listeners
  /// final broadcast = rx.toBroadcastStream(
  ///   waitForListeners: true,    // Don't start until needed
  ///   stopWhenNoListeners: true, // Pause when unused
  /// );
  /// ```
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
          if (closeReceiverOnDone && !isDisconnected) close();
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

/// Bridge from Dart Streams to channel senders.
///
/// Convert any Dart Stream into channel data, perfect for integrating
/// existing stream-based APIs with channel processing pipelines.
extension SenderStreamX<T> on Stream<T> {
  /// Redirect all stream data into a channel sender.
  ///
  /// Efficiently pipes stream data into channels with configurable backpressure
  /// handling. Essential for integrating HTTP responses, file streams, or any
  /// existing Stream-based API with channel processing.
  ///
  /// **Parameters:**
  /// - [tx]: The channel sender to receive stream data
  /// - [dropWhenFull]: If `true`, drop items when channel is full (for bounded channels)
  /// - [closeSenderOnDone]: If `true`, close sender when stream completes
  ///
  /// **HTTP Integration:**
  /// ```dart
  /// // Stream HTTP responses into channel processing
  /// final (tx, rx) = XChannel.mpsc<HttpResponse>(capacity: 100);
  ///
  /// // Redirect HTTP stream to channel
  /// final responseStream = httpClient.get(url).asStream();
  /// await responseStream.redirectToSender(tx);
  ///
  /// // Process responses in channel consumer
  /// await for (final response in rx.stream()) {
  ///   final data = await response.readAsString();
  ///   await processData(data);
  /// }
  /// ```
  ///
  /// **File Processing:**
  /// ```dart
  /// // Stream file lines into batch processor
  /// final (tx, rx) = XChannel.mpsc<String>(capacity: 1000);
  ///
  /// final fileStream = File('large_file.txt')
  ///   .openRead()
  ///   .transform(utf8.decoder)
  ///   .transform(LineSplitter());
  ///
  /// // Redirect file lines to channel
  /// await fileStream.redirectToSender(tx);
  ///
  /// // Batch process lines
  /// final batch = await rx.recvAll(max: 100);
  /// await processBatch(batch.toList());
  /// ```
  ///
  /// **Backpressure Strategies:**
  /// ```dart
  /// // Strategy 1: Wait for space (reliable)
  /// await stream.redirectToSender(tx, dropWhenFull: false);
  ///
  /// // Strategy 2: Drop on full (high throughput)
  /// await stream.redirectToSender(tx, dropWhenFull: true);
  /// ```
  ///
  Future<void> redirectToSender(
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
      if (closeSenderOnDone && !tx.isDisconnected) {
        tx.close();
      }
    }
  }
}
