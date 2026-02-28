import 'package:cross_channel/mpmc.dart';

Future<void> main() async {
  // 1. Create a bounded MPMC channel for N:M communication
  // Limited work queue prevents memory exhaustion (natural backpressure)
  final (taskTx, taskRx) = Mpmc.bounded<String>(100);

  // 2. Multiple Job Producers
  for (int i = 0; i < 2; i++) {
    final producer = taskTx.clone();
    Future.microtask(() async {
      await producer.send('Task from Producer $i');
      producer.close();
    });
  }
  taskTx.close();

  // 3. Multiple Worker Consumers (Competitive Consumption)
  final futures = <Future<void>>[];
  for (int i = 0; i < 2; i++) {
    final worker = taskRx.clone();
    futures.add(Future.microtask(() async {
      await for (final task in worker.stream()) {
        print('Worker $i processed: $task');
      }
    }));
  }
  taskRx.close();

  await Future.wait(futures);
}
