import 'package:cross_channel/src/metrics/config.dart';
import 'package:cross_channel/src/metrics/core.dart';
import 'package:cross_channel/src/metrics/exporters.dart';
import 'package:cross_channel/src/metrics/p2.dart';
import 'package:cross_channel/src/metrics/recorders.dart';
import 'package:cross_channel/src/metrics/registry.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelMetrics', () {
    test('initial state and properties', () {
      final m = ChannelMetrics();
      expect(m.sent, 0);
      expect(m.recv, 0);
      expect(m.hasSent, isFalse);
      expect(m.hasRecv, isFalse);
    });

    test('markRecvNowNs and markSendNowNs', () {
      final m = ChannelMetrics();
      m.markRecvNowNs(100);
      expect(m.recvFirstNs, 100);
      expect(m.recvLastNs, 100);

      m.markRecvNowNs(200);
      expect(m.recvFirstNs, 100);
      expect(m.recvLastNs, 200);
      expect(m.recvDurationNs, 100);

      m.markSendNowNs(300);
      expect(m.sendFirstNs, 300);
      expect(m.sendLastNs, 300);

      m.markSendNowNs(450);
      expect(m.sendFirstNs, 300);
      expect(m.sendLastNs, 450);
      expect(m.sendDurationNs, 150);
    });
  });

  group('ChannelSnapshot', () {
    test('derived metrics', () {
      final snap = ChannelSnapshot(
        sent: 10,
        recv: 5,
        dropped: 2,
        trySendOk: 8,
        trySendFail: 2,
        tryRecvOk: 4,
        tryRecvEmpty: 1,
        recvFirstNs: 1000,
        recvLastNs: 2000,
        sendFirstNs: 1000,
        sendLastNs: 1500,
      );

      expect(snap.duration.inMicroseconds, 1); // 1000 ns
      expect(snap.nsByOp, 1000 / 5);
      expect(snap.recvOpsPerSec, 5 / (1000 / 1e9));
      expect(snap.sendOpsPerSec, 10 / (500 / 1e9));
      expect(snap.sendAvgLatency, 500 / 10);
      expect(snap.recvAvgLatency, 1000 / 5);
      expect(snap.trySendFailureRate, 2 / 10);
      expect(snap.tryRecvEmptyRate, 1 / 5);
      expect(snap.dropRate, 2 / 10);
    });

    test('merge averages/combines fields', () {
      final snap1 = ChannelSnapshot(
        sent: 10,
        recv: 5,
        sendP50: 100,
        recvFirstNs: 1000,
        recvLastNs: 2000,
      );
      final snap2 = ChannelSnapshot(
        sent: 5,
        recv: 10,
        sendP50: 200,
        recvFirstNs: 500,
        recvLastNs: 2500,
      );

      final merged = snap1.merge(snap2);
      expect(merged.sent, 15);
      expect(merged.recv, 15);
      expect(merged.sendP50, 150); // average
      expect(merged.recvFirstNs, 500); // min
      expect(merged.recvLastNs, 2500); // max
    });

    test('edge cases for division by zero', () {
      final zeroSnap = ChannelSnapshot();
      expect(zeroSnap.nsByOp, 0);
      expect(zeroSnap.recvOpsPerSec, 0);
      expect(zeroSnap.sendOpsPerSec, 0);
      expect(zeroSnap.sendAvgLatency, isNull);
      expect(zeroSnap.recvAvgLatency, isNull);
      expect(zeroSnap.trySendFailureRate, 0);
      expect(zeroSnap.tryRecvEmptyRate, 0);
      expect(zeroSnap.dropRate, 0);
    });
  });

  group('GlobalMetrics', () {
    test('aggregates channels correctly', () {
      final gm = GlobalMetrics(DateTime.now(), {
        'ch1': ChannelSnapshot(sent: 10, trySendOk: 5),
        'ch2': ChannelSnapshot(sent: 5, trySendOk: 5, trySendFail: 2),
      });

      expect(gm.sent, 15);
      expect(gm.trySendOk, 10);
      expect(gm.trySendFail, 2);
      expect(gm.recv, 0);
    });

    test('merge combines channels', () {
      final gm1 = GlobalMetrics(DateTime.now(), {
        'ch1': ChannelSnapshot(sent: 10),
      });
      final gm2 = GlobalMetrics(DateTime.now(), {
        'ch1': ChannelSnapshot(sent: 5),
        'ch2': ChannelSnapshot(sent: 20),
      });

      final merged = gm1.merge(gm2);
      expect(merged.channels.length, 2);
      expect(merged.channels['ch1']!.sent, 15);
      expect(merged.channels['ch2']!.sent, 20);
    });
  });

  group('MetricsRegistry', () {
    test('singleton behavior', () {
      final r1 = MetricsRegistry();
      final r2 = MetricsRegistry();
      expect(identical(r1, r2), isTrue);
    });

    test('attach creates and reuses ChannelMetrics', () {
      final reg = MetricsRegistry();
      final met1 = reg.attach('test1');
      final met2 = reg.attach('test1');
      expect(identical(met1, met2), isTrue);

      final met3 = reg.attach('test2');
      expect(identical(met1, met3), isFalse);
    });

    test('snapshot returns global metrics', () {
      final reg = MetricsRegistry();
      final m = reg.attach('snapshot_test');
      m.sent = 100;

      final snap = reg.snapshot();
      expect(snap.channels.containsKey('snapshot_test'), isTrue);
      expect(snap.channels['snapshot_test']!.sent, 100);
    });

    test('merge adds external metrics to snapshot', () {
      final reg = MetricsRegistry();
      final extMap = {'ext_ch': ChannelSnapshot(sent: 50)};
      final extGm = GlobalMetrics(DateTime.now(), extMap);

      MetricsConfig.enabled = true;
      reg.merge(extGm);

      final snap = reg.snapshot();
      expect(snap.channels['ext_ch']?.sent, 50);
    });

    test('export does not crash', () {
      final reg = MetricsRegistry();
      expect(reg.export, returnsNormally);
    });
  });

  group('P2Quantiles', () {
    test('initial state', () {
      final p2 = P2Quantiles([0.5, 0.9]);
      expect(p2.count, 0);
      expect(p2.isReady, isFalse);
      expect(p2.get(0.5), isNull);
    });

    test('bootstrap and single insert', () {
      final p2 = P2Quantiles([0.5]);
      p2.insert(10.0);
      expect(p2.count, 0); // Not ready yet, boot buffer has 1
      p2.insert(20.0);
      p2.insert(30.0);
      p2.insert(40.0);
      p2.insert(50.0);
      expect(p2.isReady, isTrue);
      expect(p2.count, 5); // 5 elements for [0.5] (0, 0.25, 0.5, 0.75, 1.0)

      p2.insert(60.0);
      expect(p2.count, 6);
    });

    test('p50 estimation', () {
      final p2 = P2Quantiles([0.5]);
      for (var i = 1; i <= 100; i++) {
        p2.insert(i.toDouble());
      }
      expect(p2.p50, closeTo(50.0, 5.0)); // Approximative
    });

    test('reset', () {
      final p2 = P2Quantiles([0.5]);
      p2.insert(10.0);
      p2.reset();
      expect(p2.count, 0);
      expect(p2.isReady, isFalse);
    });

    test('quantile and interpolation', () {
      final p2 = P2Quantiles([0.5, 0.9]);
      for (var i = 1; i <= 100; i++) {
        p2.insert(i.toDouble());
      }
      expect(p2.quantile(0.9, interpolate: false), isNotNull);
      expect(p2.quantile(0.75), isNotNull);
      expect(p2.quantile(0.75, interpolate: false), isNotNull);
    });

    test('invalid inserts', () {
      final p2 = P2Quantiles([0.5]);
      p2.insert(double.nan);
      p2.insert(double.infinity);
      expect(p2.count, 0);
    });
  });

  group('ActiveMetricsRecorder', () {
    test('records events correctly', () {
      final m = ChannelMetrics();
      final recorder = ActiveMetricsRecorder(m);

      recorder.markWakeOne();
      expect(m.wakeOne, 1);

      recorder.markWakeAll();
      expect(m.wakeAll, 1);

      recorder.markDropOldest();
      expect(m.dropOldest, 1);

      recorder.markDropNewest();
      expect(m.dropNewest, 1);

      recorder.markDropBlockTimeout();
      expect(m.dropBlockTimeout, 1);

      recorder.markClosed();
      expect(m.closed, 1);

      recorder.trySendFail();
      expect(m.trySendFail, 1);

      recorder.tryRecvEmpty();
      expect(m.tryRecvEmpty, 1);
    });

    test('records latency when t0 > 0', () {
      final m = ChannelMetrics();
      final recorder = ActiveMetricsRecorder(m);

      // We can't easily mock _nowNs, but we can verify it doesn't crash
      // and updates the structures.
      recorder.sendOk(100);
      expect(m.sent, 1);
      expect(m.sendLastNs, greaterThan(0));

      recorder.recvOk(100);
      expect(m.recv, 1);
      expect(m.recvLastNs, greaterThan(0));

      recorder.trySendOk(100);
      expect(m.trySendOk, 1);

      recorder.tryRecvOk(100);
      expect(m.tryRecvOk, 1);
    });

    test('sample rate', () {
      // By default MetricsConfig.sampleLatency is often true in tests but depends on env
      // We just ensure startRecvTimer and startSendTimer return int
      final m = ChannelMetrics();
      final recorder = ActiveMetricsRecorder(m);

      final t1 = recorder.startSendTimer();
      expect(t1, isA<int>());

      final t2 = recorder.startRecvTimer();
      expect(t2, isA<int>());
    });
  });

  group('StdExporter', () {
    test('exportSnapshot and exportChannel do not crash', () {
      final exporter = StdExporter(useColor: false, compact: true);

      final snap = ChannelSnapshot(sent: 10, recv: 10);
      final gm = GlobalMetrics(DateTime.now(), {'ch1': snap});

      expect(() => exporter.exportSnapshot(gm), returnsNormally);
      expect(() => exporter.exportChannel('ch1', snap), returnsNormally);
    });
  });
}
