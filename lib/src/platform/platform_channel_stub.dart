import 'package:cross_channel/src/platform/platform_channel.dart';

PlatformReceiver createPlatformReceiver() =>
    throw UnimplementedError('Platform not supported');

Object packPlatformPort(PlatformPort port) =>
    throw UnsupportedError('Platform not supported');

PlatformPort unpackPlatformPort(Object raw) =>
    throw UnsupportedError('Platform not supported');
