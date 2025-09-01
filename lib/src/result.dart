/// Send/receive result types used by channel operations.
///
/// `SendResult<T>`: `SendOk`, `SendErrorFull`, `SendErrorDisconnected`.
/// `RecvResult<T>`: `RecvOk(value)`, `RecvErrorEmpty`, `RecvErrorDisconnected`.
///
/// Extensions provide convenience checks (`ok`, `full`, `disconnected`) and
/// `RecvX.valueOrNull`.
///
library;

sealed class SendResult<T> {
  const SendResult();
}

final class SendError<T> extends SendResult<T> {
  const SendError();
}

final class SendOk<T> extends SendResult<T> {
  const SendOk();
}

final class SendErrorFull<T> extends SendError<T> {
  const SendErrorFull();
}

final class SendErrorDisconnected<T> extends SendError<T> {
  const SendErrorDisconnected();
}

sealed class RecvResult<T> {
  const RecvResult();
}

final class RecvOk<T> extends RecvResult<T> {
  final T value;
  const RecvOk(this.value);
}

final class RecvError<T> extends RecvResult<T> {
  const RecvError();
}

final class RecvErrorEmpty<T> extends RecvError<T> {
  const RecvErrorEmpty();
}

final class RecvErrorDisconnected<T> extends RecvError<T> {
  const RecvErrorDisconnected();
}

extension SendResultX<T> on SendResult<T> {
  bool get ok => this is SendOk<T>;
  bool get full => this is SendErrorFull<T>;
  bool get disconnected => this is SendErrorDisconnected<T>;
}

extension RecvResultX<T> on RecvResult<T> {
  T? get valueOrNull => ok ? (this as RecvOk<T>).value : null;
  bool get ok => this is RecvOk<T>;
  bool get empty => this is RecvErrorEmpty<T>;
  bool get disconnected => this is RecvErrorDisconnected<T>;
}
