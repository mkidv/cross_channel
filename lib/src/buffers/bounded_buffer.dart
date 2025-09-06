part of '../buffers.dart';

/// Bounded FIFO queue
/// producers block/wait for permits when full
///
final class BoundedBuffer<T> implements ChannelBuffer<T> {
  BoundedBuffer({required this.capacity}) : assert(capacity > 0);

  final int capacity;
  final ListQueue<T> _q = ListQueue<T>();

  final _pushWaiters = ListQueue<Completer<void>>();
  final _popWaiters = ListQueue<Completer<T>>();
  Completer<T>? _fastWaiter;

  int _permits = 0;

  @pragma('vm:prefer-inline')
  @override
  bool get isEmpty => _q.isEmpty;

  @pragma('vm:prefer-inline')
  bool get _isFull => _q.length == capacity;

  @pragma('vm:prefer-inline')
  int get _free => capacity - _q.length - _permits;

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
    if (_isFull) return false;
    _q.addLast(v);
    return true;
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (isEmpty) return null;
    final v = _q.removeFirst();
    if (_pushWaiters.isNotEmpty) {
      while (_free > 0 && _pushWaiters.isNotEmpty) {
        _pushWaiters.removeFirst().complete();
        _permits++;
      }
    }

    return v;
  }

  @override
  Future<void> waitNotFull() async {
    if (_pushWaiters.isEmpty && _free > 0) {
      _permits++;
      return;
    }
    final c = Completer<void>();
    _pushWaiters.addLast(c);
    await c.future;
  }

  @override
  void consumePushPermit() {
    if (_permits > 0) _permits--;
  }

  @pragma('vm:prefer-inline')
  @override
  Completer<T> addPopWaiter() {
    final c = Completer<T>();

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

    if (_pushWaiters.isNotEmpty) {
      if (_free > 0) {
        _pushWaiters.removeFirst().complete();
        _permits++;
      }
    }
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
  void wakeAllPushWaiters() {
    while (_pushWaiters.isNotEmpty) {
      _pushWaiters.removeFirst().complete();
    }
  }

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
    _permits = 0;
  }
}
