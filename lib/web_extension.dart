import 'dart:async';
import 'package:web/web.dart';
import 'dart:js_interop';

import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/mpmc.dart';

/// Web MessagePort adapters: request/reply and channel bridging.
///
extension MessagePortRequestX on MessagePort {
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

  /// Sends a typed request with a dedicated reply port
  /// Awaits a single reply, throwing on timeout or error payload.
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

extension MessagePortToChannelX on MessagePort {
  /// Convert port messages to channel.
  /// When `strict == true`, the port is closed on unexpected message types.
  ///
  (MpscSender<T>, MpscReceiver<T>) toMpsc<T>({
    int capacity = 512,
    bool strict = true,
  }) {
    final (tx, rx) = Mpsc.bounded<T>(capacity);
    onmessage = ((MessageEvent msg) {
      final data = msg.data.dartify();
      if (data is T) {
        final r = tx.trySend(data);
        if (r.disconnected) close();
      } else if (strict) {
        close();
      }
    }).toJS;
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
    onmessage = ((MessageEvent msg) {
      final data = msg.data.dartify();
      if (data is T) {
        final r = tx.trySend(data);
        if (r.disconnected) close();
      } else if (strict) {
        close();
      }
    }).toJS;
    return (tx, rx);
  }
}
