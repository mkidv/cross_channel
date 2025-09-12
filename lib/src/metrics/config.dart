import 'package:cross_channel/src/metrics/exporters.dart';

/// Global metrics configuration (lightweight singleton pattern).
///
/// Controls channel metrics collection and export behavior.
/// Use this to enable/disable metrics globally and configure sampling rates.
final class MetricsConfig {
  /// Master switch to enable/disable all metrics collection.
  static bool enabled = false;

  /// Whether to measure latencies for channel operations (tryRecv/recv/send).
  /// Latency sampling may have overhead but can be disabled if not needed.
  static bool sampleLatency = false;

  /// Sample rate for metrics collection (0.0 to 1.0).
  /// Example: 0.01 = 1% of operations are sampled.
  static double sampleRate = 0.01;

  /// Metrics exporter for processing collected metrics.
  /// Defaults to [NoopExporter] which discards all metrics.
  static MetricsExporter exporter = const NoopExporter();
}
