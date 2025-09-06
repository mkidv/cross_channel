import 'dart:async';

import 'package:cross_channel/cross_channel.dart';
import 'package:cross_channel/src/core.dart';

typedef Canceller = void Function();
typedef RegisterCanceller = void Function(Canceller);
typedef Resolve<R> = FutureOr<void> Function(
  int index,
  Object? tag,
  FutureOr<R> result,
);

/// Contract for a selectable branch: attach to a source and call `resolve` when it fires.
/// Returns `true` if it resolved *synchronously* during attach (only possible for Arm.immediate).
abstract class _Branch<R> {
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  });
}

/// Small ADT representing either an immediate value or a pending future with a canceller.
/// Use this to model sources that may have a fast-path (e.g. tryPop) for sync selection.
sealed class Arm<T> {
  const Arm();
  factory Arm.immediate(T value) = _ArmImmediate<T>;
  factory Arm.pending(Future<T> future, Canceller cancel) = _ArmPending<T>;
}

class _ArmImmediate<T> implements Arm<T> {
  const _ArmImmediate(this.value);
  final T value;
}

class _ArmPending<T> implements Arm<T> {
  const _ArmPending(this.future, this.cancel);
  final Future<T> future;
  final Canceller cancel;
}

class _FutureBranch<T, R> implements _Branch<R> {
  const _FutureBranch(this.future, this.body, {this.tag});

  final Future<T> future;
  final FutureOr<R> Function(T) body;
  final Object? tag;

  @override
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  }) {
    var canceled = false;
    void cancel() => canceled = true;
    registerCanceller(cancel);

    future.then((u) {
      if (canceled) return;
      try {
        resolve(index, tag, body(u));
      } catch (e, st) {
        Zone.current.handleUncaughtError(e, st);
      }
    }, onError: (Object e, StackTrace? st) {
      if (canceled) return;
      resolve(index, tag, Future<R>.error(e, st));
    });
    return false;
  }
}

class _StreamBranch<T, R> implements _Branch<R> {
  const _StreamBranch(this.stream, this.body, {this.tag});

  final Stream<T> stream;
  final FutureOr<R> Function(T) body;
  final Object? tag;

  @override
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  }) {
    var canceled = false;
    StreamSubscription<T>? sub;

    void cancel() {
      canceled = true;
      sub?.cancel();
      sub = null;
    }

    registerCanceller(cancel);
    sub = stream.listen((u) {
      if (canceled) return;
      resolve(index, tag, body(u));
    }, onError: (Object e, StackTrace? st) {
      if (canceled) return;
      resolve(index, tag, Future<R>.error(e, st));
    }, onDone: () {
      cancel();
    }, cancelOnError: false);

    return false;
  }
}

class _TimerBranch<R> implements _Branch<R> {
  const _TimerBranch(this.delay, this.body, {this.tag});

  final Duration delay;
  final FutureOr<R> Function() body;
  final Object? tag;

  @override
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  }) {
    final t = Timer(delay, () => resolve(index, tag, body()));
    registerCanceller(() {
      if (t.isActive) t.cancel();
    });
    return false;
  }
}

class ArmBranch<T, R> implements _Branch<R> {
  const ArmBranch(this.armFactory, this.body, {this.tag});

  final Arm<T> Function() armFactory;
  final FutureOr<R> Function(T) body;
  final Object? tag;

  @override
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  }) {
    final a = armFactory();
    switch (a) {
      case _ArmImmediate<T>():
        resolve(index, tag, body(a.value));
        return true;
      case _ArmPending<T>():
        registerCanceller(a.cancel);
        a.future.then((u) {
          resolve(index, tag, body(u));
        }, onError: (Object e, StackTrace? st) {
          resolve(index, tag, Future<R>.error(e, st));
        });
        return false;
    }
  }
}

class _ReceiverBranch<T, R> implements _Branch<R> {
  const _ReceiverBranch(this.rx, this.body, {this.tag});

  final Receiver<T> rx;
  final FutureOr<R> Function(RecvResult<T>) body;
  final Object? tag;

  @override
  bool attach({
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
    required int index,
  }) {
    final (fut, cancel) = rx.recvCancelable();
    registerCanceller(cancel);
    fut.then((res) {
      if (res is RecvErrorCanceled) return;
      resolve(index, tag, body(res));
    }, onError: (Object e, StackTrace? st) {
      if (e is RecvErrorCanceled) return;
      resolve(index, tag, Future<R>.error(e, st));
    });
    return false;
  }
}

/// Lightweight, composable selector for Futures, Streams, Timers, and channels.
class XSelect {
  /// Build-and-run an async selection. First branch to resolve wins; the rest are canceled.
  /// Optionally adds a global timeout and/or fairness rotation (default).
  static Future<R> run<R>(
    void Function(SelectBuilder<R> b) build, {
    Duration? timeout,
    FutureOr<R> Function()? onTimeout,
    bool ordered = false,
  }) {
    final b = SelectBuilder<R>();
    build(b);
    if (timeout != null && onTimeout != null) {
      b.timeout(timeout, onTimeout);
    }
    if (ordered) b.ordered();
    return b.run();
  }

  /// Non-blocking selection over *immediate* arms only (e.g. `Arm.immediate`).
  /// Returns `null` if no arm can fire synchronously.
  static R? syncRun<R>(
    void Function(SelectBuilder<R> s) build, {
    bool ordered = false,
  }) {
    final b = SelectBuilder<R>();
    build(b);
    if (ordered) b.ordered();
    return b.syncRun();
  }

  /// Compose several builders into a single race. Useful to keep related branches grouped.
  static Future<R> race<R>(
    Iterable<void Function(SelectBuilder<R> b)> competitors, {
    Duration? timeout,
    FutureOr<R> Function()? onTimeout,
    bool ordered = false,
  }) =>
      run<R>((b) {
        for (final c in competitors) {
          c(b);
        }
      }, timeout: timeout, onTimeout: onTimeout, ordered: ordered);

  /// Synchronous variant of [race]. Returns immediately if any competitor exposes
  /// an `Arm.immediate`; otherwise returns `null` without subscribing.
  static R? syncRace<R>(
    Iterable<void Function(SelectBuilder<R> b)> competitors, {
    bool ordered = false,
  }) =>
      syncRun<R>((b) {
        for (final c in competitors) {
          c(b);
        }
      }, ordered: ordered);
}

class SelectBuilder<R> {
  final List<(_Branch<R> b, bool Function()? guard)> _branches = [];
  Duration? _timeout;
  FutureOr<R> Function()? _onTimeout;
  bool _ordered = false;

  SelectBuilder<R> onFuture<T>(Future<T> fut, FutureOr<R> Function(T) body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((_FutureBranch<T, R>(fut, body, tag: tag), if_));
    return this;
  }

  SelectBuilder<R> onStream<T>(Stream<T> stream, FutureOr<R> Function(T) body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((_StreamBranch<T, R>(stream, body, tag: tag), if_));
    return this;
  }

  SelectBuilder<R> onReceiver<T>(
      Receiver<T> rx, FutureOr<R> Function(RecvResult<T>) body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((_ReceiverBranch<T, R>(rx, body, tag: tag), if_));
    return this;
  }

  SelectBuilder<R> onDelay(Duration d, FutureOr<R> Function() body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((_TimerBranch<R>(d, body, tag: tag), if_));
    return this;
  }

  /// Generic "Arm" branch (enables sync selection & true immediacy).
  SelectBuilder<R> onArm<T>(
      Arm<T> Function() armFactory, FutureOr<R> Function(T) body,
      {Object? tag, bool Function()? if_}) {
    _branches.add((ArmBranch<T, R>(armFactory, body, tag: tag), if_));
    return this;
  }

  /// Ticking helper built on top of [Arm].
  SelectBuilder<R> onTick(
    Ticker ticker,
    FutureOr<R> Function() body, {
    Object? tag,
    bool Function()? if_,
  }) {
    return onArm<void>(() => ticker.arm(), (_) => body(), tag: tag, if_: if_);
  }

  /// Add a global timeout branch.
  SelectBuilder<R> timeout(Duration d, FutureOr<R> Function() body) {
    _timeout = d;
    _onTimeout = body;
    return this;
  }

  /// Preserve declaration order instead of applying fairness rotation.
  SelectBuilder<R> ordered() {
    _ordered = true;
    return this;
  }

  Future<R> run() {
    if (_branches.isEmpty) {
      throw StateError('Select requires at least one branch');
    }

    final completer = Completer<R>();
    final cancels = <Canceller>[];
    var resolved = false;

    void registerCanceller(Canceller c) => cancels.add(c);

    void resolve(int idx, Object? tag, FutureOr<R> res) {
      if (resolved) return;
      resolved = true;

      for (final cancel in cancels) {
        try {
          cancel();
        } catch (_) {}
      }

      Future.sync(() => res).then((v) {
        if (!completer.isCompleted) completer.complete(v);
      }).catchError((Object e, StackTrace? st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      });
    }

    // Apply optional guards
    final active = <_Branch<R>>[];
    for (final (b, guard) in _branches) {
      if (guard?.call() == false) continue;
      active.add(b);
    }

    if (active.isEmpty) {
      return Future.error(StateError('Select has no active branches'));
    }

    // Fairness: rotate starting offset unless ordered
    if (!_ordered && active.length > 1) {
      final n = active.length;
      final offset = DateTime.now().microsecondsSinceEpoch % n;
      if (offset != 0) {
        final rotated = <_Branch<R>>[
          ...active.skip(offset),
          ...active.take(offset),
        ];
        active
          ..clear()
          ..addAll(rotated);
      }
    }

    // Attach branches
    for (var i = 0; i < active.length; i++) {
      final immediate = active[i].attach(
        resolve: resolve,
        registerCanceller: registerCanceller,
        index: i,
      );
      if (immediate && resolved) return completer.future;
    }

    // Optional global timeout
    if (_timeout != null && _onTimeout != null) {
      final t = Timer(_timeout!, () => resolve(-1, 'timeout', _onTimeout!()));
      registerCanceller(() {
        if (t.isActive) t.cancel();
      });
    }

    return completer.future;
  }

  /// Synchronous fast-path over immediate arms only.
  R? syncRun() {
    if (_branches.isEmpty) {
      throw StateError('Select requires at least one branch');
    }

    for (final (b, guard) in _branches) {
      if (guard?.call() == false) continue;
      if (b is ArmBranch<dynamic, R>) {
        final a = b.armFactory();
        if (a is _ArmImmediate) {
          final v = (b.body)(a.value);
          // If the body returns a Future, this is not a true sync resolution.
          return v is Future ? null : v;
        }
      }
    }

    return null;
  }
}

/// Periodic ticker that exposes an `Arm<void>`:
/// - If `now >= nextAt` ⇒ `Arm.immediate` and `nextAt += period`.
/// - Otherwise ⇒ `Arm.pending` with a cancelable `Timer` until `nextAt`.
class Ticker {
  final Duration period;
  DateTime _nextAt;

  Ticker._(this.period, this._nextAt);

  /// Start a periodic ticker. By default the first tick is at `now + period`.
  factory Ticker.every(Duration period, {DateTime? startAt}) {
    final now = DateTime.now();
    return Ticker._(period, (startAt ?? now).add(period));
  }

  /// Return a selectable arm (immediate or pending).
  Arm<void> arm() {
    final now = DateTime.now();
    if (!now.isBefore(_nextAt)) {
      _nextAt = _nextAt.add(period);
      return Arm.immediate(null);
    }
    final delay = _nextAt.difference(now);
    final completer = Completer<void>();
    final t = Timer(delay, () {
      _nextAt = _nextAt.add(period);
      if (!completer.isCompleted) completer.complete();
    });
    return Arm.pending(completer.future, () {
      if (t.isActive) t.cancel();
    });
  }

  /// Reset the schedule (optional).
  void reset({DateTime? startAt}) {
    final now = DateTime.now();
    _nextAt = (startAt ?? now).add(period);
  }
}

extension SelectOnRecv<R> on SelectBuilder<R> {
  /// Convenience variant that maps the `RecvResult<T>` into value/disconnected cases.
  SelectBuilder<R> onRecvValue<T>(
    Receiver<T> rx,
    FutureOr<R> Function(T value) onValue, {
    FutureOr<R> Function()? onDisconnected,
    Object? tag,
    bool Function()? if_,
  }) {
    FutureOr<R> body(RecvResult<T> res) {
      if (res is RecvOk<T>) return onValue(res.valueOrNull as T);
      if (res is RecvErrorDisconnected) {
        if (onDisconnected != null) {
          return onDisconnected();
        }
      }
      return Future<R>.error(StateError('Unexpected RecvResult: $res'));
    }

    _branches.add(
      (_ReceiverBranch<T, R>(rx, body, tag: tag), () => !rx.isDisconnected),
    );

    return this;
  }
}
