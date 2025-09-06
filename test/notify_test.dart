import 'dart:async';

import 'package:cross_channel/notify.dart';
import 'package:test/test.dart';

void main() {
  group('Notify', () {
    test('notifyOne wake only one waiter or add permit', () async {
      final n = Notify();
      final (a, _) = n.notified();
      final (b, _) = n.notified();

      n.notifyOne();
      await a.timeout(const Duration(milliseconds: 50));
      var bResolved = false;
      unawaited(b.then((_) => bResolved = true));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(bResolved, isFalse);

      n.notifyOne();
      await b;
    });

    test('immediatly consume permit if available', () async {
      final n = Notify();
      n.notifyOne();
      final (f, _) = n.notified();
      await f;
    });

    test('notifyAll wake all waiters', () async {
      final n = Notify();
      final (a, _) = n.notified();
      final (b, _) = n.notified();
      n.notifyAll();
      await Future.wait([a, b]);
      final (c, _) = n.notified();
      var resolved = false;
      unawaited(c.then((_) => resolved = true));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(resolved, isFalse);
    });

    test('close() notify disconnected', () async {
      final n = Notify();
      final (f, _) = n.notified();
      n.close();
      await expectLater(f, throwsA(isA<StateError>()));
      expect(n.isDisconnected, isTrue);
    });

    test('cancel() properly remove waiter', () async {
      final n = Notify();
      final (f, cancel) = n.notified();
      cancel();
      await expectLater(f, throwsA(isA<StateError>()));
      n.notifyOne();
    });
  });
}
