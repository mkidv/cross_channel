import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  final (tx, rx) = XChannel.mpsc<String>();

  // 1. Throttle (max 1 event per 100ms)
  final throttledTx = tx.throttle(const Duration(milliseconds: 100));
  await throttledTx.send('event 1'); // Sent
  await throttledTx.send('event 2'); // Dropped (too soon)

  // 2. Debounce (wait 500ms of silence)
  final debouncedTx = tx.debounce(const Duration(milliseconds: 500));
  await debouncedTx.send('search 1'); // Scheduled
  await debouncedTx.send('search 2'); // search 1 cancelled, search 2 scheduled
}
