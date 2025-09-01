import 'package:cross_channel/mpsc.dart';
import 'package:cross_channel/mpmc.dart';
import 'package:cross_channel/oneshot.dart';
import 'package:cross_channel/spsc.dart';

export 'select.dart';
export 'src/core.dart'
    show SenderBatchX, SenderTimeoutX, ReceiverDrainX, ReceiverTimeoutX;
export 'src/result.dart';
export 'src/buffer.dart' show DropPolicy, OnDrop;

/// High-level static factory for channels.
///
/// Design rules:
/// - Unbounded when `capacity == null`.
/// - Rendezvous when `capacity == 0`.
/// - Bounded otherwise.
/// - `dropPolicy != null` selects a sliding queue (bounded only).
/// - `onDrop` is optional and invoked on dropped items.
final class XChannel {
  /// Create an MPSC channel (multi-producer, single-consumer).
  static (MpscSender<T>, MpscReceiver<T>) mpsc<T>({
    int? capacity,
    DropPolicy dropPolicy = DropPolicy.block,
    OnDrop<T>? onDrop,
  }) =>
      Mpsc.channel<T>(capacity: capacity, policy: dropPolicy, onDrop: onDrop);

  /// Create an MPMC channel (multi-producer, multi-consumer).
  static (MpmcSender<T>, MpmcReceiver<T>) mpmc<T>({
    int? capacity,
    DropPolicy dropPolicy = DropPolicy.block,
    OnDrop<T>? onDrop,
  }) =>
      Mpmc.channel<T>(capacity: capacity, policy: dropPolicy, onDrop: onDrop);

  /// Create a OneShot channel (single value delivery).
  ///
  /// - `consumeOnce == true`: first receiver consumes the value, then disconnect.
  /// - `consumeOnce == false`: all receivers observe the same value.
  static (OneShotSender<T>, OneShotReceiver<T>) oneshot<T>({
    bool consumeOnce = false,
  }) {
    return OneShot.channel<T>(consumeOnce: consumeOnce);
  }

  /// Create an SPSC channel backed by a ring buffer with power-of-two capacity.
  /// Extremely fast when SPSC constraints hold.
  static (SpscSender<T>, SpscReceiver<T>) spsc<T>({required int capacityPow2}) {
    return Spsc.channel<T>(capacityPow2);
  }

  /// Latest-only MPSC (single consumer). New sends overwrite older ones.
  static (MpscSender<T>, MpscReceiver<T>) mpscLatest<T>() => Mpsc.latest<T>();

  /// Latest-only MPMC (multi consumers compete for the same latest slot).
  /// Not a broadcast cache; only one receiver observes each update.
  static (MpmcSender<T>, MpmcReceiver<T>) mpmcLatest<T>() => Mpmc.latest<T>();
}
