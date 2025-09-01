import 'dart:async';

import 'package:cross_channel/src/buffer.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';
export 'src/buffer.dart' show DropPolicy, OnDrop;

/// MPMC channel: multiple producers, multiple independent consumers.
///
/// Each consumer observes items it pulls; there is no implicit broadcast.
/// Use `Receiver.clone()` to attach additional consumers.
///
final class Mpmc {
  /// Creates an unbounded MPMC channel.
  /// Producers never block; consumer receives in FIFO order.
  ///
  static (MpmcSender<T>, MpmcReceiver<T>) unbounded<T>() {
    final buf = UnboundedBuffer<T>();
    final core = _MpmcCore<T>(buf);
    final tx = core.attachSender((c) => MpmcSender<T>._(c));
    final rx = core.attachReceiver((c) => MpmcReceiver._(c));
    return (tx, rx);
  }

  /// Creates a bounded MPMC channel.
  /// If `capacity == 0`, sends rendezvous with a waiting receiver.
  ///
  static (MpmcSender<T>, MpmcReceiver<T>) bounded<T>(int capacity) {
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be >= 0');
    }

    final buf = (capacity == 0)
        ? RendezvousBuffer<T>()
        : BoundedBuffer<T>(capacity: capacity);
    final core = _MpmcCore<T>(buf);
    final tx = core.attachSender((c) => MpmcSender<T>._(c));
    final rx = core.attachReceiver((c) => MpmcReceiver._(c));
    return (tx, rx);
  }

  /// Creates a custom channel with a drop policy:
  /// - `block`: return `SendErrorFull` until space is available
  /// - `oldest`: drop the oldest queued item to make room
  /// - `newest`: drop the incoming item (send appears Ok but value is discarded)
  ///
  static (MpmcSender<T>, MpmcReceiver<T>) channel<T>({
    int? capacity,
    DropPolicy policy = DropPolicy.block,
    OnDrop<T>? onDrop,
  }) {
    final inner = capacity == null
        ? UnboundedBuffer<T>()
        : (capacity == 0)
            ? RendezvousBuffer<T>()
            : BoundedBuffer<T>(capacity: capacity);
    final bool usePolicy =
        capacity != null && capacity > 0 && policy != DropPolicy.block;
    final ChannelBuffer<T> buf = usePolicy
        ? PolicyBuffer<T>(inner, policy: policy, onDrop: onDrop)
        : inner;
    final core = _MpmcCore<T>(buf);
    final tx = core.attachSender((c) => MpmcSender<T>._(c));
    final rx = core.attachReceiver((c) => MpmcReceiver<T>._(c));
    return (tx, rx);
  }

  /// Creates an MPMC channel that keeps only the **latest** value.
  /// Semantics with multiple receivers: **competitive consumption**.
  /// All receivers pull from the same single latest slot; only one consumer
  /// will observe a given update. This is *not* a broadcast cache.
  static (MpmcSender<T>, MpmcReceiver<T>) latest<T>() {
    final core = _MpmcCore<T>(LatestOnlyBuffer<T>());
    final tx = core.attachSender((c) => MpmcSender<T>._(c));
    final rx = core.attachReceiver((c) => MpmcReceiver<T>._(c));
    return (tx, rx);
  }
}

final class _MpmcCore<T> extends ChannelCore<T, _MpmcCore<T>> {
  _MpmcCore(this.buf);

  @override
  final ChannelBuffer<T> buf;

  @override
  bool get allowMultiSenders => true;
  @override
  bool get allowMultiReceivers => true;
}

final class MpmcSender<T> implements CloneableSender<T> {
  MpmcSender._(this._core);
  final _MpmcCore<T> _core;
  bool _closed = false;

  @override
  Future<SendResult<T>> send(T v) =>
      _closed ? Future.value(SendErrorDisconnected<T>()) : _core.send(v);

  @pragma('vm:prefer-inline')
  @override
  SendResult<T> trySend(T v) =>
      _closed ? SendErrorDisconnected<T>() : _core.trySend(v);

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _core.dropSender();
  }

  @pragma('vm:prefer-inline')
  @override
  bool get isClosed => _closed;

  @pragma('vm:prefer-inline')
  @override
  MpmcSender<T> clone() {
    if (_closed) throw StateError('Sender closed');
    return _core.attachSender((c) => MpmcSender<T>._(c));
  }
}

final class MpmcReceiver<T> implements CloneableReceiver<T> {
  MpmcReceiver._(this._core);
  final _MpmcCore<T> _core;
  bool _closed = false;
  bool _consumed = false;

  @override
  Future<RecvResult<T>> recv() =>
      _closed ? Future.value(RecvErrorDisconnected<T>()) : _core.recv();

  @pragma('vm:prefer-inline')
  @override
  RecvResult<T> tryRecv() =>
      _closed ? RecvErrorDisconnected<T>() : _core.tryRecv();

  @override
  (Future<RecvResult<T>>, void Function()) recvCancelable() => _closed
      ? (Future.value(RecvErrorDisconnected<T>()), () => {})
      : _core.recvCancelable();

  @override
  Stream<T> stream() async* {
    if (_consumed) throw StateError('Receiver.stream() is single-subscription');
    _consumed = true;

    while (true) {
      switch (await _core.recv()) {
        case RecvOk<T>(value: final v):
          yield v;
        case RecvError<T>():
          return;
      }
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _core.dropReceiver();
  }

  @pragma('vm:prefer-inline')
  @override
  bool get isClosed => _closed;

  @pragma('vm:prefer-inline')
  @override
  MpmcReceiver<T> clone() {
    if (_closed) {
      throw StateError('Receiver closed');
    }
    return _core.attachReceiver((c) => MpmcReceiver._(c));
  }
}
