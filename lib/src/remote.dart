import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/protocol.dart';
import 'package:cross_channel/src/result.dart';

/// Base remote connection for inter-isolate communication.
///
/// Provides common functionality for both fire-and-forget and flow-controlled
/// connections. Subclass [FlowControlledRemoteConnection] for backpressure.
class RemoteConnection<T> {
  RemoteConnection._({
    required PlatformPort targetPort,
    ChannelBuffer<T>? localBuffer,
  })  : _targetPort = targetPort,
        _localBuffer = localBuffer;

  PlatformPort _targetPort;
  final ChannelBuffer<T>? _localBuffer;
  PlatformReceiver? _receiver;
  StreamSubscription<Object?>? _subscription;
  bool _closed = false;

  /// Creates a connection for sending to a remote channel.
  factory RemoteConnection.forSender(PlatformPort targetPort) {
    return RemoteConnection._(targetPort: targetPort);
  }

  /// Creates a connection for receiving from a remote channel.
  factory RemoteConnection.forReceiver(
    PlatformPort targetPort, {
    ChannelBuffer<T>? buffer,
  }) {
    final buf = buffer ?? UnboundedBuffer<T>();
    final conn = RemoteConnection._(targetPort: targetPort, localBuffer: buf);
    conn._setupListener((port) => ConnectRecvRequest(port, 0).toTransferable());
    return conn;
  }

  PlatformPort get targetPort => _targetPort;
  ChannelBuffer<T>? get buffer => _localBuffer;
  bool get isClosed => _closed;

  void _setupListener(
      Object Function(PlatformPort replyPort) handshakeBuilder) {
    if (_receiver != null) return;
    final rx = createReceiver();
    _receiver = rx;
    _targetPort.send(handshakeBuilder(rx.sendPort));
    _subscription = rx.messages.asyncMap(onMessage).listen((_) {});
  }

  /// Override in subclasses to customize message handling.
  Future<void> onMessage(Object? msg) async {
    if (msg is Map) {
      final ctrl = ControlMessage.fromTransferable(msg);
      if (ctrl != null) msg = ctrl;
    }

    if (msg is Disconnect) {
      close();
      return;
    }

    final buf = _localBuffer;
    if (buf == null) return;

    if (msg is List) {
      for (final v in msg) {
        if (v is T) {
          while (!buf.tryPush(v)) {
            await buf.waitNotFull();
          }
        }
      }
    } else if (msg is BatchMessage<T>) {
      for (final v in msg.values) {
        while (!buf.tryPush(v)) {
          await buf.waitNotFull();
        }
      }
    } else if (msg is T) {
      while (!buf.tryPush(msg)) {
        await buf.waitNotFull();
      }
    }
  }

  void send(T value) {
    if (_closed) return;
    _targetPort.send(value);
  }

  void sendBatch(List<T> batch) {
    if (_closed || batch.isEmpty) return;
    _targetPort.send(batch.length == 1 ? batch.first : batch);
  }

  void close() {
    if (_closed) return;
    _closed = true;

    try {
      _targetPort.send(const Disconnect());
    } catch (_) {}

    _localBuffer?.failAllPopWaiters(const RecvErrorDisconnected());

    _subscription?.cancel();
    _subscription = null;
    _receiver?.close();
    _receiver = null;
  }
}

/// Flow-controlled remote connection with credit-based backpressure.
///
/// Prevents OOM on slow consumers. Receiver grants credits after consumption.
class FlowControlledRemoteConnection<T> extends RemoteConnection<T> {
  FlowControlledRemoteConnection._({
    required super.targetPort,
    required int initialCredits,
    required int creditBatchSize,
    PlatformPort? creditPort,
    super.localBuffer,
  })  : _credits = initialCredits,
        _creditBatchSize = creditBatchSize,
        _creditPort = creditPort,
        super._();

  static const defaultInitialCredits = 65536;
  static const defaultCreditBatchSize = 1024;
  static const defaultBoundedCapacity = 65536;

  final int _creditBatchSize;
  int _credits;
  int _consumedSinceAck = 0;
  PlatformPort? _creditPort;
  int _pendingAcks = 0;
  Completer<void>? _creditWaiter;

  int get credits => _credits;

  factory FlowControlledRemoteConnection.forSender(
    PlatformPort targetPort, {
    int initialCredits = 0,
    int creditBatchSize = defaultCreditBatchSize,
  }) {
    final conn = FlowControlledRemoteConnection<T>._(
      targetPort: targetPort,
      initialCredits: initialCredits,
      creditBatchSize: creditBatchSize,
    );
    conn._setupListener((port) => ConnectSenderRequest(port).toTransferable());
    return conn;
  }

  factory FlowControlledRemoteConnection.forReceiver(
    PlatformPort targetPort, {
    int capacity = defaultBoundedCapacity,
    int creditBatchSize = defaultCreditBatchSize,
    ChannelBuffer<T>? buffer,
    PlatformPort? creditPort,
  }) {
    final buf = buffer ?? BoundedBuffer<T>(capacity: capacity);
    int? cap;
    if (buf is BoundedBuffer<T>) {
      cap = buf.capacity;
    } else if (buf is SrswBuffer<T>) {
      cap = buf.capacity;
    }

    int initCredits = cap ?? defaultBoundedCapacity;
    int batchSize =
        cap != null && cap > 1 ? cap ~/ 2 : (cap == 1 ? 1 : creditBatchSize);
    if (initCredits == 0) initCredits = 1;
    if (batchSize == 0) batchSize = 1;

    final conn = FlowControlledRemoteConnection<T>._(
      targetPort: targetPort,
      initialCredits: 0,
      creditBatchSize: batchSize,
      localBuffer: buf,
      creditPort: creditPort,
    );
    conn._setupListener(
        (port) => ConnectRecvRequest(port, initCredits).toTransferable());
    return conn;
  }

  @override
  Future<void> onMessage(Object? msg) async {
    if (msg is Map) {
      final ctrl = ControlMessage.fromTransferable(msg);
      if (ctrl != null) msg = ctrl;
    }

    if (msg is ConnectRecvRequest) {
      _targetPort = msg.replyPort; // Switch to the dedicated endpoint
      _credits += msg.initialCredits;
      _creditWaiter?.complete();
      _creditWaiter = null;
      return;
    }

    if (msg is FlowCredit) {
      _credits += msg.credits;
      _creditWaiter?.complete();
      _creditWaiter = null;
      return;
    }

    if (msg is Disconnect) {
      close();
      return;
    }

    final buf = _localBuffer;
    if (buf == null) return;

    if (msg is ConnectSenderRequest) {
      _creditPort = msg.replyPort;
      if (_pendingAcks > 0) {
        _creditPort!.send(FlowCredit(_pendingAcks).toTransferable());
        _pendingAcks = 0;
      }
      return;
    }

    int received = 0;

    if (msg is List) {
      for (final v in msg) {
        if (v is T) {
          while (!buf.tryPush(v)) {
            await buf.waitNotFull();
          }
          received++;
        }
      }
    } else if (msg is T) {
      while (!buf.tryPush(msg)) {
        await buf.waitNotFull();
      }
      received = 1;
    }

    _consumedSinceAck += received;
    if (_consumedSinceAck >= _creditBatchSize) {
      if (_creditPort != null) {
        _creditPort!.send(FlowCredit(_consumedSinceAck).toTransferable());
      } else {
        _pendingAcks += _consumedSinceAck;
      }
      _consumedSinceAck = 0;
    }
  }

  /// Public entry point for forwarding messages from a multiplexed listener (e.g. ChannelCore).
  void handleRemoteMessage(Object? msg) => onMessage(msg);

  bool trySend(T value) {
    if (_closed) return false;
    if (_credits > 0) {
      _credits--;
      _targetPort.send(value);
      return true;
    }
    return false;
  }

  @override
  Future<void> send(T value) async {
    while (_credits <= 0) {
      if (_closed) return;
      await _waitForCredits();
    }
    if (_closed) return;
    _credits--;
    _targetPort.send(value);
  }

  @override
  Future<void> sendBatch(List<T> batch) async {
    if (_closed || batch.isEmpty) return;

    var offset = 0;
    final total = batch.length;

    while (offset < total && !_closed) {
      while (_credits <= 0) {
        if (_closed) return;
        await _waitForCredits();
      }
      if (_closed) return;

      final remaining = total - offset;
      final canSend = _credits >= remaining ? remaining : _credits;

      if (canSend == 1) {
        _targetPort.send(batch[offset]);
      } else {
        _targetPort.send(batch.sublist(offset, offset + canSend));
      }
      _credits -= canSend;
      offset += canSend;
    }
  }

  Future<void> _waitForCredits() async {
    if (_credits > 0 || _closed) return;
    _creditWaiter ??= Completer<void>();
    await _creditWaiter!.future;
  }

  @override
  void close() {
    if (_closed) return;
    _creditWaiter?.complete();
    _creditWaiter = null;
    super.close();
  }
}
