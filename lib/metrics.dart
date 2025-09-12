/// Advanced metrics system for monitoring channel performance.
///
/// This module provides comprehensive metrics collection and export capabilities
/// for channel operations. Use this for production monitoring, performance
/// profiling, and observability in high-throughput applications.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:cross_channel/metrics.dart';
///
/// // Enable metrics globally
/// MetricsConfig.enabled = true;
/// MetricsConfig.sampleLatency = true;
/// MetricsConfig.sampleRate = 0.1; // 10% sampling
///
/// // Configure exporter
/// MetricsConfig.exporter = StdExporter();
///
/// // Create channels with metrics
/// final (tx, rx) = XChannel.mpsc<String>(capacity: 1000);
///
/// // Metrics are collected automatically
/// await tx.send('data');
/// final result = await rx.recv();
/// ```
///
/// ## Available Exporters
///
/// - [NoopExporter] - Default, discards all metrics
/// - [StdExporter] - Prints metrics to stdout with configurable intervals
/// - [CsvExporter] - Exports metrics to CSV format (file or custom sink)
///
/// ## Custom Exporters
///
/// ```dart
/// class MyExporter extends MetricsExporter {
///   @override
///   void exportSnapshot(GlobalMetrics gm) {
///     // Process global metrics
///   }
///
///   @override
///   void exportChannel(String id, ChannelSnapshot snap) {
///     // Process per-channel metrics
///   }
/// }
///
/// MetricsConfig.exporter = MyExporter();
/// ```
///
/// ## Performance Impact
///
/// - **Disabled**: unmeasured
/// - **Enabled**: unmeasured
/// - **Latency sampling**: unmeasured
///
/// ## Metrics Available
///
/// **Channel Operations:**
/// - `sent`, `recv` - Total operation counts
/// - `dropped`, `closed` - Loss and lifecycle events
/// - `trySendOk/Fail`, `tryRecvOk/Empty` - Non-blocking operation results
///
/// **Latency Quantiles (P² algorithm):**
/// - `sendP50`, `sendP95`, `sendP99` - Send operation latencies
/// - `recvP50`, `recvP95`, `recvP99` - Receive operation latencies
///
/// **Performance Metrics:**
/// - `mops` - Million operations per second
/// - `ns_per_op` - Nanoseconds per operation
/// - `drop_rate` - Percentage of dropped messages
///
/// This is an advanced feature - most users should start with the main
/// `cross_channel` import for basic channel usage.
library;

export 'src/metrics.dart';
