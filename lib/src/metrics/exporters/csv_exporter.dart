part of '../exporters.dart';

final class CsvExporter extends MetricsExporter {
  CsvExporter({this.sink});

  final StringSink? sink;

  bool _printedHeader = false;

  @override
  void exportSnapshot(GlobalMetrics gm) {
    _writeHeaderIfNeeded();

    _writeln([
      gm.ts.toIso8601String(),
      'global',
      '', // id
      gm.sent, gm.recv, gm.dropped, gm.closed,
      gm.trySendOk, gm.trySendFail, gm.tryRecvOk, gm.tryRecvEmpty,
      '', '', '', // global latencies not computed
      '', '', '',
      '', '', // global rates not computed  
      '', '', '', // global drop/failure rates not computed
      gm.channels.length, // channel count
    ]);
  }

  @override
  void exportChannel(String id, ChannelSnapshot s) {
    _writeHeaderIfNeeded();

    final mops = s.recvOpsPerSec > 0 ? s.recvOpsPerSec / 1e6 : null;
    final nsPerOp = s.nsByOp > 0 ? s.nsByOp : null;

    _writeln([
      DateTime.now().toIso8601String(),
      'channel',
      id,
      s.sent,
      s.recv,
      s.dropped,
      s.closed,
      s.trySendOk,
      s.trySendFail,
      s.tryRecvOk,
      s.tryRecvEmpty,
      _fmtNum(s.sendP50),
      _fmtNum(s.sendP95),
      _fmtNum(s.sendP99),
      _fmtNum(s.recvP50),
      _fmtNum(s.recvP95),
      _fmtNum(s.recvP99),
      _fmtNum(mops),   
      _fmtNum(nsPerOp, 1),
      _fmtNum(s.dropRate, 4),
      _fmtNum(s.trySendFailureRate, 4), 
      _fmtNum(s.tryRecvEmptyRate, 4),
      '', // not a global snapshot
    ]);
  }

  // ---------- helpers ----------

  static String _esc(Object? v) {
    final s = v?.toString() ?? '';
    if (s.isEmpty) return '';
    final needQuotes = s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r');
    if (!needQuotes) return s;
    return '"${s.replaceAll('"', '""')}"';
  }

  static String? _fmtNum(num? v, [int frac = 3]) {
    if (v == null || !v.isFinite) return null;
    var s = v.toStringAsFixed(frac);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  void _writeHeaderIfNeeded() {
    if (_printedHeader) return;
    _printedHeader = true;
    _writeln([
      'ts',
      'type',
      'id',
      'sent',
      'recv',
      'dropped',
      'closed',
      'trySendOk',
      'trySendFail',
      'tryRecvOk',
      'tryRecvEmpty',
      'send_p50_ns',
      'send_p95_ns',
      'send_p99_ns',
      'recv_p50_ns',
      'recv_p95_ns',
      'recv_p99_ns',
      'mops',
      'ns_per_op',
      'drop_rate',
      'try_send_failure_rate',
      'try_recv_empty_rate',
      'channels_count',
    ]);
  }

  void _writeln(List<Object?> cols) {
    final line = cols.map(_esc).join(',');
    final out = sink;
    if (out != null) {
      out.writeln(line);
    } else {
      print(line);
    }
  }
}
