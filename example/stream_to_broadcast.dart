import 'package:cross_channel/cross_channel.dart';

void main() {
  // Progress updates in multiple widgets
  final (_, rx) = XChannel.mpscLatest<double>();
  final broadcast = rx.broadcastStream();

  // Use broadcast
  broadcast.listen((_) {});
}
