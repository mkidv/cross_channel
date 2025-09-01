import 'dart:async';
import 'dart:collection';

import 'package:cross_channel/src/result.dart';

abstract class ChannelBuffer<T> {
  bool get isEmpty;

  SendResult<T> trySendNow(T value);
  T? tryPop();

  Future<void> waitSendPermit();
  void consumePermitIfAny();
  Completer<T> addRecvWaiter();
  bool removeRecvWaiter(Completer<T> c);

  void wakeAllSenders();
  void failAllReceivers(Object err);
  void clear();
}

/// Unbounded FIFO queue; producers never block.
///
final class UnboundedBuffer<T> implements ChannelBuffer<T> {
  final ListQueue<T> _q = ListQueue<T>();
  final ListQueue<Completer<T>> _recvWaiters = ListQueue<Completer<T>>();

  @override
  bool get isEmpty => _q.isEmpty;

  @pragma('vm:prefer-inline')
  @override
  SendResult<T> trySendNow(T value) {
    if (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(value);
      return SendOk<T>();
    }
    _q.addLast(value);
    return SendOk<T>();
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (_q.isEmpty) return null;
    final v = _q.removeFirst();
    return v;
  }

  @override
  Future<void> waitSendPermit() async {
    return;
  }

  @override
  void consumePermitIfAny() {
    return;
  }

  @override
  Completer<T> addRecvWaiter() {
    final c = Completer<T>();
    _recvWaiters.addLast(c);
    return c;
  }

  @override
  bool removeRecvWaiter(Completer<T> c) => _recvWaiters.remove(c);

  @override
  void wakeAllSenders() {
    return;
  }

  @override
  void failAllReceivers(Object err) {
    while (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().completeError(err);
    }
  }

  @override
  void clear() => _q.clear();
}

/// Bounded FIFO queue; producers block/wait for permits when full.
///
final class BoundedBuffer<T> implements ChannelBuffer<T> {
  BoundedBuffer({required this.capacity}) : assert(capacity > 0);

  final int capacity;
  final ListQueue<T> _q = ListQueue<T>();
  final ListQueue<Completer<void>> _sendWaiters = ListQueue<Completer<void>>();
  final ListQueue<Completer<T>> _recvWaiters = ListQueue<Completer<T>>();
  int _permits = 0;

  @override
  bool get isEmpty => _q.isEmpty;

  @pragma('vm:prefer-inline')
  int get _free => capacity - _q.length - _permits;

  @pragma('vm:prefer-inline')
  @override
  SendResult<T> trySendNow(T value) {
    if (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(value);
      return SendOk<T>();
    }
    if (_q.length < capacity) {
      _q.addLast(value);
      return SendOk<T>();
    }
    return SendErrorFull<T>();
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (_q.isEmpty) return null;
    final v = _q.removeFirst();
    _onSlotFreed();
    return v;
  }

  @override
  Future<void> waitSendPermit() async {
    if (_free > 0) {
      _permits++;
      return;
    }
    final c = Completer<void>();
    _sendWaiters.addLast(c);
    await c.future;
  }

  @pragma('vm:prefer-inline')
  void _onSlotFreed() {
    while (_free > 0 && _sendWaiters.isNotEmpty) {
      _sendWaiters.removeFirst().complete();
      _permits++;
    }
  }

  @override
  void consumePermitIfAny() {
    if (_permits > 0) _permits--;
  }

  @override
  Completer<T> addRecvWaiter() {
    final c = Completer<T>();
    _recvWaiters.addLast(c);

    if (_free > 0 && _sendWaiters.isNotEmpty) {
      _sendWaiters.removeFirst().complete();
      _permits++;
    }
    return c;
  }

  @override
  bool removeRecvWaiter(Completer<T> c) => _recvWaiters.remove(c);

  @override
  void wakeAllSenders() {
    while (_sendWaiters.isNotEmpty) {
      _sendWaiters.removeFirst().complete();
    }
  }

  @override
  void failAllReceivers(Object err) {
    while (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().completeError(err);
    }
  }

  @override
  void clear() {
    _q.clear();
    _permits = 0;
  }
}

/// Rendezvous (capacity=0): send requires a waiting receiver.
///
final class RendezvousBuffer<T> implements ChannelBuffer<T> {
  final ListQueue<Completer<void>> _sendWaiters = ListQueue<Completer<void>>();
  final ListQueue<Completer<T>> _recvWaiters = ListQueue<Completer<T>>();

  @override
  bool get isEmpty => true;

  @pragma('vm:prefer-inline')
  @override
  SendResult<T> trySendNow(T value) {
    if (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(value);
      return SendOk<T>();
    }
    return SendErrorFull<T>();
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() => null;

  @override
  Future<void> waitSendPermit() async {
    final c = Completer<void>();
    _sendWaiters.addLast(c);
    await c.future;
  }

  @override
  void consumePermitIfAny() {}

  @override
  Completer<T> addRecvWaiter() {
    final c = Completer<T>();
    _recvWaiters.addLast(c);
    if (_sendWaiters.isNotEmpty) {
      _sendWaiters.removeFirst().complete();
    }
    return c;
  }

  @override
  bool removeRecvWaiter(Completer<T> c) => _recvWaiters.remove(c);

  @override
  void wakeAllSenders() {
    while (_sendWaiters.isNotEmpty) {
      _sendWaiters.removeFirst().complete();
    }
  }

  @override
  void failAllReceivers(Object err) {
    while (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().completeError(err);
    }
  }

  @override
  void clear() {
    return;
  }
}

/// SPSC ring buffer with power-of-two capacity; minimal overhead.
///
final class SpscRingBuffer<T> implements ChannelBuffer<T> {
  SpscRingBuffer(int capacityPow2)
      : _mask = capacityPow2 - 1,
        _buf = List<T?>.filled(capacityPow2, null) {
    if (capacityPow2 < 2 || (capacityPow2 & (capacityPow2 - 1)) != 0) {
      throw ArgumentError.value(
          capacityPow2, 'capacityPow2', 'Must be a power of two and >= 2');
    }
  }

  final int _mask;
  final List<T?> _buf;
  int _head = 0, _tail = 0;
  final _sendWaiters = ListQueue<Completer<void>>();
  final _recvWaiters = ListQueue<Completer<T>>();

  @override
  bool get isEmpty => _head == _tail;

  @pragma('vm:prefer-inline')
  @override
  SendResult<T> trySendNow(T v) {
    if (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(v);
      return SendOk<T>();
    }
    final nextTail = (_tail + 1) & _mask;
    if (nextTail == _head) return SendErrorFull<T>();
    _buf[_tail] = v;
    _tail = nextTail;
    return SendOk<T>();
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (_head == _tail) return null;
    final v = _buf[_head] as T;
    _buf[_head] = null;
    _head = (_head + 1) & _mask;
    if (_sendWaiters.isNotEmpty) {
      _sendWaiters.removeFirst().complete();
    }
    return v;
  }

  @override
  Future<void> waitSendPermit() async {
    final c = Completer<void>();
    _sendWaiters.addLast(c);
    await c.future;
  }

  @override
  void consumePermitIfAny() {
    return;
  }

  @override
  Completer<T> addRecvWaiter() {
    final c = Completer<T>();
    _recvWaiters.addLast(c);
    if (_sendWaiters.isNotEmpty && _head != ((_tail + 1) & _mask)) {
      _sendWaiters.removeFirst().complete();
    }
    return c;
  }

  @override
  bool removeRecvWaiter(Completer<T> c) => _recvWaiters.remove(c);

  @override
  void wakeAllSenders() {
    while (_sendWaiters.isNotEmpty) {
      _sendWaiters.removeFirst().complete();
    }
  }

  @override
  void failAllReceivers(Object err) {
    while (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().completeError(err);
    }
  }

  @override
  void clear() {
    while (tryPop() != null) {}
  }
}

/// Latest-only buffer: coalesces and exposes only the most recent value.
///
final class LatestOnlyBuffer<T> implements ChannelBuffer<T> {
  LatestOnlyBuffer();

  T? _last;
  bool _has = false;
  final _recvWaiters = ListQueue<Completer<T>>();

  @override
  bool get isEmpty => !_has;

  @pragma('vm:prefer-inline')
  @override
  SendResult<T> trySendNow(T v) {
    if (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().complete(v);
      return SendOk<T>();
    }
    _last = v;
    _has = true;
    return SendOk<T>();
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (!_has) return null;
    _has = false;
    final v = _last as T;
    _last = null;
    return v;
  }

  @override
  Future<void> waitSendPermit() async {
    return;
  }

  @override
  void consumePermitIfAny() {
    return;
  }

  @override
  Completer<T> addRecvWaiter() {
    if (_has) {
      final c = Completer<T>()..complete(_last as T);
      _has = false;
      return c;
    }
    final c = Completer<T>();
    _recvWaiters.addLast(c);
    return c;
  }

  @override
  bool removeRecvWaiter(Completer<T> c) => _recvWaiters.remove(c);

  @override
  void wakeAllSenders() {
    return;
  }

  @override
  void failAllReceivers(Object err) {
    while (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().completeError(err);
    }
  }

  @override
  void clear() {
    _has = false;
    _last = null;
  }
}

/// Promise buffer: stores a single value; can be consumed once or observed by
/// multiple receivers depending on `consumeOnce`.
///
final class PromiseBuffer<T> implements ChannelBuffer<T> {
  PromiseBuffer({this.consumeOnce = false});

  final bool consumeOnce;

  T? _value;
  bool _has = false;
  bool _consumed = false;
  final ListQueue<Completer<T>> _recvWaiters = ListQueue<Completer<T>>();

  @override
  bool get isEmpty => !_has;

  bool get hasConsumed => _consumed;

  @pragma('vm:prefer-inline')
  @override
  SendResult<T> trySendNow(T v) {
    if (_has || _consumed) return SendErrorFull<T>();

    if (_recvWaiters.isNotEmpty) {
      if (consumeOnce) {
        _recvWaiters.removeFirst().complete(v);
        _consumed = true;
        while (_recvWaiters.isNotEmpty) {
          _recvWaiters.removeFirst().completeError(RecvErrorDisconnected<T>());
        }
        return SendOk<T>();
      } else {
        while (_recvWaiters.isNotEmpty) {
          _recvWaiters.removeFirst().complete(v);
        }
      }
    }

    _value = v;
    _has = true;
    return SendOk<T>();
  }

  @pragma('vm:prefer-inline')
  @override
  T? tryPop() {
    if (!_has) return null;
    final v = _value as T;
    if (consumeOnce) {
      _has = false;
      _value = null;
      _consumed = true;
    }
    return v;
  }

  @override
  Future<void> waitSendPermit() async {}

  @override
  void consumePermitIfAny() {}

  @override
  Completer<T> addRecvWaiter() {
    if (consumeOnce && _consumed) {
      final c = Completer<T>()..completeError(RecvErrorDisconnected<T>());
      return c;
    }

    if (_has) {
      final c = Completer<T>()..complete(_value as T);
      if (consumeOnce) {
        _has = false;
        _value = null;
        _consumed = true;
      }
      return c;
    }
    final c = Completer<T>();
    _recvWaiters.addLast(c);
    return c;
  }

  @override
  bool removeRecvWaiter(Completer<T> c) => _recvWaiters.remove(c);

  @override
  void wakeAllSenders() {}

  @override
  void failAllReceivers(Object err) {
    while (_recvWaiters.isNotEmpty) {
      _recvWaiters.removeFirst().completeError(err);
    }
  }

  @override
  void clear() {
    _value = null;
    _has = false;
  }
}

enum DropPolicy { block, oldest, newest }

typedef OnDrop<T> = void Function(T dropped);

/// Policy wrapper that applies a drop strategy when the inner buffer is full.
/// See `DropPolicy` docs for exact semantics (notably `newest`).
///
final class PolicyBuffer<T> implements ChannelBuffer<T> {
  PolicyBuffer(this._inner, {required this.policy, this.onDrop});

  final ChannelBuffer<T> _inner;
  final DropPolicy policy;
  final OnDrop<T>? onDrop;

  @override
  bool get isEmpty => _inner.isEmpty;
  @override
  T? tryPop() => _inner.tryPop();
  @override
  Future<void> waitSendPermit() => _inner.waitSendPermit();
  @override
  void consumePermitIfAny() => _inner.consumePermitIfAny();
  @override
  Completer<T> addRecvWaiter() => _inner.addRecvWaiter();
  @override
  bool removeRecvWaiter(Completer<T> c) => _inner.removeRecvWaiter(c);
  @override
  void wakeAllSenders() => _inner.wakeAllSenders();
  @override
  void failAllReceivers(Object err) => _inner.failAllReceivers(err);
  @override
  void clear() => _inner.clear();

  @pragma('vm:prefer-inline')
  @override
  SendResult<T> trySendNow(T value) {
    final r = _inner.trySendNow(value);
    if (!r.full) return r;

    switch (policy) {
      case DropPolicy.block:
        return r;
      case DropPolicy.newest:
        onDrop?.call(value);
        return SendOk<T>();
      case DropPolicy.oldest:
        final dropped = _inner.tryPop();
        if (dropped != null) onDrop?.call(dropped);
        final r2 = _inner.trySendNow(value);
        return r2.ok ? r2 : r;
    }
  }
}
