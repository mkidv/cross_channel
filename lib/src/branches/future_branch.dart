part of '../branches.dart';

/// SelectBranch implementation for racing Future operations.
///
/// Handles Future resolution/rejection with cancellation support to prevent
/// late callbacks from executing after the race is decided.
class FutureBranch<T, R> implements SelectBranch<R> {
  const FutureBranch(this.future, this.body, {this.tag});

  final Future<T> future;
  final FutureOr<R> Function(T) body;
  final Object? tag;

  @override
  bool attachSync({
    required int index,
    required Resolve<R> resolve,
  }) =>
      false;

  @override
  void attach({
    required int index,
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
  }) {
    var canceled = false;
    void cancel() => canceled = true;
    registerCanceller(cancel);

    future.then((u) {
      if (canceled) return;
      try {
        resolve(index, tag, body(u));
      } catch (e, st) {
        Zone.current.handleUncaughtError(e, st);
      }
    }, onError: (Object e, StackTrace? st) {
      if (canceled) return;
      resolve(index, tag, Future<R>.error(e, st));
    });
  }
}
