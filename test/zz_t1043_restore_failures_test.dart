// ═══════════════════════════════════════════════════════════════════════
//  t1043：恢复失败清单的「读取方 + 界面提示」门禁（第19项第 4 处不告知）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守的是什么
//
// csp 源重启恢复失败时，以前只有：日志一句 warn + 磁盘一个 restore-failures.json，
// **界面上什么都不说**。这次补了三截，缺一截用户就还是看不到原因：
// ```text
// ① Rust 侧命令：ffi.rs 必须有 `restore_failures` 分支（只读、纯本地）
// ② Dart 侧解析：{"count":N,"items":[…]} → List<RestoreFailure>（字段逐字对应）
// ③ 界面：有清单 ⇒ 画提示并**点名**源；清单为空 ⇒ **不画**（阴性对照）
// ```
//
// ⚠️ 为什么 ① 只能做源码判据：`flutter test` 里没有 dll，
//    `callAsync('restore_failures')` 必失败 ⇒ 命令是否被删只能读源码；
//    而 ②③ 都是纯函数/纯渲染，**真跑**。
//
// 跑法：`flutter test test/zz_t1043_restore_failures_test.dart`
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

void main() {
  group('① Rust 侧命令已接线（源码判据，因为没有 dll 就跑不到它）', () {
    test('★★ ffi.rs 里有 restore_failures 分支，且走只读的 with_state', () {
      // ffi.rs 含 NUL 字节 ⇒ 用字节读，不做文本断言之外的解码假设
      final bytes = File('rust/sourin_core/src/ffi.rs').readAsBytesSync();
      final src = String.fromCharCodes(bytes.where((b) => b != 0));
      expect(
        src.contains('"restore_failures" =>'),
        isTrue,
        reason: '★★ 命令名必须逐字是 restore_failures（Dart 侧 callAsync 用的就是它）。'
            '删掉这条分支 ⇒ 本条立刻红（注入①）。',
      );
      final i = src.indexOf('"restore_failures" =>');
      /*
       * ⚠️ 窗口按**字符**算，而中文在 UTF-8 里是 3 字节 ⇒ 这段注释+代码在
       * "按字节读成字符"的字符串里会膨胀 3 倍。600 字符不够（首次跑就栽在这），
       * 取 3000 仍远小于文件长度，且不跨到下一条命令（下一条在 +6KB 之后）。
       */
      final seg = src.substring(i, (i + 3000).clamp(0, src.length));
      expect(
        seg.contains('with_state('),
        isTrue,
        reason: '★ 纯本地读必须走 with_state（同步），不许走 with_state_async —— '
            '读一个 sidecar 不需要网络，也不该占用异步通道',
      );
      expect(
        seg.contains('restore_failures_json'),
        isTrue,
        reason: '★ 数据必须来自 persist::restore_failures_json（count 与 items 同源）',
      );
    });
  });

  group('② Dart 解析：字段逐字对应，坏数据不炸', () {
    test('★★★ 正常清单：count/items → List<RestoreFailure>', () {
      final rows = SourinApi.parseRestoreFailures(<String, dynamic>{
        'count': 2,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'tvbox3',
            'api': 'csp_PanWebShare',
            'reason': 'csp_PanWebShare 尚未实现',
          },
          <String, dynamic>{
            'id': 'tvbox4',
            'api': 'csp_AppDrama',
            'reason': 'csp_AppDrama 尚未实现',
          },
        ],
      });
      expect(rows.length, 2, reason: '两条都必须解析出来，实际 $rows');
      expect(rows[0].displayName, 'csp_PanWebShare',
          reason: '★ 展示名优先用 api（用户能照着在配置里找到是哪一条）');
      expect(rows[0].reason, 'csp_PanWebShare 尚未实现',
          reason: '★★ reason 必须**原样**透出 —— 实现层说是「尚未实现」，'
              '界面不许改写成「加载失败」（那会把"等版本"说成"重试就行"）');
    });

    test('★★ 阴性：空 items / 缺字段 / 没有 items 键 ⇒ 空清单，不抛', () {
      expect(SourinApi.parseRestoreFailures(<String, dynamic>{}), isEmpty);
      expect(
        SourinApi.parseRestoreFailures(<String, dynamic>{'count': 0, 'items': <dynamic>[]}),
        isEmpty,
      );
      // 缺 id 与 api 的垃圾行必须被丢掉（不许在界面上画出空名字）
      final dirty = SourinApi.parseRestoreFailures(<String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{'reason': '只有原因'},
          <String, dynamic>{'id': 'x', 'api': 'csp_Y', 'reason': 'y 尚未实现'},
        ],
      });
      expect(dirty.length, 1, reason: '没名字的行要丢掉，实际 $dirty');
      expect(dirty[0].displayName, 'csp_Y');
    });
  });

  group('③ 界面：有清单点名画、空清单一行不画', () {
    Widget host(Widget child) => MaterialApp(
          theme: AppTheme.themeFor(Brightness.dark),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        );

    const sample = <RestoreFailure>[
      RestoreFailure(
        id: 'tvbox3',
        api: 'csp_PanWebShare',
        reason: 'csp_PanWebShare 尚未实现',
      ),
    ];

    testWidgets('★★★ 有失败 ⇒ 画提示、点名源、说清后果与下一步', (t) async {
      await t.pumpWidget(host(const TvboxRestoreFailuresView(failures: sample)));
      await t.pump();

      final box = find.byKey(const ValueKey<String>('tvbox-restore-failures'));
      expect(box, findsOneWidget, reason: '★★★ 有失败就必须画出来（注入②：if 恒 false 时本条红）');

      final all = t
          .widgetList<Text>(find.descendant(of: box, matching: find.byType(Text)))
          .map((w) => w.data ?? '')
          .join('\n');
      expect(all, contains('上次启动没能恢复 1 个源'), reason: '标题要说清"几个"');
      expect(all, contains('csp_PanWebShare'),
          reason: '★★ 必须点名（用户要知道是不是自己正在用的那条）');
      expect(all, contains('尚未实现'),
          reason: '★★ 原因要照原样说 —— 这是用户判断"等版本还是重试"的唯一依据');
      expect(all, contains('重新导入'),
          reason: '★ 还要给下一步（只说坏了、不说怎么办，等于把问题丢回给用户）');

      // 用户文案纪律：不许出现 markdown 星号与开发用语
      expect(all.contains('**'), isFalse, reason: '★ 本仓没有 markdown 渲染器，** 会原样显示');
      for (final banned in const ['修复', '缺陷', 'Owner', '探针', 'task-']) {
        expect(all.contains(banned), isFalse,
            reason: '★ 用户可见文案里不许出现开发用语「$banned」');
      }
    });

    testWidgets('★★★ 阴性：空清单 / 未注入且读不到 ⇒ 一行都不画（零尺寸）', (t) async {
      await t.pumpWidget(host(const TvboxRestoreFailuresView(failures: <RestoreFailure>[])));
      await t.pump();
      expect(
        find.byKey(const ValueKey<String>('tvbox-restore-failures')),
        findsNothing,
        reason: '★★ 没有失败时挂一条常驻红字 ⇒ 用户学会无视它，警示就失效了',
      );
      final size = t.getSize(find.byType(TvboxRestoreFailuresView));
      expect(size.height, 0, reason: '空清单必须是零尺寸（不许占位）');
    });

    testWidgets('★ 超过 5 条只列前 5 + 一句"还有 N 个"，不刷屏', (t) async {
      final many = List<RestoreFailure>.generate(
        7,
        (i) => RestoreFailure(id: 'id$i', api: 'csp_X$i', reason: 'csp_X$i 尚未实现'),
      );
      await t.pumpWidget(host(TvboxRestoreFailuresView(failures: many)));
      await t.pump();
      expect(find.byKey(const ValueKey<String>('tvbox-restore-failures')), findsOneWidget);
      expect(find.textContaining('上次启动没能恢复 7 个源'), findsOneWidget);
      expect(find.textContaining('还有 2 个没列出'), findsOneWidget);
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ④ 挂到「源列表页」：列表头部那一行（第 19 项最后一跳）
  // ═════════════════════════════════════════════════════════════════════
  //
  // # 这一组补的是**接线 + 异步读取**，不是组件本身
  // ```text
  // ③ 组证的是"给一份清单，它画不画"（构造参数直喂）。
  // 本组证的是另外两件事：
  //   ① 它走**核心读取**那条路（`SourinApi.restoreFailures` → fetcher 注入）；
  //   ② 源列表页的头部**真的把它挂上了**。
  // 少了 ②，把 `TvboxRestoreFailuresView()` 从列表头删掉，③ 组**照样全绿**
  // —— 那正是"做完了但没接上"的经典漏法。
  // ```
  //
  // ⚠️ 挂载点为什么用源码判据而不是整页渲染：源列表是**二级页**
  //    （`_PluginsPage`，同文件里是私有类，构造要 `SettingsPageState` 宿主），
  //    整页挂载还要预载 dll + 真导航才能到。渲染断言已在上面/下面真跑，
  //    这里只补"那一行在不在、在不在最上面"。
  group('④ 源列表页头部已挂载（接线 + 异步读取路径）', () {
    tearDown(() {
      SourinApi.debugRestoreFailuresFetcher = null;
    });

    Widget host(Widget child) => MaterialApp(
          theme: AppTheme.themeFor(Brightness.dark),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        );

    testWidgets('★★★ 核心给出清单 ⇒ 列表头部那一条真画出来并点名', (t) async {
      SourinApi.debugRestoreFailuresFetcher =
          () async => const <RestoreFailure>[
                RestoreFailure(
                  id: 'tvbox9',
                  api: 'csp_AppDrama',
                  reason: 'csp_AppDrama 尚未实现',
                ),
              ];

      await t.pumpWidget(host(const TvboxRestoreFailuresView()));
      // 异步读取路径：`initState` 里发起，落地后 setState ⇒ 需要两帧
      await t.pump();
      await t.pump();

      final box = find.byKey(const ValueKey<String>('tvbox-restore-failures'));
      expect(box, findsOneWidget,
          reason: '★★★ 核心说"上次有源没恢复"，列表页就必须画出来 —— '
              '把 if 改成恒 false（注入）本条立刻红');
      final all = t
          .widgetList<Text>(find.descendant(of: box, matching: find.byType(Text)))
          .map((w) => w.data ?? '')
          .join('\n');
      expect(all, contains('csp_AppDrama'),
          reason: '★★ 必须点名（用户要知道是哪一条没回来）');
      expect(all, contains('尚未实现'), reason: '★★ 原因照原样透出');
    });

    testWidgets('★★ 核心返回空清单 ⇒ 一行不画、零尺寸（不占位）', (t) async {
      SourinApi.debugRestoreFailuresFetcher = () async => const <RestoreFailure>[];

      await t.pumpWidget(host(const TvboxRestoreFailuresView()));
      await t.pump();
      await t.pump();

      expect(find.byKey(const ValueKey<String>('tvbox-restore-failures')),
          findsNothing,
          reason: '★★ 一切正常时列表头不许挂任何提示（阴性对照）');
      expect(t.getSize(find.byType(TvboxRestoreFailuresView)).height, 0,
          reason: '★ 空清单必须零尺寸，不能悄悄占掉列表上方一块空白');
    });

    test('★ 挂载点：列表头部第一行就是这个组件（在动作按钮之前）', () {
      final src = File('lib/ui/settings_page.dart').readAsStringSync();
      final mount = src.indexOf('const TvboxRestoreFailuresView(),');
      expect(mount, greaterThan(0),
          reason: '★ 组件没被挂上 ⇒ 用户永远看不到恢复失败（③④ 渲染断言也管不到挂载点）');
      final install = src.indexOf('onPressed: _installPlugin,');
      expect(install, greaterThan(0), reason: '前提：找到动作按钮区');
      expect(mount, lessThan(install),
          reason: '★ 必须在动作按钮**之前**（= 列表最上面）：放在卡片后面等于没说');
    });
  });
}
