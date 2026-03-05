/// Advanced metrics system for monitoring channel performance.
///
/// This module provides comprehensive metrics collection and export capabilities
/// for channel operations. Use this for production monitoring, performance
/// profiling, and observability in high-throughput applications.
///
/// ## Usage Patterns
///
/// {@tool snippet example/metrics_example.dart}
/// {@end-tool}
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
