<p align="center">
  <a href="LICENSE">
    <img alt="License" src="https://img.shields.io/github/license/mkidv/cross_channel">
  </a>
  <a href="https://pub.dev/packages/cross_channel">
    <img alt="pub.dev" src="https://img.shields.io/pub/v/cross_channel?label=pub.dev">
  </a>
  <a href="https://pub.dev/packages/cross_channel/score">
    <img alt="pub points" src="https://img.shields.io/pub/points/cross_channel">
  </a>
  <a href="https://github.com/mkidv/cross_channel/actions">
    <img alt="CI" src="https://github.com/mkidv/cross_channel/actions/workflows/dart.yml/badge.svg">
  </a>
</p>

# cross_channel

Fast & flexible channels for Dart/Flutter.  
Rust-style concurrency primitives: **MPSC, MPMC, SPSC, OneShot**, plus **drop policies**, **latest-only**, **select**, stream/isolate/web adapters.

<p align="center">
  <b>Bench-tested</b> · <code>~1.7–1.9 Mops/s</code> for classic queues · <code>~130–140 Mops/s</code> for LatestOnly
</p>

## ✨ Features

- **Drop policies**: `block`, `oldest`, `newest`
- **LatestOnly** buffers (coalesce to last)
- **Select** over Futures, Streams, Receivers & Timers
- **Backpressure** with bounded queues; **rendezvous** (`capacity=0`)
- **Notify** primitive (lightweight wakeups: `notifyOne`, `notifyAll`, `notified`)
- **Stream adapters**: `toBroadcastStream`, `redirectToSender`
- **Isolate/Web adapters**: request/reply, `ReceivePort` / `MessagePort` bridges
- **Battle-tested**: unit + stress tests, micro-benchmarks included

## 📦 Install

```bash
dart pub add cross_channel
```

## 🧭 API

### High-Level (XChannel)

```dart
final (tx, rx) = XChannel.mpsc<T>(capacity: 1024, dropPolicy: DropPolicy.block);
final (tx, rx) = XChannel.mpmc<T>(capacity: 1024, dropPolicy: DropPolicy.oldest);
final (tx, rx) = XChannel.mpscLatest<T>(); // MPSC latest-only
final (tx, rx) = XChannel.mpmcLatest<T>(); // MPMC latest-only (competitive)
final (tx, rx) = XChannel.spsc<int>(capacity: 1024); // pow2 rounded internally
final (tx, rx) = XChannel.oneshot<T>(consumeOnce: false);
```

### Low-Level

Low-level flavors are available in `mpsc.dart`, `mpmc.dart`, `spsc.dart`, `oneshot.dart`.

```dart
import 'package:cross_channel/mpsc.dart';
final (tx, rx) = Mpsc.unbounded<T>(); // chunked=true (default)
final (tx, rx) = Mpsc.unbounded<T>(chunked: false); // simple unbounded
final (tx, rx) = Mpsc.bounded<T>( 1024);
final (tx, rx) = Mpsc.channel<T>(capacity: 1024, dropPolicy: DropPolicy.oldest, onDrop: (d) {});
final (tx, rx) = Mpsc.latest<T>();

import 'package:cross_channel/mpmc.dart';
final (tx, rx) = Mpmc.unbounded<T>(); // chunked=true (default)
final (tx, rx) = Mpmc.unbounded<T>(chunked: false); // simple unbounded
final (tx, rx) = Mpmc.bounded<T>(1024);
final (tx, rx) = Mpmc.channel<T>(capacity: 1024, dropPolicy: DropPolicy.oldest, onDrop: (d) {});
final (tx, rx) = Mpmc.latest<T>();

import 'package:cross_channel/spsc.dart';
final (tx, rx) = Spsc.channel<T>(1024); // pow2 rounded internally

import 'package:cross_channel/oneshot.dart';
final (tx, rx) = OneShot.channel<T>(consumeOnce: false);
```

### Note

- Unbounded channels use chunked buffer by default (hot ring and chunked overflow)
  - Defaults: hot=8192, chunk=4096, rebalanceBatch=64, threshold=cap/16, gate=chunk/2.
- Streams are single-subscription. Clone receivers for parallel consumers on MPMC.
- Interop available in `isolate_extension.dart`, `stream_extension.dart`, `web_extension.dart`.
- Core traits & buffers available in `src/*`.

## 🚦 Choosing a channel

| Channel        | Producers | Consumers                          | Use case                           | Notes                              |
| -------------- | --------- | ---------------------------------- | ---------------------------------- | ---------------------------------- |
| **MPSC**       | multi     | single                             | Task queue, async pipeline         | Backpressure & drop policies       |
| **MPMC**       | multi     | multi                              | Work-sharing worker pool           | Consumers _compete_ (no broadcast) |
| **SPSC**       | single    | single                             | Ultra-low-latency hot path         | Lock-free ring (pow2 capacity)     |
| **OneShot**    | 1         | 1 (or many)                        | Request/response, once-only signal | `consumeOnce` option               |
| **LatestOnly** | multi     | single (MPSC) / competitive (MPMC) | Progress, sensors, UI signals      | Always coalesces to last value     |

### When to use Notify vs channels

- Use **Notify** for control-plane wakeups without payloads:
  config-changed, flush, shutdown, “poke a waiter”, etc.
  (notifyOne / notifyAll; waiter calls notified() and awaits.)
- Use **channels** for data-plane messages with payloads and ordering:
  tasks, jobs, progress values, events to be processed, etc.

## 💡 Quick examples

### MPSC with backpressure

```dart
import 'package:cross_channel/cross_channel.dart';

Future<void> producer(MpscSender<int> tx) async {
  for (var i = 0; i < 100; i++) {
    await tx.send(i); // waits if queue is full
  }
  tx.close();
}

Future<void> consumer(MpscReceiver<int> rx) async {
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

Future<void> ui(MpscReceiver<double> rx) async {
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

### OneShot (single vs multi observe)

```dart
// consumeOnce = true: first receiver consumes, then disconnects
final (stx, srx) = XChannel.oneshot<String>(consumeOnce: true);

// consumeOnce = false: every receiver sees the same value (until higher-level teardown)
final (btx, brx) = XChannel.oneshot<String>(consumeOnce: false);
```

## 🔔 Notify (lightweight wakeups)

A tiny synchronization primitive to signal tasks without passing data.

- `notified()` → returns a `(Future<void>, cancel)` pair.
  - If a permit is available, it completes immediately and **consumes** one permit.
  - Otherwise it registers a waiter until notified or canceled.
- `notifyOne()` → wakes **one** waiter or stores **one** permit if none is waiting.
- `notifyAll()` → wakes **all** current waiters (does **not** store permits).
- `close()` → wakes everyone with `disconnected`.
- Integrates with `XSelect` via `onFuture`.

```dart
import 'package:cross_channel/cross_channel.dart';

final n = Notify();

// Waiter
final (f, cancel) = n.notified();
// ... later: cancel();  // optional

// Notifiers
n.notifyOne(); // or
n.notifyAll();

// With XSelect
final (fu, _) = n.notified();
await XSelect.run<void>((s) => s
  ..onFuture<void>(fu, (_) => null, tag: 'notify')
  ..onTick(Ticker.every(const Duration(seconds: 1)), () => null, tag: 'tick')
);
```

## 🧰 Select (futures/streams/receivers/timers)

`XSelect` lets you race multiple asynchronous branches and cancel the losers.

```dart
import 'package:cross_channel/cross_channel.dart';

Future<void> main() async {
  final (tx, rx) = XChannel.mpsc<int>(capacity: 8);

  // Example: first event wins among a stream, a channel, a timer, and a future.
  final result = await XSelect.run<String>((s) => s
    ..onStream<int>(
      Stream.periodic(const Duration(milliseconds: 50), (i) => i),
      (i) => 'stream:$i',
      tag: 'S',
    )
    // simple
    ..onRecvValue<int>(
      rx,
      (v) => 'recv:$v',
      onDisconnected: () => 'disconnected',
      tag: 'R',
    )
    // full control over RecvResult
    ..onReceiver<int>(
      rx,
      (res) {
        if (res is RecvOk<int>) return 'recv:${res.value}';
        if (res is RecvErrorDisconnected) return 'disconnected';
        return 'unexpected:$res';
      },
      tag: 'R'?
    )
    ..onTick(
     Ticker.every(const Duration(milliseconds: 50)),
      () => 'timer',
      tag: 'T',
    )
    ..onFuture<String>(
      Future<String>.delayed(const Duration(milliseconds: 80), () => 'future'),
      (s) => s,
      tag: 'F',
    )
  );

  print('winner -> $result');
}
```

Notes:

- returns the _first resolved_ branch and cancels the rest.
- ordered = true forces order, otherwise we use fairness rotation
- `syncRun` only uses immediate arms, aka non blocking

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

## 🧩 Results & helpers

```dart
// SendResult: SendOk | SendErrorFull | SendErrorDisconnected
// RecvResult: RecvOk(value) | RecvErrorEmpty | RecvErrorDisconnected

// Extensions:

// SendResult
r.hasSend;
r.isFull;
r.isDisconnected;
r.isTimeout;
r.isFailed;
r.hasError;

// RecvResult
rr.hasValue;
rr.isEmpty;
rr.isDisconnected;
rr.isTimeout;
rr.isFailed;
rr.hasError;
rr.valueOrNull;

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

## 📊 Benchmarks (Dart VM, i7-8550U, High priority, CPU affinity set)

- Benches are **single-isolate** micro-benchmarks.
- Pinning affinity/priority helps stabilize latencies.

### MPSC

| case                              | Mops/s (median) | ns/op (median) | max us (median) |
| --------------------------------- | --------------: | -------------: | --------------: |
| ping-pong cap=1 (1P/1C)           |            1.87 |          535.7 |           177.0 |
| pipeline cap=1024 (1P/1C)         |            1.83 |          547.1 |           264.0 |
| pipeline unbounded (1P/1C)        |            1.83 |          546.5 |           269.0 |
| multi-producers x4 cap=1024       |            1.06 |          946.5 |         13907.0 |
| pipeline rendezvous cap=0 (1P/1C) |            1.68 |          593.8 |           150.0 |
| sliding=oldest cap=1024 (1P/1C)   |           24.19 |           41.3 |         41133.0 |
| sliding=newest cap=1024 (1P/1C)   |           55.25 |           18.1 |         17895.0 |
| latestOnly (coalesce) (1P/1C)     |          135.89 |            7.4 |          7353.0 |

### MPMC

| case                                      | Mops/s (median) | ns/op (median) | max us (median) |
| ----------------------------------------- | --------------: | -------------: | --------------: |
| ping-pong cap=1 (1P/1C)                   |            1.87 |          536.1 |           129.0 |
| pipeline cap=1024 (1P/1C)                 |            1.90 |          525.0 |           121.0 |
| pipeline unbounded (1P/1C)                |            1.87 |          534.1 |           233.0 |
| producers x4 cap=1024 (1C)                |            1.07 |          937.8 |         12581.0 |
| producers x4 / consumers x4 cap=1024      |            1.78 |          561.3 |            95.0 |
| pipeline rendezvous cap=0 (1P/1C)         |            1.72 |          580.1 |           126.0 |
| sliding=oldest cap=1024 (1P/1C)           |           24.24 |           41.3 |         41048.0 |
| sliding=newest cap=1024 (1P/1C)           |           54.14 |           18.5 |         18270.0 |
| latestOnly (coalesce) (1P/1C)             |          139.90 |            7.1 |          7143.0 |
| latestOnly (coalesce) (1P/4C competitive) |          125.00 |            8.0 |          7994.0 |

### SPSC

| case                             | Mops/s (median) | ns/op (median) | max us (median) |
| -------------------------------- | --------------: | -------------: | --------------: |
| spsc ping-pong pow2=1024 (1P/1C) |            1.76 |          569.8 |           108.0 |
| spsc pipeline pow2=1024 (1P/1C)  |            1.78 |          562.8 |            99.0 |
| spsc pipeline pow2=4096 (1P/1C)  |            1.80 |          555.3 |            92.0 |

### ONESHOT

| case                          | Mops/s (median) | ns/op (median) | max us (median) |
| ----------------------------- | --------------: | -------------: | --------------: |
| oneshot create+send+recv      |            2.62 |          381.7 |           146.0 |
| oneshot reuse sender (new rx) |            2.56 |          390.5 |            44.0 |

### INTER-ISOLATE

| case                                  | Mops/s (median) | ns/op (median) | max us (median) |
| ------------------------------------- | --------------: | -------------: | --------------: |
| SendPort roundtrip Uint8List (16.0KB) |            0.05 |        20665.0 |           199.0 |
| raw SendPort ping-pong (int)          |            0.20 |         5078.9 |          1334.0 |
| raw event drain (int)                 |            2.42 |          413.9 |             0.0 |

### ISOLATE

| case                 | Mops/s (median) | ns/op (median) | max us (median) |
| -------------------- | --------------: | -------------: | --------------: |
| isolate event drain  |            0.60 |         1675.8 |             0.0 |
| isolate request echo |            0.04 |        24088.7 |          1498.0 |

### How to bench

This repo ships with two PowerShell scripts to run the micro-benchmarks. They produce consistent, copy-pastable output and (optionally) a CSV for later analysis.

> Windows or PowerShell Core (`pwsh`) on macOS/Linux is fine.  
> For non-PowerShell usage, see the manual commands at the end.

#### **Lite** — fast dev loop

Compiles and runs once per target. No CSV, no CPU pinning, no priority tweaks.

```powershell
# All suites, 1e6 iterations per case
.\bench_lite.ps1 -Target all -Count 1000000

# Single suite
.\bench_lite.ps1 -Target mpsc -Count 1000000
```

#### **_Full_** — reproducible runs + CSV

Lets you set CPU affinity, process priority, repeat counts, and append results to a CSV.

```powershell
# Compile & Run, MPMC only, 5 repeats, High priority, CPU0,
# append CSV lines to bench\out.csv
.\bench_full.ps1 `
  -Target mpmc `
  -Action cr `
  -Count 1000000 `
  -Repeat 5 `
  -Priority High `
  -Affinity 0x1 `
  -Csv `
  -OutCsv "bench\out.csv" `
  -AppendCsv
```

Parameters (full mode):

- Target: spsc, mpsc, mpmc, oneshot, isolate, inter_isolate, all
- Action: compile (just build), run (run existing exes), cr (compile+run)
- Count: iterations per case (e.g., 1000000)
- Repeat: run the suite multiple times (e.g., -Repeat 5)
- Priority: Idle · BelowNormal · Normal · AboveNormal · High · RealTime
- Affinity: CPU bitmask (e.g., 0x1 = CPU0, 0x3 = CPU0–1)
- Csv: write results to CSV
- OutCsv: CSV path (default bench\out.csv)
- AppendCsv: append instead of overwriting the header

Stability tips: pin CPU with -Affinity, raise -Priority High, do a warm-up repeat, and keep the machine idle.

#### CSV format

Each benchmark prints lines like:

```csv
suite,case,mops,ns_per_op,max_latency_us,notes
MPMC,"pipeline cap=1024 (1P/1C)",1.91,524.5,51.0,
```

- suite: group (e.g., MPSC, MPMC, SPSC, ONESHOT, ISOLATE, INTER-ISOLATE)
- case: scenario description (e.g., pipeline cap=1024 (1P/1C))
- mops: million ops/sec (higher = better)
- ns_per_op: nanoseconds per op (lower = better)
- max_latency_us: max observed recv latency in microseconds (lower = better)
- notes: free text (often empty)

You can aggregate across repeats (median/mean/p95) in your own tooling.

## 🧪 Testing

This repo ships with comprehensive unit, stress and integration tests (isolate/web/stream).

```bash
dart test
```

## License

MIT
