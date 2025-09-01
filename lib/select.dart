import 'dart:async';

import 'package:cross_channel/src/core.dart';
import 'package:cross_channel/src/result.dart';

abstract class _Branch<R> {
  void attach({
    required void Function(int, Object?, R) resolve,
    required void Function(void Function()) registerCanceller,
    required int index,
  });
}

final class _FutureBranch<U, R> implements _Branch<R> {
  final Future<U> future;
  final Future<R> Function(U) body;
  final Object? tag;
  _FutureBranch(this.future, this.body, this.tag);

  @override
  void attach({
    required void Function(int, Object?, R) resolve,
    required void Function(void Function()) registerCanceller,
    required int index,
  }) {
    bool canceled = false;
    void cancel() => canceled = true;
    registerCanceller(cancel);

    future.then((u) async {
      if (canceled) return;
      final r = await body(u);
      if (!canceled) resolve(index, tag, r);
    }, onError: (_) {});
  }
}

final class _StreamBranch<U, R> implements _Branch<R> {
  final Stream<U> stream;
  final Future<R> Function(U) body;
  final Object? tag;

  _StreamBranch(this.stream, this.body, this.tag);

  @override
  void attach({
    required void Function(int, Object?, R) resolve,
    required void Function(void Function()) registerCanceller,
    required int index,
  }) {
    StreamSubscription<U>? sub;
    bool resolved = false;

    void cancel() {
      if (resolved) return;
      sub?.cancel();
    }

    registerCanceller(cancel);

    sub = stream.listen((u) async {
      if (resolved) return;
      resolved = true;
      await sub?.cancel();
      final r = await body(u);
      resolve(index, tag, r);
    }, onError: (_) async {
      await sub?.cancel();
    }, cancelOnError: false);
  }
}

final class _ReceiverBranch<T, R> implements _Branch<R> {
  final Receiver<T> rx;
  final Future<R> Function(T)? ok;
  final Future<R> Function()? empty;
  final Future<R> Function()? disconnected;
  final Object? tag;
  _ReceiverBranch(this.rx, {this.ok, this.empty, this.disconnected, this.tag});

  @override
  void attach({
    required void Function(int, Object?, R) resolve,
    required void Function(void Function()) registerCanceller,
    required int index,
  }) {
    if (rx is! KeepAliveReceiver<T>) {
      rx.recv().then((res) async {
        switch (res) {
          case RecvOk<T>(value: final v):
            if (ok != null) {
              resolve(index, tag, await ok!(v));
            }
          case RecvErrorEmpty<T>():
            if (empty != null) {
              resolve(index, tag, await empty!());
            }
          case RecvErrorDisconnected<T>():
            if (disconnected != null) {
              resolve(index, tag, await disconnected!());
            }
          case RecvError<T>():
            break;
        }
      });
      registerCanceller(() {}); // no-op
      return;
    }

    final ops = rx as KeepAliveReceiver<T>;
    final (fut, cancel) = ops.recvCancelable();
    registerCanceller(cancel);

    fut.then((res) async {
      switch (res) {
        case RecvOk<T>(value: final v):
          if (ok != null) {
            resolve(index, tag, await ok!(v));
          }
        case RecvErrorEmpty<T>():
          if (empty != null) {
            resolve(index, tag, await empty!());
          }
        case RecvErrorDisconnected<T>():
          if (disconnected != null) {
            resolve(index, tag, await disconnected!());
          }
        case RecvError<T>():
          break;
      }
    });
  }
}

final class Select<R> {
  static SelectBuilder<R> any<R>(void Function(SelectBuilder<R>) build) {
    final b = SelectBuilder<R>();
    build(b);
    return b;
  }
}

final class SelectBuilder<R> {
  final List<_Branch<R>> _arms = [];

  SelectBuilder<R> onFuture<U>(Future<U> fut, Future<R> Function(U) body,
      {Object? tag}) {
    _arms.add(_FutureBranch<U, R>(fut, body, tag));
    return this;
  }

  SelectBuilder<R> onStream<U>(
    Stream<U> s,
    Future<R> Function(U) body, {
    Object? tag,
  }) {
    _arms.add(_StreamBranch<U, R>(s, body, tag));
    return this;
  }

  SelectBuilder<R> onReceiver<T>(
    Receiver<T> rx, {
    Future<R> Function(T)? ok,
    Future<R> Function()? empty,
    Future<R> Function()? disconnected,
    Object? tag,
  }) {
    _arms.add(_ReceiverBranch<T, R>(rx,
        ok: ok, empty: empty, disconnected: disconnected, tag: tag));
    return this;
  }

  SelectBuilder<R> onTimer(Duration d, Future<R> Function() body,
      {Object? tag}) {
    return onFuture<void>(Future<void>.delayed(d), (_) => body(),
        tag: tag ?? 'timer($d)');
  }

  Future<R> run() async {
    if (_arms.isEmpty) {
      throw StateError('Select.any requires at least one arm');
    }

    final c = Completer<R>();
    final cancels = <void Function()>[];
    bool resolved = false;

    void registerCanceller(void Function() f) => cancels.add(f);

    void resolve(int index, Object? tag, R result) {
      if (resolved) return;
      resolved = true;
      for (final cancel in cancels) {
        try {
          cancel();
        } catch (_) {}
      }
      if (!c.isCompleted) c.complete(result);
    }

    for (var i = 0; i < _arms.length; i++) {
      _arms[i].attach(
        resolve: resolve,
        registerCanceller: registerCanceller,
        index: i,
      );
    }
    return c.future;
  }
}
