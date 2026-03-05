import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  final (tx, rx) = XChannel.mpsc<String>(capacity: 100);
  final items = ['batch 1', 'batch 2', 'batch 3'];

  // 1. Batch sending
  await tx.sendAll(items);
  await tx.trySendAll(['fast 1', 'fast 2']);

  // 2. Batch receiving (with 100ms idle timeout)
  final batch = await rx.recvAll(
    idle: const Duration(milliseconds: 100),
    max: 10,
  );
  print('Received batch: $batch');

  // 3. Immediate drain
  final available = rx.tryRecvAll(max: 5);
  print('Immediately available: $available');
}
