class Stats {
  final String name;
  final int iters;
  final Duration elapsed;
  final int maxLatencyNs;
  final String? notes;
  Stats(this.name, this.iters, this.elapsed, this.maxLatencyNs, {this.notes});

  @override
  String toString() {
    final ns = elapsed.inMicroseconds * 1000;
    final nsPerOp = ns / iters;
    final opsPerSec = iters / (elapsed.inMicroseconds / 1e6);
    final mops = opsPerSec / 1e6;
    final maxUs = maxLatencyNs / 1000.0;

    return '${name.padRight(50)}'
        '${mops.toStringAsFixed(2)} Mops/s   '
        '${nsPerOp.toStringAsFixed(1)} ns/op   '
        'max recv latency ~ ${maxUs.toStringAsFixed(1)} µs'
        '${notes != null ? '\n${''.padLeft(50)}${notes!}' : ''}';
  }

  String toCsv({
    required String suite,
    String? caseName,
  }) {
    final ns = elapsed.inMicroseconds * 1000;
    final nsPerOp = ns / iters;
    final opsPerSec = iters / (elapsed.inMicroseconds / 1e6);
    final mops = opsPerSec / 1e6;
    final maxUs = maxLatencyNs / 1000.0;

    final caseLabel = caseName ?? name;

    return '$suite,"$caseLabel",${mops.toStringAsFixed(2)},'
        '${nsPerOp.toStringAsFixed(1)},${maxUs.toStringAsFixed(1)}';
  }
}

(int iters, bool csv, bool experimental) parseArgs(List<String> args) {
  final iters =
      args.isNotEmpty && !args[0].contains('--') ? int.parse(args[0]) : 500_000;
  var csv = false;
  var exp = false;
  for (final a in args) {
    if (a.startsWith('--csv')) csv = true;
    if (a.startsWith('--exp')) exp = true;
  }

  return (iters, csv, exp);
}

extension IntBytesX on int {
  String bytesToPrettyString() {
    if (this < 1024) return '${this}B';
    if (this < 1024 * 1024) return '${(this / 1024).toStringAsFixed(1)}KB';
    return '${(this / (1024 * 1024)).toStringAsFixed(2)}MB';
  }
}
