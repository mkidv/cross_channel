/// Protocol for Cross-Channel internal communication.
library;

import 'package:cross_channel/src/platform/platform.dart';

/// Base class for all internal control messages.
sealed class ControlMessage {
  const ControlMessage();
}

/// Request sent by a remote Receiver to the channel owner (ChannelCore)
/// to initiate a data stream subscription.
final class ConnectRecvRequest extends ControlMessage {
  final PlatformPort replyPort;

  const ConnectRecvRequest(this.replyPort);
}

/// Request sent by a remote Sender to the channel owner (ChannelCore)
/// to initiate a flow-controlled session (sending credits).
final class ConnectSenderRequest extends ControlMessage {
  final PlatformPort replyPort; // Where to send FlowCredits
  const ConnectSenderRequest(this.replyPort);
}

/// Acknowledge from ChannelCore that subscription is accepted.
final class ConnectOk extends ControlMessage {
  const ConnectOk();
}

/// Signals intentional disconnection from sender/receiver.
final class Disconnect extends ControlMessage {
  const Disconnect();
}

/// Wrapper for batched data messages (used by proxy loop for throughput).
/// The receiver should unwrap and process each element.
final class BatchMessage<T> extends ControlMessage {
  final List<T> values;

  const BatchMessage(this.values);
}

/// Credits sent by receiver to sender for backpressure control.
/// Sender should only send up to [credits] messages before waiting for more.
final class FlowCredit extends ControlMessage {
  final int credits;

  const FlowCredit(this.credits);
}
