import 'dart:async';

/// A tiny synchronization primitive to signal tasks without passing data
///
class Notify {
  int _permits = 0;
  int _epoch = 0; // only for debug
  bool _closed = false;

  final List<Completer<void>> _waiters = <Completer<void>>[];

  int get epoch => _epoch;

  bool get isDisconnected => _closed;

  (Future<void>, void Function()) notified() {
    if (_closed) {
      return (Future<void>.error(StateError('Notify.disconnected')), () {});
    }
    if (_permits > 0) {
      _permits--;
      return (Future.value(), () {});
    }
    final c = Completer<void>();
    _waiters.add(c);
    void cancel() {
      if (!c.isCompleted) {
        _waiters.remove(c);
        c.completeError(StateError('Notify.canceled'));
      }
    }

    return (c.future, cancel);
  }

  void notifyOne() {
    if (_closed) return;
    _epoch++;
    for (var i = 0; i < _waiters.length; i++) {
      final c = _waiters.removeAt(0);
      if (!c.isCompleted) {
        c.complete();
        return;
      }
    }
    _permits++;
  }

  void notifyAll() {
    if (_closed) return;
    _epoch++;
    while (_waiters.isNotEmpty) {
      final c = _waiters.removeLast();
      if (!c.isCompleted) c.complete();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    while (_waiters.isNotEmpty) {
      final c = _waiters.removeLast();
      if (!c.isCompleted) {
        c.completeError(StateError('Notify.disconnected'));
      }
    }
  }
}
