// Adapted from media_kit 1.2.6 screenshot semantics. Its MIT notice follows.
// Copyright (c) 2021 & onwards Hitesh Kumar Saini <saini123hitesh@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/native_library.dart';

Future<Uint8List?> capturePlayerScreenshot(
  Player player, {
  String? format = 'image/jpeg',
  bool includeLibassSubtitles = false,
}) async {
  final native = player.platform;
  if (native is! NativePlayer) {
    return player.screenshot(
      format: format,
      includeLibassSubtitles: includeLibassSubtitles,
    );
  }
  return NativePlayer.lock.synchronized(() async {
    if (format != null && format != 'image/jpeg' && format != 'image/png') {
      throw ArgumentError.value(
        format,
        'format',
        'Supported values are: image/jpeg, image/png, null',
      );
    }
    if (native.disposed) {
      throw AssertionError('[Player] has been disposed');
    }
    await native.waitForPlayerInitialization;
    await native.waitForVideoControllerInitializationIfAttached;
    // Hold the same lock until the worker has returned and freed its node.
    // A timeout must not release the lock while C still owns the player pointer.
    return compute(
      _capture,
      _CaptureRequest(
        native.ctx.address,
        NativeLibrary.path,
        format,
        includeLibassSubtitles,
      ),
    );
  });
}

class _CaptureRequest {
  const _CaptureRequest(this.ctx, this.library, this.format, this.subtitles);

  final int ctx;
  final String library;
  final String? format;
  final bool subtitles;
}

Uint8List? _capture(_CaptureRequest request) {
  final mpv = generated.MPV(DynamicLibrary.open(request.library));
  final ctx = Pointer<generated.mpv_handle>.fromAddress(request.ctx);
  final strings = ['screenshot-raw', request.subtitles ? 'subtitles' : 'video'];
  final allocations = <Pointer<Utf8>>[];
  Pointer<Pointer<Utf8>> args = nullptr;
  Pointer<generated.mpv_node> result = nullptr;
  var nodeOwned = false;
  try {
    result = calloc<generated.mpv_node>();
    args = calloc<Pointer<Utf8>>(strings.length + 1);
    for (var i = 0; i < strings.length; i++) {
      final value = strings[i].toNativeUtf8(allocator: calloc);
      allocations.add(value);
      args[i] = value;
    }
    args[strings.length] = nullptr;
    final status = mpv.mpv_command_ret(ctx, args.cast(), result);
    if (status < 0) return null;
    nodeOwned = true;
    if (result.ref.format != generated.mpv_format.MPV_FORMAT_NODE_MAP) {
      return null;
    }
    final map = result.ref.u.list;
    if (map == nullptr || map.ref.num < 0 ||
        map.ref.keys == nullptr || map.ref.values == nullptr) {
      return null;
    }
    int? width, height, stride, dataSize;
    String? pixelFormat;
    Pointer<Uint8> data = nullptr;
    for (var i = 0; i < map.ref.num; i++) {
      final keyPointer = map.ref.keys[i];
      if (keyPointer == nullptr) return null;
      final key = keyPointer.cast<Utf8>().toDartString();
      final value = map.ref.values[i];
      if (value.format == generated.mpv_format.MPV_FORMAT_INT64) {
        switch (key) {
          case 'w': width = value.u.int64; break;
          case 'h': height = value.u.int64; break;
          case 'stride': stride = value.u.int64; break;
        }
      } else if (key == 'format' &&
          value.format == generated.mpv_format.MPV_FORMAT_STRING) {
        final text = value.u.string;
        if (text != nullptr) pixelFormat = text.cast<Utf8>().toDartString();
      } else if (key == 'data' &&
          value.format == generated.mpv_format.MPV_FORMAT_BYTE_ARRAY) {
        final bytes = value.u.ba;
        if (bytes != nullptr) {
          data = bytes.ref.data.cast<Uint8>();
          dataSize = bytes.ref.size;
        }
      }
    }
    if (width == null || height == null || stride == null || dataSize == null ||
        width <= 0 || height <= 0 || stride <= 0 || dataSize <= 0 ||
        width > stride ~/ 4 || height > dataSize ~/ stride || data == nullptr ||
        (pixelFormat != 'bgr0' && pixelFormat != 'bgra')) {
      return null;
    }
    // The division checks above avoid overflow when validating native bounds.
    final bytes = data.asTypedList(dataSize);
    if (request.format == null) return Uint8List.fromList(bytes);
    final pixels = image.Image(width: width, height: height, numChannels: 3);
    for (final pixel in pixels) {
      final offset = pixel.y * stride + pixel.x * 4;
      pixel.b = bytes[offset];
      pixel.g = bytes[offset + 1];
      pixel.r = bytes[offset + 2];
    }
    return request.format == 'image/png'
        ? image.encodePng(pixels)
        : image.encodeJpg(pixels);
  } finally {
    try {
      // client.h requires this only when the command has succeeded.
      if (nodeOwned) mpv.mpv_free_node_contents(result);
    } finally {
      for (final allocation in allocations) {
        calloc.free(allocation);
      }
      if (args != nullptr) calloc.free(args);
      if (result != nullptr) calloc.free(result);
    }
  }
}
