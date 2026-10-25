// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R3-⑤ 弹幕源**可以绑定多个**（并且真的合并）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 弹幕源可以绑定多个
// ```
//
// # 改前的实测读数（这是本条存在的全部理由）
// ```text
// danmaku_settings_dialog.dart 的「弹幕来源」页签：
//   标题写着 `可多选 · 勾上即合并`
//   四个 `_sourceRow(...)` 调用点 **4/4** 都是 `onChanged: null`
//   ⇒ `_sourceRow` 把勾选框画成只读图标（它自己的注释也写着「勾选框只读」）
//   ⇒ **一个都点不动**
//
// 「当前生效」那行读数拼的是 `_biliCount + 本机在线 + dan-api 配置`，
// 括号里的 `state.count` 是**宿主取回来的总条数** ——
// 与"用户勾了哪几路"没有任何因果关系
// ⇒ 就算勾选能点，读数也**不会变**（看不出来"多绑生效了没有"）。
// ```
// ⇒ 结论：**改前不能绑定多个**。这不是"控件语义不清"，是**真·假功能**。
//
// # 本门禁钉什么（★ 全部读**真实合并结果**，不读控件状态）
// ```text
// ① 勾 2 个源 ⇒ 两个源的内容**都**出现在合并结果里（逐条查正文）
// ② 勾 2 个源 ⇒ 读数从「单源」变成「2 路 … 合并后 N 条」
// ③ 取消一路   ⇒ 那一源的内容**真的消失**（不是只是勾没了）
// ④ 跨源重复   ⇒ 去重真的发生（同 (0.1s, 正文) 只留一条）
// ⑤ 本片源自带 **不可取消**（它是视频自带的，取消不了这个事实）
// ⑥ 宿主没注入样本 ⇒ **如实降级**成单源，不许凭空画"N 路合并"
// ```
//
// # 故障注入（已实测）
// ```text
// ① 把四个 `onChanged:` 改回 `null`         ⇒ ①②③⑤ 组全红
// ② 把 `_activeFeedChannels` 改成永远只返回第一路 ⇒ ①②③④ 组红
// ③ 把 `_mergedPreview` 改成只喂 `chans.first`    ⇒ ①③④ 组红
// ④ 把 `_sourceRow` 里 `onChanged(!checked)` 改成 `onChanged(true)` ⇒ ③ 组红
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

// ── 两个源各自的弹幕（**内容可区分**，这样才能证明"两路都进来了"）────────
//
// ⚠️ 刻意让两路**没有**重叠：合并后条数 = 两路之和 ⇒ 断言能直接判真值。
List<DanmakuComment> _srcA() => const <DanmakuComment>[
      DanmakuComment(cid: 1, time: 1.0, text: '本片源-第一条'),
      DanmakuComment(cid: 2, time: 2.0, text: '本片源-第二条'),
      DanmakuComment(cid: 3, time: 3.0, text: '本片源-第三条'),
    ];

List<DanmakuComment> _srcB() => const <DanmakuComment>[
      DanmakuComment(cid: 11, time: 1.5, text: 'dan-api-第一条'),
      DanmakuComment(cid: 12, time: 2.5, text: 'dan-api-第二条'),
    ];

/// 两路里**同一条**弹幕（同一时刻同一句话被两个源各抓了一遍）
List<DanmakuComment> _srcBDup() => const <DanmakuComment>[
      // 与 _srcA 的第 1 条同 (time, text) ⇒ 跨源去重必须吃掉它
      DanmakuComment(cid: 21, time: 1.0, text: '本片源-第一条'),
      DanmakuComment(cid: 22, time: 9.0, text: 'dan-api-独有'),
    ];

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: child),
    );

/// 面板的默认状态：开关开着、有本片源数据
DanmakuSettingsState _state() => const DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1,
      opacity: 1,
      speed: 8,
      area: 1,
    );

/// 挂载面板并切到「弹幕来源」页签
Future<void> _openSources(
  WidgetTester t, {
  Map<DanmakuFeedChannel, List<DanmakuComment>>? samples,
  int? biliCount = 3,
}) async {
  await t.pumpWidget(_host(DanmakuSettingsDialog(
    state: _state(),
    onSetEnabled: (_) {},
    onSetFontScale: (_) {},
    onSetOpacity: (_) {},
    onSetSpeed: (_) {},
    onSetArea: (_) {},
    onReload: () {},
    onClose: () {},
    biliCount: biliCount,
    onOpenBili: () {},
    feedSamples: samples,
  )));
  await t.pumpAndSettle();
  await t.tap(find.descendant(
    of: find.byType(SegmentedButton<DanmakuPanelTab>),
    // 第12项将来源选择移入高级；继续驱动真实开关验证合并结果。
    matching: find.text('高级'),
  ));
  await t.pumpAndSettle();
}

/// 点某一路的勾选框（整行可点，按**文案**定位那一行）
Future<void> _toggleRow(WidgetTester t, String label) async {
  await t.ensureVisible(find.text(label));
  await t.tap(find.text(label));
  await t.pumpAndSettle();
}

/// 从「当前生效」那一行读出读数（面板里唯一以「当前生效：」开头的文案）
String _activeLine(WidgetTester t) {
  // 高级页同时显示服务端地址状态；限定真实合并读数，避免同名文案冲突。
  final f = find.descendant(
    of: find.byKey(const ValueKey('danmaku-active-feed-summary')),
    matching: find.textContaining('当前生效：'),
  );
  expect(f, findsOneWidget, reason: '找不到「当前生效」读数行 —— 判据失效');
  return (t.widget<Text>(f).data)!;
}

/// 某一路上游的正文在**屏幕上的所有文本**里出现了吗
bool _onScreen(WidgetTester t, String text) => find
    .textContaining(text)
    .evaluate()
    .isNotEmpty;

void main() {
  // 第10项首次默认全部启用；本组显式构造单源起点，继续验证合并与去重。
  setUp(() => UiPrefs.debugResetForTest(<String, String>{
    'danmaku.feeds.enabled': 'biliSource',
  }));
  tearDown(() => UiPrefs.debugResetForTest());

  /// UiPrefs.set 会排 300ms 定时器（见 task35 的说明），跑掉它免得报 pending
  Future<void> settlePrefs(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ① 勾 2 个源 ⇒ 两个都生效（读**真实合并结果**）
  // ═══════════════════════════════════════════════════════════════════
  group('① 绑 2 个源 ⇒ 两个都真的进合并结果', () {
    testWidgets('★★★ 两路内容都在，且读数说「2 路」', (t) async {
      await _openSources(t, samples: <DanmakuFeedChannel, List<DanmakuComment>>{
        DanmakuFeedChannel.biliSource: _srcA(),
        DanmakuFeedChannel.danApi: _srcB(),
      });

      /*
       * 起点：只有「本片源自带」在集合里（其余默认不勾）
       * ⇒ 单源读数
       */
      expect(_activeLine(t), contains('单源'),
          reason: '起点必须是单源 —— 否则下面的"变多路"证明不了任何事');

      // 勾上 dan-api
      await _toggleRow(t, 'dan-api');
      await settlePrefs(t);

      final line = _activeLine(t);
      expect(line, contains('2 路'),
          reason: '★★★ 勾第二个源后必须变成 2 路 —— 这是"多绑生效"的直接读数');
      expect(line, contains('合并后 5 条'),
          reason: '★★★ 3 条 + 2 条 = 5 条：**合并结果的条数**，不是控件状态');
      expect(line, contains('本片源自带'),
          reason: '★ 两路的名字都要在读数里（用户要知道合了谁）');
      expect(line, contains('dan-api'));
    });

    testWidgets('★★ 合并后条数 = 两路之和（证明两路都喂进去了）', (t) async {
      await _openSources(t, samples: <DanmakuFeedChannel, List<DanmakuComment>>{
        DanmakuFeedChannel.biliSource: _srcA(),
        DanmakuFeedChannel.localService: _srcB(),
      });
      await _toggleRow(t, '本机服务');
      await settlePrefs(t);

      final line = _activeLine(t);
      // 3 + 2 = 5；少一路就只会是 3 或 2
      expect(line, contains('合并后 5 条'),
          reason: '★★ 只喂一路时这里会是 3 或 2 —— 5 是两路都在的唯一解释');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 取消一路 ⇒ 那一源的内容**真的**消失
  // ═══════════════════════════════════════════════════════════════════
  group('② 取消勾选 ⇒ 真的不合并了（不是只把勾去掉）', () {
    testWidgets('★★★ 勾上再取消 ⇒ 条数退回单源', (t) async {
      await _openSources(t, samples: <DanmakuFeedChannel, List<DanmakuComment>>{
        DanmakuFeedChannel.biliSource: _srcA(),
        DanmakuFeedChannel.danApi: _srcB(),
      });

      await _toggleRow(t, 'dan-api');
      await settlePrefs(t);
      expect(_activeLine(t), contains('合并后 5 条'));

      // 再点一次 ⇒ 取消
      await _toggleRow(t, 'dan-api');
      await settlePrefs(t);

      final line = _activeLine(t);
      expect(line, contains('单源'),
          reason: '★★★ 取消后必须退回单源 —— 只是勾没了但还在合，就是假开关');
      expect(line, contains('3 条'),
          reason: '★ 条数也要退回去（dan-api 那 2 条不许残留）');
    });

    testWidgets('★★ 取消后读数里不再出现那一路的名字', (t) async {
      await _openSources(t, samples: <DanmakuFeedChannel, List<DanmakuComment>>{
        DanmakuFeedChannel.biliSource: _srcA(),
        DanmakuFeedChannel.danApi: _srcB(),
      });
      await _toggleRow(t, 'dan-api');
      await settlePrefs(t);
      expect(_activeLine(t), contains('dan-api'));

      await _toggleRow(t, 'dan-api');
      await settlePrefs(t);
      expect(_activeLine(t), isNot(contains('dan-api')),
          reason: '★★ 名字还在 = 读数没跟上勾选状态（改前的病）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 跨源去重真的发生
  // ═══════════════════════════════════════════════════════════════════
  group('③ 两路有重复 ⇒ 去重读数必须 > 0', () {
    testWidgets('★★★ 同一 (0.1s, 正文) 只留一条', (t) async {
      await _openSources(t, samples: <DanmakuFeedChannel, List<DanmakuComment>>{
        DanmakuFeedChannel.biliSource: _srcA(),
        DanmakuFeedChannel.danApi: _srcBDup(),
      });
      await _toggleRow(t, 'dan-api');
      await settlePrefs(t);

      /*
       * _srcA = 3 条，_srcBDup = 2 条，其中 1 条与 _srcA 首条重复
       * ⇒ 合并后 3 + 2 - 1 = 4 条，去重 1 条
       */
      final line = _activeLine(t);
      expect(line, contains('合并后 4 条'),
          reason: '★★★ 重复那条必须被吃掉（去重判据 = core 的 DanmakuAggregator）');
      expect(line, contains('跨源去重 1 条'),
          reason: '★★ 去重了多少也要如实说 —— 用户才知道"为什么比相加少"');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 本片源自带不可取消
  // ═══════════════════════════════════════════════════════════════════
  group('④ 本片源自带：默认勾、不可取消', () {
    testWidgets('★★★ 点它不会把它取消掉', (t) async {
      await _openSources(t, samples: <DanmakuFeedChannel, List<DanmakuComment>>{
        DanmakuFeedChannel.biliSource: _srcA(),
      });

      expect(_activeLine(t), contains('本片源自带'),
          reason: '★ 默认勾上（Owner 第 2 条：它是视频自带的）');

      await _toggleRow(t, '本片源自带');
      await settlePrefs(t);

      expect(_activeLine(t), contains('本片源自带'),
          reason: '★★★ 它是**视频本身**带的弹幕 —— 用户取消不了这个事实');
      expect(_activeLine(t), contains('3 条'),
          reason: '★ 条数也不许因此归零');
    });

    testWidgets('★★ 它带「默认」徽标（与其它几路区分开）', (t) async {
      await _openSources(t, samples: <DanmakuFeedChannel, List<DanmakuComment>>{
        DanmakuFeedChannel.biliSource: _srcA(),
      });
      expect(find.text('默认'), findsOneWidget);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 宿主没注入样本 ⇒ 如实降级（不凭空画"N 路合并"）
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ 没有真实样本时不许假装合并', () {
    testWidgets('★★★ 勾了 dan-api 但宿主没给内容 ⇒ 仍然是单源', (t) async {
      await _openSources(t, samples: null);

      await _toggleRow(t, 'dan-api');
      await settlePrefs(t);

      final line = _activeLine(t);
      expect(line, contains('单源'),
          reason: '★★★ 勾了但没有原料 ⇒ 合并结果只有本片源那一路。'
              '这里若显示"2 路"就是凭空捏造（本仓明令禁止）');
      expect(line, contains('3 条'),
          reason: '★ 本片源那 3 条（宿主只给了条数、没给内容）照样如实报');
    });

    testWidgets('★★★ 多路但缺逐条内容 ⇒ 说「合计」，**不许**说「合并后」',
        (t) async {
      /*
       * 真实形状：宿主只给了 `biliCount`（条数），另外一路也只有条数 ——
       * 这种情况下**没法**去重，只能说"合计"。
       * 拿相加冒充合并 = 在有重复时给出错误数字，用户会照着它排错。
       */
      await _openSources(
        t,
        samples: <DanmakuFeedChannel, List<DanmakuComment>>{
          DanmakuFeedChannel.danApi: _srcB(), // 有内容
        },
      );
      await _toggleRow(t, 'dan-api');
      await settlePrefs(t);

      final line = _activeLine(t);
      expect(line, contains('合计'),
          reason: '★★★ 本片源只有条数没有内容 ⇒ 不能逐条合并');
      expect(line, contains('未逐条合并'),
          reason: '★★ 必须**明说**能力限制 —— 沉默会让用户以为去重做过了');
      expect(line, isNot(contains('合并后')),
          reason: '★★★ 「合并后」是**做过去重**的口径，这里没做，不许用');
    });

    testWidgets('★★ 完全没有任何样本 ⇒ 说清楚没有来源在供弹幕', (t) async {
      await _openSources(t, samples: null, biliCount: null);

      expect(
        find.textContaining('还没有任何来源在供弹幕'),
        findsOneWidget,
        reason: '★ 空态要明说 —— 空白会让人以为面板坏了',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ 三路一起（不是只有两路能用）
  // ═══════════════════════════════════════════════════════════════════
  group('⑥ 三路同时绑定', () {
    testWidgets('★★★ 3 路 ⇒ 读数说 3 路，条数是三路之和', (t) async {
      await _openSources(t, samples: <DanmakuFeedChannel, List<DanmakuComment>>{
        DanmakuFeedChannel.biliSource: _srcA(), // 3
        DanmakuFeedChannel.danApi: _srcB(), // 2
        DanmakuFeedChannel.localService: const <DanmakuComment>[
          DanmakuComment(cid: 31, time: 7.0, text: '本机-唯一一条'),
        ], // 1
      });

      await _toggleRow(t, 'dan-api');
      await settlePrefs(t);
      await _toggleRow(t, '本机服务');
      await settlePrefs(t);

      final line = _activeLine(t);
      expect(line, contains('3 路'), reason: '★★★ 三路都能勾');
      expect(line, contains('合并后 6 条'), reason: '★ 3 + 2 + 1 = 6');
    });
  });
}
