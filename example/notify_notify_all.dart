// ignore_for_file: unused_element

import 'package:cross_channel/notify.dart';

void main() {
  final shutdownFlag = Notify();

  // Graceful shutdown - wake all workers
  void initiateShutdown() {
    shutdownFlag.notifyAll(); // All workers check shutdown state
  }
}
