# Changelog

---

## [Unreleased]

### Planned

- **Broadcast ring (pub-sub)** with per-subscriber cursors and lag detection.
- **Watch / State channel**: latest-only with optional `replay(1)` for late subscribers.
- **Cancellation scopes & tokens** integrated with `Select`.
- **Rate-limiting adapters** on senders/receivers: `throttle`, `debounce`, `window`.


---

## [0.8.2] – 2025-09-29

### Added

- **XChannel**
  - Add metricsId paremeter to `XChannel` factories

---

## [0.8.1] – 2025-09-12

### Fixed

- Performance claims in README

---

## [0.8.0] – 2025-09-12

### Added

- **XSelect**
  - **New branch types** (modularized under `src/branches/`):
    - `FutureBranch`, `StreamBranch`, `RecvBranch`, `TimerBranch` — each encapsulates its attach/attachSync logic.
    - `onNotify` and `onNotifyOnce` arms to integrate `Notify` into `XSelect`.
    - `onRecvValue` now accepts `onError` and `onDisconnected` callbacks for fine-grained handling.
  - **TimerBranch** improvements:
    - Support for both one-shot (`once`) and periodic (`period`) timers.
    - Catch-up logic ensures no drift when ticks are delayed.
  - **Synchronous fast-path**:
    - New `attachSync` method for branches.
    - `XSelect.run` probes branches synchronously before arming async listeners.
- **ChannelMetrics**: global metrics system for channels.
  - New `MetricsRecorder` interface (`ActiveMetricsRecorder` / `NoopMetricsRecorder`).
  - Configurable via `MetricsConfig` (enable/disable, sample rate, exporters).
  - Built-in exporters: `StdExporter`, `CsvExporter`, `NoopExporter`.
  - Quantiles computed via P² algorithm for p50/p95/p99 latency.

### Changed

- **XSelect**
  - **Refactored**:
    - Split monolithic branch implementations into dedicated classes (`FutureBranch`, `StreamBranch`, etc.).
    - Internal resolution now calls `attachSync` first (zero-latency when possible).
    - Fairness rotation preserved, `.ordered()` still available to disable it.
  - **Timeout handling**:
    - Renamed `timeout(duration, ...)` → `onTimeout(duration, ...)` for consistency with other branch APIs.
    - Implemented via `TimerBranch.once`.
- **Buffers**
  - Internal waiters now use `Completer.sync` for immediate resolution instead of scheduling via microtask
    (applies to **unbounded**, **bounded**, **chunked**, and **latestOnly**).

### Breaking

- **XSelect**
  - **Removed Ticker/Arm API**:
    - Old `Ticker.every` and `Arm<T>` types are gone.
    - Replace with `onTick(Duration, ...)` (periodic timers) or `onDelay(Duration, ...)` (one-shot).
  - **Internals**:
    - `_Branch`/`ArmBranch` types removed, replaced by `SelectBranch` interface.

### Migration guide (0.8 → 0.9)

```diff
- ..timeout(Duration(seconds: 5), () => 'fallback')
+ ..onTimeout(Duration(seconds: 5), () => 'fallback')

- ..onTick(Ticker.every(Duration(seconds: 1)), () => 'tick')
+ ..onTick(Duration(seconds: 1), () => 'tick')
```

---

## [0.7.3] – 2025-09-07

### Changed

- **Docs & inline comments:** extensive `///` API docs and usage examples across whole package

---

## [0.7.2] – 2025-09-07

### Added

- **XSelect**
  - Builder API:
    - New `onFutureValue`, `onFutureError`, `onStreamDone` — convenience variants.
    - New `onDelay` for single-shot timers.
    - New `onSend(sender, value, ...)` to race a send completion.
- **Docs & inline comments:** extensive `///` API docs and usage examples across whole package

### Changed

- **XSelect**
  - Fairness & ordering: default start-index rotation for fairness (prevents starvation); call `.ordered()` to preserve declaration order.
  - Cancellation: consistent loser cleanup (cancel timers/subs, ignore late futures); clearer error propagation (use of `Future.error` and `Zone`).

### Fixed

- Synchronous resolution path: if an `Arm.immediate` fires during `attach`, the selection resolves without over-subscribing other branches.

---

## [0.7.1] – 2025-09-06

### Fixed

- `pubspec.yaml`: expanded `description` to satisfy pub.dev length checks.

---

## [0.7.0] – 2025-09-06

### Breaking

- **Select → XSelect**
  - `Select.any(...)` **removed**. Use:
    - `XSelect.run<T>((b) => b ... )` — async, waits for first ready arm.
    - `XSelect.syncRun<T>((b) => b ... )` — **non-blocking**, returns immediately if an arm is ready.
    - `XSelect.race<T>([ (b) => b.onFuture(...), ... ])` — race multiple builders.
    - `XSelect.syncRace<T>([ ... ])` — non-blocking variant.
  - Builder API changes:
    - New `onRecvValue(rx, onValue, onDisconnected: ...)` when you only care about values.
    - New `onTick(Ticker, ...)` and `timeout(duration, ...)`.
    - `onStream`, `onFuture` kept (signatures aligned).
  - Loop control: `SelectDecision` **removed**. Just return the value you want from the winning arm. If you used `continueLoop/breakLoop`, return a `bool` instead and branch on it.
- **Property rename**
  - `Receiver.isClosed` → **`Receiver.isDisconnected`** (and it’s available on **all** receivers, not just closable ones).
- **Result helpers rename**
  - `SendResultX.isOk` → **`hasSend`**
  - `RecvResultX.isOk` → **`hasValue`**
  - (Others kept: `isFull`, `isDisconnected`, `isTimeout`, `isFailed`, `hasError`, `isEmpty`, `valueOrNull`.)
- **Low-level channel factory parameter rename**
  - `{Mpsc,Mpmc}.channel<T>(..., **dropPolicy**: ...)` → `{Mpsc,Mpmc}.channel<T>(..., **policy**: ...)`
  - `onDrop` unchanged.
- **SPSC constructor signature**
  - `Spsc.channel<T>(**capacityPow2:** 1024)` → `Spsc.channel<T>(1024)` (positional power-of-two).
- **MPMC send semantics clarified**
  - Sending with **no live receivers** now returns `SendErrorDisconnected` immediately (enforced consistently across bounded/unbounded).

### Added

- **Notify** primitive:

  - `notified()` → `(Future<void>, cancel)` that consumes a permit if available, otherwise waits.
  - `notifyOne()` wakes one waiter or stores a permit; `notifyAll()` wakes all current waiters.
  - `close()` wakes waiters with `disconnected`.
  - `epoch` for tracing/tests.

- **Uniform receiver capabilities**:
  - `recvCancelable()` on **all** receivers.
  - `isDisconnected` property available on **all** receivers.
- **Ticker**
  - `Ticker.every(Duration)` with `.reset(...)` to integrate timed arms via `onTick`.
- **Examples**
  - `example/` showcasing MPSC, MPMC, SPSC, OneShot, LatestOnly, and `XSelect`.

### Changed

- **Select integration**
  - `XSelect` now uses `recvCancelable()` under the hood for receivers; cancellation is best-effort where an implementation cannot immediately abort a pending wait.
- **Unbounded buffers**
  - Now **chunked** by default for throughput & GC friendliness:
    - Hot small ring + chunked overflow.
    - Tuned defaults (internal): `hot=8192`, `chunk=4096`, `rebalanceBatch=64`, `threshold=cap/16`, `gate=chunk/2`.
  - `Mpsc.unbounded` / `Mpmc.unbounded` accept `chunked: true|false` (default **true**).
- **LatestOnly**
  - Fast-path coalescing tightened; benches around ~110–140 Mops/s on common desktop VMs.
- Docs/README updated to `XSelect.*`, `policy` parameter, SPSC signature, **`isDisconnected`**, and universal `recvCancelable()`.

### Migration guide (0.6 → 0.7)

```diff

- while (!rx.isClosed) {
+ while (!rx.isDisconnected) {
    // ...
  }
```

```diff
- final out = await Select.any((s) => s
-   ..onReceiver(rx, ok: (v) => SelectDecision.breakLoop)
-   ..onFuture(fut, (_) => SelectDecision.continueLoop));

+ final broke = await XSelect.run<bool>((s) => s
+   ..onRecvValue(rx, (v) => true, onDisconnected: () => true)
+   ..onFuture(fut, (_) => false));
+ if (broke) break;
```

```diff
- final (tx, rx) = Mpmc.channel<int>(capacity: 1024, dropPolicy: DropPolicy.oldest);
+ final (tx, rx) = Mpmc.channel<int>(capacity: 1024, policy: DropPolicy.oldest);
```

```diff
- final (tx, rx) = Spsc.channel<int>(capacityPow2: 1024);
+ final (tx, rx) = Spsc.channel<int>(1024);
```

```diff
- if ((await tx.send(v)).isOk) { ... }
+ if ((await tx.send(v)).hasSend) { ... }
```

```diff
- final r = await rx.recv(); if (r.isOk) use(r.valueOrNull);
+ final r = await rx.recv(); if (r.hasValue) use(r.valueOrNull!);

```

---

## [0.6.0] – 2025-09-01

### Added

- **Select**:
  - `Select.any((s) => s.onReceiver(...).onFuture(...).onStream(...).onTimer(...))`
  - Each branch executes an async block, first to complete wins
  - Losing branch are properly cancelled (`recvCancelable`, stream cancel)
  - `SelectDecision` (`continueLoop` / `breakLoop`) for loop control
  - Added `removeRecvWaiter` to all buffers
  - New `recvCancelable` helper in `ChannelOps`

---

## [0.5.0] – 2025-08-31

### Added

- Timeout helpers:
  - `recvTimeout`, `sendTimeout`
- Batch helpers :
  - `sendAll`, `recvAll`, `trySendAll`, `tryRecvAll`

## [0.4.0] – 2025-08-30

---

### Added

- **LatestOnly channels**:
  - `Mpsc` and `Mpmc` `latestOnly`
- Semantics: new sends overwrite previous values

## [0.3.0] – 2025-08-29

### Added

- **Isolate adapters**:
  - `ReceivePort` → `Mpsc` / `Mpmc`
  - Typed request/reply via `SendPort.request`
- **Web adapters**:
  - `MessagePort` → `Mpsc` / `Mpmc`
  - Typed requests with `MessageChannel`
- **Stream adapters**:
  - `Receiver.toBroadcastStream`, `Stream.redirectToSender`

---

## [0.2.0] – 2025-08-27

### Added

- **SPSC ring buffer**:
  - Power-of-two capacity
  - Ultra-low overhead `trySend`, `tryRecv`
- **OneShot channel**:
  - `consumeOnce=true`: first receiver consumes and disconnects
  - `consumeOnce=false`: all receivers observe the same value
- Drop policies: `block`, `oldest`, `newest`
- Result extensions:
  - `SendResultX` (`ok`, `full`, `disconnected`)
  - `RecvResultX` (`ok`, `empty`, `disconnected`, `valueOrNull`)

---

## [0.1.0] – 2025-08-24

### Added

- **MPSC channels** (multi-producer, single-consumer)
  - `unbounded`, `bounded(capacity)`, `rendezvous(cap=0)`
- **MPMC channels** (multi-producer, multi-consumer)
  - `unbounded`, `bounded(capacity)`
- Core traits: `ChannelCore`, `ChannelOps`, `ChannelLifecycle`
