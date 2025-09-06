import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';
export 'src/buffers.dart' show DropPolicy, OnDrop;

/// MPSC channel: multiple producers, single consumer.
///
class Mpsc {
  /// Creates an unbounded MPSC channel.
  /// Producers never block; consumer receives in FIFO order.
  ///
  static (MpscSender<T>, MpscReceiver<T>) unbounded<T>({bool chunked = true}) {
    final buf = chunked ? ChunkedBuffer<T>() : UnboundedBuffer<T>();
    final core = _MpscCore<T>(buf);
    final tx = core.attachSender((c) => MpscSender<T>._(c));
    final rx = core.attachReceiver((c) => MpscReceiver<T>._(c));
    return (tx, rx);
  }

  /// Creates a bounded MPSC channel.
  /// If `capacity == 0`, sends rendezvous with a waiting receiver.
  ///
  static (MpscSender<T>, MpscReceiver<T>) bounded<T>(int capacity) {
    if (capacity < 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be >= 0');
    }

    final buf = (capacity == 0)
        ? RendezvousBuffer<T>()
        : BoundedBuffer<T>(capacity: capacity);
    final core = _MpscCore<T>(buf);
    final tx = core.attachSender((c) => MpscSender<T>._(c));
    final rx = core.attachReceiver((c) => MpscReceiver<T>._(c));
    return (tx, rx);
  }

  /// Creates a custom channel with a drop policy:
  /// - `block`: return `SendErrorFull` until space is available
  /// - `oldest`: drop the oldest queued item to make room
  /// - `newest`: drop the incoming item (send appears Ok but value is discarded)
  ///
  static (MpscSender<T>, MpscReceiver<T>) channel<T>({
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
    final core = _MpscCore<T>(buf);
    final tx = core.attachSender((c) => MpscSender<T>._(c));
    final rx = core.attachReceiver((c) => MpscReceiver<T>._(c));
    return (tx, rx);
  }

  /// Creates an MPSC channel that keeps only the **latest** value.
  /// Each new send coalesces/overwrites the previous one.
  /// Suitable for UI signals, progress, sensors, etc.
  ///
  static (MpscSender<T>, MpscReceiver<T>) latest<T>() {
    final core = _MpscCore<T>(LatestOnlyBuffer<T>());
    final tx = core.attachSender((c) => MpscSender<T>._(c));
    final rx = core.attachReceiver((c) => MpscReceiver<T>._(c));
    return (tx, rx);
  }
}

final class _MpscCore<T> extends ChannelCore<T, _MpscCore<T>> {
  _MpscCore(this.buf);

  @override
  final ChannelBuffer<T> buf;

  @override
  bool get allowMultiSenders => true;
  @override
  bool get allowMultiReceivers => false;
}

/// A clonable producer handle for an MPSC channel.
/// Call `close()` to drop this producer; the channel disconnects when
/// all producers are dropped and the buffer becomes empty.
///
final class MpscSender<T> implements CloneableSender<T> {
  MpscSender._(this._core);
  final _MpscCore<T> _core;
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
  MpscSender<T> clone() {
    if (_closed) throw StateError('Sender closed');
    return _core.attachSender((c) => MpscSender<T>._(c));
  }
}

/// The single consumer handle for an MPSC channel.
/// `stream()` is single-subscription. Call `close()` to drop the consumer;
/// pending receivers are completed with `RecvErrorDisconnected`.
///
final class MpscReceiver<T> implements KeepAliveReceiver<T> {
  MpscReceiver._(this._core);
  final _MpscCore<T> _core;
  bool _consumed = false;
  bool _closed = false;

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
    if (_consumed) throw StateError('stream is single-subscription');
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
}
