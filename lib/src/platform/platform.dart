import 'package:cross_channel/src/platform/platform_channel.dart';
import 'package:cross_channel/src/platform/platform_channel_stub.dart'
    if (dart.library.io) 'platform_channel_io.dart'
    if (dart.library.js_interop) 'platform_channel_web.dart'; // Modern web

export 'platform_channel.dart';
//  if (dart.library.html) 'platform_channel_web.dart'; // Legacy web support

/// Creates a platform-specific receiver (ReceivePort on VM, Stream on Web).
PlatformReceiver createReceiver() => createPlatformReceiver();
