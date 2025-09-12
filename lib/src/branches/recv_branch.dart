part of '../branches.dart';

/// SelectBranch implementation for racing channel receive operations.
///
/// Handles both synchronous (tryRecv) and asynchronous (recvCancelable) 
/// receive operations with proper cancellation support.
class RecvBranch<T, R> implements SelectBranch<R> {
  const RecvBranch(this.rx, this.body, {this.tag});

  final Receiver<T> rx;
  final FutureOr<R> Function(RecvResult<T>) body;
  final Object? tag;

  @override
  bool attachSync({
    required int index,
    required Resolve<R> resolve,
  }) {
    final res = rx.tryRecv();
    if (res.hasValue) {
      resolve(index, tag, body(res));
      return true;
    }
    return false;
  }

  @override
  void attach({
    required int index,
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
  }) {
    final (fut, cancel) = rx.recvCancelable();
    registerCanceller(cancel);
    fut.then((res) {
      if (res is RecvErrorCanceled) return;
      resolve(index, tag, body(res));
    }, onError: (Object e, StackTrace? st) {
      if (e is RecvErrorCanceled) return;
      resolve(index, tag, Future<R>.error(e, st));
    });
  }
}
