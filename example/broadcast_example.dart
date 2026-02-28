import 'package:cross_channel/broadcast.dart';

Future<void> main() async {
  // 1. Create a Broadcast (SPMC) ring channel
  final (tx, broadcast) = Broadcast.channel<String>(1024);

  // 2. Create multiple subscribers
  final sub1 = broadcast.subscribe();
  final sub2 = broadcast.subscribe();

  // 3. Publisher
  Future.microtask(() async {
    await tx.send('System Update Available');
    await tx.send('Battery Low');
    tx.close();
  });

  // 4. Consumers receive the SAME messages concurrently
  Future.microtask(() async {
    await for (final msg in sub1.stream()) {
      print('UI Component 1 received: $msg');
    }
  });

  Future.microtask(() async {
    await for (final msg in sub2.stream()) {
      print('UI Component 2 received: $msg');
    }
  });
}
