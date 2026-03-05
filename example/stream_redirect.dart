import 'package:cross_channel/cross_channel.dart';
// ignore: implementation_imports
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/stream_extension.dart';

Future<void> main() async {
  final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
  final stream = Stream.fromIterable(['data']);

  // Redirect stream to channel
  await stream.redirectToSender(tx as KeepAliveSender<String>);
}
