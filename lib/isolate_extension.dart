import 'dart:async';
import 'dart:isolate';

import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/mpmc.dart';
import 'package:cross_channel/src/channel_type.dart';

/// Type-safe isolate communication with request/reply patterns.
///
/// Essential for CPU-intensive background work, parallel processing,
/// and isolate-based architectures without blocking the main isolate.
/// Provides structured communication with proper error handling.
extension SendPortRequestX on SendPort {
  /// Send a structured command to the isolate.
  ///
  /// Convenience method for sending commands with optional data payload.
  /// The command is automatically added to the data map for structured
  /// processing on the receiving end.
  ///
  /// **Example:**
  /// ```dart
  /// // Send a processing command
  /// workerPort.sendCmd('process_data', data: {
  ///   'input': largeDataset,
  ///   'options': processingOptions,
  /// });
  /// ```
  @pragma('vm:prefer-inline')
  void sendCmd(String command, {Map<String, Object?>? data}) {
    final payload = <String, Object?>{...?data, 'command': command};
    send(payload);
  }

  /// Send a typed request and await the response with timeout protection.
  ///
  /// Perfect for request/reply patterns with background isolates. Creates a
  /// dedicated reply port, sends the request, and waits for exactly one response.
  /// Handles timeouts and error payloads automatically.
  ///
  /// **Parameters:**
  /// - [command]: The command string for the worker to process
  /// - [data]: Optional data payload to include with the request
  /// - [timeout]: Maximum time to wait for a response (default: 3 seconds)
  ///
  /// **Background Processing Example:**
  /// ```dart
  /// // Main isolate - send heavy computation to worker
  /// final result = await workerPort.request<ComputationResult>(
  ///   'compute_statistics',
  ///   data: {
  ///     'dataset': millionRecords,
  ///     'algorithm': 'advanced_analysis'
  ///   },
  ///   timeout: Duration(minutes: 10),
  /// );
  ///
  /// print('Computation complete: ${result.summary}');
  /// ```
  ///
  /// **Image Processing Example:**
  /// ```dart
  /// // Offload image processing to background isolate
  /// final processedImage = await imageWorkerPort.request<Uint8List>(
  ///   'apply_filters',
  ///   data: {
  ///     'image_data': originalImageBytes,
  ///     'filters': ['blur', 'sharpen', 'contrast'],
  ///   },
  /// );
  /// ```
  ///
  /// **Error Handling:**
  /// ```dart
  /// try {
  ///   final result = await workerPort.request<String>('process');
  /// } on TimeoutException {
  ///   print('Worker took too long to respond');
  /// } on StateError catch (e) {
  ///   print('Worker returned error: $e');
  /// }
  /// ```
  ///
  Future<R> request<R>(
    String command, {
    Map<String, Object?>? data,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final completer = Completer<Object?>();
    final reply = RawReceivePort();

    reply.handler = (Object? msg) {
      if (completer.isCompleted) return;
      completer.complete(msg);
    };

    sendCmd(command, data: {...?data, 'reply': reply.sendPort});

    try {
      final obj = await completer.future.timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException(
            'request("$command") timed out after $timeout',
          );
        },
      );

      if (obj is Map && obj['error'] != null) {
        throw StateError('request("$command") failed: ${obj['error']}');
      }

      try {
        return obj as R;
      } on TypeError {
        throw StateError(
          'request("$command") returned incompatible type: ${obj.runtimeType} expected: $R',
        );
      }
    } finally {
      reply.close();
    }
  }
}

/// Bridge isolate ports to structured channel processing.
///
/// Convert raw isolate message passing to type-safe channel operations.
/// Essential for building robust isolate architectures with proper error
/// handling and backpressure management.
extension ReceivePortToChannelX on ReceivePort {
  /// Convert port messages to MPSC channel (legacy method).
  ///
  /// **Deprecated**: Use [toChannel] with `type: ChannelType.mpsc` for new code.
  /// When `strict == true`, the port is closed on unexpected message types.
  ///
  (MpscSender<T>, MpscReceiver<T>) toMpsc<T>({
    int? capacity,
    DropPolicy policy = DropPolicy.block,
    OnDrop<T>? onDrop,
    bool chunked = true,
    bool strict = true,
  }) {
    final (tx, rx) = Mpsc.channel<T>(
      capacity: capacity,
      policy: policy,
      onDrop: onDrop,
      chunked: chunked,
    );
    listen((msg) {
      if (msg is T) {
        final r = tx.trySend(msg);
        if (r.isDisconnected) close();
      } else if (strict) {
        close();
      }
    });
    return (tx, rx);
  }

  /// Convert port messages to MPMC channel (legacy method).
  ///
  /// **Deprecated**: Use [toChannel] with `type: ChannelType.mpmc` for new code.
  /// When `strict == true`, the port is closed on unexpected message types.
  ///
  (MpmcSender<T>, MpmcReceiver<T>) toMpmc<T>({
    int? capacity,
    DropPolicy policy = DropPolicy.block,
    OnDrop<T>? onDrop,
    bool chunked = true,
    bool strict = true,
  }) {
    final (tx, rx) = Mpmc.channel<T>(
      capacity: capacity,
      policy: policy,
      onDrop: onDrop,
      chunked: chunked,
    );
    listen((msg) {
      if (msg is T) {
        final r = tx.trySend(msg);
        if (r.isDisconnected) close();
      } else if (strict) {
        close();
      }
    });
    return (tx, rx);
  }

  /// Convert port messages to a channel with unified API.
  ///
  /// Modern, unified approach that replaces [toMpsc] and [toMpmc].
  /// When `strict == true`, the port is closed on unexpected message types.
  ///
  /// **Parameters:**
  /// - [type]: Channel type (mpsc or mpmc)
  /// - [capacity]: Buffer size (null = unbounded, 0 = rendezvous)
  /// - [policy]: Drop policy for bounded channels
  /// - [onDrop]: Optional callback for dropped items
  /// - [chunked]: Use optimized chunked buffer
  /// - [strict]: Close port on type mismatches
  ///
  /// **Example:**
  /// ```dart
  /// // Worker isolate event processing
  /// final rp = ReceivePort();
  /// final (tx, rx) = rp.toChannel<WorkerCommand>(
  ///   type: ChannelType.mpsc,
  ///   capacity: 1000,
  /// );
  ///
  /// // Structured command processing
  /// await for (final cmd in rx.stream()) {
  ///   switch (cmd.type) {
  ///     case 'process': await handleProcess(cmd);
  ///     case 'shutdown': return;
  ///   }
  /// }
  /// ```
  (dynamic, dynamic) toChannel<T>(
    ChannelType type, {
    int? capacity,
    DropPolicy policy = DropPolicy.block,
    OnDrop<T>? onDrop,
    bool chunked = true,
    bool strict = true,
  }) {
    switch (type) {
      case ChannelType.mpsc:
        return toMpsc<T>(
          capacity: capacity,
          policy: policy,
          onDrop: onDrop,
          chunked: chunked,
          strict: strict,
        );
      case ChannelType.mpmc:
        return toMpmc<T>(
          capacity: capacity,
          policy: policy,
          onDrop: onDrop,
          chunked: chunked,
          strict: strict,
        );
    }
  }
}
