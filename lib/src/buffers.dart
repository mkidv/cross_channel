import 'dart:async';
import 'dart:collection';

import 'package:cross_channel/src/result.dart';

part 'buffers/bounded_buffer.dart';
part 'buffers/broadcast_ring.dart';
part 'buffers/chunked_buffer.dart';
part 'buffers/latestonly_buffer.dart';
part 'buffers/policy_buffer_wrapper.dart';
part 'buffers/pop_waiter_queue.dart';
part 'buffers/promise_buffer.dart';
part 'buffers/rendezvous_buffer.dart';
part 'buffers/srsw_buffer.dart';
part 'buffers/unbounded_buffer.dart';

abstract class ChannelBuffer<T> {
  bool get isEmpty;

  bool tryPush(T v);
  T? tryPop();
  List<T> tryPopMany(int max);

  Future<void> waitNotEmpty();
  Future<void> waitNotFull();
  void consumePushPermit();
  Completer<T> addPopWaiter();
  bool removePopWaiter(Completer<T> c);

  void wakeAllPushWaiters();
  void failAllPopWaiters(Object e);
  void clear();
}
