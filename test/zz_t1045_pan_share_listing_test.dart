// ═══════════════════════════════════════════════════════════════════════
//  t1045：网盘分享「列得出」—— 匿名列目录的界面落点（第 20 项）
// ═══════════════════════════════════════════════════════════════════════
//
// # 它守的是什么（"文案跑在能力前面"的收口）
// ```text
// `identify_pan_share` 的 reason 早就写着「未登录也能列出分享里的文件」，
// 而 Dart 侧对 `pan_list_share` **零调用点** ⇒ 那句话当时是空头承诺。
// 现在补了三截，缺一截用户就还是看不到：
//   ① Rust 已经实现（`pan_list_share`，匿名链路，真网络两条都过）
//   ② Dart 调用点 + 解析（`SourinApi.panListShare` / PanShareListing）
//   ③ 界面：有清单 ⇒ 画标题 + N 个条目 + note + 「可列不可播」；
//            失败 ⇒ 画**原因**；没点过 ⇒ 零尺寸
// ```
//
// # 为什么 ③ 用公开 widget 测（不挂整页）
// ```text
// 列目录是**真网络**（匿名链路要打上游），flutter test 里既没有 dll 也不该出网。
// 而"列表画没画、条目点没点名"是纯渲染 ⇒ 喂数据就能真验。
// ⇒ `PanShareListingSection` 三态公开，测试直接驱动；
//    注入「把 if 恒 false」即可证明 ① 的断言有牙。
// ```
//
// # 文案纪律（三道门禁刚绿）
// ```text
// 用户可见文案里：不许 markdown 星号、不许开发用语、不许站名。
// 本文件的断言会把渲染出的所有 Text 拼起来做这三项检查。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/design/widgets/app_text_button.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/pan_share_dialog.dart';

/// 与 Rust `pan_list::ShareListing::to_json` **逐字同形**的一份响应
Map<String, dynamic> rustJson() => <String, dynamic>{
      'ok': true,
      'kind': 'quark',
      'kindName': '夸克网盘',
      'shareId': 'abc123',
      'pwd': null,
      'title': '示例合集',
      'count': 3,
      'entries': <Map<String, dynamic>>[
        <String, dynamic>{'name': '第 01 集.mp4', 'size': 734003200, 'isDir': false},
        <String, dynamic>{'name': '第 02 集.mp4', 'size': 1048576, 'isDir': false},
        <String, dynamic>{'name': '花絮', 'size': 0, 'isDir': true},
      ],
      'note': '未登录时能列出 3 个文件，但取直链需要登录夸克网盘账号',
      'resolvable': false,
    };

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// 把某棵子树里所有 Text 拼起来（文案纪律检查用）
String allText(WidgetTester t, Finder scope) => t
    .widgetList<Text>(find.descendant(of: scope, matching: find.byType(Text)))
    .map((w) => w.data ?? '')
    .join('\n');

void main() {
  group('① 解析：Rust 吐的键逐字对应，坏数据不炸', () {
    test('★★ 正常响应 ⇒ title/entries/isDir/note/resolvable 全部读出', () {
      final l = PanShareListing.fromJson(rustJson());
      expect(l.title, '示例合集');
      expect(l.count, 3, reason: '★ count 必须等于真实条目数（不是另读一个字段）');
      expect(l.entries[0].name, '第 01 集.mp4');
      expect(l.entries[0].isDir, isFalse);
      expect(l.entries[0].sizeText, '700.0 MB',
          reason: '★ 人类可读大小（734003200 B ≈ 700 MB）');
      expect(l.entries[2].isDir, isTrue);
      expect(l.entries[2].sizeText, '',
          reason: '★ 目录不显示"0 B"噪声');
      expect(l.note, contains('能列出 3 个文件'));
      expect(l.resolvable, isFalse,
          reason: '★★ 能力边界：能列 ≠ 能播（Rust 恒 false，界面必须照实说）');
    });

    test('★★ 阴性：缺 entries / entries 里混坏元素 ⇒ 空清单，不抛', () {
      expect(PanShareListing.fromJson(const <String, dynamic>{}).count, 0);
      final mixed = PanShareListing.fromJson(<String, dynamic>{
        'entries': <dynamic>[
          'not-a-map',
          <String, dynamic>{'name': 'ok.txt', 'size': 10, 'isDir': false},
        ],
      });
      expect(mixed.count, 1, reason: '坏条目要跳过，好条目要留下');
      expect(mixed.entries.single.name, 'ok.txt');
    });
  });

  group('② 界面：有清单就点名画出来（注入可证伪）', () {
    testWidgets('★★★ 标题 + N 个条目 + 逐条名字/大小/目录 + note + 可列不可播',
        (t) async {
      await t.pumpWidget(host(
        PanShareListingSection(listing: PanShareListing.fromJson(rustJson())),
      ));
      await t.pump();

      final box = find.byKey(const ValueKey<String>('pan-share-listing'));
      expect(box, findsOneWidget,
          reason: '★★★ 核心说"能列出文件"，界面就必须画出来 —— '
              '把 section 里的 if 恒 false（注入）本条立刻红');

      expect(find.text('示例合集'), findsOneWidget, reason: '★ 标题要显示');
      expect(find.text('3 个条目'), findsOneWidget,
          reason: '★ 条目数必须是真数（3），不是"若干"');

      for (var i = 0; i < 3; i++) {
        expect(find.byKey(ValueKey<String>('pan-share-listing-entry-$i')),
            findsOneWidget,
            reason: '★★ 第 $i 条必须画出来（逐条列出才算"列得出"）');
      }
      expect(find.text('第 01 集.mp4'), findsOneWidget);
      expect(find.text('700.0 MB'), findsOneWidget);
      expect(find.text('花絮'), findsOneWidget);

      final note = find.byKey(const ValueKey<String>('pan-share-listing-note'));
      expect(t.widget<Text>(note).data, contains('能列出 3 个文件'),
          reason: '★★ note 原文要透出（用户才知道"能列但播不了"的边界）');

      final notResolvable =
          find.byKey(const ValueKey<String>('pan-share-listing-not-resolvable'));
      expect(notResolvable, findsOneWidget,
          reason: '★★ resolvable=false 必须显式说"可列不可播"，不许让用户以为能播');

      // 文案纪律：无星号、无开发用语、无站名
      final text = allText(t, box);
      expect(text.contains('**'), isFalse, reason: '★ 本仓没有 markdown 渲染器');
      for (final banned in const ['缺陷', 'Owner', '探针', 'task-', '尚未实现']) {
        expect(text.contains(banned), isFalse,
            reason: '★ 用户可见文案不许出现开发用语「$banned」');
      }
      for (final station in const ['tyyszy', 'sakura', 'cctv']) {
        expect(text.contains(station), isFalse,
            reason: '★ 不许出现站名「$station」');
      }
      // 能力边界：列表区里**不许**出现播放入口
      //
      // ⚠️ 不能断言"文案里不含『播放』二字" —— 那句如实的边界说明本身就会写
      //    「还不能用它播放」。要钉的是**没有可点的播放入口**。
      expect(find.widgetWithText(AppTextButton, '播放'), findsNothing,
          reason: '★★ 能列 ≠ 能播；出现可点的"播放"就等于给了假入口');
      expect(find.widgetWithText(FilledButton, '播放'), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsNothing,
          reason: '★ 连播放图标也不许有（用户会当成能播）');
    });
  });

  group('③ 空 / 失败：不画列表，且把原因说出来', () {
    testWidgets('★★ 有失败原因 ⇒ 只画原因、不画列表', (t) async {
      await t.pumpWidget(host(const PanShareListingSection(
        error: '列目录没有完成：分享已失效或需要提取码',
      )));
      await t.pump();

      expect(find.byKey(const ValueKey<String>('pan-share-listing')), findsNothing,
          reason: '★★ 拿不到目录时**不许**画一个空列表（那会被读成"分享里没文件"）');
      final err = find.byKey(const ValueKey<String>('pan-share-listing-error'));
      expect(err, findsOneWidget, reason: '★★ 必须如实显示失败原因');
      expect(t.widget<Text>(err).data, contains('分享已失效'),
          reason: '★ 原因要具体，不许只说"失败了"');
    });

    testWidgets('★★ 两者都没有 ⇒ 零尺寸（没点过就不占位）', (t) async {
      await t.pumpWidget(host(const PanShareListingSection()));
      await t.pump();
      expect(find.byKey(const ValueKey<String>('pan-share-listing')), findsNothing);
      expect(find.byKey(const ValueKey<String>('pan-share-listing-error')),
          findsNothing);
      expect(t.getSize(find.byType(PanShareListingSection)).height, 0,
          reason: '★ 没列过目录时不许占位（否则对话框凭空多一块空白）');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  ④ 接线：对话框真的调了 `panListShare`（防"组件做好了但没人用"）
  // ─────────────────────────────────────────────────────────────────
  //
  // ⚠️ 为什么这条只能是源码判据：`identify` 与 `panListShare` 都要 FFI，
  //    整页挂载 + 真点击在 flutter test 里跑不到（没有 dll）。
  //    渲染那三态已在 ②③ **真跑**，这里只补最后一截"有没有接上"。
  group('④ 接线', () {
    test('★★ 对话框真的调 SourinApi.panListShare，且入口按钮只在识别成功后出现',
        () {
      final src = File('lib/ui/widgets/pan_share_dialog.dart').readAsStringSync();
      expect(src.contains('SourinApi.panListShare('), isTrue,
          reason: '★★ 组件做好了但对话框不调它 ⇒ 用户仍然列不出文件'
              '（本次要修的正是这个"零调用点"）');
      expect(src.contains("key: const ValueKey<String>('pan-share-list-files')"),
          isTrue,
          reason: '★ 入口按钮必须在（否则用户没有触发点）');
      expect(src.contains('if (s.recognized)'), isTrue,
          reason: '★ 入口只在"认出盘且拿到分享 id"之后出现（认不出时列目录没有意义）');
    });
  });
}
