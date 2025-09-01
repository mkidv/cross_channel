import 'dart:async';
import 'dart:isolate';

import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/mpmc.dart';

/// Isolate adapters: request/reply and channel bridging.
///
extension SendPortRequestX on SendPort {
  @pragma('vm:prefer-inline')
  void sendCmd(String command, {Map<String, Object?>? data}) {
    final payload = <String, Object?>{...?data, 'command': command};
    send(payload);
  }

  /// Sends a typed request with a dedicated reply port
  /// Awaits a single reply, throwing on timeout or error payload.
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

extension ReceivePortToChannelX on ReceivePort {
  /// Convert port messages to channel.
  /// When `strict == true`, the port is closed on unexpected message types.
  ///
  (MpscSender<T>, MpscReceiver<T>) toMpsc<T>({
    int capacity = 512,
    bool strict = true,
  }) {
    final (tx, rx) = Mpsc.bounded<T>(capacity);
    listen((msg) {
      if (msg is T) {
        final r = tx.trySend(msg);
        if (r.disconnected) close();
      } else if (strict) {
        close();
      }
    });
    return (tx, rx);
  }

  /// Convert port messages to channel.
  /// When `strict == true`, the port is closed on unexpected message types.
  ///
  (MpmcSender<T>, MpmcReceiver<T>) toMpmc<T>({
    int capacity = 512,
    bool strict = true,
  }) {
    final (tx, rx) = Mpmc.bounded<T>(capacity);
    listen((msg) {
      if (msg is T) {
        final r = tx.trySend(msg);
        if (r.disconnected) close();
      } else if (strict) {
        close();
      }
    });
    return (tx, rx);
  }
}
