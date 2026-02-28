import 'package:cross_channel/src/platform/platform_channel.dart';
import 'package:cross_channel/src/platform/platform_channel_stub.dart'
    if (dart.library.io) 'platform_channel_io.dart'
    if (dart.library.js_interop) 'platform_channel_web.dart'; // Modern web

export 'platform_channel.dart';
//  if (dart.library.html) 'platform_channel_web.dart'; // Legacy web support

/// Creates a platform-specific receiver (ReceivePort on VM, Stream on Web).
PlatformReceiver createReceiver() => createPlatformReceiver();

/// Packs a [PlatformPort] into its raw transferable form.
///
/// On VM: returns the raw [SendPort] (auto-serialized by [Isolate.spawn]).
/// On Web: returns the raw [MessagePort] (must be in postMessage transfer list).
Object packPort(PlatformPort port) => packPlatformPort(port);

/// Unpacks a raw transferable object back into a [PlatformPort].
///
/// On VM: wraps a [SendPort]. On Web: wraps a [MessagePort].
PlatformPort unpackPort(Object raw) => unpackPlatformPort(raw);
