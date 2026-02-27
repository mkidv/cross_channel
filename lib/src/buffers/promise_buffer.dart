part of '../buffers.dart';

/// Promise buffer: stores a single value; can be consumed once or observed by
/// multiple receivers depending on `consumeOnce`.
///
final class PromiseBuffer<T> implements ChannelBuffer<T> {
  PromiseBuffer({this.consumeOnce = false});

  final bool consumeOnce;

  T? _value;
  bool _has = false;
  bool _consumed = false;
  final _popWaiters = ListQueue<Completer<T>>();
  final _notEmptyWaiters = ListQueue<Completer<void>>();

  @pragma('vm:prefer-inline')
  @override
  bool get isEmpty => !_has;

  bool get hasConsumed => _consumed;

  @pragma('vm:prefer-inline')
  @override
  bool tryPush(T v) {
    if (!isEmpty || _consumed) return false;

    if (_popWaiters.isNotEmpty) {
      if (consumeOnce) {
        _popWaiters.removeFirst().complete(v);
        _consumed = true;
        while (_popWaiters.isNotEmpty) {
          _popWaiters.removeFirst().completeError(StateError('consumed'));
        }
        return true;
      } else {
        while (_popWaiters.isNotEmpty) {
          _popWaiters.removeFirst().complete(v);
        }
        _value = v;
        _has = true;
        return true;
      }
    }
    _value = v;
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
    final v = _value as T;
    if (consumeOnce) {
      _value = null;
      _has = false;
      _consumed = true;
    }
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
    final c = Completer<T>();

    if (consumeOnce && _consumed) {
      c.completeError(StateError('consumed'));
      return c;
    }

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
    _value = null;
    _has = false;
    _consumed = false;
    while (_notEmptyWaiters.isNotEmpty) {
      _notEmptyWaiters
          .removeFirst()
          .completeError(StateError('Buffer cleared'));
    }
  }
}
