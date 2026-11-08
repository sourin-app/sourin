// test/zz_t1056_danmaku_search_prefill_test.dart
//
// ══════════════════════════════════════════════════════════════════════════
//  N4-2：弹幕搜索页**默认必须填剧名**（2026-10-27）
// ══════════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// 搜索弹幕不支持填入中文，而且默认没有填充剧的名字
// ```
//
// # 根因（读码可证，不是猜）
// ```text
// 改前 initState：_keyword.text = draft?.keyword ?? widget.state.searchKeyword;
//
// `??` 只在**左侧为 null** 时右转。而 `DanmakuSearchDraft()` 的默认
// `keyword = ''`（**空串，不是 null**，danmaku_search_page.dart:10）
// ⇒ 挂载点 player_page.dart:2131 造的正是一个默认 draft
// ⇒ 左侧 '' 赢，右侧 `state.searchKeyword`（宿主已算好的剧名）
//   **永远拿不到** ⇒ 页面打开是空的。
// ```
//
// # 守什么
// ```text
// ① 主判据：宿主给了剧名 + 默认 draft（keyword 为空串）⇒ 输入框里就是剧名
// ② 跨卸载恢复（旧11 语义）：draft.keyword **非空**时用它，不是用宿主剧名
//    —— 用户自己打的词比猜测的更好，这条不许被"预填"改坏
// ③ 阴性对照：宿主剧名也为空 ⇒ 输入框保持空，且**不报错、不填占位串**
// ④ 用户主动清空后不许被"预填"回弹（否则用户清不掉输入框）
// ```
//
// # 为什么必须驱动真 widget
// ```text
// 这条缺陷的本质是"两个数据源的优先级判错"——源码字符串断言看不出
// （`draft?.keyword ?? widget.state.searchKeyword` 这行**改前就在**，
//  看上去完全正确）。只有把真的 draft 交给真的页面、再读真的
// `TextField` 的 controller 才能判。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

// ══════════════════════════════════════════════════════════════════════════
// 夹具
// ══════════════════════════════════════════════════════════════════════════

const String kShow = '鬼灭之刃';

DanmakuSettingsState stateWith({String searchKeyword = kShow}) =>
    DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1,
      opacity: 1,
      speed: 1,
      area: 1,
      searchSearched: false,
      searchStale: false,
      searchError: null,
      searchResults: const <DanmakuMatch>[],
      searchKeyword: searchKeyword,
    );

Widget page(DanmakuSettingsState state, {DanmakuSearchDraft? draft}) =>
    MaterialApp(
      home: DanmakuSearchPage(
        state: state,
        biliState: const BiliImportState(),
        localTitles: const <String>['第1集', '第2集'],
        onSearch: (_) {},
        onBiliSearch: (_) {},
        onPickMatch: (_) {},
        onBatchBind: (_) {},
        onBiliImport: (_) {},
        onBiliSelectPage: (_) {},
        onClose: () {},
        draft: draft,
      ),
    );

/// 读搜索页关键词输入框里的**真实**文本
String keywordText(WidgetTester t) {
  final field = find.byType(ui.TextField);
  expect(field, findsOneWidget,
      reason: '★★ 搜索页必须有一个关键词输入框 —— 找不到说明树变了，'
          '下面所有断言都会退化成对空树的断言（铁律 149）');
  return t.widget<ui.TextField>(field).controller!.text;
}

// ══════════════════════════════════════════════════════════════════════════
// 用例
// ══════════════════════════════════════════════════════════════════════════

void main() {
  testWidgets('★★★ 主判据：默认 draft（keyword 为空串）⇒ 输入框里必须是宿主给的剧名',
      (t) async {
    final draft = DanmakuSearchDraft(); // keyword == ''（宿主挂载点同款）
    await t.pumpWidget(page(stateWith(), draft: draft));
    await t.pump();

    expect(
      keywordText(t),
      kShow,
      reason: '★★★ N4-2 主判据：draft.keyword 是**空串**（不是 null）时，'
          '必须回退宿主的 state.searchKeyword —— '
          '`draft?.keyword ?? …` 这种写法在这里永不右转（这就是改前那条缺陷）',
    );
  });

  testWidgets('★★ 跨卸载恢复（旧11）：draft 里有用户自己的词 ⇒ 用它，不覆盖成剧名',
      (t) async {
    final draft = DanmakuSearchDraft(keyword: '用户自己搜的词');
    await t.pumpWidget(page(stateWith(), draft: draft));
    await t.pump();

    expect(
      keywordText(t),
      '用户自己搜的词',
      reason: '★★ 用户自己打的词比宿主猜测的更好 —— '
          '"预填剧名"不许把跨卸载恢复改坏（旧11 契约）',
    );
  });

  testWidgets('★★ 阴性对照：宿主剧名也为空 ⇒ 保持空，不报错、不填占位串', (t) async {
    final draft = DanmakuSearchDraft();
    await t.pumpWidget(page(stateWith(searchKeyword: ''), draft: draft));
    await t.pump();

    expect(keywordText(t), '',
        reason: '★★ 没有剧名时不许填任何占位串（"未知"/"未命名"都算伪造信息）');
    expect(t.takeException(), isNull,
        reason: '★ 没有剧名不是错误场景，不许抛异常');
  });

  testWidgets('★ 无 draft 挂载（draft == null）⇒ 同样用宿主剧名', (t) async {
    await t.pumpWidget(page(stateWith(), draft: null));
    await t.pump();

    expect(keywordText(t), kShow,
        reason: '★ draft 为空时走宿主的 searchKeyword —— 这条是原先就对的路径，'
            '不许在修 N4-2 时被改坏（保留既有契约）');
  });

  testWidgets('★★ 用户主动清空后不许被"预填"回弹', (t) async {
    final draft = DanmakuSearchDraft();
    await t.pumpWidget(page(stateWith(), draft: draft));
    await t.pump();
    expect(keywordText(t), kShow, reason: '前置：先确认预填生效');

    // 用户把输入框清空（真实输入路径）
    await t.enterText(find.byType(ui.TextField), '');
    await t.pump();

    expect(keywordText(t), '',
        reason: '★★ 用户清空必须**留得住** —— 若预填写成"每帧回弹剧名"，'
            '用户就永远清不掉这个框（这是把 N4-2 修过头的典型后果）');
  });
}