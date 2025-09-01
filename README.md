# cross_channel

Fast & flexible channels for Dart/Flutter.  
Rust-style concurrency primitives: **MPSC, MPMC, SPSC, OneShot**, plus **drop policies**, **latest-only**, **select**, stream/isolate/web adapters.

<p align="center">
  <b>Bench-tested</b> · <code>~1.7–1.8 Mops/s</code> for classic queues · <code>~84–87 Mops/s</code> for LatestOnly
</p>

---

## 🚦 Choosing a channel

| Channel        | Producers | Consumers                          | Use case                           | Notes                              |
| -------------- | --------- | ---------------------------------- | ---------------------------------- | ---------------------------------- |
| **MPSC**       | multi     | single                             | Task queue, async pipeline         | Backpressure & drop policies       |
| **MPMC**       | multi     | multi                              | Work-sharing worker pool           | Consumers _compete_ (no broadcast) |
| **SPSC**       | single    | single                             | Ultra-low-latency hot path         | Lock-free ring (pow2 capacity)     |
| **OneShot**    | 1         | 1 (or many)                        | Request/response, once-only signal | `consumeOnce` option               |
| **LatestOnly** | multi     | single (MPSC) / competitive (MPMC) | Progress, sensors, UI signals      | Always coalesces to last value     |

---

## ✨ Features

- **Drop policies**: `block`, `oldest`, `newest`
- **LatestOnly** buffers (coalesce to last)
- **Select** over Futures, Streams, Receivers & Timers
- **Backpressure** with bounded queues; **rendezvous** (`capacity=0`)
- **Stream adapters**: `toBroadcastStream`, `redirectToSender`
- **Isolate/Web adapters**: request/reply, `ReceivePort` / `MessagePort` bridges
- **Battle-tested**: unit + stress tests, micro-benchmarks included

---

## 📦 Install

```bash
dart pub add cross_channel
```

---

## 🧭 API surface (high-level)

```dart
final (tx, rx) = XChannel.mpsc<T>(capacity: 1024, dropPolicy: DropPolicy.block);
final (tx, rx) = XChannel.mpmc<T>(capacity: 1024, dropPolicy: DropPolicy.oldest);
final (tx, rx) = XChannel.mpscLatest<T>();   // MPSC latest-only
final (tx, rx) = XChannel.mpmcLatest<T>();   // MPMC latest-only (competitive)
final (tx, rx) = XChannel.spsc<T>(capacityPow2: 1024);
final (tx, rx) = XChannel.oneshot<T>(consumeOnce: false);
```

Low-level flavors are available in `mpsc.dart`, `mpmc.dart`, `spsc.dart`, `oneshot.dart`.

```dart
import 'package:cross_channel/mpsc.dart';
final (tx, rx) = Mpsc.unbounded<T>();
final (tx, rx) = Mpsc.bounded<T>(capacity: 1024);
final (tx, rx) = Mpsc.channel<T>(capacity: 1024, dropPolicy: DropPolicy.oldest, onDrop: (d) {});
final (tx, rx) = Mpsc.latest<T>();

import 'package:cross_channel/mpmc.dart';
final (tx, rx) = Mpmc.unbounded<T>();
final (tx, rx) = Mpmc.bounded<T>(capacity: 1024);
final (tx, rx) = Mpmc.channel<T>(capacity: 1024, dropPolicy: DropPolicy.oldest, onDrop: (d) {});
final (tx, rx) = Mpmc.latest<T>();

import 'package:cross_channel/spsc.dart';
final (tx, rx) = Spsc.channel<T>(capacityPow2: 1024);  // power-of-two

import 'package:cross_channel/oneshot.dart';
final (tx, rx) = OneShot.channel<T>(consumeOnce: false);
```

Interop available in `isolate_extension.dart`, `stream_extension.dart`, `web_extension.dart`.
Core traits & buffers available in `src/*`.

---

## 💡 Quick examples

### MPSC with backpressure

```dart
import 'package:cross_channel/cross_channel.dart';

Future<void> producer(MpscSender tx) async {
  for (var i = 0; i < 100; i++) {
    await tx.send(i); // waits if queue is full
  }
  tx.close();
}

Future<void> consumer(MpscReceiver rx) async {
  await for (final v in rx.stream()) {
    // handle v
  }
}

void main() {
  final (tx, rx) = XChannel.mpsc<int>(capacity: 8);
  Future.wait([producer(tx), consumer(rx)])
}
```

### MPMC worker pool (competitive consumption)

```dart
import 'package:cross_channel/cross_channel.dart';

Future<void> worker(int id, MpmcReceiver<String> rx) async {
  await for (final task in rx.stream()) {
    // process task
  }
}

void main() async {
  final (tx, rx0) = XChannel.mpmc<String>(capacity: 16);
  final rx1 = rx0.clone();
  final rx2 = rx0.clone();

  final w0 = worker(0, rx0);
  final w1 = worker(1, rx1);
  final w2 = worker(2, rx2);

  for (var i = 0; i < 20; i++) {
    await tx.send('task $i');
  }
  tx.close();

  await Future.wait([w0, w1, w2]);
}
```

### LatestOnly signal (coalesced progress)

```dart
import 'package:cross_channel/cross_channel.dart';

Future<void> ui(MpscReceiver rx) async {
  await for (final p in rx.stream()) {
    // update progress bar with p in [0..1]
  }
}

void main() async {
  final (tx, rx) = XChannel.mpscLatest<double>();

  final _ = ui(rx);
  for (var i = 0; i <= 100; i++) {
    tx.trySend(i / 100); // overwrites previous value
    await Future.delayed(const Duration(milliseconds: 10));
  }
  tx.close();
}
```

---

### Sliding queues (drop policies)

```dart
final (tx, rx) = XChannel.mpsc<int>(
  capacity: 1024,
  dropPolicy: DropPolicy.oldest, // or DropPolicy.newest
  onDrop: (d) => print('dropped $d'),
);
```

- `oldest`: evicts the oldest queued item to make room (keeps newest data flowing)
- `newest`: drops the incoming item (send “looks ok” but value discarded)
- `block`: default (producer waits when full)

---

### OneShot (single vs multi observe)

```dart
// consumeOnce = true: first receiver consumes, then disconnects
final (stx, srx) = XChannel.oneshot<String>(consumeOnce: true);

// consumeOnce = false: every receiver sees the same value (until higher-level teardown)
final (btx, brx) = XChannel.oneshot<String>(consumeOnce: false);
```

---

## 🧰 Select (futures/streams/receivers/timers)

`select` lets you race multiple asynchronous branch and cancel the losers.

```dart
import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  final (tx, rx) = XChannel.mpsc<int>(capacity: 8);

  // Example: first event wins among a stream, a channel, a timer, and a future.
  final result = await Select.any<String>((s) => s
    .onStream<int>(
      Stream.periodic(const Duration(milliseconds: 50), (i) => i),
      (i) async => 'stream:$i',
      tag: 'S',
    )
    .onReceiver<int>(
      rx,
      ok: (v) async => 'recv:$v',
      empty: () async => 'empty',             // if tryRecv() would be empty at attach time
      disconnected: () async => 'disconnected',
      tag: 'R',
    )
    .onTimer(const Duration(milliseconds: 120), () async => 'timer', tag: 'T')
    .onFuture<String>(
      Future<String>.delayed(const Duration(milliseconds: 80), () => 'future'),
      (s) async => s,
      tag: 'F',
    )
  ).run();

  print('winner -> $result');
}
```

Notes:

- Receivers that implement `KeepAliveReceiver` use cancelable waits internally.
- If you pass a non-keepalive `Receiver`, `Select` falls back to a non-cancelable `recv` (still safe, just not interruptible).
- The builder returns the _first resolved_ branch and cancels the rest.

---

## 🔗 Interop

### Stream

```dart
import 'package:cross_channel/stream_extension.dart';

// Receiver → broadcast Stream (pause/resume when no listeners)
final broadcast = rx.toBroadcastStream(
  waitForListeners: true,
  stopWhenNoListeners: true,
  closeReceiverOnDone: false,
);

// Stream → Sender (optional drop on full; auto-close sender on done)
await someStream.redirectToSender(tx, dropWhenFull: true);
```

### Isolates

```dart
import 'dart:isolate';
import 'package:cross_channel/isolate_extension.dart';

// Typed request/reply
final reply = await someSendPort.request<Map<String, Object?>>(
  'get_user',
  data: {'id': 42},
  timeout: const Duration(seconds: 3),
);

// Port → channel bridge
final rp = ReceivePort();
final (tx, rx) = rp.toMpsc<MyEvent>(capacity: 512, strict: true);
```

### Web

```dart
import 'package:web/web.dart';
import 'package:cross_channel/web_extension.dart';


final channel = MessageChannel();

// Typed request/reply
final res = await channel.port1.request<String>('ping');

// Port → channel bridge
final (tx, rx) = channel.port2.toMpmc<JsEvent>(capacity: 512, strict: true);

```

---

## 🧩 Results & helpers

```dart
// SendResult: SendOk | SendErrorFull | SendErrorDisconnected
// RecvResult: RecvOk(value) | RecvErrorEmpty | RecvErrorDisconnected

// Extensions:
r.ok; r.full; r.disconnected;       // on SendResult
res.ok; res.empty; res.disconnected; // on RecvResult
res.valueOrNull;

// Timeouts/batching/draining:
await tx.sendTimeout(v, const Duration(milliseconds: 10));
await tx.sendAll(iterable);     // waits on full
tx.trySendAll(iterable);        // best-effort

rx.tryRecvAll(max: 128);        // burst non-blocking drain
await rx.recvAll(idle: Duration(milliseconds: 1), max: 1024);

// Cancelable receive (KeepAliveReceiver only):
final (fut, cancel) = rx.recvCancelable();
cancel(); // attempts to abort the wait if still pending
```

Streams: Receiver.stream() is single-subscription. Clone receivers for parallel consumers on MPMC.

---

## 📊 Benchmarks (Dart VM, i7-8550U, High priority, CPU affinity set)

### MPSC

```
ping-pong cap=1 (1P/1C)          1.73 Mops/s   577.7 ns/op
pipeline cap=1024 (1P/1C)        1.73 Mops/s   578.4 ns/op
pipeline unbounded (1P/1C)       1.72 Mops/s   580.2 ns/op
multi-producers x4 cap=1024      1.30 Mops/s   768.4 ns/op
rendezvous cap=0 (1P/1C)         1.73 Mops/s   578.2 ns/op
sliding=oldest cap=1024          16.12 Mops/s   62.0 ns/op
sliding=newest cap=1024          31.82 Mops/s   31.4 ns/op
latestOnly (coalesce)            83.99 Mops/s   11.9 ns/op
```

### MPMC

```
ping-pong cap=1 (1P/1C)          1.74 Mops/s   573.4 ns/op
pipeline cap=1024 (1P/1C)        1.74 Mops/s   574.6 ns/op
pipeline unbounded (1P/1C)       1.75 Mops/s   571.6 ns/op
producers x4 cap=1024 (1C)       1.32 Mops/s   757.6 ns/op
producers x4 / consumers x4      1.70 Mops/s   587.3 ns/op
rendezvous cap=0                 1.75 Mops/s   570.3 ns/op
sliding=oldest cap=1024          15.47 Mops/s   64.6 ns/op
sliding=newest cap=1024          31.69 Mops/s   31.6 ns/op
latestOnly (1P/1C)               87.31 Mops/s   11.5 ns/op
latestOnly (1P/4C competitive)   83.65 Mops/s   12.0 ns/op
```

### SPSC (ring)

```
ping-pong pow2=1024              1.80 Mops/s   555.4 ns/op
pipeline pow2=1024               1.82 Mops/s   549.1 ns/op
pipeline pow2=4096               1.81 Mops/s   552.2 ns/op
```

### OneShot

```
create+send+recv                 2.40 Mops/s   417.2 ns/op
reuse sender (new rx)            2.30 Mops/s   434.8 ns/op
```

### Inter-isolate baselines

```
SendPort ping-pong (int)         0.20 Mops/s   5110 ns/op
Uint8List roundtrip (16 KB)      0.05 Mops/s   19992.5 ns/op
raw event drain (int)            2.35 Mops/s   426.4 ns/op
isolate request echo             0.04 Mops/s   25768.5 ns/op
isolate event drain              0.61 Mops/s   1636.9 ns/op
```

- Numbers are **single-isolate** micro-benchmarks.
- Pinning affinity/priority helps stabilize latencies.

---

⚙️ Implementation notes (what you get)

- Buffers: `UnboundedBuffer`, `BoundedBuffer`, `RendezvousBuffer`, `LatestOnlyBuffer`, `SpscRingBuffer`, `PromiseBuffer` (for OneShot)
- Policies: `PolicyBuffer<T>` wraps any buffer and applies `DropPolicy`
- Lifecycle: precise sender/receiver tracking, deterministic disconnect semantics
- Ops: fast path `try*`, slow path permits/waiters, cancelable receives
- Results: tiny sealed hierarchies + convenience extensions

---

## 🧪 Testing

This repo ships with comprehensive unit, stress and integration tests (isolate/web/stream).

```bash
dart test
```

---

## License

MIT
