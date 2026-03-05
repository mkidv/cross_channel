import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  final (tx, _) = XChannel.mpsc<String>();

  // Pattern Matching
  final result = await tx.send('data');
  switch (result) {
    case SendOk():
      print('Sent successfully');
    case SendErrorFull():
      print('Channel full');
    case SendErrorDisconnected():
      print('No receivers');
    default:
      print('Other error');
  }

  // Extension Methods
  final result2 = tx.trySend('data');
  if (result2.hasSend) {
    print('Success!');
  } else if (result2.isFull) {
    print('Full!');
  }
}
