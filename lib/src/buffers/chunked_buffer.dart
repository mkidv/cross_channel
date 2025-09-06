part of '../buffers.dart';

/// Unbounded "burst-proof" FIFO queue
/// producers never block
/// hot ring + chunked overflow (no per-element alloc, no bulk grow)
///
final class ChunkedBuffer<T> implements ChannelBuffer<T> {
  ChunkedBuffer({
    this.hotCapacityPow2 = 8192,
    this.chunkCapacityPow2 = 4096,
    this.rebalanceBatch = 64,

    /// pow2 (16, 32…)
    this.rebalanceThresholdDiv = 16,

    /// pow2 (2, 4)
    this.minChunkGateDiv = 2,
  })  : assert(hotCapacityPow2 >= 2),
        assert(chunkCapacityPow2 >= 2),
        assert((hotCapacityPow2 & (hotCapacityPow2 - 1)) == 0),
        assert((chunkCapacityPow2 & (chunkCapacityPow2 - 1)) == 0) {
    _ring = List<T?>.filled(hotCapacityPow2, null);
    _ringMask = hotCapacityPow2 - 1;
  }

  final int hotCapacityPow2;
  final int chunkCapacityPow2;
  final int rebalanceBatch;
  final int rebalanceThresholdDiv;
  final int minChunkGateDiv;

  late List<T?> _ring;
  late int _ringMask;
  int _head = 0, _tail = 0;

  // overflow queue
  final ListQueue<_Chunk<T>> _ov = ListQueue<_Chunk<T>>();

  final _popWaiters = ListQueue<Completer<T>>();
  Completer<T>? _fastWaiter;

  factory ChunkedBuffer.forBurst(int burst,
      {int? rebalanceBatch,
      bool halfChunk = false,
      int? rebalanceThresholdDiv,
      int? minChunkGateDiv}) {
    final hot = _roundUpToPow2(burst + 1);
    final chunk = halfChunk ? (hot >> 1) : hot;
    return ChunkedBuffer<T>(
      hotCapacityPow2: hot,
      chunkCapacityPow2: chunk,
      rebalanceBatch: rebalanceBatch ?? 32,
      rebalanceThresholdDiv: rebalanceThresholdDiv ?? 16,
      minChunkGateDiv: minChunkGateDiv ?? 2,
    );
  }

  @pragma('vm:prefer-inline')
  bool get _ringEmpty => _head == _tail;
  @pragma('vm:prefer-inline')
  bool get _ringFull => ((_tail + 1) & _ringMask) == _head;
  @pragma('vm:prefer-inline')
  int _nextRing(int i) => (i + 1) & _ringMask;

  @override
  bool get isEmpty => _ringEmpty && _ov.isEmpty;

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

    if (!_ringFull) {
      _ring[_tail] = v;
      _tail = _nextRing(_tail);
      return true;
    }
    // overflow chunked
    var tailChunk = _ov.isEmpty ? null : _ov.last;
    if (tailChunk == null || tailChunk.isFull) {
      tailChunk = _Chunk<T>(chunkCapacityPow2);
      _ov.addLast(tailChunk);
    }
    tailChunk.push(v);
    return true;
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (!_ringEmpty) {
      final v = _ring[_head] as T;
      _ring[_head] = null;
      _head = _nextRing(_head);
      return v;
    }
    if (_ov.isEmpty) return null;
    final v = _ov.first.pop();
    if (_ov.first.isEmpty) _ov.removeFirst();

    if (rebalanceBatch > 0 && _ov.isNotEmpty) {
      final int fill = (_tail - _head) & _ringMask;
      final int capacity = _ringMask + 1;
      // seuil = capacity / rebalanceThresholdDiv if pow2 == shift.
      final int threshold =
          (rebalanceThresholdDiv & (rebalanceThresholdDiv - 1)) == 0
              ? (capacity >> (rebalanceThresholdDiv.bitLength - 1))
              : (capacity ~/ rebalanceThresholdDiv);
      if (fill <= threshold) {
        // Batch
        final int maxMove = (rebalanceBatch <= 16 && capacity <= 2048)
            ? rebalanceBatch
            : (rebalanceBatch >> 1);
        var moved = 0;
        while (moved < maxMove && !_ringFull && _ov.isNotEmpty) {
          final c = _ov.first;
          // wait size/minChunkGateDiv.
          final int gate = (minChunkGateDiv & (minChunkGateDiv - 1)) == 0
              ? (c.sizePow2 >> (minChunkGateDiv.bitLength - 1))
              : (c.sizePow2 ~/ minChunkGateDiv);
          final approxCount = (c._t - c._h) & c._mask;
          if (approxCount < gate) break;
          final x = c.pop();
          if (x == null) {
            _ov.removeFirst();
            continue;
          }
          _ring[_tail] = x;
          _tail = _nextRing(_tail);
          moved++;
          if (c.isEmpty) _ov.removeFirst();
        }
      }
    }
    return v;
  }

  @override
  Future<void> waitNotFull() async {}
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
    while (!_ringEmpty) {
      _ring[_head] = null;
      _head = _nextRing(_head);
    }
    _head = _tail = 0;
    _ov.clear();
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

final class _Chunk<T> {
  _Chunk(this.sizePow2)
      : _buf = List<T?>.filled(sizePow2, null),
        _mask = sizePow2 - 1;
  final int sizePow2;
  final List<T?> _buf;
  final int _mask;
  int _h = 0, _t = 0;

  @pragma('vm:prefer-inline')
  bool get isEmpty => _h == _t;
  @pragma('vm:prefer-inline')
  bool get isFull => ((_t + 1) & _mask) == _h;

  @pragma('vm:prefer-inline')
  void push(T v) {
    // assume not full
    _buf[_t] = v;
    _t = (_t + 1) & _mask;
  }

  @pragma('vm:prefer-inline')
  T? pop() {
    if (isEmpty) return null;
    final v = _buf[_h] as T;
    _buf[_h] = null;
    _h = (_h + 1) & _mask;
    return v;
  }
}
