part of '../branches.dart';

/// SelectBranch implementation for racing Stream operations.
///
/// Listens to the first event from a stream and properly cancels the
/// subscription when the branch loses the race.
class StreamBranch<T, R> implements SelectBranch<R> {
  const StreamBranch(this.stream, this.body, {this.tag});

  final Stream<T> stream;
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
    StreamSubscription<T>? sub;

    void cancel() {
      canceled = true;
      sub?.cancel();
      sub = null;
    }

    registerCanceller(cancel);
    sub = stream.listen((u) {
      if (canceled) return;
      resolve(index, tag, body(u));
    }, onError: (Object e, StackTrace? st) {
      if (canceled) return;
      resolve(index, tag, Future<R>.error(e, st));
    }, onDone: () {
      cancel();
    }, cancelOnError: false);
  }
}
