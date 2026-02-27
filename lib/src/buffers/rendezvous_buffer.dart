part of '../buffers.dart';

/// Rendezvous (capacity=0): send requires a waiting receiver.
///
final class RendezvousBuffer<T> implements ChannelBuffer<T> {
  RendezvousBuffer();

  final _pushWaiters = ListQueue<Completer<void>>();
  final _popWaiters = ListQueue<Completer<T>>();
  final _notEmptyWaiters = ListQueue<Completer<void>>();

  @pragma('vm:prefer-inline')
  @override
  bool get isEmpty => true;

  @pragma('vm:prefer-inline')
  @override
  bool tryPush(T v) {
    if (_popWaiters.isNotEmpty) {
      _popWaiters.removeFirst().complete(v);
      return true;
    }
    return false;
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() => null;

  @override
  List<T> tryPopMany(int max) => const [];

  @override
  Future<void> waitNotEmpty() async {
    if (_pushWaiters.isNotEmpty) return;
    final c = Completer<void>();
    _notEmptyWaiters.addLast(c);
    await c.future;
  }

  @override
  Future<void> waitNotFull() async {
    if (_popWaiters.isNotEmpty) return;
    final c = Completer<void>();
    _pushWaiters.addLast(c);
    _notifyNotEmpty();
    await c.future;
  }

  void _notifyNotEmpty() {
    while (_notEmptyWaiters.isNotEmpty) {
      _notEmptyWaiters.removeFirst().complete();
    }
  }

  @override
  void consumePushPermit() {}

  @pragma('vm:prefer-inline')
  @override
  Completer<T> addPopWaiter() {
    final c = Completer<T>();

    _popWaiters.addLast(c);

    if (_pushWaiters.isNotEmpty) {
      _pushWaiters.removeFirst().complete();
    }
    return c;
  }

  @pragma('vm:prefer-inline')
  @override
  bool removePopWaiter(Completer<T> c) => _popWaiters.remove(c);

  @override
  void wakeAllPushWaiters() {
    while (_pushWaiters.isNotEmpty) {
      _pushWaiters.removeFirst().complete();
    }
  }

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
    while (_notEmptyWaiters.isNotEmpty) {
      _notEmptyWaiters.removeFirst().completeError(StateError('Buffer cleared'));
    }
  }
}
