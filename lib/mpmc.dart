import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';
export 'src/buffers.dart' show DropPolicy, OnDrop;

/// MPMC channel: multiple producers, multiple independent consumers.
///
/// Each consumer observes items it pulls; there is no implicit broadcast.
/// Use `Receiver.clone()` to attach additional consumers.
///
final class Mpmc {
  /// Creates an unbounded MPMC channel.
  /// Producers never block; consumer receives in FIFO order.
  ///
  static (MpmcSender<T>, MpmcReceiver<T>) unbounded<T>({bool chunked = true}) {
    final buf = chunked ? ChunkedBuffer<T>() : UnboundedBuffer<T>();
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
    bool chunked = true,
  }) {
    final inner = capacity == null
        ? chunked
            ? ChunkedBuffer<T>()
            : UnboundedBuffer<T>()
        : (capacity == 0)
            ? RendezvousBuffer<T>()
            : BoundedBuffer<T>(capacity: capacity);
    final bool usePolicy =
        capacity != null && capacity > 0 && policy != DropPolicy.block;
    final ChannelBuffer<T> buf = usePolicy
        ? PolicyBufferWrapper<T>(inner, policy: policy, onDrop: onDrop)
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

  @pragma('vm:prefer-inline')
  @override
  bool get isDisconnected => _core.sendDisconnected || _closed;

  @override
  Future<SendResult> send(T v) =>
      _closed ? Future.value(const SendErrorDisconnected()) : _core.send(v);

  @pragma('vm:prefer-inline')
  @override
  SendResult trySend(T v) =>
      _closed ? const SendErrorDisconnected() : _core.trySend(v);

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _core.dropSender();
  }

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

  @pragma('vm:prefer-inline')
  @override
  bool get isDisconnected => _core.recvDisconnected || _closed;

  @override
  Future<RecvResult<T>> recv() =>
      _closed ? Future.value(const RecvErrorDisconnected()) : _core.recv();

  @pragma('vm:prefer-inline')
  @override
  RecvResult<T> tryRecv() =>
      _closed ? const RecvErrorDisconnected() : _core.tryRecv();

  @override
  (Future<RecvResult<T>>, void Function()) recvCancelable() => _closed
      ? (Future.value(const RecvErrorDisconnected()), () => {})
      : _core.recvCancelable();

  @override
  Stream<T> stream() async* {
    if (_consumed) throw StateError('Receiver.stream() is single-subscription');
    _consumed = true;

    while (true) {
      switch (await _core.recv()) {
        case RecvOk<T>(value: final v):
          yield v;
        case RecvError():
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
  MpmcReceiver<T> clone() {
    if (_closed) {
      throw StateError('Receiver closed');
    }
    return _core.attachReceiver((c) => MpmcReceiver._(c));
  }
}
