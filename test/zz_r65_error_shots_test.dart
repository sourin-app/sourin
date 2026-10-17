@Tags(['native-media'])

// ═══════════════════════════════════════════════════════════════════════
//  第 65 轮 · 第 6 / 7 条：**真实渲染树截图**取证
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须截图（而不是只跑断言）
//
// ```text
// 断言只能证"树上有某个 Text"。它证不了：
//   ✗ 文字有没有被 Column 挤出去 / 溢出
//   ✗ 标题 + 正文 + 下一步 三层叠起来还能不能看
//   ✗ 用户扫一眼能不能分清"源的问题"还是"软件的问题"
// ```
// Owner 第 6 条的原话是「不知道是源的问题还是软件本身的问题」——
// 那是**观感**问题，只有看图能回答。
//
// # ★ 为什么不截整个播放页
// ```text
// 实测：对挂了 PlayerPage 的整棵树调 `toImage()` ⇒ 测试 "did not complete"
// （libmpv 的渲染上下文与 flutter_tester 的离屏光栅器抢同一个 GPU 资源；
//   本仓 dart_test.yaml 顶部记的就是这个坑）。
// ⇒ 改成**只截错误层组件本身**，它们的像素与真实播放页里那两个组件
//   **完全一致**（同一个 widget、同一套 token），图仍然是真证据，
//   只是把会崩的那块（视频纹理）排除在外。
// ```

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player_page.dart';

const String kShotDir = '.probe/round65-c/shots';

/// Owner 截图里的**两条真实原文**（逐字）
const String kPermRaw =
    'SourinCoreException(other): 插件报错: 该内容需要大会员，开通后可观看';
const String kProxyRaw =
    'Failed to open http://127.0.0.1:57209/s/18df5c6d883dafdc11a485c0f7398/.';

final GlobalKey _key = GlobalKey();

/// 把一棵 Widget 渲染到 1280×800 并**真写成 PNG**
Future<void> shootWidget(
  WidgetTester t,
  Widget child,
  String name, {
  Size size = const Size(1280, 800),
}) async {
  await t.binding.setSurfaceSize(size);
  await t.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (ctx) => Scaffold(body: child),
        ),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 50));

  final b = _key.currentContext!.findRenderObject();
  if (b is! RenderRepaintBoundary) throw StateError('不是 RepaintBoundary');
  final img = await b.toImage(pixelRatio: 1.0);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  Directory(kShotDir).createSync(recursive: true);
  File('$kShotDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());

  await t.binding.setSurfaceSize(null);
}

void main() {
  testWidgets('① 权限类失败（改后）', (t) async {
    final f = PlaybackErrorText.classify(kPermRaw);
    expect(f.kind, PlaybackFailureKind.permission, reason: '夹具自检');

    await shootWidget(
      t,
      PlayerErrorCardForProbe(
        failure: f,
        onRetry: () {},
        onBack: () {},
      ),
      '01-after-permission',
    );
  });

  testWidgets('② 代理类失败（改后）', (t) async {
    final f = PlaybackErrorText.classify(kProxyRaw);
    expect(f.kind, PlaybackFailureKind.proxy, reason: '夹具自检');

    await shootWidget(
      t,
      PlayerErrorCardForProbe(
        failure: f,
        onRetry: () {},
        onBack: () {},
      ),
      '02-after-proxy',
    );
  });

  testWidgets('③ 源没给地址（改后）', (t) async {
    final f = PlaybackErrorText.classify('该内容没有可播放的地址');
    expect(f.kind, PlaybackFailureKind.source, reason: '夹具自检');

    await shootWidget(
      t,
      PlayerErrorCardForProbe(
        failure: f,
        onRetry: () {},
        onBack: () {},
      ),
      '03-after-no-address',
    );
  });

  testWidgets('④ 解码失败（改后）', (t) async {
    final f = PlaybackErrorText.classify('Could not open codec.');
    expect(f.kind, PlaybackFailureKind.decode, reason: '夹具自检');

    await shootWidget(
      t,
      PlayerErrorCardForProbe(
        failure: f,
        onRetry: () {},
        onBack: () {},
      ),
      '04-after-decode',
    );
  });

  testWidgets('⑤ 【改前对照】Owner 看到的那两个画面', (t) async {
    // 改前 = 没有归类、没有净化：直接把 toString() 贴上屏
    await shootWidget(
      t,
      PlayerErrorCardForProbe(
        rawOnly: kPermRaw,
        onRetry: () {},
        onBack: () {},
      ),
      '00-before-permission',
    );
    await shootWidget(
      t,
      PlayerErrorCardForProbe(
        rawOnly: kProxyRaw,
        onRetry: () {},
        onBack: () {},
      ),
      '00-before-proxy',
    );
  });
}
