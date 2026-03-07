import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
  final stream = Stream.fromIterable(['data']);

  // Redirect stream to channel
  await stream.pipeTo(tx);
}
