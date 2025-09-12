/// P² multi-quantiles (Jain & Chlamtac, 1985)
/// Single sketch that tracks multiple quantiles by sharing markers.
final class P2Quantiles {
  /// Quantiles requested by the caller (e.g. [0.5, 0.95, 0.99]).
  final List<double> probs;

  // Cumulative probabilities for markers, sorted & deduplicated in [0, 1].
  late final List<double> _dn;
  // Marker heights (q), desired positions (np), and current positions (n).
  // We keep n as double for simpler arithmetic (C++ often uses int).
  late final List<double> _q;
  late final List<double> _np;
  late final List<double> _n;

  bool _ready = false;         // becomes true after bootstrap
  int _count = 0;              // number of ingested samples
  final List<double> _boot = <double>[]; // bootstrap buffer (first m samples)

  P2Quantiles(Iterable<double> ps)
      : probs = List<double>.from(ps, growable: false) {
    assert(probs.isNotEmpty, 'Probs is empty');
    for (final p in probs) {
      assert(p > 0.0 && p < 1.0, 'Each p must satisfy 0 < p < 1');
    }
    _initMarkerLayout();
  }

  /// Number of samples ingested.
  int get count => _count;

  /// Whether the sketch has completed bootstrap (i.e., has m samples).
  bool get isReady => _ready;

  /// Ingest a sample (ignores NaN/Inf).
  @pragma('vm:prefer-inline')
  void insert(double x) {
    if (!x.isFinite) return; // guard against NaN/Inf pollution
    if (!_ready) {
      _bootstrapInsert(x);
      return;
    }

    _count++;

    // B1) Locate cell k such that q[k] <= x < q[k+1], with endpoint fixes.
    final k = _locateCell(x);

    // B2) Advance positions: n[i]++ for i >= k+1, and np[i] += dn[i] for all.
    _advancePositions(k);

    // B3) Adjust interior markers (parabolic prediction with linear fallback).
    _adjustInteriorMarkers();
  }

  /// Return the exact marker value for a tracked quantile `p` if present.
  /// (i.e. the marker whose cumulative probability is closest to `p`).
  double? get(double p) {
    final idx = _nearestMarkerIndexForP(p);
    if (idx < 0 || !_ready) return null;
    return _q[idx];
  }

  /// Return the estimated quantile for an arbitrary `p` in (0,1).
  /// If `interpolate` is true, uses linear interpolation between nearest markers;
  /// otherwise returns the value at the nearest marker ("nearest" behavior).
  double? quantile(double p, {bool interpolate = true}) {
    if (!(p > 0.0 && p < 1.0) || !_ready) return null;
    if (!interpolate) return get(p);

    final (i0, i1) = _bracketForP(p);
    if (i0 == i1) return _q[i0];

    final p0 = _dn[i0], p1 = _dn[i1];
    final q0 = _q[i0], q1 = _q[i1];
    final denom = (p1 - p0).abs();
    if (denom < 1e-12) return q0;
    final t = (p - p0) / (p1 - p0);
    return q0 + t * (q1 - q0);
  }

  double? get p50 => get(0.5);
  double? get p90 => get(0.9);
  double? get p95 => get(0.95);
  double? get p99 => get(0.99);

  /// Reset the sketch to its initial (empty) state. Marker layout is preserved.
  void reset() {
    _ready = false;
    _count = 0;
    for (var i = 0; i < _q.length; i++) {
      _q[i] = 0.0;
      _n[i] = 0.0;
      _np[i] = (_q.length - 1) * _dn[i] + 1.0; // desired positions reset
    }
    _boot.clear();
  }

  // ---- Internal: layout, bootstrap, and update -------------------------------

  /// Build the marker layout:
  /// dn = {0, 1} union ⋃p{ p/2, p, (1+p)/2 }, sorted & deduplicated.
  void _initMarkerLayout() {
    final dnSet = <double>{0.0, 1.0};
    for (final p in probs) {
      dnSet.add(p);
      dnSet.add(p / 2.0);
      dnSet.add((1.0 + p) / 2.0);
    }
    final dn = dnSet.toList()..sort();
    _dn = <double>[];
    double? last;
    for (final v in dn) {
      // Numeric de-duplication with epsilon tolerance:
      if (last == null || (v - last).abs() > 1e-12) {
        _dn.add(v);
        last = v;
      }
    }

    final m = _dn.length;
    _q = List<double>.filled(m, 0.0);
    _n = List<double>.filled(m, 0.0);
    _np = List<double>.filled(m, 0.0);
    for (var i = 0; i < m; i++) {
      _np[i] = (m - 1) * _dn[i] + 1.0; // desired positions at init
    }
  }

  /// Bootstrap phase: collect the first m samples, sort them, and seed (q, n).
  void _bootstrapInsert(double x) {
    _boot.add(x);
    if (_boot.length < _q.length) return;

    _boot.sort();
    for (var i = 0; i < _q.length; i++) {
      _q[i] = _boot[i];
      _n[i] = (i + 1).toDouble(); // positions 1..m
    }
    _boot.clear();
    _ready = true;
    _count = _q.length;
  }

  /// Locate the cell index k such that q[k] <= x < q[k+1].
  /// Handles endpoint updates (min/max) as per P² algorithm.
  @pragma('vm:prefer-inline')
  int _locateCell(double x) {
    final last = _q.length - 1;
    if (x < _q[0]) {
      _q[0] = x;
      return 0;
    }
    if (x >= _q[last]) {
      _q[last] = x;
      return last - 1; // clamp so that (k+1) exists
    }
    var k = 0;
    // Linear scan is fine (m is small). Binary search is possible if needed.
    while (k + 1 < _q.length && x >= _q[k + 1]) {
      k++;
    }
    return k;
    // NB: ties resolve to the upper cell (x >= q[k+1]) which is consistent.
  }

  /// Advance current and desired positions (B2 step).
  @pragma('vm:prefer-inline')
  void _advancePositions(int k) {
    // n[i]++ for all i >= k+1
    for (var i = k + 1; i < _n.length; i++) {
      _n[i] += 1.0;
    }
    // np[i] += dn[i] for all i
    for (var i = 0; i < _np.length; i++) {
      _np[i] += _dn[i];
    }
  }

  /// Adjust interior markers (B3 step) using parabolic prediction with
  /// linear fallback, and clamping between neighbors.
  void _adjustInteriorMarkers() {
    for (var i = 1; i < _q.length - 1; i++) {
      final d = _np[i] - _n[i];
      if (!((d >= 1.0 && _n[i + 1] - _n[i] > 1.0) ||
          (d <= -1.0 && _n[i - 1] - _n[i] < -1.0))) {
        continue;
      }

      final s = d.sign; // +1.0 or -1.0 (0.0 shouldn't happen here)
      if (s == 0.0) continue;

      final qPar = _parabolic(i, s);
      double newQ;
      if (qPar != null && qPar.isFinite && qPar > _q[i - 1] && qPar < _q[i + 1]) {
        newQ = qPar;
      } else {
        newQ = _linear(i, s);
      }

      // Clamp to neighbors as a final safety.
      if (newQ < _q[i - 1]) newQ = _q[i - 1];
      if (newQ > _q[i + 1]) newQ = _q[i + 1];

      _q[i] = newQ;
      _n[i] += s;
    }
  }

  /// Parabolic prediction (Jain & Chlamtac).
  double? _parabolic(int i, double s) {
    final nPrev = _n[i - 1], nCur = _n[i], nNext = _n[i + 1];
    final qPrev = _q[i - 1], qCur = _q[i], qNext = _q[i + 1];
    final dn1 = nNext - nCur;
    final dn0 = nCur - nPrev;
    final denom = nNext - nPrev;
    if (dn1 == 0.0 || dn0 == 0.0 || denom == 0.0) return null;

    final num = (s * (nCur - nPrev + s) * (qNext - qCur) / dn1) +
        ((nNext - nCur - s) * (qCur - qPrev) / dn0);
    final qPar = qCur + (s * num) / denom;
    return qPar.isFinite ? qPar : null;
  }

  /// Linear fallback update.
  double _linear(int i, double s) {
    final idx = i + (s > 0 ? 1 : -1);
    final denom = _n[idx] - _n[i];
    if (denom == 0.0) return _q[i];
    return _q[i] + s * (_q[idx] - _q[i]) / denom;
  }

  /// Find nearest marker index for probability p (with epsilon tolerance).
  int _nearestMarkerIndexForP(double p) {
    if (!(p > 0.0 && p < 1.0)) return -1;
    var best = -1;
    var bestErr = double.infinity;
    for (var i = 0; i < _dn.length; i++) {
      final err = (_dn[i] - p).abs();
      if (err < bestErr) {
        bestErr = err;
        best = i;
      }
    }
    return best;
  }

  /// Find bracketing marker indices (i0, i1) such that dn[i0] <= p <= dn[i1].
  (int, int) _bracketForP(double p) {
    if (p <= _dn.first) return (0, 0);
    if (p >= _dn.last) return (_dn.length - 1, _dn.length - 1);
    var i = 0;
    while (i + 1 < _dn.length && _dn[i + 1] < p) {
      i++;
    }
    return (i, i + 1);
  }
}
