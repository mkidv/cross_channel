import 'dart:async';

/// A lightweight synchronization primitive for control-plane signaling.
///
/// [Notify] is perfect for coordination without data payloads. Unlike channels,
/// it doesn't carry values - just wake-up signals. Use it for configuration
/// changes, shutdown notifications, flush commands, and "check your state" signals.
///
/// ## Key Concepts
/// - **Permits**: Stored notifications that can be consumed immediately
/// - **Waiters**: Tasks waiting for notifications
/// - **notifyOne**: Wake one waiter or store one permit
/// - **notifyAll**: Wake all current waiters (doesn't store permits)
///
/// ## Usage Patterns
///
/// **Basic signaling:**
/// ```dart
/// final notify = Notify();
///
/// // Waiter
/// final (future, cancel) = notify.notified();
/// await future; // Waits until notified
///
/// // Notifier
/// notify.notifyOne(); // Wakes one waiter
/// ```
///
/// **Configuration reload pattern:**
/// ```dart
/// final configChanged = Notify();
///
/// // Worker listening for config changes
/// Future<void> worker() async {
///   while (!shutdown) {
///     final (notified, cancel) = configChanged.notified();
///
///     // Race between work and config changes
///     await XSelect.run((s) => s
///       ..onFuture(notified, (_) => 'config_changed')
///       ..onTick(Ticker.every(Duration(seconds: 1)), () => 'work')
///     );
///
///     reloadConfig();
///   }
/// }
///
/// // Trigger config reload
/// configChanged.notifyAll(); // Wake all workers
/// ```
///
/// **Shutdown coordination:**
/// ```dart
/// final shutdown = Notify();
///
/// // Graceful shutdown
/// Future<void> gracefulShutdown() async {
///   shutdown.notifyAll(); // Signal all workers
///   await Future.delayed(Duration(seconds: 5)); // Grace period
///   shutdown.close(); // Force remaining waiters to fail
/// }
/// ```
///
/// ## When to use Notify vs Channels
/// - **Use Notify for**: Config changes, shutdown signals, flush commands,
///   "wake up and check" notifications
/// - **Use Channels for**: Data processing, task queues, request/reply,
///   anything with payloads
class Notify {
  int _permits = 0;
  int _epoch = 0; // only for debug
  bool _closed = false;

  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// Debug counter that increments on each notification (for testing/debugging).
  int get epoch => _epoch;

  /// `true` if this [Notify] has been closed and will reject new waiters.
  bool get isDisconnected => _closed;

  /// Register to be notified, returning a future and cancellation function.
  ///
  /// If a permit is available, the future completes immediately and consumes
  /// one permit. Otherwise, registers a waiter until [notifyOne]/[notifyAll]
  /// is called or the operation is canceled.
  ///
  /// **Returns:**
  /// - `future`: Completes when notified or fails if canceled/closed
  /// - `cancel`: Function to cancel the notification (optional)
  ///
  /// **Example:**
  /// ```dart
  /// final (future, cancel) = notify.notified();
  ///
  /// // Option 1: Wait indefinitely
  /// await future;
  ///
  /// // Option 2: Cancel if taking too long
  /// Timer(Duration(seconds: 10), cancel);
  /// await future.catchError((e) => print('Canceled or timed out'));
  /// ```
  (Future<void>, void Function()) notified() {
    if (_closed) {
      return (Future<void>.error(StateError('Notify.disconnected')), () {});
    }
    if (_permits > 0) {
      _permits--;
      return (Future.value(), () {});
    }
    final c = Completer<void>();
    _waiters.add(c);
    void cancel() {
      if (!c.isCompleted) {
        _waiters.remove(c);
        c.completeError(StateError('Notify.canceled'));
      }
    }

    return (c.future, cancel);
  }

  /// Wake up exactly one waiter, or store one permit if no waiters.
  ///
  /// If there are waiting tasks, wakes the first one. If no tasks are waiting,
  /// stores a permit that will be consumed by the next [notified] call.
  ///
  /// **Use cases:**
  /// - Single resource became available
  /// - One-time configuration change
  /// - Single task completion notification
  ///
  /// **Example:**
  /// ```dart
  /// // Resource pool - notify when one resource is free
  /// void releaseResource() {
  ///   returnResourceToPool();
  ///   resourceAvailable.notifyOne(); // Wake one waiting task
  /// }
  /// ```
  void notifyOne() {
    if (_closed) return;
    _epoch++;
    for (var i = 0; i < _waiters.length; i++) {
      final c = _waiters.removeAt(0);
      if (!c.isCompleted) {
        c.complete();
        return;
      }
    }
    _permits++;
  }

  /// Wake up all currently waiting tasks (does not store permits).
  ///
  /// Immediately wakes all tasks currently waiting on [notified].
  /// Unlike [notifyOne], this does not store permits for future waiters.
  ///
  /// **Use cases:**
  /// - Broadcast shutdown signal
  /// - Configuration reload for all workers
  /// - "Check your state" broadcast
  ///
  /// **Example:**
  /// ```dart
  /// // Graceful shutdown - wake all workers
  /// void initiateShutdown() {
  ///   shutdownFlag.notifyAll(); // All workers check shutdown state
  /// }
  /// ```
  void notifyAll() {
    if (_closed) return;
    _epoch++;
    while (_waiters.isNotEmpty) {
      final c = _waiters.removeLast();
      if (!c.isCompleted) c.complete();
    }
  }

  void notifyN(int n) {
    if (_closed || n <= 0) return;
    _epoch += n;
    while (n-- > 0 && _waiters.isNotEmpty) {
      final c = _waiters.removeAt(0);
      if (!c.isCompleted) c.complete();
    }
    if (n > 0) _permits += n;
  }

  Future<void> notifiedTimeout(Duration d) {
    final (fut, cancel) = notified();
    return fut.timeout(d, onTimeout: () {
      cancel();
      throw TimeoutException('Notify.wait timed out after $d');
    });
  }

  /// Close this [Notify] and fail all current and future waiters.
  ///
  /// All currently waiting tasks will fail with [StateError], and any
  /// future calls to [notified] will return a failed future.
  ///
  /// **Example:**
  /// ```dart
  /// // Force shutdown after grace period
  /// Future<void> forceShutdown() async {
  ///   await Future.delayed(Duration(seconds: 30)); // Grace period
  ///   shutdownNotify.close(); // Force all remaining waiters to fail
  /// }
  /// ```
  void close() {
    if (_closed) return;
    _closed = true;
    while (_waiters.isNotEmpty) {
      final c = _waiters.removeLast();
      if (!c.isCompleted) {
        c.completeError(StateError('Notify.disconnected'));
      }
    }
  }
}
