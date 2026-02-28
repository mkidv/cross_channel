import 'package:cross_channel/oneshot.dart';

Future<void> main() async {
  // 1. Create a one-shot promise channel
  // `consumeOnce: true` means only the first receiver gets the value.
  final (responseTx, responseRx) = OneShot.channel<String>(consumeOnce: true);

  // 2. Server Side (Promise resolution)
  Future.microtask(() async {
    // Send exactly one response
    await responseTx.send('Operation completed successfully');
  });

  // 3. Client Side
  final result = await responseRx.recv();

  if (result is RecvOk<String>) {
    print('Response: ${result.value}');
  } else if (result is RecvErrorDisconnected) {
    print('Server disconnected without answering');
  }
}
