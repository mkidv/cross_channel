/// Channel types for unified platform integration API.
///
/// Used by platform extensions to specify which type of channel to create
/// when bridging from external systems (isolates, web workers, etc.).
enum ChannelType {
  /// Multi-producer, single-consumer channel.
  ///
  /// Perfect for task queues and event processing where multiple sources
  /// send data to a single consumer.
  mpsc,

  /// Multi-producer, multi-consumer channel.
  ///
  /// Perfect for work distribution where multiple producers send work
  /// and multiple consumers compete to process it (work-stealing pattern).
  mpmc,
}
