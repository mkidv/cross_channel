part of '../buffers.dart';

/// Single-Producer Multi-Consumer logical ring buffer.
///
/// Features:
/// - Write cursor (monotonically increasing).
/// - Multiple read cursors (managed via [addSubscriber] / [removeSubscriber]).
/// - Overwrite old data (Ring).
/// - Lag detection for readers.
final class BroadcastRing<T> implements ChannelBuffer<T> {
  BroadcastRing(int capacity) : assert(capacity > 0) {
    final alloc = _roundUpToPow2(capacity);
    _buf = List<T?>.filled(alloc, null);
    _mask = alloc - 1;
    _capacity = alloc;
  }

  late final List<T?> _buf;
  late final int _mask;
  late final int _capacity;

  /// Global write index (monotonically increasing)
  int _writeSeq = 0;

  /// Waiters for new data (one per subscriber that is waiting)
  final _waiters = <_BroadcastCursor<T>, Completer<void>>{};

  bool _closed = false;

  @override
  bool get isEmpty => false;

  @pragma('vm:prefer-inline')
  @override
  bool tryPush(T v) {
    if (_closed) return false;

    final seq = _writeSeq;
    final idx = seq & _mask;
    _buf[idx] = v;
    _writeSeq = seq + 1;

    if (_waiters.isNotEmpty) {
      final list = _waiters.values.toList(growable: false);
      _waiters.clear();
      for (final c in list) {
        c.complete();
      }
    }
    return true;
  }

  /// Register a new cursor.
  /// [replay] items from the past if available.
  Object addSubscriber(int replay) {
    final startSeq = (_writeSeq - replay) < 0 ? 0 : (_writeSeq - replay);
    // Ensure we don't start before the actual tail of the buffer (which is writeSeq - cap)
    final minSeq = _writeSeq - _capacity;
    final actualStart = startSeq < minSeq ? minSeq : startSeq;

    return _BroadcastCursor<T>(actualStart < 0 ? 0 : actualStart);
  }

  void removeSubscriber(Object cursor) {
    if (cursor is _BroadcastCursor<T>) {
      final c = _waiters.remove(cursor);
      c?.complete(); // release
    }
  }

  RecvResult<T> tryReceive(Object cursorHandle) {
    final cursor = cursorHandle as _BroadcastCursor<T>;

    final wSeq = _writeSeq;
    var rSeq = cursor.seq;

    // 1. Check for lag
    if (rSeq < (wSeq - _capacity)) {
      rSeq = wSeq - _capacity;
      cursor.seq = rSeq;
    }

    // 2. Check if empty
    if (rSeq >= wSeq) {
      return _closed ? const RecvErrorDisconnected() : const RecvErrorEmpty();
    }

    // 3. Read
    final v = _buf[rSeq & _mask];
    cursor.seq = rSeq + 1;

    return RecvOk(v as T);
  }

  Future<RecvResult<T>> receive(Object cursorHandle) async {
    final cursor = cursorHandle as _BroadcastCursor<T>;
    while (true) {
      final res = tryReceive(cursor);
      if (res.hasValue || res.isDisconnected) return res;

      if (_closed) return const RecvErrorDisconnected();

      final c = Completer<void>();
      _waiters[cursor] = c;
      await c.future;
    }
  }

  @override
  T? tryPop() => throw UnimplementedError();

  @override
  List<T> tryPopMany(int max) => throw UnimplementedError();

  @override
  Future<void> waitNotEmpty() async => throw UnimplementedError();

  @override
  Future<void> waitNotFull() async {}

  @override
  void consumePushPermit() {}

  @override
  Completer<T> addPopWaiter() => throw UnimplementedError();

  @override
  bool removePopWaiter(Completer<T> c) => false;

  @override
  void wakeAllPushWaiters() {}

  @override
  void failAllPopWaiters(Object e) {
    for (final c in _waiters.values) {
      c.completeError(e);
    }
    _waiters.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_waiters.isNotEmpty) {
      final list = _waiters.values.toList();
      _waiters.clear();
      for (final c in list) {
        c.complete();
      }
    }
  }

  @override
  void clear() {
    for (var i = 0; i < _buf.length; i++) {
      _buf[i] = null;
    }
    _writeSeq = 0;
    close();
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

class _BroadcastCursor<T> {
  int seq;
  _BroadcastCursor(this.seq);
}
