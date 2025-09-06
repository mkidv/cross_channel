import 'dart:async';
import 'dart:collection';

part 'buffers/bounded_buffer.dart';
part 'buffers/chunked_buffer.dart';
part 'buffers/latestonly_buffer.dart';
part 'buffers/policy_buffer_wrapper.dart';
part 'buffers/srsw_buffer.dart';
part 'buffers/promise_buffer.dart';
part 'buffers/rendezvous_buffer.dart';
part 'buffers/unbounded_buffer.dart';

abstract class ChannelBuffer<T> {
  bool get isEmpty;

  bool tryPush(T v);
  T? tryPop();

  Future<void> waitNotFull();
  void consumePushPermit();
  Completer<T> addPopWaiter();
  bool removePopWaiter(Completer<T> c);

  void wakeAllPushWaiters();
  void failAllPopWaiters(Object e);
  void clear();
}
