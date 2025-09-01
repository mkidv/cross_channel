import 'package:cross_channel/src/buffer.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';

/// Single-producer/single-consumer channel backed by a power-of-two ring buffer.
/// Very low overhead; best used when SPSC is guaranteed by design.
///
final class Spsc {
  static (SpscSender<T>, SpscReceiver<T>) channel<T>(int capacityPow2) {
    final core = _SpscCore<T>(SpscRingBuffer<T>(capacityPow2));
    final tx = core.attachSender((c) => SpscSender<T>._(c));
    final rx = core.attachReceiver((c) => SpscReceiver<T>._(c));
    return (tx, rx);
  }
}

final class _SpscCore<T> extends ChannelCore<T, _SpscCore<T>> {
  _SpscCore(this.buf);
  @override
  final ChannelBuffer<T> buf;

  @override
  bool get allowMultiSenders => false;
  @override
  bool get allowMultiReceivers => false;
}

final class SpscSender<T> implements KeepAliveSender<T> {
  SpscSender._(this._core);
  final _SpscCore<T> _core;
  bool _closed = false;

  @override
  Future<SendResult<T>> send(T v) =>
      _closed ? Future.value(SendErrorDisconnected<T>()) : _core.send(v);

  @override
  SendResult<T> trySend(T v) =>
      _closed ? SendErrorDisconnected<T>() : _core.trySend(v);

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _core.dropSender();
  }

  @override
  bool get isClosed => _closed;
}

final class SpscReceiver<T> implements KeepAliveReceiver<T> {
  SpscReceiver._(this._core);
  final _SpscCore<T> _core;
  bool _closed = false;
  bool _consumed = false;

  @override
  Future<RecvResult<T>> recv() =>
      _closed ? Future.value(RecvErrorDisconnected<T>()) : _core.recv();

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

  @override
  bool get isClosed => _closed;
}
