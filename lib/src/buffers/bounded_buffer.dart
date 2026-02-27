part of '../buffers.dart';

/// Bounded FIFO queue
/// producers block/wait for permits when full
final class BoundedBuffer<T> implements ChannelBuffer<T> {
  BoundedBuffer({required this.capacity}) : assert(capacity > 0);

  final int capacity;
  final ListQueue<T> _q = ListQueue<T>();
  final _pushWaiters = ListQueue<Completer<void>>();
  final _waiters = PopWaiterQueue<T>();

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
    // Fast path: complete waiting receiver directly
    if (isEmpty && _waiters.completeOne(v)) {
      return true;
    }
    if (_isFull) return false;
    _q.addLast(v);
    _waiters.wakeNotEmptyWaiters();
    return true;
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (isEmpty) return null;
    final v = _q.removeFirst();
    _wakeWaitersIfSpace();
    return v;
  }

  @override
  List<T> tryPopMany(int max) {
    if (isEmpty) return const [];
    final count = max < _q.length ? max : _q.length;
    final out = List<T>.generate(count, (_) => _q.removeFirst(), growable: false);
    _wakeWaitersIfSpace();
    return out;
  }

  @pragma('vm:prefer-inline')
  void _wakeWaitersIfSpace() {
    if (_pushWaiters.isNotEmpty) {
      while (_free > 0 && _pushWaiters.isNotEmpty) {
        _pushWaiters.removeFirst().complete();
        _permits++;
      }
    }
  }

  @override
  Future<void> waitNotEmpty() async {
    if (!isEmpty) return;
    await _waiters.addNotEmptyWaiter().future;
  }

  @override
  Future<void> waitNotFull() async {
    if (_pushWaiters.isEmpty && _free > 0) {
      _permits++;
      return;
    }
    final c = Completer<void>.sync();
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
    final c = _waiters.add(tryPop, () => isEmpty);

    // Wake push waiters if space available
    if (_pushWaiters.isNotEmpty && _free > 0) {
      _pushWaiters.removeFirst().complete();
      _permits++;
    }
    return c;
  }

  @pragma('vm:prefer-inline')
  @override
  bool removePopWaiter(Completer<T> c) => _waiters.remove(c);

  @override
  void wakeAllPushWaiters() {
    while (_pushWaiters.isNotEmpty) {
      _pushWaiters.removeFirst().complete();
    }
  }

  @override
  void failAllPopWaiters(Object e) => _waiters.failAll(e);

  @override
  void clear() {
    _q.clear();
    _permits = 0;
    _waiters.clear();
  }
}
