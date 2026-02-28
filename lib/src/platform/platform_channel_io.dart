import 'dart:async';
import 'dart:isolate';

import 'package:cross_channel/src/platform/platform_channel.dart';

PlatformReceiver createPlatformReceiver() => _IoReceiver();

/// Returns the raw [SendPort] (natively serializable by [Isolate.spawn]).
Object packPlatformPort(PlatformPort port) => (port as _IoPort)._sp;

/// Wraps a raw [SendPort] back into a [PlatformPort].
PlatformPort unpackPlatformPort(Object raw) => _IoPort(raw as SendPort);

class _IoReceiver implements PlatformReceiver {
  final _rp = ReceivePort();

  @override
  @pragma('vm:prefer-inline')
  PlatformPort get sendPort => _IoPort(_rp.sendPort);

  @override
  @pragma('vm:prefer-inline')
  Stream<Object?> get messages => _rp;

  @override
  @pragma('vm:prefer-inline')
  void close() => _rp.close();
}

class _IoPort implements PlatformPort {
  final SendPort _sp;
  _IoPort(this._sp);

  @override
  @pragma('vm:prefer-inline')
  void send(Object? message) => _sp.send(message);
}
