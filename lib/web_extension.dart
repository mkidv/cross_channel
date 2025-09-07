import 'dart:async';
import 'package:web/web.dart';
import 'dart:js_interop';

import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/mpmc.dart';
import 'package:cross_channel/src/channel_type.dart';

/// Type-safe Web Worker communication with MessageChannel integration.
///
/// Essential for background processing in web applications using Web Workers
/// while maintaining type safety and structured error handling. Integrates
/// seamlessly with JavaScript's MessageChannel API.
extension MessagePortRequestX on MessagePort {
  /// Send a structured command to the Web Worker.
  ///
  /// Convenience method for sending commands with optional data payload
  /// and transferable objects. Handles JS interop automatically.
  ///
  /// **Parameters:**
  /// - [command]: Command string for the worker to process
  /// - [data]: Optional data payload
  /// - [transfer]: Optional transferable objects (ArrayBuffers, etc.)
  ///
  /// **Example:**
  /// ```dart
  /// // Send image processing command with transfer
  /// final imageBuffer = await loadImageBuffer();
  /// workerPort.sendCmd(
  ///   'process_image',
  ///   data: {'filters': ['blur', 'sharpen']},
  ///   transfer: imageBuffer, // Transfer ownership for performance
  /// );
  /// ```
  void sendCmd(
    String command, {
    Map<String, Object?>? data,
    JSObject? transfer,
  }) {
    final payload = <String, Object?>{...?data, 'command': command};
    if (transfer != null) {
      postMessage(payload.jsify(), transfer);
    } else {
      postMessage(payload.jsify());
    }
  }

  /// Send a typed request to Web Worker and await the response.
  ///
  /// Creates a dedicated MessageChannel for the reply, sends the request,
  /// and waits for exactly one response. Perfect for offloading CPU-intensive
  /// work to Web Workers while maintaining type safety.
  ///
  /// **Parameters:**
  /// - [command]: Command string for the worker
  /// - [data]: Optional data payload
  /// - [timeout]: Maximum wait time (default: 3 seconds)
  ///
  /// **Web Worker Processing:**
  /// ```dart
  /// // Main thread - send heavy computation to worker
  /// final result = await workerPort.request<ProcessingResult>(
  ///   'analyze_data',
  ///   data: {
  ///     'dataset': largeDataset,
  ///     'algorithm': 'machine_learning'
  ///   },
  ///   timeout: Duration(minutes: 5),
  /// );
  /// ```
  ///
  /// **Image Processing:**
  /// ```dart
  /// // Offload image filters to Web Worker
  /// final filteredImage = await imageWorkerPort.request<ImageData>(
  ///   'apply_filters',
  ///   data: {
  ///     'image': originalImage,
  ///     'filters': ['gaussian_blur', 'edge_detection']
  ///   },
  /// );
  /// ```
  ///
  /// **Crypto Operations:**
  /// ```dart
  /// // Secure hashing in Web Worker
  /// final hash = await cryptoWorkerPort.request<String>(
  ///   'compute_hash',
  ///   data: {'algorithm': 'SHA-256', 'data': sensitiveData},
  /// );
  /// ```
  ///
  Future<R> request<R>(
    String command, {
    Map<String, Object?>? data,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final completer = Completer<Object?>();
    final reply = MessageChannel();

    reply.port2.onmessage = ((MessageEvent msg) {
      if (completer.isCompleted) return;
      completer.complete(msg.data?.dartify());
    }).toJS;

    sendCmd(
      command,
      data: {...?data, 'reply': reply.port1},
      transfer: reply.port1,
    );

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
      reply.port1.close();
      reply.port2.close();
    }
  }
}

/// Bridge Web Worker ports to structured channel processing.
///
/// Convert raw MessagePort communication to type-safe channel operations.
/// Essential for building robust Web Worker architectures with proper
/// error handling and message flow control.
extension MessagePortToChannelX on MessagePort {
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
    onmessage = ((MessageEvent msg) {
      final data = msg.data.dartify();
      if (data is T) {
        final r = tx.trySend(data);
        if (r.isDisconnected) close();
      } else if (strict) {
        close();
      }
    }).toJS;
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
    onmessage = ((MessageEvent msg) {
      final data = msg.data.dartify();
      if (data is T) {
        final r = tx.trySend(data);
        if (r.isDisconnected) close();
      } else if (strict) {
        close();
      }
    }).toJS;
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
  /// // Web Worker communication
  /// final worker = Worker('processor.js');
  /// final channel = MessageChannel();
  /// worker.postMessage({'port': channel.port1}, [channel.port1]);
  ///
  /// final (tx, rx) = channel.port2.toChannel<ProcessingTask>(
  ///   type: ChannelType.mpsc,
  ///   capacity: 500,
  /// );
  ///
  /// // Send tasks to worker
  /// await tx.send(ProcessingTask('heavy_computation', data));
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
