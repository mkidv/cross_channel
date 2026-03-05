import 'dart:async';

import 'package:cross_channel/cross_channel.dart';
// ignore: implementation_imports
import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/stream_extension.dart';

Future<void> main() async {
  final (tx, rx) = XChannel.mpsc<String>();

  // 1. Convert Receiver to Broadcast Stream
  final broadcast = rx.toBroadcastStream();

  broadcast.listen((String msg) => print('Subscriber A: $msg'));
  broadcast.listen((String msg) => print('Subscriber B: $msg'));

  // 2. Redirect Stream to Sender
  final stream = Stream.fromIterable(['event 1', 'event 2', 'event 3']);
  // KeepAliveSender is required for toBroadcastStream/redirectToSender access
  await stream.redirectToSender(tx as KeepAliveSender<String>);
}
