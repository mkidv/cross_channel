part of '../buffers.dart';

/// Encapsulates the pop waiter queue logic shared across buffer implementations.
///
/// Uses a fast-path single waiter (`_fastWaiter`) for the common case,
/// falling back to a queue for multiple concurrent waiters.
final class PopWaiterQueue<T> {
  final ListQueue<Completer<T>> _popWaiters = ListQueue();
  final ListQueue<Completer<void>> _notEmptyWaiters = ListQueue();
  Completer<T>? _fastWaiter;

  bool get hasWaiters => _fastWaiter != null || _popWaiters.isNotEmpty;

  /// Adds a waiter. If [tryPop] returns a value, completes immediately.
  /// Otherwise registers the waiter for later completion.
  @pragma('vm:prefer-inline')
  Completer<T> add(T? Function() tryPop, bool Function() isEmpty) {
    final c = Completer<T>.sync();

    final v = tryPop();
    if (v != null) {
      c.complete(v);
      return c;
    }

    if (_fastWaiter == null) {
      _fastWaiter = c;
      // Double-check for race condition
      if (!isEmpty() && identical(_fastWaiter, c)) {
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

  /// Removes a waiter if it hasn't been completed yet.
  @pragma('vm:prefer-inline')
  bool remove(Completer<T> c) {
    if (identical(_fastWaiter, c)) {
      _fastWaiter = null;
      return true;
    }
    return _popWaiters.remove(c);
  }

  /// Completes the next waiter with [value]. Returns true if a waiter existed.
  @pragma('vm:prefer-inline')
  bool completeOne(T value) {
    final fw = _fastWaiter;
    if (fw != null) {
      _fastWaiter = null;
      fw.complete(value);
      return true;
    }
    if (_popWaiters.isNotEmpty) {
      _popWaiters.removeFirst().complete(value);
      return true;
    }
    return false;
  }

  /// Fails all waiters with [error].
  void failAll(Object error) {
    final fw = _fastWaiter;
    _fastWaiter = null;
    if (fw != null) fw.completeError(error);

    while (_popWaiters.isNotEmpty) {
      _popWaiters.removeFirst().completeError(error);
    }
    while (_notEmptyWaiters.isNotEmpty) {
      _notEmptyWaiters.removeFirst().completeError(error);
    }
  }

  /// Adds a not-empty waiter.
  @pragma('vm:prefer-inline')
  Completer<void> addNotEmptyWaiter() {
    final c = Completer<void>.sync();
    _notEmptyWaiters.addLast(c);
    return c;
  }

  /// Wakes all not-empty waiters.
  @pragma('vm:prefer-inline')
  void wakeNotEmptyWaiters() {
    while (_notEmptyWaiters.isNotEmpty) {
      _notEmptyWaiters.removeFirst().complete();
    }
  }

  /// Clears all state.
  void clear() {
    _fastWaiter = null;
    while (_notEmptyWaiters.isNotEmpty) {
      _notEmptyWaiters.removeFirst().completeError(StateError('Buffer cleared'));
    }
  }
}
