part of '../buffers.dart';

/// Single Read Single Write Buffer
/// with power-of-two capacity
/// minimal overhead
///
final class SrswBuffer<T> implements ChannelBuffer<T> {
  SrswBuffer(int capacity) : assert(capacity > 0) {
    final alloc = _roundUpToPow2(capacity);
    _buf = List<T?>.filled(alloc, null);
    _mask = alloc - 1;
  }

  late final List<T?> _buf;
  late final int _mask;
  int _head = 0, _tail = 0;

  Completer<void>? _spaceWaiter;
  Completer<T>? _dataWaiter;

  @pragma('vm:prefer-inline')
  @override
  bool get isEmpty => _head == _tail;

  @pragma('vm:prefer-inline')
  bool get _isFull => ((_tail + 1) & _mask) == _head;

  @pragma('vm:prefer-inline')
  @override
  bool tryPush(T v) {
    if (_dataWaiter != null && isEmpty) {
      _dataWaiter!.complete(v);
      _dataWaiter = null;
      return true;
    }
    final nextTail = (_tail + 1) & _mask;
    if (nextTail == _head) return false;
    _buf[_tail] = v;
    _tail = nextTail;
    return true;
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (isEmpty) return null;
    final v = _buf[_head] as T;
    _buf[_head] = null;
    _head = (_head + 1) & _mask;
    if (_spaceWaiter != null && !_isFull) {
      _spaceWaiter!.complete();
      _spaceWaiter = null;
    }
    return v;
  }

  @override
  Future<void> waitNotFull() async {
    if (!_isFull) return;
    final c = Completer<void>();
    _spaceWaiter = c;
    await c.future;
  }

  @override
  void consumePushPermit() {}

  @pragma('vm:prefer-inline')
  @override
  Completer<T> addPopWaiter() {
    final c = Completer<T>();
    final v = tryPop();
    if (v != null) {
      c.complete(v);
      return c;
    }
    _dataWaiter = c;

    if (!isEmpty && identical(_dataWaiter, c)) {
      _dataWaiter = null;
      final v1 = tryPop();
      if (v1 != null) c.complete(v1);
    }

    return c;
  }

  @pragma('vm:prefer-inline')
  @override
  bool removePopWaiter(Completer<T> c) {
    if (identical(_dataWaiter, c)) {
      _dataWaiter = null;
      return true;
    }
    return false;
  }

  @override
  void wakeAllPushWaiters() {
    if (_spaceWaiter != null) {
      _spaceWaiter!.complete();
      _spaceWaiter = null;
    }
  }

  @override
  void failAllPopWaiters(Object e) {
    if (_dataWaiter != null) {
      _dataWaiter!.completeError(e);
      _dataWaiter = null;
    }
  }

  @override
  void clear() {
    while (!isEmpty) {
      _buf[_head] = null;
      _head = (_head + 1) & _mask;
    }
  }

  @pragma('vm:prefer-inline')
  static int _roundUpToPow2(int x) {
    var v = x <= 1 ? 1 : x - 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v |= v >> 32;
    return v + 1;
  }
}
