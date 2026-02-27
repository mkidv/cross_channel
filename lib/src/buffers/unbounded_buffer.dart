part of '../buffers.dart';

/// Unbounded FIFO queue
/// producers never block
final class UnboundedBuffer<T> implements ChannelBuffer<T> {
  UnboundedBuffer();

  final _q = ListQueue<T>();
  final _waiters = PopWaiterQueue<T>();

  @pragma('vm:prefer-inline')
  @override
  bool get isEmpty => _q.isEmpty;

  @pragma('vm:prefer-inline')
  @override
  bool tryPush(T v) {
    // Fast path: complete waiting receiver directly
    if (isEmpty && _waiters.completeOne(v)) {
      return true;
    }
    _q.addLast(v);
    _waiters.wakeNotEmptyWaiters();
    return true;
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (isEmpty) return null;
    return _q.removeFirst();
  }

  @override
  List<T> tryPopMany(int max) {
    if (isEmpty) return const [];
    final count = max < _q.length ? max : _q.length;
    return List<T>.generate(count, (_) => _q.removeFirst(), growable: false);
  }

  @override
  Future<void> waitNotEmpty() async {
    if (!isEmpty) return;
    await _waiters.addNotEmptyWaiter().future;
  }

  @override
  Future<void> waitNotFull() async {}

  @override
  void consumePushPermit() {}

  @pragma('vm:prefer-inline')
  @override
  Completer<T> addPopWaiter() => _waiters.add(tryPop, () => isEmpty);

  @pragma('vm:prefer-inline')
  @override
  bool removePopWaiter(Completer<T> c) => _waiters.remove(c);

  @override
  void wakeAllPushWaiters() {}

  @override
  void failAllPopWaiters(Object e) => _waiters.failAll(e);

  @override
  void clear() {
    _q.clear();
    _waiters.clear();
  }
}
