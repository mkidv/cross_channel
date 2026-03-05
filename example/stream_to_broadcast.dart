import 'package:cross_channel/cross_channel.dart';
import 'package:cross_channel/stream_extension.dart';

void main() {
  // Progress updates in multiple widgets
  final (_, rx) = XChannel.mpscLatest<double>();
  final broadcast = rx.toBroadcastStream();

  // Use broadcast
  broadcast.listen((_) {});
}
