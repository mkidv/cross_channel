import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:cross_channel/src/platform/platform_channel.dart';
import 'package:web/web.dart' as web;

PlatformReceiver createPlatformReceiver() => _WebMessageReceiver();

/// A PlatformReceiver backed by a MessageChannel (or a single MessagePort).
class _WebMessageReceiver implements PlatformReceiver {
  final web.MessageChannel _channel;

  _WebMessageReceiver() : _channel = web.MessageChannel();

  // On Web, the "sendPort" equivalent is the other end of the MessageChannel.
  // We give away port2 to be sent to remote contexts.
  @override
  PlatformPort get sendPort => _WebPort(_channel.port2);

  // We listen on port1 locally.
  @override
  late final Stream<Object?> messages = _createMessageStream(_channel.port1);

  @override
  void close() {
    _channel.port1.close();
    _channel.port2.close();
  }
}

Stream<Object?> _createMessageStream(web.MessagePort port) {
  // We can use a StreamController that listens to 'onmessage'
  final controller = StreamController<Object?>();

  port.start();

  port.onmessage = ((web.MessageEvent e) {
    // Dartify the data coming back
    controller.add(e.data.dartify());
  }).toJS;

  // Handle onmessageerror if needed
  controller.onCancel = () {
    port.close();
  };

  return controller.stream;
}

class _WebPort implements PlatformPort {
  final web.MessagePort _port;

  _WebPort(this._port);

  @override
  void send(Object? message) {
    final transferList = <JSObject>[];
    final jsMessage = _prepareMessage(message, transferList);

    // Use the raw postMessage with transfer list
    _port.postMessage(jsMessage, transferList.toJS);
  }

  /// Recursively walks the message to find nested _WebPort objects.
  /// Unwraps the underlying MessagePort and adds it to the transfer list.
  /// Returns the jsify-ready object.
  JSAny? _prepareMessage(Object? message, List<JSObject> transferList) {
    if (message == null) return null;

    if (message is _WebPort) {
      transferList.add(message._port);
      return message._port;
    }

    if (message is List) {
      final length = message.length;
      // Define efficient array creation if possible, or use literal
      final arr = JSArray();
      for (var i = 0; i < length; i++) {
        arr.setProperty(i.toJS, _prepareMessage(message[i], transferList));
      }
      return arr;
    }

    if (message is Map) {
      final obj = JSObject();
      for (final entry in message.entries) {
        final key = entry.key;
        // Optimization: assume string keys for max speed in "anywhere" context
        // if not string, toString().
        obj.setProperty(
            key.toString().toJS, _prepareMessage(entry.value, transferList));
      }
      return obj;
    }

    return message.jsify();
  }
}
