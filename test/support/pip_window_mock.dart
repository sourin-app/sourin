import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';

class WindowFailure {
  WindowFailure(this.key, this.occurrence, this.afterMutation);
  final String key;
  final int occurrence;
  final bool afterMutation;
}

/// Every window operation is a MethodChannel fixture, never a native window.
class PipWindowMock {
  Size size = const Size(1592, 904);
  Offset position = const Offset(73.25, 114.5);
  Size minimumSize = const Size(900, 600);
  bool alwaysOnTop = false;
  bool resizable = true;
  bool skipTaskbar = false;
  final calls = <Map<String, Object?>>[];
  final counts = <String, int>{};
  final failures = <WindowFailure>[];
  String? gateKey;
  Completer<void>? gateReached;
  Completer<void>? gateRelease;

  Map<String, Object?> snapshot() => {
    'size': [size.width, size.height],
    'position': [position.dx, position.dy],
    'minimumSize': [minimumSize.width, minimumSize.height],
    'alwaysOnTop': alwaysOnTop,
    'resizable': resizable,
    'skipTaskbar': skipTaskbar,
  };

  void failNext(String key, {int occurrence = 1, bool afterMutation = false}) {
    failures.add(
      WindowFailure(key, (counts[key] ?? 0) + occurrence, afterMutation),
    );
  }

  void blockNext(String key) {
    gateKey = key;
    gateReached = Completer<void>();
    gateRelease = Completer<void>();
  }

  void releaseGate() {
    if (gateRelease != null && !gateRelease!.isCompleted) {
      gateRelease!.complete();
    }
  }

  void clearFailures() => failures.clear();

  String keyFor(MethodCall call, Map<dynamic, dynamic> args) {
    switch (call.method) {
      case 'setBounds':
        return args.containsKey('width')
            ? 'setBounds:size'
            : 'setBounds:position';
      case 'setMinimumSize':
        return args['width'] == 0.0
            ? 'setMinimumSize:zero'
            : 'setMinimumSize:restore';
      case 'setResizable':
        return 'setResizable:${args['isResizable']}';
      case 'setAlwaysOnTop':
        return 'setAlwaysOnTop:${args['isAlwaysOnTop']}';
      case 'setSkipTaskbar':
        return 'setSkipTaskbar:${args['isSkipTaskbar']}';
      default:
        return call.method;
    }
  }

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments is Map
        ? call.arguments as Map
        : <Object?, Object?>{};
    final key = keyFor(call, args);
    final number = (counts[key] ?? 0) + 1;
    counts[key] = number;
    final log = <String, Object?>{
      'method': call.method,
      'key': key,
      'occurrence': number,
      'arguments': Map<Object?, Object?>.from(args),
      'before': snapshot(),
      'nativeWindowCall': false,
    };
    calls.add(log);
    if (gateKey == key) {
      gateKey = null;
      gateReached!.complete();
      await gateRelease!.future;
    }
    WindowFailure? failure;
    for (final item in failures) {
      if (item.key == key && item.occurrence == number) {
        failure = item;
        break;
      }
    }
    if (failure != null) failures.remove(failure);
    if (failure != null && !failure.afterMutation) {
      log['injectedFailure'] = 'before-mutation';
      throw PlatformException(
        code: 'explicit-window-fixture-failure',
        message: key,
      );
    }
    Object? result;
    switch (call.method) {
      case 'getBounds':
        result = {
          'x': position.dx,
          'y': position.dy,
          'width': size.width,
          'height': size.height,
        };
      case 'isAlwaysOnTop':
        result = alwaysOnTop;
      case 'isResizable':
        result = resizable;
      case 'isSkipTaskbar':
        result = skipTaskbar;
      case 'setBounds':
        if (args.containsKey('width')) {
          size = Size(
            math.max((args['width'] as num).toDouble(), minimumSize.width),
            math.max((args['height'] as num).toDouble(), minimumSize.height),
          );
        }
        if (args.containsKey('x')) {
          position = Offset(
            (args['x'] as num).toDouble(),
            (args['y'] as num).toDouble(),
          );
        }
      case 'setMinimumSize':
        minimumSize = Size(
          (args['width'] as num).toDouble(),
          (args['height'] as num).toDouble(),
        );
      case 'setAlwaysOnTop':
        alwaysOnTop = args['isAlwaysOnTop'] == true;
      case 'setResizable':
        resizable = args['isResizable'] == true;
      case 'setSkipTaskbar':
        skipTaskbar = args['isSkipTaskbar'] == true;
      default:
        throw StateError('Unexpected window fixture method: ${call.method}');
    }
    log['after'] = snapshot();
    if (failure != null) {
      log['injectedFailure'] = 'after-mutation';
      throw PlatformException(
        code: 'explicit-window-fixture-failure',
        message: key,
      );
    }
    return result;
  }

  void save(String name, Map<String, Object?> evidence) {
    final root = Platform.environment['PIP_FIXTURE_OUTPUT_ROOT'];
    if (root == null) return;
    Directory(root).createSync(recursive: true);
    File('$root/$name.json').writeAsStringSync(
      jsonEncode({
        'fixtureOnly': true,
        'realWindowCalls': 0,
        'guiStarted': false,
        'protectedOwnerOpened': false,
        ...evidence,
        'calls': calls,
      }),
      encoding: utf8,
    );
  }
}
