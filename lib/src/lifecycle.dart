import 'package:cross_channel/src/buffers.dart';
import 'package:cross_channel/src/result.dart';

/// Channel lifecycle: tracks active senders/receivers and handles shutdown.
/// On last sender drop + empty buffer, receivers are completed with
/// `RecvErrorDisconnected`. On last receiver drop, pending receivers are failed
/// and the buffer is cleared; senders are awakened.
///
mixin ChannelLifecycle<T, Self extends Object> {
  ChannelBuffer<T> get buf;

  bool get allowMultiSenders;
  bool get allowMultiReceivers;

  int _activeSenders = 0;
  int _activeReceivers = 0;
  bool _closedSenders = false;
  bool _closedReceivers = false;

  @pragma('vm:prefer-inline')
  bool get sendDisconnected =>
      _closedSenders || (_closedReceivers && _activeReceivers == 0);

  @pragma('vm:prefer-inline')
  bool get recvDisconnected =>
      _closedReceivers || (_closedSenders && buf.isEmpty);

  @pragma('vm:prefer-inline')
  S attachSender<S>(S Function(Self) make) {
    if (_closedReceivers) throw StateError('Channel has no receivers');
    if (!allowMultiSenders && _activeSenders > 0) {
      throw StateError('Single-sender channel already attached');
    }
    _activeSenders++;
    return make(this as Self);
  }

  @pragma('vm:prefer-inline')
  R attachReceiver<R>(R Function(Self) make) {
    if (_closedReceivers) throw StateError('Channel has no receivers');
    if (!allowMultiReceivers && _activeReceivers > 0) {
      throw StateError('Single-receiver channel already attached');
    }
    if (_closedSenders && buf.isEmpty) {
      throw StateError('Channel closed');
    }
    _activeReceivers++;
    return make(this as Self);
  }

  @pragma('vm:prefer-inline')
  void dropSender() {
    if (_closedSenders) return;
    if (_activeSenders > 0) _activeSenders--;
    if (_activeSenders == 0) {
      _closedSenders = true;
      buf.wakeAllPushWaiters();
      if (buf.isEmpty) buf.failAllPopWaiters(const RecvErrorDisconnected());
    }
  }

  @pragma('vm:prefer-inline')
  void dropReceiver() {
    if (_closedReceivers) return;
    if (_activeReceivers > 0) _activeReceivers--;
    if (_activeReceivers == 0) {
      _closedReceivers = true;
      buf.wakeAllPushWaiters();
      buf.failAllPopWaiters(const RecvErrorDisconnected());
      buf.clear();
    }
  }
}
