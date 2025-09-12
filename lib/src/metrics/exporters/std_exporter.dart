part of '../exporters.dart';

final class StdExporter extends MetricsExporter {
  StdExporter({
    this.useColor = true,
    this.compact = false,
    this.width = 120,
  });

  final bool useColor;
  final bool compact;
  final int width;

  bool _printedChannelsHeader = false;
  bool _showTry = true;

  @override
  void exportSnapshot(GlobalMetrics gm) {
    _printedChannelsHeader = false;
    final sep = '─' * width;

    var sent = 0, recv = 0, dropped = 0, closed = 0;
    var tsOk = 0, tsFail = 0, trOk = 0, trEmpty = 0;
    for (final s in gm.channels.values) {
      sent += s.sent;
      recv += s.recv;
      dropped += s.dropped;
      closed += s.closed;
      tsOk += s.trySendOk;
      tsFail += s.trySendFail;
      trOk += s.tryRecvOk;
      trEmpty += s.tryRecvEmpty;
    }

    _showTry = !(tsOk == 0 && tsFail == 0 && trOk == 0 && trEmpty == 0);

    final title = _bold('GLOBAL ${gm.ts.toIso8601String()}', useColor);
    print('\n$title');
    print(_dim(sep, useColor));

    void row(String k, String v) => print('${_padR(k, 18)}  ${_padL(v, 12)}');
    row('Channels', _fmtInt(gm.channels.length));
    row('Sent', _fmtInt(sent));
    row('Recv', _fmtInt(recv));
    if (!compact) {
      row('Dropped', _fmtInt(dropped));
      row('Closed', _fmtInt(closed));
    }

    print(_dim(sep, useColor));
    _printChannelsHeader();
  }

  @override
  void exportChannel(String id, ChannelSnapshot s) {
    final idW = (width >= 140) ? 40 : (width >= 120 ? 30 : 20);
    final numW = 11, pairW = 18, latW = 10, rateW = 12;

    final cells = <String>[
      _cyan(_padR(_truncMid(id, idW), idW), useColor),
      _padL(_fmtInt(s.sent), numW),
      _padL(_fmtInt(s.recv), numW),
      if (_showTry) _padL(_fmtPair(s.trySendOk, s.trySendFail), pairW),
      if (_showTry) _padL(_fmtPair(s.tryRecvOk, s.tryRecvEmpty), pairW),
      _yellow(_padL(_fmtLatency(s.sendP50), latW), useColor),
      if (!compact) ...[
        _padL(_fmtLatency(s.sendP95), latW),
        _padL(_fmtLatency(s.sendP99), latW),
      ],
      _yellow(_padL(_fmtLatency(s.recvP50), latW), useColor),
      if (!compact) ...[
        _padL(_fmtLatency(s.recvP95), latW),
        _padL(_fmtLatency(s.recvP99), latW),
      ],
      _padL(
          s.recvOpsPerSec == 0
              ? '–'
              : '${_fmtFixed(s.recvOpsPerSec / 1e6, 2)} M',
          rateW),
      _padL(s.nsByOp == 0 ? '–' : _fmtFixed(s.nsByOp, 1), rateW),
    ];

    print(cells.join('  '));
  }

  void _printChannelsHeader() {
    if (_printedChannelsHeader) return;
    _printedChannelsHeader = true;

    final idW = (width >= 140) ? 40 : (width >= 120 ? 30 : 20);
    final numW = 11, pairW = 18, latW = 10, rateW = 12;

    final header = [
      _padR('channel', idW),
      _padL('sent', numW),
      _padL('recv', numW),
      if (_showTry) _padL('trySend', pairW),
      if (_showTry) _padL('tryRecv', pairW),
      _padL('send p50', latW),
      if (!compact) ...[
        _padL('p95', latW),
        _padL('p99', latW),
      ],
      _padL('recv p50', latW),
      if (!compact) ...[
        _padL('p95', latW),
        _padL('p99', latW),
      ],
      _padL('mops', rateW),
      _padL('ns/op', rateW),
    ].join('  ');

    print(_dim(header, useColor));
  }
}

String _fmtPair(int ok, int fail, {bool color = true}) {
  final okStr = _padL(_fmtInt(ok), 8);
  final failStr = _padL(_fmtInt(fail), 8);
  final left = color ? _green(okStr, true) : okStr;
  final right = color ? _red(failStr, true) : failStr;
  return '$left|$right';
}

String _fmtInt(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    final j = s.length - i;
    b.write(s[i]);
    if (j > 1 && j % 3 == 1) b.write('\u2009');
  }
  return b.toString();
}

String _fmtFixed(num v, int frac) {
  var s = v.toStringAsFixed(frac);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

String _fmtLatency(double? ns) {
  if (ns == null || !ns.isFinite) return '–';
  if (ns < 1e3) return '${_fmtFixed(ns, 0)}ns';
  if (ns < 1e6) return '${_fmtFixed(ns / 1e3, 1)}µs';
  if (ns < 1e9) return '${_fmtFixed(ns / 1e6, 3)}ms';
  return '${_fmtFixed(ns / 1e9, 3)}s';
}

int _visibleLen(String s) {
  final ansi = RegExp(r'\x1B\[[0-9;]*m');
  return s.replaceAll(ansi, '').runes.length;
}

String _padR(String s, int w) {
  final len = _visibleLen(s);
  if (len >= w) return s;
  return '$s${' ' * (w - len)}';
}

String _padL(String s, int w) {
  final len = _visibleLen(s);
  if (len >= w) return s;
  return '${' ' * (w - len)}$s';
}

String _truncMid(String s, int max) {
  final ansi = RegExp(r'\x1B\[[0-9;]*m');
  final raw = s.replaceAll(ansi, '');
  if (raw.length <= max) return s;
  if (max <= 1) return '…';
  final keep = max - 1;
  final head = (keep / 2).floor();
  final tail = keep - head;
  final t = '${raw.substring(0, head)}…${raw.substring(raw.length - tail)}';
  return t;
}

String _dim(String s, bool color) => color ? '\x1b[2m$s\x1b[0m' : s;
String _bold(String s, bool color) => color ? '\x1b[1m$s\x1b[0m' : s;
String _cyan(String s, bool color) => color ? '\x1b[36m$s\x1b[0m' : s;
String _green(String s, bool color) => color ? '\x1b[32m$s\x1b[0m' : s;
String _yellow(String s, bool color) => color ? '\x1b[33m$s\x1b[0m' : s;
String _red(String s, bool color) => color ? '\x1b[31m$s\x1b[0m' : s;
