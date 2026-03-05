import 'package:cross_channel/web_extension.dart';
import 'package:web/web.dart';

Future<void> main() async {
  final mc = MessageChannel();
  final port = mc.port1;

  // 1. Send command
  port.sendCmd('process', data: {'id': 1});

  // 2. Request/Reply pattern
  // final result = await port.request<String>('status');
}
