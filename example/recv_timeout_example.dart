// ignore_for_file: avoid_print

import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  final (_, rx) = XChannel.mpsc<String>();

  // No data arrives
  final result = await rx.recvTimeout(const Duration(seconds: 2));

  if (result.isTimeout) {
    print('No data in 2s!');
  }
}
