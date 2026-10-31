// ═══════════════════════════════════════════════════════════════════════
//  T1b 接线①（2026-11-01）：**接线层**门禁（纯源码断言，不碰 libmpv）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★★ 为什么这个文件**不带** `native-media` 标签
// ```text
// 带标签 ⇒ 该文件在全量 flutter test 里**默认 skip**
//   （dart_test.yaml：加载 libmpv 会让 flutter_tester 偶发 native 崩溃）。
// 而本文件全是**静态源码断言**，根本不需要 libmpv ——
//   把它们随 widget 用例一起 skip = 全量里形同虚设。
// 本批的主题恰恰是防「接线了但没真接」：接线断言若在默认全量里不跑，
//   那道缝就又开了（与 T5 同一类）。
// ⇒ 必须与 widget 用例分家：静态放这里（默认真跑），widget 放
//   `t20261101_pan_line_precheck_test.dart`（带标签，按需强跑）。
// ```
//
// # 它守的三截（少任何一截，"已实现"都是空的）
// ```text
// ① Rust 引擎（tvbox_pan_check，commit b84dd9d）
//   → ② Dart 封装（SourinApi.panCheck，items 序列化成字符串传）
//     → ③ 线路面板的行标注（_StreamSheet.panStateOf ← _panStateFor）
// 另加 ② 的静默失败收口：候选「空 / 被摘」的留痕接线
// ```
//
// # ★★ 断言前必须先 `stripComments` 剥注释（本批踩过两次的坑）
// ```text
// 直接 `src.contains('xxx')` ⇒ 把那行代码**注释掉**照样匹配 ⇒ 注入后门禁
// 仍是绿的（"接线了但没真接"就靠这道缝活下来）。
// ⇒ 剥注释是硬要求；本文件还有一条**仪器自检**用例专门盯着它。
// ```
//
// # 故障注入（逐条实测，全部 RED）
// ```text
// 注入① 删 _resolveAndPlay 出口的 _armPanPrecheck   ⇒ 组①-1 红
// 注入② 删 _reload 出口的 _armPanPrecheck          ⇒ 组①-1 红
// 注入③ 删 _adoptLiveChannel 出口的 _armPanPrecheck ⇒ 组①-1 红
// 注入④ panStateOf: _panStateFor → null            ⇒ 组①-2 红
// 注入⑤ 命令名打错                                  ⇒ 组②-1 红
// 注入⑥ items 不序列化成字符串                       ⇒ 组②-2 红
// 注入⑦ 删留痕调用                                  ⇒ 组③-1 红
// 注入⑧ 留痕去掉记账闸                               ⇒ 组③-2 红
// 注入⑨ 注释掉 panStateOf（不删）                    ⇒ 组①-2 红  ← 关键
// 注入⑩ 注释掉 FFI 调用（不删）                      ⇒ 组②-1 红  ← 关键
// 注入⑪ 注释掉留痕调用（不删）                       ⇒ 组③-1 红  ← 关键
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/strip_comments.dart';

void main() {
  late String page;
  late String api;
  late String prepare;
  setUpAll(() {
    page = stripComments(
        File('lib/ui/player_page.dart').readAsStringSync());
    api = stripComments(
        File('lib/core/sourin_api.dart').readAsStringSync());
    prepare = stripComments(
        File('lib/core/stream_prepare.dart').readAsStringSync());
  });

  // ═══════════════════════════════════════════════════════════════════
  //  组① 三截链的接线
  // ═══════════════════════════════════════════════════════════════════
  group('① 接线：预检真的接到了线路列表的每一个出口', () {
    test('★★ 四个 _streams 出口**都**调了 _armPanPrecheck', () {
      /*
       * ⚠️ 口径：`_armPanPrecheck(list)` 全文件共 **5** 处 ——
       *    四个取数出口 + 门禁探针里那一处（探针只是转发，不算"接线"）。
       *    ⇒ 用"独立成行、缩进 6 格"的调用形态来数，排除探针那处。
       */
      expect(
        RegExp(r'^      _armPanPrecheck\(list\);$', multiLine: true)
            .allMatches(page)
            .length,
        4,
        reason: '★ 线路列表有四个产出点（_load / _reload / _adoptLiveChannel / '
            '_resolveAndPlay）。少一处 = 那条路上的线路永远不预检 —— '
            '正是本批 T5 同款漏网。',
      );
    });

    test('★★ 抽屉真传 panStateOf（标注不是孤儿函数）', () {
      expect(page.contains('panStateOf: _panStateFor'), isTrue,
          reason: '_StreamSheet 构造点必须接生产 _panStateFor —— '
              '否则标注只在测试里存在，用户一行都看不到');
    });

    test('★★ 死链不可点的字面（与 zz_t33 ④ 的契约同源）', () {
      expect(page.contains('enabled: s.isPlayable && !isPanDead'), isTrue,
          reason: 'bad（死链）行必须不可点；字面前缀保留 `s.isPlayable` '
              '（zz_t33_drm_ui_verify_test ④ 按它钉 DRM 行）');
      expect(page.contains('onTap: s.isPlayable && !isPanDead ?'), isTrue);
      // ★ 防"退回只看 isPlayable" ⇒ 那会让死链重新可点
      expect(page.contains('onTap: s.isPlayable ? '), isFalse,
          reason: '★ 退回 onTap: s.isPlayable ? 会让死链行重新可点');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  组② Dart 封装（第 ② 截）
  // ═══════════════════════════════════════════════════════════════════
  group('② 封装：SourinApi.panCheck 不是空壳', () {
    test('★★ 真的调了 FFI 命令', () {
      expect(api.contains("SourinCore.callAsync('tvbox_pan_check'"), isTrue,
          reason: '★ 把 callAsync 注释掉也必须红 —— '
              'Dart 侧"零消费点"就是这么来的');
    });

    test('★★ items 是**序列化成字符串**传的（FFI 参数解析器的硬约束）', () {
      expect(api.contains("{'items': payload}"), isTrue,
          reason: 'ffi.rs 的参数解析器只有 a.str(，没有数组方法 ⇒ '
              '传 List 会让 Rust 报「items 不是 JSON 数组」');
      expect(api.contains('jsonEncode('), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  组③ ② 的静默失败收口：留痕接线
  // ═══════════════════════════════════════════════════════════════════
  group('③ 留痕：候选「空 / 被摘」不许再静默', () {
    test('★★ 四个取数出口都调了 _logCandidateShortfall', () {
      expect(
        RegExp(r'^      _logCandidateShortfall\(list\);$', multiLine: true)
            .allMatches(page)
            .length,
        4,
        reason: '少一处 = 那条路上的候选缺失仍然零日志（appget 同款黑洞）',
      );
    });

    test('★★ 防刷屏（lead 批复 B）：key 记账 + 按 key 分家', () {
      final m = RegExp(r'void _logCandidateShortfall\(').firstMatch(page);
      expect(m, isNotNull);
      final body = page.substring(m!.end, (m.end + 1600).clamp(0, page.length));
      expect(body.contains('_shortfallLoggedKeys.add(key)'), isTrue,
          reason: '★ 不记账 ⇒ 每次换源/每条线路都记一行 ⇒ 日志被淹');
      /*
       * ★★ 不许有"换集清整本账"这种写法（实测踩到的两个坑）：
       *   清账时预置 key ⇒ 首次调用被**自己的账**挡住 ⇒ 留痕整个失效；
       *   只清不置     ⇒ 来回切两集即可重复记 ⇒ 防刷屏被绕过。
       */
      expect(body.contains('_shortfallLoggedKeys.clear()'), isFalse,
          reason: '★ key 已含 provider+contentId（天然按集分家）⇒ 不需要 clear');
      expect(body.contains('kShortfallLogKeyCap'), isTrue,
          reason: 'key 集合要有上限（否则看几百集积累几百个 key）');
      // 两本账分开（预检 vs 候选缺失 —— 混用会互相挡）
      expect(page.contains('final Set<String> _shortfallLoggedKeys'), isTrue);
      expect(page.contains('final Set<String> _panFailLoggedKeys'), isTrue);
    });

    test('★★ 留痕真的消费了 StreamPreparer 的摘除字段', () {
      expect(page.contains('StreamPreparer.lastDroppedCount'), isTrue,
          reason: '★ 这个字段此前全仓零消费 = 摘了但没人对任何地方说');
      expect(page.contains('StreamPreparer.lastDroppedReasons'), isTrue);
      final m = RegExp(r'void _logCandidateShortfall\(').firstMatch(page);
      final body = page.substring(m!.end, (m.end + 1600).clamp(0, page.length));
      expect(body.contains('StreamPreparer.lastDroppedCount'), isTrue);
      expect(body.contains('StreamPreparer.lastDroppedReasons'), isTrue);
    });

    test('★ 预检失败也有留痕（静默失败 = 缺陷）', () {
      final m = RegExp(r'void _armPanPrecheck\(').firstMatch(page);
      expect(m, isNotNull);
      final body = page.substring(m!.end, (m.end + 3200).clamp(0, page.length));
      expect(body.contains("AppLog.write('PLAY', '网盘预检失败"), isTrue,
          reason: '★ 预检失败不许静默（它只是不显示标注，但必须是留痕的）');
      expect(body.contains('_panFailLoggedKeys.add(key)'), isTrue,
          reason: '预检失败同样要防刷屏（lead 批复 B）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  组④ 仪器自检 + 边界
  // ═══════════════════════════════════════════════════════════════════
  group('④ 仪器自检与边界', () {
    test('★★ 剥注释本身有效（注释里的串不算命中）', () {
      final doctored = '// _armPanPrecheck(list)\nvoid f(){}';
      expect(stripComments(doctored).contains('_armPanPrecheck(list)'), isFalse,
          reason: '★ 这道缝就是本批踩过的假绿来源 —— 仪器自己必须先堵上');
      // URL 里的 // 不许被当注释（那会削掉真代码 ⇒ 假红）
      final withUrl = "const u = 'https://x.invalid/a.m3u8';\nvoid g(){}";
      expect(stripComments(withUrl).contains('https://x.invalid/a.m3u8'), isTrue,
          reason: '字符串字面量必须保住 —— 否则真代码被削掉变成假红');
    });

    test('边界：stream_prepare.dart 的摘除判据本批**不许**动（已立下批项）', () {
      expect(prepare.contains('String? _whyUnusable(String url)'), isTrue,
          reason: '★ 摘除判据的改动已立下批项，本批只收留痕 —— 动了就报给 Lead');
    });

    test('★ 换源弹层**不接**（候选是搜索条目、无 URL）—— 这条是决定，不是遗漏', () {
      final dlg = stripComments(
          File('lib/ui/widgets/source_switch_dialog.dart').readAsStringSync());
      /*
       * ★ 为什么这里断言"不接"而不是"接了"：
       *   该弹层渲染的是 searchAllStream 的**搜索命中条目**（MediaItem 只有
       *   id/title/note，**没有播放 URL**），而预检的输入是 URL ⇒ 没有可接的。
       *   硬凑一个接线点 = 又一处"接线了但没真接"（本批已踩过两次）。
       *   ⇒ 把它钉成"故意不接"，免得下一个人再补一个假接线。
       */
      expect(dlg.contains('panCheck'), isFalse,
          reason: '★ Lead 批复：换源弹层的候选没有 URL，预检不该接在这里');
    });
  });
}
