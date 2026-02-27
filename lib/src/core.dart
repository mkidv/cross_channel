import 'dart:async';

import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/lifecycle.dart';
import 'package:cross_channel/src/metrics/recorders.dart';
import 'package:cross_channel/src/ops.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/protocol.dart';
import 'package:cross_channel/src/registry.dart';
import 'package:cross_channel/src/remote.dart';
import 'package:cross_channel/src/result.dart';

export 'package:cross_channel/src/registry.dart';

typedef Channel<T> = (Sender<T> tx, Receiver<T> rx);

final _senderConnections = Expando<FlowControlledRemoteConnection<dynamic>>();
final _receiverConnections = Expando<FlowControlledRemoteConnection<dynamic>>();

/// Core channel traits: lifecycle + send/recv ops binding.
///
/// `ChannelCore<T, Self>` ties a buffer implementation to lifecycle
/// (attach/drop senders/receivers, disconnection semantics) and exposes the
/// high-level send/recv operations via `ChannelSendOps<T>` and `ChannelRecvOps<T>`.
abstract class ChannelCore<T, Self extends Object>
    with ChannelSendOps<T>, ChannelRecvOps<T>, ChannelLifecycle<T, Self> {
  ChannelCore({this.metricsId, MetricsRecorder? metrics})
      : _mx = metrics ?? buildMetricsRecorder(metricsId) {
    // Register immediately upon creation
    _id = ChannelRegistry.register(this);
  }

  late final int _id;

  /// The unique (local) ID of this channel channel.
  int get id => _id;

  @override
  int get channelId => _id;

  @override
  ChannelBuffer<T> get buf;
  @override
  bool get isSendClosed => sendDisconnected;
  @override
  bool get isRecvClosed => recvDisconnected;

  @override
  ChannelCore<T, Object>? get localSendChannel => null;
  @override
  ChannelCore<T, Object>? get localRecvChannel => null;

  final String? metricsId;
  final MetricsRecorder _mx;

  @override
  @pragma('vm:prefer-inline')
  MetricsRecorder get mx => _mx;

  /// Create a PlatformReceiver for remote interactions (lazy loaded).
  /// This receiver is used to receive messages from remote Isolates/Workers.
  PlatformReceiver? _remoteReceiver;
  final _connectedSenders = <FlowControlledRemoteConnection<T>>[];
  int _activeProxyLoops = 0;

  PlatformPort get sendPort {
    if (_remoteReceiver == null) {
      final rx = createReceiver();
      _remoteReceiver = rx;
      rx.messages.listen((msg) {
        if (msg is T) {
          buf.tryPush(msg);
        } else if (msg is List) {
          for (final v in msg) {
            if (v is T) buf.tryPush(v);
          }
        } else if (msg is ConnectRecvRequest) {
          _handleConnectRecvRequest(msg);
        } else if (msg is ConnectSenderRequest) {
          _handleConnectSenderRequest(msg);
        } else if (msg is FlowCredit) {
          for (final c in _connectedSenders) {
            c.handleRemoteMessage(msg);
          }
        }
        if (!buf.isEmpty) buf.wakeAllPushWaiters();
      });
    }
    return _remoteReceiver!.sendPort;
  }

  void _handleConnectRecvRequest(ConnectRecvRequest req) {
    // Determine if we can accept a new receiver
    if (!allowMultiReceivers && _activeProxyLoops > 0) {
      // Reject connection
      req.replyPort.send(const Disconnect());
      return;
    }
    _spawnProxyLoop(req.replyPort);
  }

  void _handleConnectSenderRequest(ConnectSenderRequest req) {
    // Basic multi-sender check
    if (!allowMultiSenders && _connectedSenders.isNotEmpty) {
      // Reject connection
      req.replyPort.send(const Disconnect());
      return;
    }

    final conn = FlowControlledRemoteConnection<T>.forReceiver(
      req.replyPort,
      buffer: buf,
    );
    _connectedSenders.add(conn);
    // Note: cleanup of _connectedSenders would require monitoring conn closure
  }

  Future<void> _spawnProxyLoop(PlatformPort remotePort) async {
    _activeProxyLoops++;
    const batchSize = 64;
    final conn = FlowControlledRemoteConnection<T>.forSender(remotePort);

    // Broadcast specialization: each remote subscriber needs its own cursor
    final ring = buf is BroadcastRing<T> ? buf as BroadcastRing<T> : null;
    final cursor = ring?.addSubscriber(0);

    try {
      while (!recvDisconnected) {
        if (ring != null) {
          final res = await ring.receive(cursor!);
          if (res.isDisconnected) return;
          if (res.hasValue) {
            await conn.send(res.value);
          }
          continue;
        }

        // Fast path: drain immediately available items
        final immediate = buf.tryPopMany(batchSize);
        if (immediate.isNotEmpty) {
          await conn.sendBatch(immediate);
          continue;
        }

        // Slow path: wait for data
        await buf.waitNotEmpty();
        if (recvDisconnected) return;

        var v = buf.tryPop();
        if (v == null) {
          // Rendezvous or race: wait for an actual handoff
          final c = buf.addPopWaiter();
          if (recvDisconnected) {
            buf.removePopWaiter(c);
            return;
          }
          try {
            v = await c.future;
          } catch (_) {
            return;
          }
        }

        // Got one, try to batch more
        final more = buf.tryPopMany(batchSize - 1);
        if (more.isEmpty) {
          await conn.send(v as T);
        } else {
          await conn.sendBatch([v as T, ...more]);
        }
      }
    } catch (_) {
      // Disconnected or error - exit silently
    } finally {
      if (ring != null && cursor != null) {
        ring.removeSubscriber(cursor);
      }
      conn.close();
      _activeProxyLoops--;
    }
  }
}

/// Standard generic implementation of [ChannelCore].
///
final class StandardChannelCore<T> extends ChannelCore<T, StandardChannelCore<T>> {
  StandardChannelCore(
    this.buf, {
    required this.allowMultiSenders,
    required this.allowMultiReceivers,
    super.metricsId,
  });

  @override
  final ChannelBuffer<T> buf;
  @override
  final bool allowMultiSenders;
  @override
  final bool allowMultiReceivers;
}

abstract class Closeable {
  void close();
}

abstract class Clones<Self> {
  Self clone();
}

/// A handle to a channel's sending side.
///
/// Can be sent between Isolates.
abstract class Sender<T> with ChannelSendOps<T> {
  /// The local ID of the channel.
  @override
  int get channelId;

  ChannelCore<T, Object>? _cachedLocal;

  @pragma('vm:prefer-inline')
  @override
  ChannelCore<T, Object>? get localSendChannel {
    if (_cachedLocal != null) return _cachedLocal;
    final local = ChannelRegistry.get(channelId);
    if (local != null && !identical(local, this)) {
      return _cachedLocal = local as ChannelCore<T, Object>;
    }
    return null;
  }

  /// The PlatformPort for remote communication.
  @override
  PlatformPort get remotePort;

  FlowControlledRemoteConnection<T>? _cachedConn;

  @pragma('vm:prefer-inline')
  @override
  FlowControlledRemoteConnection<T>? get remoteConnection {
    if (localSendChannel != null) return null;
    return _cachedConn ??= _senderConnections[this] as FlowControlledRemoteConnection<T>?;
  }

  /// Ensures connection is established for remote interactions
  FlowControlledRemoteConnection<T> _ensureConnection() {
    final existing = remoteConnection;
    if (existing != null) return existing;

    final newConn = FlowControlledRemoteConnection<T>.forSender(remotePort);
    _senderConnections[this] = newConn;
    _cachedConn = newConn;
    return newConn;
  }

  @override
  Future<SendResult> send(T value) async {
    if (localSendChannel case final lc?) return lc.send(value);
    if (isSendClosed) return const SendErrorDisconnected();

    // Remote with Expando-based flow control
    final t0 = mx.startSendTimer();
    final rc = _ensureConnection();
    await rc.send(value);
    mx.sendOk(t0);
    return const SendOk();
  }

  @override
  SendResult trySend(T value) {
    if (localSendChannel case final lc?) return lc.trySend(value);
    if (isSendClosed) return const SendErrorDisconnected();

    final t0 = mx.startSendTimer();
    final rc = _ensureConnection();
    if (rc.trySend(value)) {
      mx.trySendOk(t0);
      return const SendOk();
    }
    mx.trySendFail();
    return SendErrorFull();
  }

  String? get metricsId => null;

  @override
  MetricsRecorder get mx => _mx ??= buildMetricsRecorder(metricsId);
  MetricsRecorder? _mx;

  @override
  bool get isSendClosed => false;

  /// The buffer is unused by Sender when using remotePort.
  @override
  ChannelBuffer<T>? get buf => null;
}

/// A handle to a channel's receiving side.
///
/// Can be sent between Isolates.
abstract class Receiver<T> with ChannelRecvOps<T> {
  /// The local ID of the channel.
  @override
  int get channelId;

  ChannelCore<T, Object>? _cachedLocal;

  @pragma('vm:prefer-inline')
  @override
  ChannelCore<T, Object>? get localRecvChannel {
    if (_cachedLocal != null) return _cachedLocal;
    final local = ChannelRegistry.get(channelId);
    if (local != null && !identical(local, this)) {
      return _cachedLocal = local as ChannelCore<T, Object>;
    }
    return null;
  }

  /// The PlatformPort to communicate with the channel.
  PlatformPort get remotePort;

  String? get metricsId => null;

  @override
  MetricsRecorder get mx => _mx ??= buildMetricsRecorder(metricsId);
  MetricsRecorder? _mx;

  @override
  bool get isRecvClosed => false;

  /// Gets the remote buffer, initializing connection via Expando if needed.
  @override
  ChannelBuffer<T> get buf {
    // If we have a stored connection in Expando, use its buffer
    var conn = _receiverConnections[this] as FlowControlledRemoteConnection<T>?;
    if (conn != null) return conn.buffer!;

    // Otherwise, create new connection and store it
    conn = FlowControlledRemoteConnection<T>.forReceiver(remotePort);
    _receiverConnections[this] = conn;
    return conn.buffer!;
  }

  /// Closes the remote connection if active.
  void closeRemote() {
    final conn = _receiverConnections[this] as FlowControlledRemoteConnection<T>?;
    conn?.close();
    _receiverConnections[this] = null;
  }
}

abstract class KeepAliveSender<T> extends Sender<T> implements Closeable {}

abstract class KeepAliveReceiver<T> extends Receiver<T> implements Closeable {
  Stream<T> stream();
}

abstract class CloneableSender<T> extends KeepAliveSender<T>
    implements Clones<CloneableSender<T>> {}

abstract class CloneableReceiver<T> extends KeepAliveReceiver<T>
    implements Clones<CloneableReceiver<T>> {}
