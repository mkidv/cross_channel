# Changelog

---

## [Unreleased]

### Planned

- **Broadcast ring** with lag detection
- **Watch** channel (coalescing last value)
- **Notify** primitive (wake one/all)

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

## [0.4.0] – 2025-09-30

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
