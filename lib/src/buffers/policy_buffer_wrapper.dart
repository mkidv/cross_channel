part of '../buffers.dart';

enum DropPolicy { block, oldest, newest }

typedef OnDrop<T> = void Function(T dropped);

/// Policy wrapper that applies a drop strategy when the inner buffer is full.
/// See `DropPolicy` docs for exact semantics (notably `newest`).
///
final class PolicyBufferWrapper<T> implements ChannelBuffer<T> {
  PolicyBufferWrapper(this._inner, {required this.policy, this.onDrop});

  final ChannelBuffer<T> _inner;
  final DropPolicy policy;
  final OnDrop<T>? onDrop;

  @override
  bool get isEmpty => _inner.isEmpty;

  @override
  T? tryPop() => _inner.tryPop();

  @override
  Future<void> waitNotFull() => _inner.waitNotFull();

  @override
  void consumePushPermit() => _inner.consumePushPermit();

  @override
  Completer<T> addPopWaiter() => _inner.addPopWaiter();

  @override
  bool removePopWaiter(Completer<T> c) => _inner.removePopWaiter(c);

  @override
  void wakeAllPushWaiters() => _inner.wakeAllPushWaiters();

  @override
  void failAllPopWaiters(Object e) => _inner.failAllPopWaiters(e);

  @override
  void clear() => _inner.clear();

  @pragma('vm:prefer-inline')
  @override
  bool tryPush(T v) {
    final r = _inner.tryPush(v);
    if (r) return r;

    switch (policy) {
      case DropPolicy.block:
        return r;
      case DropPolicy.newest:
        try {
          onDrop?.call(v);
        } catch (_) {}
        return true;
      case DropPolicy.oldest:
        final dropped = _inner.tryPop();
        if (dropped != null) {
          try {
            onDrop?.call(dropped);
          } catch (_) {}
        }
        final r2 = _inner.tryPush(v);
        return r2 ? r2 : r;
    }
  }
}
