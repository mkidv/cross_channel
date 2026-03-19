/// Protocol for Cross-Channel internal communication.
library;

import 'package:cross_channel/src/metrics/core.dart';
import 'package:cross_channel/src/platform/platform.dart';

/// Base class for all internal control messages.
sealed class ControlMessage {
  const ControlMessage();

  /// Converts this message to a transferable Map representation for Web.
  Map<String, Object?> toTransferable();

  /// Reconstructs a control message from its transferable Map representation.
  static ControlMessage? fromTransferable(Object? data) {
    if (data is! Map) return null;
    final map = data.cast<String, Object?>();
    final type = map['#cc'];

    return switch (type) {
      'ConnectRecvRequest' => ConnectRecvRequest(
          unpackPort(map['replyPort']!), map['initialCredits']! as int),
      'ConnectSenderRequest' =>
        ConnectSenderRequest(unpackPort(map['replyPort']!)),
      'ConnectOk' => const ConnectOk(),
      'Disconnect' => const Disconnect(),
      'FlowCredit' => FlowCredit(map['credits']! as int),
      'BatchMessage' => BatchMessage(map['values']! as List),
      'MetricsSync' => MetricsSync(
          map['metricsId']! as String,
          map['originId']! as String,
          ChannelSnapshot.fromTransferable(
              map['snapshot']! as Map<Object?, Object?>)),
      _ => null,
    };
  }
}

/// Request sent by a remote Receiver to the channel owner (ChannelCore)
/// to initiate a data stream subscription.
final class ConnectRecvRequest extends ControlMessage {
  const ConnectRecvRequest(this.replyPort, this.initialCredits);

  final PlatformPort replyPort;
  final int initialCredits;

  @override
  Map<String, Object?> toTransferable() => {
        '#cc': 'ConnectRecvRequest',
        'replyPort': packPort(replyPort),
        'initialCredits': initialCredits,
      };
}

/// Request sent by a remote Sender to the channel owner (ChannelCore)
/// to initiate a flow-controlled session (sending credits).
final class ConnectSenderRequest extends ControlMessage {
  // Where to send FlowCredits
  const ConnectSenderRequest(this.replyPort);

  final PlatformPort replyPort;

  @override
  Map<String, Object?> toTransferable() => {
        '#cc': 'ConnectSenderRequest',
        'replyPort': packPort(replyPort),
      };
}

/// Acknowledge from ChannelCore that subscription is accepted.
final class ConnectOk extends ControlMessage {
  const ConnectOk();

  @override
  Map<String, Object?> toTransferable() => {'#cc': 'ConnectOk'};
}

/// Signals intentional disconnection from sender/receiver.
final class Disconnect extends ControlMessage {
  const Disconnect();

  @override
  Map<String, Object?> toTransferable() => {'#cc': 'Disconnect'};
}

/// Wrapper for batched data messages (used by proxy loop for throughput).
/// The receiver should unwrap and process each element.
final class BatchMessage<T> extends ControlMessage {
  const BatchMessage(this.values);

  final List<T> values;

  @override
  Map<String, Object?> toTransferable() => {
        '#cc': 'BatchMessage',
        'values': values,
      };
}

/// Credits sent by receiver to sender for backpressure control.
/// Sender should only send up to [credits] messages before waiting for more.
final class FlowCredit extends ControlMessage {
  const FlowCredit(this.credits);

  final int credits;

  @override
  Map<String, Object?> toTransferable() => {
        '#cc': 'FlowCredit',
        'credits': credits,
      };
}

/// Syncs metrics from a remote sender/receiver to the channel's parent isolate.
final class MetricsSync extends ControlMessage {
  const MetricsSync(this.metricsId, this.originId, this.snapshot);

  final String metricsId;
  final String originId;
  final ChannelSnapshot snapshot;

  @override
  Map<String, Object?> toTransferable() => {
        '#cc': 'MetricsSync',
        'metricsId': metricsId,
        'originId': originId,
        'snapshot': snapshot.toTransferable(),
      };
}
