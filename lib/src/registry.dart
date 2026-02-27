import 'package:cross_channel/src/core.dart';

/// Global registry for active channels.
///
/// Maps channel IDs (integers) to active [ChannelCore] instances within the
/// current Isolate. This enables "Universal Handles" where a sender can look up
/// the local channel for maximum performance, or fallback to remote port communication
/// if the channel is in another Isolate.
///
/// **Performance:**
/// Uses a growable [List] for O(1) access. Lookup overhead is negligible (<5ns).
abstract final class ChannelRegistry {
  static final List<ChannelCore<dynamic, Object>?> _channels = [];
  static final List<int> _freeSlots = [];

  /// Register a channel and return its ID.
  static int register(ChannelCore<dynamic, Object> channel) {
    if (_freeSlots.isNotEmpty) {
      final id = _freeSlots.removeLast();
      _channels[id] = channel;
      return id;
    }
    final id = _channels.length;
    _channels.add(channel);
    return id;
  }

  /// Unregister a channel by ID.
  static void unregister(int id) {
    if (id < 0 || id >= _channels.length) return;
    _channels[id] = null;
    _freeSlots.add(id);
  }

  /// Get a channel by ID (fast path).
  @pragma('vm:prefer-inline')
  static ChannelCore<dynamic, Object>? get(int id) {
    if (id < 0 || id >= _channels.length) return null;
    return _channels[id];
  }
}
