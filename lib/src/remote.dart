import 'dart:async';
import 'dart:collection';

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
    conn._initReceiver();
    return conn;
  }

  PlatformPort get targetPort => _targetPort;
  ChannelBuffer<T>? get buffer => _localBuffer;
  bool get isClosed => _closed;

  void _initReceiver() {
    if (_receiver != null) return;
    final rx = createReceiver();
    _receiver = rx;
    _targetPort.send(ConnectRecvRequest(rx.sendPort, 0));
    _subscription = rx.messages.asyncMap(onMessage).listen((_) {});
  }

  /// Override in subclasses to customize message handling.
  Future<void> onMessage(Object? msg) async {
    final buf = _localBuffer;
    if (buf == null) return;

    if (msg is List<T>) {
      for (final v in msg) {
        while (!buf.tryPush(v)) {
          await buf.waitNotFull();
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
    } else if (msg is Disconnect) {
      close();
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

    _localBuffer?.failAllPopWaiters(const RecvErrorDisconnected());

    try {
      _targetPort.send(const Disconnect());
    } catch (_) {}

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
    int? initialCreditsToSend,
    PlatformPort? creditPort,
    super.localBuffer,
  })  : _credits = initialCredits,
        _creditBatchSize = creditBatchSize,
        _initialCreditsToSend = initialCreditsToSend ?? 0,
        _creditPort = creditPort,
        super._();

  static const defaultInitialCredits = 65536;
  static const defaultCreditBatchSize = 1024;
  static const defaultBoundedCapacity = 65536;

  final int _creditBatchSize;
  final int _initialCreditsToSend;
  int _credits;
  int _consumedSinceAck = 0;
  PlatformPort? _creditPort;
  int _pendingAcks = 0;
  Completer<void>? _creditWaiter;
  final ListQueue<T> _pendingSend = ListQueue();

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
    conn._initSenderListener();
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
    int batchSize = cap != null && cap > 1 ? cap ~/ 2 : (cap == 1 ? 1 : creditBatchSize);
    if (initCredits == 0) initCredits = 1;
    if (batchSize == 0) batchSize = 1;

    final conn = FlowControlledRemoteConnection<T>._(
      targetPort: targetPort,
      initialCredits: 0,
      creditBatchSize: batchSize,
      initialCreditsToSend: initCredits,
      localBuffer: buf,
      creditPort: creditPort,
    );
    conn._initReceiverListener();
    return conn;
  }

  void _initSenderListener() {
    final rx = createReceiver();
    _receiver = rx;
    _targetPort.send(ConnectSenderRequest(rx.sendPort).toTransferable());

    _subscription = rx.messages.listen((msg) {
      if (msg is Map) {
        final ctrl = ControlMessage.fromTransferable(msg);
        if (ctrl != null) msg = ctrl;
      }

      if (msg is ConnectRecvRequest) {
        _targetPort = msg.replyPort; // Switch to the dedicated endpoint

        _credits += msg.initialCredits;
        _flushPending();
        _creditWaiter?.complete();
        _creditWaiter = null;
      } else if (msg is FlowCredit) {
        _credits += msg.credits;
        _flushPending();
        _creditWaiter?.complete();
        _creditWaiter = null;
      } else if (msg is Disconnect) {
        close();
      }
    });
  }

  void _initReceiverListener() {
    final rx = createReceiver();
    _receiver = rx;
    _targetPort.send(ConnectRecvRequest(rx.sendPort, _initialCreditsToSend).toTransferable());
    _subscription = rx.messages.asyncMap(onMessage).listen((_) {});
  }

  @override
  Future<void> onMessage(Object? msg) async {
    if (msg is Map) {
      final ctrl = ControlMessage.fromTransferable(msg);
      if (ctrl != null) msg = ctrl;
    }

    if (msg is FlowCredit) {
      _credits += msg.credits;
      _flushPending();
      _creditWaiter?.complete();
      _creditWaiter = null;
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
    } else if (msg is Disconnect) {
      close();
      return;
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
    // Fix: Do not queue on trySend failure.
    // _pendingSend.add(value); <--- This was the bug
    return false;
  }

  @override
  Future<void> send(T value) async {
    if (_closed) return;
    if (_credits > 0) {
      _credits--;
      _targetPort.send(value);
      return;
    }
    _pendingSend.add(value);
    await _waitForCredits();
  }

  @override
  Future<void> sendBatch(List<T> batch) async {
    if (_closed || batch.isEmpty) return;

    var offset = 0;
    final total = batch.length;

    while (offset < total && !_closed) {
      if (_credits > 0) {
        final remaining = total - offset;
        final canSend = _credits >= remaining ? remaining : _credits;

        if (canSend == 1) {
          _targetPort.send(batch[offset]);
        } else {
          _targetPort.send(batch.sublist(offset, offset + canSend));
        }
        _credits -= canSend;
        offset += canSend;
      } else {
        await _waitForCredits();
      }
    }
  }

  Future<void> _waitForCredits() async {
    if (_credits > 0 || _closed) return;
    _creditWaiter ??= Completer<void>();
    await _creditWaiter!.future;
  }

  void _flushPending() {
    while (_credits > 0 && _pendingSend.isNotEmpty) {
      _credits--;
      _targetPort.send(_pendingSend.removeFirst());
    }
  }

  @override
  void close() {
    if (_closed) return;
    _creditWaiter?.complete();
    _creditWaiter = null;
    _pendingSend.clear();
    super.close();
  }
}
