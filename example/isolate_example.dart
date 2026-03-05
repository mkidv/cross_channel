import 'dart:isolate';

import 'package:cross_channel/isolate_extension.dart';

Future<void> main() async {
  final rp = ReceivePort();
  final sp = rp.sendPort;

  // 1. Send structured command
  sp.sendCmd('process', data: {'id': 123});

  // 2. Request/Reply pattern (requires worker support)
  // final result = await sp.request<String>('status');
}
