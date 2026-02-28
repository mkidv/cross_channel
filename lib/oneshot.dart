import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/platform/platform.dart';
import 'package:cross_channel/src/result.dart';

export 'src/extensions.dart';
export 'src/result.dart';

/// A tuple representing a OneShot channel (Sender, Receiver).
typedef OneShotChannel<T> = (OneShotSender<T>, OneShotReceiver<T>);

/// One-shot channels - Promise-like single-value delivery with advanced semantics.
///
/// Specialized channels for delivering exactly one value, similar to futures but
/// with more flexible consumption patterns. Perfect for request-response scenarios,
/// async initialization, and promise-like patterns.
///
/// ## Core Features
/// - **Single-value semantics**: Exactly one value can be sent
/// - **Flexible consumption**: Choose between consume-once or multi-reader patterns
/// - **Promise-like behavior**: Similar to futures but with channel semantics
/// - **Type-safe results**: Explicit success/failure handling
/// - **Zero buffering**: Direct producer-to-consumer handoff
///
/// ## Consumption Modes
///
/// ### `consumeOnce: true` (Default Promise Behavior)
/// - First receiver gets the value and consumes it
/// - Channel disconnects immediately after consumption
/// - Subsequent receivers get `RecvErrorDisconnected`
/// - Perfect for request-response patterns
///
/// ### `consumeOnce: false` (Broadcast Promise)
/// - All receivers (current and future) get the same value
/// - Value remains available until explicitly handled
/// - Multiple receivers can read the same result
/// - Perfect for initialization values or shared results
///
/// ## Example
/// {@tool snippet example/oneshot_example.dart}
/// {@end-tool}
class OneShot {
  static OneShotChannel<T> channel<T>({
    bool consumeOnce = false,
    String? metricsId,
  }) {
    final core = _OneShotCore<T>(consumeOnce: consumeOnce, metricsId: metricsId);
    final tx = core.attachSender((c) => OneShotSender<T>._(c.id, c.createRemotePort()));
    final rx = core.attachReceiver((c) => OneShotReceiver<T>._(c.id, c.createRemotePort()));
    return (tx, rx);
  }
}

final class _OneShotCore<T> extends ChannelCore<T, _OneShotCore<T>> {
  _OneShotCore({required bool consumeOnce, super.metricsId})
      : buf = PromiseBuffer<T>(consumeOnce: consumeOnce);

  @override
  final PromiseBuffer<T> buf;

  @override
  bool get allowMultiSenders => false;
  @override
  bool get allowMultiReceivers => false;

  @override
  bool get sendDisconnected => buf.hasConsumed || !buf.isEmpty;
  @override
  bool get recvDisconnected => buf.hasConsumed && buf.isEmpty;

  @override
  bool get isSendClosed => sendDisconnected;
  @override
  bool get isRecvClosed => recvDisconnected;
}

final class OneShotSender<T> extends Sender<T> {
  OneShotSender._(this.channelId, this.remotePort);

  /// Reconstructs a remote-only sender from a transferable representation.
  factory OneShotSender.fromTransferable(Map<String, Object?> data) =>
      OneShotSender._(-1, unpackPort(data['port']!));

  @override
  final int channelId;

  @override
  final PlatformPort remotePort;

  @override
  Future<SendResult> send(T value) async {
    if (localSendChannel case final lc?) return lc.send(value);

    // OneShot doesn't need backpressure, use fire-and-forget to avoid overhead
    remotePort.send(value);
    return const SendOk();
  }

  @override
  SendResult trySend(T value) {
    if (localSendChannel case final lc?) return lc.trySend(value);

    remotePort.send(value);
    return const SendOk();
  }
}

final class OneShotReceiver<T> extends Receiver<T> {
  OneShotReceiver._(this.channelId, this.remotePort);

  /// Reconstructs a remote-only receiver from a transferable representation.
  factory OneShotReceiver.fromTransferable(Map<String, Object?> data) =>
      OneShotReceiver._(-1, unpackPort(data['port']!));

  @override
  final int channelId;
  @override
  final PlatformPort remotePort;
}
