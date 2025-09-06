/// Send/receive result types used by channel operations.
///
/// `SendResult<T>`: `SendOk`, `SendErrorFull`, `SendErrorDisconnected`, `SendErrorTimeout`, `SendErrorFailed`.
/// `RecvResult<T>`: `RecvOk`, `RecvErrorEmpty`, `RecvErrorDisconnected`, `RecvErrorTimeout`, `RecvErrorFailed`.
///
/// Extensions provide convenience checks
///
library;

sealed class SendResult {
  const SendResult();
}

final class SendOk extends SendResult {
  const SendOk();
}

sealed class SendError extends SendResult {
  const SendError();
}

final class SendErrorFull extends SendError {
  const SendErrorFull();
}

final class SendErrorDisconnected extends SendError {
  const SendErrorDisconnected();
}

final class SendErrorTimeout extends SendError {
  final Duration limit;
  const SendErrorTimeout(this.limit);
}

final class SendErrorFailed extends SendError {
  final Object cause;
  const SendErrorFailed(this.cause);
}

sealed class RecvResult<T> {
  const RecvResult();
}

final class RecvOk<T> extends RecvResult<T> {
  final T value;
  const RecvOk(this.value);
}

sealed class RecvError extends RecvResult<Never> {
  const RecvError();
}

final class RecvErrorCanceled extends RecvError {
  const RecvErrorCanceled();
}

final class RecvErrorEmpty extends RecvError {
  const RecvErrorEmpty();
}

final class RecvErrorDisconnected extends RecvError {
  const RecvErrorDisconnected();
}

final class RecvErrorTimeout extends RecvError {
  final Duration limit;
  const RecvErrorTimeout(this.limit);
}

final class RecvErrorFailed extends RecvError {
  final Object cause;
  const RecvErrorFailed(this.cause);
}

extension SendResultX<T> on SendResult {
  bool get isFull => this is SendErrorFull;
  bool get isDisconnected => this is SendErrorDisconnected;
  bool get isTimeout => this is SendErrorTimeout;
  bool get isFailed => this is SendErrorFailed;
  bool get hasSend => this is SendOk;
  bool get hasError => isFull || isDisconnected || isTimeout || isFailed;
}

extension RecvResultX<T> on RecvResult<T> {
  bool get isEmpty => this is RecvErrorEmpty;
  bool get isDisconnected => this is RecvErrorDisconnected;
  bool get isTimeout => this is RecvErrorTimeout;
  bool get isFailed => this is RecvErrorFailed;
  bool get hasValue => this is RecvOk<T>;
  bool get hasError => isEmpty || isDisconnected || isTimeout || isFailed;
  T? get valueOrNull => hasValue ? (this as RecvOk<T>).value : null;
}
