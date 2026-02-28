/// Protocol for Cross-Channel internal communication.
library;

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
      'ConnectRecvRequest' =>
        ConnectRecvRequest(unpackPort(map['replyPort']!), map['initialCredits']! as int),
      'ConnectSenderRequest' => ConnectSenderRequest(unpackPort(map['replyPort']!)),
      'ConnectOk' => const ConnectOk(),
      'Disconnect' => const Disconnect(),
      'FlowCredit' => FlowCredit(map['credits']! as int),
      'BatchMessage' => BatchMessage(map['values']! as List),
      _ => null,
    };
  }
}

/// Request sent by a remote Receiver to the channel owner (ChannelCore)
/// to initiate a data stream subscription.
final class ConnectRecvRequest extends ControlMessage {
  final PlatformPort replyPort;
  final int initialCredits;

  const ConnectRecvRequest(this.replyPort, this.initialCredits);

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
  final PlatformPort replyPort; // Where to send FlowCredits
  const ConnectSenderRequest(this.replyPort);

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
  final List<T> values;

  const BatchMessage(this.values);

  @override
  Map<String, Object?> toTransferable() => {
        '#cc': 'BatchMessage',
        'values': values,
      };
}

/// Credits sent by receiver to sender for backpressure control.
/// Sender should only send up to [credits] messages before waiting for more.
final class FlowCredit extends ControlMessage {
  final int credits;

  const FlowCredit(this.credits);

  @override
  Map<String, Object?> toTransferable() => {
        '#cc': 'FlowCredit',
        'credits': credits,
      };
}
