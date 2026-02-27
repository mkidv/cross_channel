part of '../buffers.dart';

/// Latest-only buffer: coalesces and exposes only the most recent value.
///
final class LatestOnlyBuffer<T> implements ChannelBuffer<T> {
  LatestOnlyBuffer();

  T? _last;
  bool _has = false;
  final _popWaiters = ListQueue<Completer<T>>();
  final _notEmptyWaiters = ListQueue<Completer<void>>();

  @pragma('vm:prefer-inline')
  @override
  bool get isEmpty => !_has;

  @pragma('vm:prefer-inline')
  @override
  bool tryPush(T v) {
    if (_popWaiters.isNotEmpty) {
      _popWaiters.removeFirst().complete(v);
      return true;
    }
    _last = v;
    _has = true;
    while (_notEmptyWaiters.isNotEmpty) {
      _notEmptyWaiters.removeFirst().complete();
    }
    return true;
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (isEmpty) return null;
    final v = _last as T;
    _last = null;
    _has = false;
    return v;
  }

  @override
  List<T> tryPopMany(int max) {
    final v = tryPop();
    return v == null ? const [] : [v];
  }

  @override
  Future<void> waitNotEmpty() async {
    if (!isEmpty) return;
    final c = Completer<void>.sync();
    _notEmptyWaiters.addLast(c);
    await c.future;
  }

  @override
  Future<void> waitNotFull() async {}

  @override
  void consumePushPermit() {}

  @pragma('vm:prefer-inline')
  @override
  Completer<T> addPopWaiter() {
    final c = Completer<T>.sync();

    final v = tryPop();
    if (v != null) {
      c.complete(v);
      return c;
    }

    _popWaiters.addLast(c);
    return c;
  }

  @pragma('vm:prefer-inline')
  @override
  bool removePopWaiter(Completer<T> c) => _popWaiters.remove(c);

  @override
  void wakeAllPushWaiters() {}

  @override
  void failAllPopWaiters(Object e) {
    while (_popWaiters.isNotEmpty) {
      _popWaiters.removeFirst().completeError(e);
    }
    while (_notEmptyWaiters.isNotEmpty) {
      _notEmptyWaiters.removeFirst().completeError(e);
    }
  }

  @override
  void clear() {
    _last = null;
    _has = false;
    while (_notEmptyWaiters.isNotEmpty) {
      _notEmptyWaiters
          .removeFirst()
          .completeError(StateError('Buffer cleared'));
    }
  }
}
