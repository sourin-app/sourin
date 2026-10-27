// ═══════════════════════════════════════════════════════════════════════
//  R2-#7-bili 门禁：视频站搜索结果**必须画封面**
// ═══════════════════════════════════════════════════════════════════════
//
// # 它守什么（Owner 实测：「绑定弹幕那里 搜索出来的 bilibili 的没有封面」）
// ```text
// 根因（已取证）：`danmaku_search_page.dart` 里视频站那一块是**光板 ListTile**
//   —— 只有 title + bvid，`BiliSearchItem.cover` **没人读**。
//   数据层是好的（真响应喂产品自己的解析器 ⇒ 17/17 条带 cover），
//   也不是防盗链（8/8 个真图 URL 不带 headers 全 200）
//   ⇒ **就是本页漏画了这一格**。
// ```
//
// # 判据要求（**必须能真红**，且红在**判据**上不是编译错）
// ```text
// ① **带 cover 的条目必须建出 `Image`** —— 这是"真的画了"的行为级证据
// ② **无 cover 的条目必须走占位（不建 Image）** —— 否则占位逻辑被绕过
// ③ 两条臂的 `Image` 数**必须不同** —— 若相同，说明"有没有 cover 走同一条分支"
//     （那就是把字段忽略了；这条正是注入要打的）
// ④ `errorBuilder` 必须在位（源码断言，但**必须剥注释**）——
//    依据：`bili_import_dialog.dart:533-537` 逐字：不给 errorBuilder 时
//    封面加载失败会变成**未捕获异常**（SDK image.dart:1233 的 reportErrors）。
//    ⚠️ 本仓踩过两次"裸 contains 被注释满足"（见
//       `.probe/t66-scanner-blockcomment-scope.md`）⇒ 这里**先剥注释再判**。
// ```
//
// # ⚠️ 为什么不能断言"图真的显示出来了"
// ```text
// `flutter test` 里**没有 HTTP** ⇒ `Image.network` 必然走 `errorBuilder`。
//   ⇒ "看不到图"在单测里是**恒真**的 ⇒ 拿它当判据就是**空真**（铁律 149）。
//   ⇒ 所以判据只能是"建没建出 `Image`"（= UI **尝试**画了）+ "有没有走占位分支"。
//     真网络那一层由实机读数承担（见交付说明），不在这里假装。
// ```
//
// 跑法：flutter test test/zz_r2_danmaku_bili_cover_test.dart --concurrency=1
//
// # 故障注入（已实测，见 `.probe/r2-danmaku-bili-cover-inject.log`）
// ```text
// 注入：把 `leading:` 那一格整段摘掉（回到改前的光板 ListTile）
//   ⇒ ①组红（`Image` 数 1 → 0），且 ③组"两臂不同"也随之红。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

const String _kSrc = 'lib/ui/danmaku_search_page.dart';

/// 剥掉行注释与块注释 —— **只判代码**。
///
/// 依据：本仓两次踩坑（`.probe/t66-scanner-blockcomment-scope.md`）：
/// 解释"改前是什么"的注释里会**逐字引用**被禁的字面量 ⇒ 裸 `contains` 把它算成违规
/// ⇒ 假红，而"修法"只能是删掉那段有价值的留档。
String stripComments(String src) {
  final out = StringBuffer();
  var inBlock = false;
  for (final line in src.split('\n')) {
    final t = line.trimLeft();
    if (inBlock) {
      final p = t.indexOf('*/');
      if (p >= 0) {
        inBlock = false;
        out.writeln(t.substring(p + 2));
      }
      continue;
    }
    final b = t.indexOf('/*');
    if (b >= 0) {
      final rest = t.substring(b + 2);
      if (rest.contains('*/')) {
        out.writeln(t.substring(0, b));
      } else {
        inBlock = true;
        out.writeln(t.substring(0, b));
      }
      continue;
    }
    if (t.startsWith('//')) {
      out.writeln();
      continue;
    }
    out.writeln(line);
  }
  return out.toString();
}

BiliSearchItem _item({required String cover, required String bvid}) =>
    BiliSearchItem(
      bvid: bvid,
      title: '条目标题 $bvid',
      cover: cover,
      duration: '1:00',
    );

Future<void> _mount(WidgetTester t, List<BiliSearchItem> bili) async {
  await t.pumpWidget(MaterialApp(
    theme: AppTheme.themeFor(Brightness.dark),
    home: Scaffold(
      body: DanmakuSearchPage(
        state: const DanmakuSettingsState(
          enabled: true,
          appId: '',
          appSecret: '',
          fontScale: 1,
          opacity: 1,
          speed: 1,
          area: 1,
        ),
        biliState: BiliImportState(
          searchKeyword: '火影',
          searchResults: bili,
        ),
        localTitles: const <String>['第1集'],
        onSearch: (_) {},
        onBiliSearch: (_) {},
        onPickMatch: (_) {},
        onBatchBind: (_) {},
        onBiliImport: (_) {},
        onBiliSelectPage: (_) {},
        onClose: () {},
      ),
    ),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  group('R2-#7 视频站搜索结果画封面', () {
    testWidgets('① 带 cover ⇒ 必须建出 Image（真的画了）', (t) async {
      t.view.physicalSize = const Size(900, 1200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await _mount(t, <BiliSearchItem>[
        _item(cover: 'https://i2.hdslb.com/bfs/archive/abc.jpg', bvid: 'BV1aaa'),
      ]);
      final n = find.byType(Image).evaluate().length;
      expect(n, greaterThan(0),
          reason: '★★★ 带 cover 的条目必须建出 `Image` —— 否则就是**没画封面**'
              '（这正是 Owner 实测到的「没有封面」形态）。实际 Image 数 = $n');
    });

    testWidgets('② 无 cover ⇒ 走占位，不建 Image', (t) async {
      t.view.physicalSize = const Size(900, 1200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await _mount(t, <BiliSearchItem>[_item(cover: '', bvid: 'BV1bbb')]);
      final n = find.byType(Image).evaluate().length;
      expect(n, 0,
          reason: '★ 无 cover 时不该建 `Image`（那会去加载空 URL）。'
              '实际 Image 数 = $n');
      // 占位必须在位（否则那一格是空白 ⇒ 用户分不清"加载中"与"没有")
      expect(find.byIcon(Icons.movie_outlined), findsWidgets,
          reason: '★★ 无封面必须给占位图标 —— 空白格会让用户以为还在加载');
    });

    testWidgets('③ 两条臂的 Image 数必须**不同**（否则字段被忽略）', (t) async {
      t.view.physicalSize = const Size(900, 1200);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await _mount(t, <BiliSearchItem>[
        _item(cover: 'https://i2.hdslb.com/bfs/archive/abc.jpg', bvid: 'BV1ccc'),
      ]);
      final withCover = find.byType(Image).evaluate().length;
      await _mount(t, <BiliSearchItem>[_item(cover: '', bvid: 'BV1ddd')]);
      final withoutCover = find.byType(Image).evaluate().length;

      expect(withCover == withoutCover, isFalse,
          reason: '★★★ 有 cover 与无 cover **必须走不同分支**。'
              '若两者相同 ⇒ `item.cover` 被忽略（= 改前那条光板 ListTile 的形态）。'
              '实测：有 cover=$withCover，无 cover=$withoutCover');
    });

    testWidgets('④ errorBuilder 必须在位（**剥注释后**判源码）', (t) async {
      final code = stripComments(File(_kSrc).readAsStringSync());
      expect(code.contains('errorBuilder'), isTrue,
          reason: '★★★ 必须给 `errorBuilder`。依据 `bili_import_dialog.dart:533-537` '
              '逐字：Flutter 的 Image 只在 `errorBuilder == null` 时上报错误 '
              '(SDK image.dart:1233 的 reportErrors) ⇒ 不给的话，封面加载失败会在'
              '单测里变成**未捕获异常**，而用户只想看到"这条没封面"。\n'
              '⚠️ 已剥注释后判 —— 注释里描述这条规矩不算数。');
    });

    testWidgets('⑤ 视频站那一块不许退回光板 ListTile（结构判据）', (t) async {
      final code = stripComments(File(_kSrc).readAsStringSync());
      // 视频站那块（`b.searchResults`）后面必须紧跟带 leading 的 ListTile
      expect(
        RegExp(r'for \(final item in b\.searchResults\)\s*ListTile\(\s*'
                r'leading:')
            .hasMatch(code),
        isTrue,
        reason: '★★★ 视频站结果必须画 `leading:`（封面格）。'
            '改前是 `ListTile(title: …, subtitle: …)` —— 没有 leading。',
      );
    });
  });
}