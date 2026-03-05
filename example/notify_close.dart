// ignore_for_file: unused_element

import 'package:cross_channel/notify.dart';

Future<void> main() async {
  final shutdownNotify = Notify();

  // Force shutdown after grace period
  Future<void> forceShutdown() async {
    await Future<void>.delayed(Duration(seconds: 30)); // Grace period
    shutdownNotify.close(); // Force all remaining waiters to fail
  }
}
