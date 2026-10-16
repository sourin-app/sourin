// 本批换控件后的**真机验证探针**（用真的 sourin_core.dll 走真数据路径）。
//
// ⚠️ 缺 `sourin_core.dll` 时**整文件 skip**（照 `t61_panel_radius_test.dart:152` 的范式）——
//    「夹具缺失」是 skip 不是 fail，但绝不能假装通过。
//
// 跑法（必须把 core dll 目录加进 PATH）：
//   $env:PATH = "<repo>\rust\sourin_core\target\release;$env:PATH"
//   $env:SOURIN_SHOT_DIR = '.probe\shots'
//   flutter test test/zz_cr_real_ui_verify_test.dart --concurrency=1
//
// 验证目标（本批改动的功能面）：
//   ① 真核心加载得了（不是 mock）
//   ② browse 分类胶囊换成 FilterChip 后：渲染得出来、点得动、回调对
//   ③ live 频道条换 chip 后：渲染 + 按源筛选仍工作
//   ④ 弹幕面板 / 播放器面板换控件后仍渲染
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart' as models;
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/browse_page.dart';

import 'support/ui_shot.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

/// 核心能不能加载 —— 缺了就当夹具缺失（skip），别让默认套件红
bool get _coreReady {
  try {
    SourinCore.version;
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  setUpAll(() async {
    await loadRealFonts();
  });

  test('① 真核心真的加载了（不是桩）', () {
    if (!_coreReady) {
      markTestSkipped('sourin_core.dll 夹具缺失 ⇒ 本条无从断言');
      return;
    }
    final v = SourinCore.version;
    print('CORE version = $v');
    expect(v, contains('sourin-core'),
        reason: '★ 核心没加载 ⇒ 后面全是空树上的假绿');
  });

  testWidgets('② browse 分类胶囊：换成 FilterChip 后仍渲染 + 点得动', (t) async {
    if (!_coreReady) {
      markTestSkipped('sourin_core.dll 夹具缺失 ⇒ 本条无从断言');
      return;
    }
    await setShotViewport(t, const Size(1000, 800));
    // ★ 记录**产品真的调了几次取页** —— 点分类的唯一真实后果
    final calls = <int>[];
    await t.pumpWidget(_host(BrowsePage(
      provider: 'demo',
      title: '电影',
      pageLoaderForTest: (p) async {
        calls.add(p);
        return models.Page<models.MediaItem>(
          items: [
            for (var i = 0; i < 8; i++)
              models.MediaItem(
                id: 'm$i',
                title: '条目 $i',
                cover: '',
                note: '',
              ),
          ],
          page: p,
          pageCount: 1,
        );
      },
    )));
    final st = t.state<BrowsePageState>(find.byType(BrowsePage));
    st.debugSetCategories([
      for (var i = 0; i < 4; i++) models.Category(id: '$i', name: '分类$i'),
    ]);
    // ★ 真核心在跑 ⇒ `_init` 里的 getCategories 是**真的** FFI 调用，
    //   要先等它失败/返回，`_load(1)` 才会接着跑。等不到就明确失败，
    //   绝不让后面的断言退化成对空树的假绿。
    for (var i = 0; i < 60 && st.debugItemCount == 0; i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 50)));
    }
    await t.pumpAndSettle();

    // 前置：页面真活了
    expect(st.debugItemCount, greaterThan(0),
        reason: '★ 第 1 页没进来 ⇒ 后面的断言都在空树上');

    // 胶囊真的画出来了
    for (var i = 0; i < 4; i++) {
      expect(find.text('分类$i'), findsWidgets, reason: '★ 少了分类$i 这颗胶囊');
    }
    expect(find.byType(FilterChip), findsWidgets,
        reason: '★ 分类胶囊必须是框架的 FilterChip');

    /*
     * 点得动 —— ★ 判据必须是**真实结果**，不能是测试自己写进去的标记。
     *
     * 改前这里写的是 `picked = 1; expect(picked, 1);` —— 那是**恒真**：
     * 就算 FilterChip.onSelected 根本没接上 _switchCategory，它也照样绿。
     * 现在改成读**产品真的改了什么**：
     *   `pageLoaderForTest` 收到的页码/分类 + 页面标题里的分类名。
     */
    final callsBefore = calls.length;
    await t.tap(find.text('分类2').first);
    await t.pumpAndSettle();
    for (var i = 0; i < 40 && calls.length == callsBefore; i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() =>
          Future<void>.delayed(const Duration(milliseconds: 50)));
    }

    expect(calls.length, greaterThan(callsBefore),
        reason: '★★ 点分类胶囊必须真的触发重新取页（_switchCategory）—— '
            '不触发就说明 chip 的 onSelected 没接上，而「页面标题变了」本身不是证据');

    // ★ 光看取页次数还不够：若 onSelected 改成直接 _load(1)，次数也会涨，
    //   但分类根本没切换。所以要同时读**渲染结果**里 chip 的选中态。
    FilterChip chipOf(String label) => t
        .widgetList<FilterChip>(find.byType(FilterChip))
        .firstWhere((c) => c.label is Text && (c.label as Text).data == label);
    final chip2 = chipOf('分类2');
    expect(chip2.selected, isTrue,
        reason: '★★ 点了分类2 ⇒ 它必须真的处于选中态（读 element 树，不是读测试自己写的值）');
    final chip0 = chipOf('分类0');
    expect(chip0.selected, isFalse, reason: '★ 单选：点了分类2，分类0 必须取消选中');

    print('BROWSE chip tap OK (loader 被再调用 ${calls.length - callsBefore} 次)');

    await saveViewShot(t, 'real_browse_categories');
  });
}