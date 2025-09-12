/// Result types for type-safe channel operations without exceptions.
///
/// All channel operations return explicit result types instead of throwing exceptions.
/// This allows for predictable error handling and better performance.
///
/// ## Send Results
/// - [SendOk]: Operation succeeded
/// - [SendErrorFull]: Channel buffer is full (bounded channels only)
/// - [SendErrorDisconnected]: No receivers available
/// - [SendErrorTimeout]: Operation timed out
/// - [SendErrorFailed]: Operation failed due to an exception
///
/// ## Receive Results
/// - [RecvOk]: Received a value successfully
/// - [RecvErrorEmpty]: No values available (try again later)
/// - [RecvErrorDisconnected]: No senders available
/// - [RecvErrorTimeout]: Operation timed out
/// - [RecvErrorCanceled]: Canceled pending receive (cancelable API)
/// - [RecvErrorFailed]: Operation failed due to an exception
///
/// ## Usage Patterns
///
/// **Pattern Matching:**
/// ```dart
/// final result = await tx.send('data');
/// switch (result) {
///   case SendOk():
///     print('Sent successfully');
///     break;
///   case SendErrorFull():
///     print('Channel full, try again later');
///     break;
///   case SendErrorDisconnected():
///     print('No receivers available');
///     break;
///   case SendError():
///     print('Unexpected error');
///     break;
/// }
/// ```
///
/// **Extension Methods:**
/// ```dart
/// final result = tx.trySend('data');
/// if (result.hasSend) {
///   print('Success!');
/// } else if (result.isFull) {
///   await tx.send('data'); // Wait for space
/// }
/// ```
library;

/// Result of a channel send operation.
///
/// Use pattern matching or extension methods to handle different outcomes:
/// ```dart
/// final result = await sender.send(value);
/// if (result.hasSend) {
///   // Success
/// } else if (result.isFull) {
///   // Channel full, implement backpressure
/// }
/// ```
sealed class SendResult {
  const SendResult();
}

/// Send operation completed successfully.
///
/// The value was accepted by the channel and will be delivered to receivers.
final class SendOk extends SendResult {
  const SendOk();
}

/// Base class for send operation errors.
sealed class SendError extends SendResult {
  const SendError();
}

/// Channel buffer is full and cannot accept more values.
///
/// This only occurs with bounded channels when using [Sender.trySend].
/// Use [Sender.send] to wait for space, or implement backpressure logic.
///
/// **Example:**
/// ```dart
/// final result = tx.trySend(value);
/// if (result is SendErrorFull) {
///   // Option 1: Wait for space
///   await tx.send(value);
///
///   // Option 2: Drop the value
///   print('Channel full, dropping value');
/// }
/// ```
final class SendErrorFull extends SendError {
  const SendErrorFull();
}

/// No active receivers are available to receive the value.
///
/// This occurs when all receivers have been closed or dropped.
/// The send operation is abandoned and the value is not queued.
///
/// **Example:**
/// ```dart
/// final result = await tx.send(value);
/// if (result is SendErrorDisconnected) {
///   print('No receivers available, stopping producer');
///   break; // Exit producer loop
/// }
/// ```
final class SendErrorDisconnected extends SendError {
  const SendErrorDisconnected();
}

/// Send operation timed out.
///
/// This occurs when using [SenderTimeoutX.sendTimeout] and the operation
/// doesn't complete within the specified duration.
///
/// **Example:**
/// ```dart
/// final result = await tx.sendTimeout(value, Duration(seconds: 5));
/// if (result is SendErrorTimeout) {
///   print('Send timed out after ${result.limit}');
/// }
/// ```
final class SendErrorTimeout extends SendError {
  /// The timeout duration that was exceeded.
  final Duration limit;
  const SendErrorTimeout(this.limit);
}

/// Send operation failed due to an unexpected exception.
///
/// This is a rare case that indicates an internal error or resource exhaustion.
/// The [cause] contains the original exception for debugging.
final class SendErrorFailed extends SendError {
  /// The original exception that caused the failure.
  final Object cause;
  const SendErrorFailed(this.cause);
}

/// Result of a channel receive operation.
///
/// Use pattern matching or extension methods to handle different outcomes:
/// ```dart
/// final result = await receiver.recv();
/// if (result.hasValue) {
///   print('Received: ${result.valueOrNull}');
/// } else if (result.isDisconnected) {
///   print('Channel closed');
/// }
/// ```
sealed class RecvResult<T> {
  const RecvResult();
}

/// Successfully received a value from the channel.
///
/// **Example:**
/// ```dart
/// final result = await rx.recv();
/// if (result is RecvOk<String>) {
///   print('Received: ${result.value}');
/// }
/// ```
final class RecvOk<T> extends RecvResult<T> {
  /// The value that was received from the channel.
  final T value;
  const RecvOk(this.value);
}

/// Base class for receive operation errors.
sealed class RecvError extends RecvResult<Never> {
  const RecvError();
}

/// Receive operation was canceled before completion.
///
/// This occurs when using [KeepAliveReceiver.recvCancelable] and the
/// cancel function is called while the operation is pending.
///
/// **Example:**
/// ```dart
/// final (future, cancel) = rx.recvCancelable();
/// // Later...
/// cancel(); // Will cause RecvErrorCanceled
/// ```
final class RecvErrorCanceled extends RecvError {
  const RecvErrorCanceled();
}

/// Channel is empty and no values are available.
///
/// This only occurs with [Receiver.tryRecv]. Use [Receiver.recv] to wait
/// for values, or check again later.
///
/// **Example:**
/// ```dart
/// final result = rx.tryRecv();
/// if (result is RecvErrorEmpty) {
///   print('No values available, try again later');
/// }
/// ```
final class RecvErrorEmpty extends RecvError {
  const RecvErrorEmpty();
}

/// All senders have been closed and no more values will arrive.
///
/// This indicates the end of the stream. No more receive operations
/// will succeed on this channel.
///
/// **Example:**
/// ```dart
/// final result = await rx.recv();
/// if (result is RecvErrorDisconnected) {
///   print('Channel closed, no more data');
///   break; // Exit receive loop
/// }
/// ```
final class RecvErrorDisconnected extends RecvError {
  const RecvErrorDisconnected();
}

/// Receive operation timed out.
///
/// This occurs when using [ReceiverTimeoutX.recvTimeout] and no value
/// arrives within the specified duration.
///
/// **Example:**
/// ```dart
/// final result = await rx.recvTimeout(Duration(seconds: 5));
/// if (result is RecvErrorTimeout) {
///   print('No data received within ${result.limit}');
/// }
/// ```
final class RecvErrorTimeout extends RecvError {
  /// The timeout duration that was exceeded.
  final Duration limit;
  const RecvErrorTimeout(this.limit);
}

/// Receive operation failed due to an unexpected exception.
///
/// This is a rare case that indicates an internal error.
/// The [cause] contains the original exception for debugging.
final class RecvErrorFailed extends RecvError {
  /// The original exception that caused the failure.
  final Object cause;
  const RecvErrorFailed(this.cause);
}

/// Convenient boolean checks for [SendResult].
///
/// Instead of pattern matching, you can use these extension methods
/// for quick boolean checks:
///
/// ```dart
/// final result = tx.trySend(value);
/// if (result.hasSend) {
///   print('Success!');
/// } else if (result.isFull) {
///   await tx.send(value); // Wait for space
/// } else if (result.isDisconnected) {
///   return; // No receivers
/// }
/// ```
extension SendResultX on SendResult {
  /// `true` if the channel buffer was full (bounded channels only).
  bool get isFull => this is SendErrorFull;

  /// `true` if no receivers are available.
  bool get isDisconnected => this is SendErrorDisconnected;

  /// `true` if the operation timed out.
  bool get isTimeout => this is SendErrorTimeout;

  /// `true` if the operation failed due to an exception.
  bool get isFailed => this is SendErrorFailed;

  /// `true` if the send operation succeeded.
  bool get hasSend => this is SendOk;

  /// `true` if any error occurred (convenience for error handling).
  bool get hasError => isFull || isDisconnected || isTimeout || isFailed;
}

/// Convenient boolean checks and value extraction for [RecvResult].
///
/// Instead of pattern matching, you can use these extension methods:
///
/// ```dart
/// final result = await rx.recv();
/// if (result.hasValue) {
///   final value = result.valueOrNull!;
///   print('Received: $value');
/// } else if (result.isDisconnected) {
///   print('Channel closed');
///   break;
/// }
/// ```
extension RecvResultX<T> on RecvResult<T> {
  /// `true` if the channel is empty (no values available right now).
  bool get isEmpty => this is RecvErrorEmpty;

  /// `true` if all senders are closed (end of stream).
  bool get isDisconnected => this is RecvErrorDisconnected;

  /// `true` if the operation timed out.
  bool get isTimeout => this is RecvErrorTimeout;

  /// `true` if the operation failed due to an exception.
  bool get isFailed => this is RecvErrorFailed;

  /// `true` if the pending receive was canceled.
  bool get isCanceled => this is RecvErrorCanceled;

  /// `true` if a value was successfully received.
  bool get hasValue => this is RecvOk<T>;

  /// `true` if any error occurred (convenience for error handling).
  bool get hasError =>
      isEmpty || isDisconnected || isTimeout || isFailed || isCanceled;

  /// Extract the received value, or `null` if no value was received.
  ///
  /// **Example:**
  /// ```dart
  /// final result = rx.tryRecv();
  /// final value = result.valueOrNull;
  /// if (value != null) {
  ///   print('Got: $value');
  /// }
  /// ```
  T? get valueOrNull => hasValue ? (this as RecvOk<T>).value : null;

  /// Extract the received value or throw if not available.
  T get value =>
      hasValue ? (this as RecvOk<T>).value : throw StateError('no value');

  /// Extract the error union as [RecvError], or `null` if success.
  RecvError? get errorOrNull => hasError ? (this as RecvError) : null;

  /// Extract the error union as [RecvError] or throw if success.
  RecvError get error =>
      hasError ? (this as RecvError) : throw StateError('no error');
}
