part of '../branches.dart';

/// SelectBranch implementation for timer-based operations.
///
/// Supports both one-shot delays and periodic timers with catch-up logic
/// to prevent drift when ticks are delayed.
class TimerBranch<R> implements SelectBranch<R> {
  TimerBranch.once(this.delay, this.body, {this.tag})
      : period = null,
        periodic = false,
        _nextAt = DateTime.now().add(delay!);

  TimerBranch.period(this.period, this.body, {this.tag, DateTime? startAt})
      : delay = null,
        periodic = true,
        _nextAt = (startAt ?? DateTime.now()).add(period!);

  DateTime? _nextAt;
  final Duration? delay;
  final Duration? period;
  final bool periodic;
  final FutureOr<R> Function() body;
  final Object? tag;

  @override
  bool attachSync({
    required int index,
    required Resolve<R> resolve,
  }) {
    final now = DateTime.now();

    if (periodic) {
      if (!now.isBefore(_nextAt!)) {
        _nextAt = _advanceNextAt(now);
        resolve(index, tag, body());
        return true;
      }
    } else {
      if (!now.isBefore(_nextAt!)) {
        _nextAt = null;
        resolve(index, tag, body());
        return true;
      }
    }
    return false;
  }

  @override
  void attach({
    required int index,
    required Resolve<R> resolve,
    required RegisterCanceller registerCanceller,
  }) {
    if (periodic) {
      bool cancelled = false;
      Timer? t;

      void scheduleNext() {
        if (cancelled) return;
        final now = DateTime.now();
        final dueAt = _futureNextAt(now);
        final delay = dueAt.difference(now);
        t = Timer(delay, () {
          if (cancelled) return;
          _nextAt = _advanceNextAt(DateTime.now());
          resolve(index, tag, body());
          scheduleNext();
        });
      }

      scheduleNext();
      registerCanceller(() {
        cancelled = true;
        t?.cancel();
      });
    } else {
      final target = _nextAt;
      if (target == null) return;
      final now = DateTime.now();
      final delta = target.difference(now);
      final delay = delta.isNegative ? Duration.zero : delta;
      final t = Timer(delay, () {
        _nextAt = null;
        resolve(index, tag, body());
      });
      registerCanceller(() {
        if (t.isActive) t.cancel();
      });
    }
  }

  DateTime _advanceNextAt(DateTime now) {
    var next = _nextAt!;
    final p = period!;
    if (!now.isBefore(next)) {
      final delta = now.difference(next);
      final jumps = delta.isNegative || p == Duration.zero
          ? 0
          : (delta.inMicroseconds ~/ p.inMicroseconds) + 1;
      next = next.add(Duration(microseconds: jumps * p.inMicroseconds));
    }
    return next;
  }

  DateTime _futureNextAt(DateTime now) {
    var next = _nextAt!;
    final p = period!;
    if (!now.isBefore(next)) {
      final delta = now.difference(next);
      final jumps = (delta.inMicroseconds ~/ p.inMicroseconds) + 1;
      next = next.add(Duration(microseconds: jumps * p.inMicroseconds));
    }
    return next;
  }
}
