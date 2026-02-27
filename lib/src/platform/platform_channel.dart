import 'dart:async';

/// A platform-agnostic handle for sending messages to another context (Isolate or Worker).
///
/// Wraps `SendPort` on VM and `MessagePort` (or equivalent) on Web.
abstract interface class PlatformPort {
  /// Sends an asynchronous message to the remote receiver.
  ///
  /// This is a "fire-and-forget" operation at the transport level.
  void send(Object? message);
}

/// A platform-agnostic receiver for messages from another context.
///
/// Wraps `ReceivePort` on VM and `MessagePort` event stream on Web.
abstract interface class PlatformReceiver {
  /// The port that can be sent to other contexts to send messages back to this receiver.
  PlatformPort get sendPort;

  /// The stream of incoming messages.
  Stream<Object?> get messages;

  /// Closes the receiver and releases resources.
  void close();
}
