import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  final (tx, _) = XChannel.mpsc<String>(capacity: 1);

  // Fill the channel
  tx.trySend('first');

  // Next send will block and then timeout
  final result = await tx.sendTimeout('second', const Duration(seconds: 2));

  if (result.isTimeout) {
    print('Send timed out!');
  }
}
