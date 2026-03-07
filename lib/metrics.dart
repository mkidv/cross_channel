/// Advanced metrics system for monitoring channel performance.
///
/// This module provides comprehensive metrics collection and export capabilities
/// for channel operations. Use this for production monitoring, performance
/// profiling, and observability in high-throughput applications.
///
/// ## Usage Patterns
///
/// ```dart
/// import 'package:cross_channel/cross_channel.dart';
/// import 'package:cross_channel/metrics.dart';
///
/// Future<void> main() async {
///   // 1. Enable metrics globally
///   MetricsConfig.enabled = true;
///   MetricsConfig.sampleLatency = true;
///
///   // 2. Configure exporter (Standard output)
///   MetricsConfig.exporter = StdExporter();
///
///   // 3. Create channels with metrics
///   final (tx, rx) = XChannel.mpsc<String>(
///     capacity: 100,
///     metricsId: 'data_pipeline',
///   );
///
///   // 4. Metrics collected automatically
///   await tx.send('performance data');
///   await rx.recv();
///
///   // 5. Access snapshots (advanced)
///   final snapshot = MetricsRegistry().snapshot();
///   print('Total messages: ${snapshot.sent}');
/// }
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
