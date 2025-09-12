part of '../buffers.dart';

/// Unbounded FIFO queue
/// producers never block
///
final class UnboundedBuffer<T> implements ChannelBuffer<T> {
  UnboundedBuffer();

  final _q = ListQueue<T>();
  final _popWaiters = ListQueue<Completer<T>>();
  Completer<T>? _fastWaiter;

  @pragma('vm:prefer-inline')
  @override
  bool get isEmpty => _q.isEmpty;

  @pragma('vm:prefer-inline')
  @override
  bool tryPush(T v) {
    if (isEmpty) {
      final fw = _fastWaiter;
      if (fw != null) {
        _fastWaiter = null;
        fw.complete(v);
        return true;
      }
      if (_popWaiters.isNotEmpty) {
        _popWaiters.removeFirst().complete(v);
        return true;
      }
    }
    _q.addLast(v);
    return true;
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (isEmpty) return null;
    return _q.removeFirst();
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

    if (_fastWaiter == null) {
      _fastWaiter = c;
      if (!isEmpty && identical(_fastWaiter, c)) {
        _fastWaiter = null;
        final v2 = tryPop();
        if (v2 != null) {
          c.complete(v2);
          return c;
        }
        _fastWaiter = c;
      }
      return c;
    }

    _popWaiters.addLast(c);
    return c;
  }

  @pragma('vm:prefer-inline')
  @override
  bool removePopWaiter(Completer<T> c) {
    if (identical(_fastWaiter, c)) {
      _fastWaiter = null;
      return true;
    }
    return _popWaiters.remove(c);
  }

  @override
  void wakeAllPushWaiters() {}

  @override
  void failAllPopWaiters(Object e) {
    final fw = _fastWaiter;
    _fastWaiter = null;
    if (fw != null) fw.completeError(e);
    while (_popWaiters.isNotEmpty) {
      _popWaiters.removeFirst().completeError(e);
    }
  }

  @override
  void clear() {
    _fastWaiter = null;
    _q.clear();
  }
}
