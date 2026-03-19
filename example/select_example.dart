// ignore_for_file: avoid_print

import 'dart:async';

import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  final dataChannel = XChannel.mpsc<String>().$2;

  // Responsive UI with timeout
  final result = await XSelect.run<String>((s) => s
    ..onRecvValue(dataChannel, (data) => 'got_data: $data')
    ..onTick(const Duration(seconds: 1), () => 'heartbeat')
    ..onTimeout(const Duration(seconds: 30), () => 'timeout_reached'));

  print(result);
}
