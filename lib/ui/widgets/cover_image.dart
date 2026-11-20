import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

final _doubanImageHost = RegExp(r'^img[0-9]+\.doubanio\.com$');
const _doubanCoverHeaders = <String, String>{
  'Referer': 'https://movie.douban.com/',
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
};

Map<String, String>? _coverHeaders(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      !_doubanImageHost.hasMatch(uri.host)) {
    return null;
  }
  // CSP recommendations expose public Douban URLs without cover_headers.
  // These CDNs reject both a missing Referer and Dart's default User-Agent.
  // Keep the policy on the exact image hosts; local proxies carry source headers.
  return _doubanCoverHeaders;
}

/// Replaces CDN headers rather than appending a second default User-Agent,
/// and routes empty transparent image sentinels to the caller's errorBuilder.
/// Small visible icons and animated images remain valid.
class _CoverNetworkImage extends ImageProvider<NetworkImage>
    implements NetworkImage {
  _CoverNetworkImage(this.url) : headers = _coverHeaders(url);

  // Covers are finite downloads. Keep this deadline independent of the core's
  // intentionally unbounded video-body transport. Every received body chunk
  // resets the idle timer, so a progressing large image remains supported.
  static const _networkWait = Duration(seconds: 20);
  static final HttpClient _client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = _networkWait;
  static final HttpClient _localClient = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = _networkWait
    ..findProxy = (uri) => _isLoopback(uri)
        ? 'DIRECT'
        : HttpClient.findProxyFromEnvironment(uri);

  static bool _isLoopback(Uri uri) =>
      uri.host == 'localhost' ||
      (InternetAddress.tryParse(uri.host)?.isLoopback ?? false);

  Future<HttpClientRequest> _open(Uri uri) {
    var expired = false;
    final client = _isLoopback(uri) ? _localClient : _client;
    final opening = client.getUrl(uri).then((request) {
      if (expired) {
        // DNS/connection completion can arrive after our deadline. Consume its
        // abort error and release that request without sending image headers.
        request.done.ignore();
        request.abort();
      }
      return request;
    });
    return opening.timeout(
      _networkWait,
      onTimeout: () {
        expired = true;
        throw TimeoutException('Cover connection timed out', _networkWait);
      },
    );
  }

  Future<Uint8List> _readResponse(
    HttpClientResponse response,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    final length = response.contentLength;
    final expected =
        length < 0 ||
            response.compressionState ==
                HttpClientResponseCompressionState.decompressed
        ? null
        : length;
    var received = 0;
    Stream<List<int>> body = response.timeout(_networkWait).map((chunk) {
      received += chunk.length;
      chunks.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: received,
          expectedTotalBytes: expected,
        ),
      );
      return chunk;
    });
    if (response.compressionState ==
        HttpClientResponseCompressionState.compressed) {
      body = body.transform(gzip.decoder);
    }
    final output = BytesBuilder(copy: false);
    // await-for cancels the subscription on timeout/decoder errors. In contrast,
    // merely timing out a consolidation Future leaves its body consuming bytes.
    await for (final chunk in body) {
      output.add(chunk);
    }
    return output.takeBytes();
  }

  @override
  final String url;

  @override
  double get scale => 1.0;

  @override
  final Map<String, String>? headers;

  @override
  WebHtmlElementStrategy get webHtmlElementStrategy =>
      WebHtmlElementStrategy.never;

  @override
  Future<NetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<NetworkImage>(this);

  @override
  ImageStreamCompleter loadImage(
    NetworkImage key,
    ImageDecoderCallback decode,
  ) => _load(key, decode);

  ImageStreamCompleter _load(
    NetworkImage key,
    Future<ui.Codec> Function(ui.ImmutableBuffer) decode,
  ) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadBytes(key, decode, chunks),
      chunkEvents: chunks.stream,
      scale: key.scale,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _loadBytes(
    NetworkImage key,
    Future<ui.Codec> Function(ui.ImmutableBuffer) decode,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    try {
      final uri = Uri.base.resolve(key.url);
      final request = await _open(uri);
      headers?.forEach((name, value) => request.headers.set(name, value));
      final response = await request.close().timeout(
        _networkWait,
        onTimeout: () {
          final error = TimeoutException(
            'Cover response timed out',
            _networkWait,
          );
          request.abort(error);
          throw error;
        },
      );
      if (response.statusCode != HttpStatus.ok) {
        // Preserve the known HTTP error even if its optional body never ends.
        await response.listen(null, onError: (Object _) {}).cancel();
        throw NetworkImageLoadException(
          statusCode: response.statusCode,
          uri: uri,
        );
      }
      final bytes = await _readResponse(response, chunks);
      if (bytes.isEmpty) throw StateError('Cover image response is empty');
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        // Real posters do not need an additional pixel decode. Tiny CDN
        // sentinels are small responses; inspect their intrinsic size before
        // ResizeImage can turn a large, valid poster into a small thumbnail.
        if (bytes.length <= 4096) await _rejectTransparentSentinel(buffer);
      } catch (_) {
        buffer.dispose();
        rethrow;
      }
      return await decode(buffer);
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      unawaited(chunks.close());
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _CoverNetworkImage && url == other.url;

  // Scale and header policy are fixed for a URL. ImageCache looks up the same
  // provider repeatedly while resolving it; do not reparse the URL each time.
  late final int _hashCode = Object.hash(_CoverNetworkImage, url);

  @override
  int get hashCode => _hashCode;
}

Future<void> _rejectTransparentSentinel(ui.ImmutableBuffer buffer) async {
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  try {
    if (descriptor.width > 8 || descriptor.height > 8) return;
    final codec = await descriptor.instantiateCodec();
    try {
      if (codec.frameCount != 1) return;
      final frame = await codec.getNextFrame();
      try {
        final pixels = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (pixels == null) return;
        for (var alpha = 3; alpha < pixels.lengthInBytes; alpha += 4) {
          if (pixels.getUint8(alpha) != 0) return;
        }
        throw StateError('Cover image contains only a transparent placeholder');
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor.dispose();
  }
}

/// 网络图片解码宽度的**上限**（物理像素）。
///
/// ★ 上界是**防御性**的，不是性能开关：`cacheWidth` 会直接进
///   `ResizeImageKey`，值不同 ⇒ 缓存 key 不同 ⇒ **同一张图被解码
///   两份、驻留两份**。给它一个荒谬的值（无界约束、算错宽度、
///   将来误传）就是给自己造重复解码。
///
/// ⚠️ 4096 是**故意留足**的：4K 屏（3840 物理像素）整宽铺一张海报
///    仍在界内，TV / 大屏场景不会被削。
///
/// ★ 值**超过原图**也不会真的放大 —— `Image.network` 构造出的
///   `ResizeImage` 用默认 `allowUpscaling: false`，会把目标尺寸夹回
///   原图的固有尺寸（`painting/image_provider.dart:1372-1379`）。
///   所以这个上界只影响"缓存 key 是否一致"，不影响画质与内存。
const int kCoverDecodeMaxPx = 4096;

/// 按**布局宽度**算出 `Image.network` 的 `cacheWidth`（物理像素）。
///
/// ═══════════════════════════════════════════════════════════════════
/// ★★★ 为什么需要它
/// ═══════════════════════════════════════════════════════════════════
/// 不传 `cacheWidth` 时，`Image.network` 按**原图**解码，再交给
/// `BoxFit` 缩放 —— 缩放发生在**画完之后**，内存早就付过了。
///
/// 真机实测（1280x800、DPR = 1.0、追更页，`RenderImage` 普查 33 个）：
/// ```text
/// [0] 解码  600x848              布局 162x243 物理 ⇒  12.9×
/// [1] 解码 1920x1080                              ⇒  52.5×
/// [3] 解码 2204x3104 (26.10MB)                    ⇒ 173.2×
/// ```
/// 卡片只需要 162x243，却按 2204x3104 解码 ⇒ **一张海报驻留
/// 26.10MB**。`imageCache` 上限 100MB ⇒ 四张就顶到上限，之后每滚
/// 一屏都在"挤出去 → 解回来"之间反复，这正是滚动掉帧的来源。
///
/// 传了 `cacheWidth` 之后，解码目标 = 布局宽度 × DPR ⇒ 卡片要多少
/// 就解多少，`imageCache` 驻留随之落到同一量级。
///
/// ═══════════════════════════════════════════════════════════════════
/// ★ 为什么**只给宽**、不给高
/// ═══════════════════════════════════════════════════════════════════
/// 海报的宽高比是 2:3，但**源图未必**（上面实测里 1920x1080、
/// 1077x608 都是 16:9）。同时给 `cacheWidth` + `cacheHeight` 会把
/// 源图**拉伸**到那个尺寸（`ResizeImage` 不保比例）；只给宽 ⇒ 按
/// 原比例缩放 ⇒ 与今天 `BoxFit` 的观感**逐字一致**。
///
/// ═══════════════════════════════════════════════════════════════════
/// ★ 下界为什么是 1（不是 0）
/// ═══════════════════════════════════════════════════════════════════
/// `Image.network` 里有 `assert(cacheWidth == null || cacheWidth > 0)`
/// （`flutter/lib/src/widgets/image.dart:481`）。窄布局下
/// `(layoutWidth * dpr).round()` 可以是 0 ⇒ **debug 构建直接崩**。
///
/// ═══════════════════════════════════════════════════════════════════
/// ★ 无界约束是"崩"，不是"图小一点"
/// ═══════════════════════════════════════════════════════════════════
/// `LayoutBuilder` 在无界约束下给 `double.infinity`，而
/// `(double.infinity).round()` 会抛
/// `UnsupportedError: Infinity or NaN toInt` —— 那是**整页崩**。
/// 所以非有限值一律退到 [kCoverDecodeMaxPx]，绝不把异常留给
/// `round()`。
int coverDecodeWidth(BuildContext context, double layoutWidth) {
  final dpr = MediaQuery.devicePixelRatioOf(context);
  final raw = layoutWidth * dpr;
  if (!raw.isFinite) return kCoverDecodeMaxPx;
  return raw.round().clamp(1, kCoverDecodeMaxPx).toInt();
}

/// 按**目标框高度**算出 `BoxFit.cover` 需要的解码高度（物理像素）。
///
/// ═══════════════════════════════════════════════════════════════════
/// ★★★ 为什么是「高度」而不是「宽度」（2026-10-01 Owner 报封面糊）
/// ═══════════════════════════════════════════════════════════════════
///
/// # 症状
/// 首页「外部视频源」的封面明显糊，其它源（2:3 竖版海报）正常。
///
/// # 根因
/// ```text
/// 卡片（poster_card）      148 × 223 逻辑 px（2:3 竖版）
/// 某视频站封面（实测 API）      2560 × 1440    （16:9 横版）
///
/// BoxFit.cover 的缩放（取 max）：
///   scaleW = 148 / 2560 = 0.0578
///   scaleH = 223 / 1440 = 0.1549   ← 取这个
///   ⇒ 实际绘制 396 × 223
///
/// 而 [coverDecodeWidth] 给的是 148
///   ⇒ 解码 148×83，再被拉成 396×223 ⇒ 水平放大 **2.68 倍** ⇒ 糊
/// ```
///
/// # 为什么给高度就对了（**不需要知道源图宽高比**）
/// `ResizeImage` 只给一个维度时，**另一个按原比例算**
/// （`painting/image_provider.dart` 的 `ResizeImage`：
/// `width == null` ⇒ `height = (imgH * width / imgW)`，反之亦然）。
/// ```text
/// 令解码高 = 目标高（223）
///   某视频站 16:9  2560×1440 ⇒ 解码 396×223 ⇒ 绘制 396×223 ⇒ 放大 1.00 ✔
///   竖版 2:3   600×900  ⇒ 解码 149×223 ⇒ 绘制 149×223 ⇒ 放大 1.00 ✔
///   超宽 4:1  4000×1000 ⇒ 解码 892×223 ⇒ 绘制 892×223 ⇒ 放大 1.00 ✔
///   方形 1:1   800×800  ⇒ 解码 223×223 ⇒ 绘制 223×223 ⇒ 放大 1.00 ✔
/// ```
/// ⇒ ★ **四种比例全部 1.00 倍**，而且**无需推断源图比例**
///   （推断比例要解析 URL、还会猜错）。
///
/// # 为什么"高度足够 ⇒ 宽度必然足够"
/// `cover` 的定义就是"**两个方向都不留空**"⇒ 绘制尺寸在两个方向
/// 上都 **≥** 目标框。既然解码高 == 目标高，而绘制高 ≥ 目标高，
/// 那么绘制高 ≥ 解码高；又因为解码与绘制**同比例**（cover 不改比例）
/// ⇒ 绘制宽 ≥ 解码宽 ⇒ **水平方向也不会放大**。✔
///
/// # 为什么不用 [coverDecodeWidth]
/// `test/t74_cover_image_test.dart` 的 A1–A5（17 条断言）把
/// `coverDecodeWidth` 的语义**逐值钉死**（`== 148` 等）。
/// 它的语义本身没错 —— 它回答的是"布局多宽"，只是
/// **没考虑 cover 在源图更宽时会按高度放大**。
/// ⇒ 所以**新增**这个函数并让 `coverImage` 用它，
///   `coverDecodeWidth` **原样保留**（它的调用点与测试都不动）。
///
/// # 边界
/// * [layoutHeight] 为 null / 非有限 / ≤ 0 ⇒ 退回 [coverDecodeWidth]
///   （= **行为与改动前逐字相同**，绝不猜）
/// * 结果同样夹在 `[1, kCoverDecodeMaxPx]`
/// * ★ 只增不减：返回值取 `max(按高度算的, 按宽度算的)` ——
///   万一某个场景下"按宽度"更大（理论上不会，因为 cover 两向都 ≥），
///   也不会比改动前更糊。
int coverDecodeHeightFor(
  BuildContext context, {
  required double layoutWidth,
  double? layoutHeight,
}) {
  final base = coverDecodeWidth(context, layoutWidth);

  if (layoutHeight == null || !layoutHeight.isFinite || layoutHeight <= 0) {
    return base;
  }

  final dpr = MediaQuery.devicePixelRatioOf(context);
  final raw = layoutHeight * dpr;
  if (!raw.isFinite) return kCoverDecodeMaxPx;
  final px = raw.round().clamp(1, kCoverDecodeMaxPx).toInt();
  return px > base ? px : base;
}

/// 一张"按布局宽度解码"的网络图（海报 / 封面 / 图标）。
///
/// ★ 返回的就是 `Image` 本身，**不**新包一层 widget class ——
///   元素树里的类型必须保持 `Image`，否则任何现存或将来
///   `find.byType(Image)` 的语义都会**静默**改变。
///
/// `fit` / `frameBuilder` / `loadingBuilder` / `errorBuilder` 原样
/// 透传（默认值与 `Image.network` 逐字相同 = 都不传）：本函数
/// 决定解码尺寸并补充公开图片 CDN 所需请求头，不参与占位、加载中、失败时的表现。
///
/// ⚠️ 需要 `MediaQuery` 祖先（`devicePixelRatioOf` 找不到会抛）。
///    `MaterialApp` 自带一个，本仓的调用点都在其下。
///
/// ═══════════════════════════════════════════════════════════════════
/// ★★★ 2026-10-01：[layoutHeight]（修 Owner 报的「封面糊」）
/// ═══════════════════════════════════════════════════════════════════
/// 传了 [layoutHeight] 时改用 **`cacheHeight`**（而不是 `cacheWidth`）：
/// `ResizeImage` 只给一个维度时另一个**按原比例**算，而 `cover` 保证
/// 两个方向的绘制尺寸都 ≥ 目标框 ⇒ **高度够 ⇒ 宽度必然够**。
/// ```text
/// 148×223 卡片（2:3）+ 各种源图 ⇒ 解码高一律 223：
///   某视频站 16:9 2560×1440 ⇒ 解码 396×223 ⇒ 绘制 396×223 ⇒ 放大 1.00 ✔
///   竖版 2:3   600×900 ⇒ 解码 149×223 ⇒ 绘制 149×223 ⇒ 放大 1.00 ✔
/// ```
/// ★ **不需要知道源图宽高比** —— 这是它比"按比例反推宽度"更稳的地方
///   （反推要解析 URL，且遇到未知源会猜错）。
///
/// ★ **[layoutHeight] 不传 ⇒ 行为与改动前逐字相同**（仍用 `cacheWidth`
///   = [coverDecodeWidth]）。这是刻意的：`test/t74_cover_image_test.dart`
///   的 B2 钉着「`ResizeImage.width == 布局宽 × DPR`、`height == null`」
///   这条既有契约，而绝大多数调用点（2:3 源图填 2:3 卡片）
///   **本来就不需要**新参数。
///
/// ⚠️ 两种模式**互斥**（只传其中一个）：`ResizeImage` 同时给 width+height
///    会把源图**拉伸**成那个尺寸（不保比例）—— 那会让 16:9 封面变形。
Image coverImage(
  BuildContext context, {
  required String url,
  required double layoutWidth,
  BoxFit? fit,
  ImageFrameBuilder? frameBuilder,
  ImageLoadingBuilder? loadingBuilder,
  ImageErrorWidgetBuilder? errorBuilder,
  double? layoutHeight,
}) {
  final useHeight =
      layoutHeight != null && layoutHeight.isFinite && layoutHeight > 0;
  final cacheWidth = useHeight ? null : coverDecodeWidth(context, layoutWidth);
  final cacheHeight = useHeight
      ? coverDecodeHeightFor(
          context,
          layoutWidth: layoutWidth,
          layoutHeight: layoutHeight,
        )
      : null;

  if (!kIsWeb) {
    return Image(
      image: ResizeImage.resizeIfNeeded(
        cacheWidth,
        cacheHeight,
        _CoverNetworkImage(url),
      ),
      fit: fit,
      frameBuilder: frameBuilder,
      loadingBuilder: loadingBuilder,
      errorBuilder: errorBuilder,
    );
  }

  return Image.network(
    url,
    fit: fit,
    cacheWidth: cacheWidth,
    cacheHeight: cacheHeight,
    frameBuilder: frameBuilder,
    loadingBuilder: loadingBuilder,
    errorBuilder: errorBuilder,
  );
}
