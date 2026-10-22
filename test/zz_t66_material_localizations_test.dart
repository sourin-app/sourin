// 门禁：WidgetsApp 的 localizationsDelegates 必须真的提供
// **material_ui 的** MaterialLocalizations，且 zh_CN 下拿到的是**中文**。
//
// ## 为什么需要这条（两次真实故障）
//
// ```text
// 第一次（2026-10-18，M4：MaterialApp → WidgetsApp）：
//   delegates 只放了 Widgets / Cupertino，**漏了 Material 的**
//   ⇒ 真机隔离启动，第一次弹更新窗就崩：
//     Unhandled Exception: Null check operator used on a null value
//     #0  MaterialLocalizations.of (material_ui/src/material_localizations.dart:718)
//     #1  new DialogRoute        (material_ui/src/dialog.dart:1906)
//     #5  showAppDialog          (ui/widgets/overlay_motion.dart:324)
//
// 第二次（2026-10-18 同一天，修法错误）：
//   补了 `DefaultMaterialLocalizations.delegate` —— 它在 zh_CN 下**不加载**
//   （isSupported = languageCode == 'en'）⇒ 真机仍然崩。
//   于是自建 `_AnyLocaleMaterialDelegate`（无脑 true + 硬编码英文）
//   ⇒ 不崩了，但中文用户开读屏听到的是英文 "Dismiss"。
//
// 第三次（2026-10-22，PR #32 CodeRabbit 线程 2）：
//   material_ui 1.6.0 自带 `GlobalMaterialLocalizations`
//   （global_material_localizations.dart:72 实现的是 **material_ui 自己的**
//   MaterialLocalizations）⇒ 既同源、又有真中文。
//   `lib/shell.dart` 改成顶层常量 `kAppLocalizationsDelegates`，
//   本门禁**真的把它挂到树上**做行为断言。
// ```
//
// ## 这条门禁守什么（行为级，不是 grep 类名）
//
// ```text
// ① 挂上 kAppLocalizationsDelegates + Locale('zh','CN')
//    ⇒ `MaterialLocalizations.of(context)` 非 null（不崩）
//    ⇒ `modalBarrierDismissLabel` 是**中文**（'关闭'），不是 'Dismiss'
// ② 同一组代理换成 en_US ⇒ 拿到英文（证明 locale 真的被尊重，
//    ① 的中文不是某处硬编码的巧合）
// ③ 负向读数：把这组代理里的 Material 项滤掉再挂 ⇒ `of()` 必须抛
//    —— 这就是 2026-10-18 那次线上崩溃的形状，门禁必须能看见它
// ④ 类型锚：我们这套里的 Material 代理必须是 material_ui 的
//    MaterialLocalizations（与 DialogRoute 同源）；Cupertino 代理必须是
//    **flutter 侧**的 CupertinoLocalizations（material_ui 的整包 delegates
//    里的 Cupertino 来自 cupertino_ui，类型不同 ⇒ 不能整包换）
// ⑤ 接线：`lib/shell.dart` 的 WidgetsApp 真的用了这个常量
//    （常量存在但 App 没用它 = 白改）
// ⑥ 判据自检：提取函数不能吃整文件（否则 ⑤ 会假绿）
// ```
//
// ## 怎么证明它会红
//
// ```text
// · 往 kAppLocalizationsDelegates 里去掉 Material 那一项 ⇒ ① 立刻红
// · 把 Material 项换回 DefaultMaterialLocalizations.delegate ⇒ ① 红在中文字符断言上
// · 把 WidgetsApp 的 localizationsDelegates 改回字面量列表 ⇒ ⑤ 红
// 见提交信息里的注入读数。
// ```
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoLocalizations;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart'
    show GlobalMaterialLocalizations, MaterialLocalizations;
import 'package:sourin_spike/shell.dart' show kAppLocalizationsDelegates;

/// 中文（CJK 统一表意文字）判据：至少一个汉字。
final RegExp _cjk = RegExp(r'[\u4e00-\u9fff]');

/// 从 `lib/shell.dart` 里取出 `localizationsDelegates:` 这个**实参**。
///
/// ★ 不用裸 `indexOf` 找 delegate 名 —— 文件里有多处注释引用这些名字
/// （2026-10-18 踩过「命中注释」的坑），所以先定位参数名，
/// 再取到该实参结束的那个逗号为止。
String _extractDelegatesArg(String src) {
  // 剔除注释行，避免命中注释里的引用
  final code = StringBuffer();
  for (final line in src.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('*') ||
        t.startsWith('//') ||
        t.startsWith('/*') ||
        t.startsWith('*/')) {
      continue;
    }
    code.writeln(line);
  }
  final clean = code.toString();

  const key = 'localizationsDelegates:';
  final i = clean.indexOf(key);
  expect(i, greaterThan(0),
      reason: '★ 找不到 `$key` —— 判据失效，'
          '说明 WidgetsApp 的构造参数名变了，本门禁需要更新');

  // 从参数名之后取到「同一层级的逗号」为止（括号/方括号配对）
  var depth = 0;
  var end = -1;
  for (var p = i + key.length; p < clean.length; p++) {
    final c = clean[p];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth < 0) {
        end = p;
        break;
      }
    }
    if (c == ',' && depth == 0) {
      end = p;
      break;
    }
  }
  expect(end, greaterThan(i),
      reason: '★ `$key` 这个实参没有结束（没有逗号也没有右括号）—— 源码结构异常');

  return clean.substring(i, end);
}

/// 把一组代理挂到树上，返回**稳定之后**的 Builder context。
///
/// ★ 为什么要 `pumpAndSettle`：`Localizations` 的 delegate 加载是异步的
/// （即使 Global* 返回的是 SynchronousFuture，`LocalizationsState._loadAll`
/// 仍然要过一个 microtask）。首帧就去 `of(context)` 会拿到"还没加载"的
/// 状态 ⇒ 门禁会对着一个假红/假绿下结论。
Future<BuildContext> _mountAndSettle(
  WidgetTester tester, {
  required Locale locale,
  required List<LocalizationsDelegate<dynamic>> delegates,
}) async {
  late BuildContext ctx;
  await tester.pumpWidget(Localizations(
    locale: locale,
    delegates: delegates,
    child: Builder(builder: (c) {
      ctx = c;
      return const SizedBox(width: 8, height: 8);
    }),
  ));
  await tester.pumpAndSettle();
  return ctx;
}

void main() {
  group('★★★ 行为级：真的挂上代理，看 MaterialLocalizations 拿到什么', () {
    testWidgets('★★★ zh_CN ⇒ MaterialLocalizations 非 null 且 barrier 标签是中文', (tester) async {
      final ctx = await _mountAndSettle(
        tester,
        locale: const Locale('zh', 'CN'),
        delegates: kAppLocalizationsDelegates,
      );

      // ① 不再崩：`of()` 内部是 `Localizations.of<T>(...)!`，
      //    拿不到就抛 TypeError（2026-10-18 的真机崩溃形状）。
      late MaterialLocalizations loc;
      expect(
        () => loc = MaterialLocalizations.of(ctx),
        returnsNormally,
        reason: '★★★ zh_CN 下 `MaterialLocalizations.of(context)` 抛异常 —— '
            '这正是 2026-10-18 真机崩溃的形状（Null check operator used on a '
            'null value）。说明 kAppLocalizationsDelegates 里的 Material 代理'
            '对 zh_CN 不生效（例如换成了只认 en 的 Default 版）。',
      );

      final label = loc.modalBarrierDismissLabel;

      // ② 是中文，不是英文
      expect(
        _cjk.hasMatch(label),
        isTrue,
        reason: '★★★ zh_CN 下 `modalBarrierDismissLabel` = "$label" —— '
            '**不是中文**。中文本地化没生效：中文用户开读屏听到的是英文。',
      );
      expect(
        label,
        isNot('Dismiss'),
        reason: '★★★ 拿到的是英文默认文案 "Dismiss" —— '
            '说明挂的是 DefaultMaterialLocalizations（只有英文），'
            '或者 Material 代理压根没进树。',
      );
      // ③ 版本锚：material_ui 1.6.0 的 zh 文案逐字是 '关闭'
      //    （generated_material_localizations.dart:45298）
      expect(
        label,
        '关闭',
        reason: '★★ `modalBarrierDismissLabel` 的中文文案变了。\n'
            '当前锚的是 material_ui 1.6.0（'
            'generated_material_localizations.dart:45298 => 关闭）。\n'
            '★ 如果只是升级 material_ui：去读新版的 zh 文案再**有意识**改这里，'
            '不要为了让门禁变绿而改；不同就说明上游文案变了，要记一笔。',
      );
    });

    testWidgets('★ 阴性对照：同一组代理换成 en_US ⇒ 英文（证明 locale 真被尊重）',
        (tester) async {
      final ctx = await _mountAndSettle(
        tester,
        locale: const Locale('en', 'US'),
        delegates: kAppLocalizationsDelegates,
      );
      final loc = MaterialLocalizations.of(ctx);
      final label = loc.modalBarrierDismissLabel;

      expect(label, 'Dismiss',
          reason: '★ en_US 下拿到的不是 "Dismiss"（而是 "$label"）—— '
              '说明本地化没按 locale 切换。'
              '另一种解释：上面那条"中文"断言可能是某处硬编码的巧合。');
      expect(_cjk.hasMatch(label), isFalse,
          reason: '★★ en_US 下拿到了中文 "$label" —— locale 根本没被尊重。');
    });

    testWidgets('★★★ 负向读数：滤掉 Material 代理 ⇒ of() 必须抛（当年的崩溃形状）',
        (tester) async {
      // ★ 用 `delegate.type` 过滤，不靠类名字符串 ——
      //   这样即使将来换实现（只要是 MaterialLocalizations 的代理）也一样处理。
      final withoutMaterial = kAppLocalizationsDelegates
          .where((d) => d.type != MaterialLocalizations)
          .toList();
      expect(
        withoutMaterial.length,
        kAppLocalizationsDelegates.length - 1,
        reason: '★ 过滤没生效：滤掉 Material 之后数量没少 1。'
            '说明 kAppLocalizationsDelegates 里**没有** type 为 '
            'MaterialLocalizations 的代理 —— 那就是本门禁要抓的缺陷本身。',
      );

      final ctx = await _mountAndSettle(
        tester,
        locale: const Locale('zh', 'CN'),
        delegates: withoutMaterial,
      );

      expect(
        () => MaterialLocalizations.of(ctx),
        throwsA(anything),
        reason: '★★★ 没有 Material 代理时 `of()` 居然没抛 —— '
            '本门禁的判据方向错了（它必须能看见 2026-10-18 那次崩溃）。',
      );
    });
  });

  group('★★ 类型锚：代理的 type 必须与 DialogRoute / 第三方组件同源', () {
    test('★★★ Material 代理是 material_ui 的 MaterialLocalizations（不是 flutter 侧的）',
        () {
      final material = kAppLocalizationsDelegates
          .where((d) => d.type == MaterialLocalizations)
          .toList();
      expect(
        material,
        hasLength(1),
        reason: '★★★ `kAppLocalizationsDelegates` 里 type 为 '
            '`MaterialLocalizations`（material_ui 的）的代理有 '
            '${material.length} 个，必须是**恰好 1 个**。\n'
            '· 0 个 ⇒ DialogRoute / showDialog 会崩（2026-10-18 第一次故障）\n'
            '· 多于 1 个 ⇒ 两个代理抢同一个 Type，谁生效取决于顺序',
      );
    });

    test('★★★ Cupertino 代理是 flutter 侧的（material_ui 整包里的那个不是）', () {
      // ① 我们这套里：必须有一个 flutter 侧 CupertinoLocalizations 的代理
      final ours = kAppLocalizationsDelegates
          .where((d) => d.type == CupertinoLocalizations)
          .toList();
      expect(
        ours,
        hasLength(1),
        reason: '★★★ `kAppLocalizationsDelegates` 里没有 flutter 侧的 '
            '`CupertinoLocalizations` 代理（找到 ${ours.length} 个）。\n'
            '本仓第三方组件读的是 flutter 侧 CupertinoLocalizations，'
            '缺了它们的一致性文案就没了。',
      );

      // ② material_ui 的整包 delegates 里的 Cupertino 代理**不是**这个类型
      //    （来自 cupertino_ui 包：global_material_localizations.dart:5
      //     `import 'package:cupertino_ui/cupertino_ui.dart'
      //      show GlobalCupertinoLocalizations;`）
      //
      // ★ 这条是本门禁的**回头条件探针**：如果哪天这里不空了，
      //   说明 material_ui 改用 flutter 侧 Cupertino 了，整包换也许可行 ——
      //   那时应该回来重读 decision note 再决定，而不是直接改断言。
      final bundledFlutterCupertino = GlobalMaterialLocalizations.delegates
          .where((d) => d.type == CupertinoLocalizations)
          .toList();
      expect(
        bundledFlutterCupertino,
        isEmpty,
        reason: '★★ material_ui 的 `GlobalMaterialLocalizations.delegates` '
            '整包里出现了 **flutter 侧** CupertinoLocalizations 的代理'
            '（${bundledFlutterCupertino.length} 个）—— '
            '上游可能已经统一类型。回头读 '
            '.agents/notes/implemented/architecture/'
            '2026-10-22-material-localizations-use-material-ui-global.md 的'
            '「回头条件」再决定是否整包换。',
      );
    });
  });

  group('★ 接线与判据自检（常量存在 ≠ App 用了它）', () {
    test('★★★ WidgetsApp 的 localizationsDelegates 真的用了 kAppLocalizationsDelegates',
        () {
      final src = File('lib/shell.dart').readAsStringSync();
      final arg = _extractDelegatesArg(src);

      expect(
        arg.contains('kAppLocalizationsDelegates'),
        isTrue,
        reason: '★★★ `lib/shell.dart` 的 WidgetsApp 里 '
            '`localizationsDelegates:` 用的不是 `kAppLocalizationsDelegates` '
            '（实际：${arg.trim()}）。\n'
            '常量本身是对的，但 App 没用它 ⇒ 上面那些行为断言全都在测一个'
            '**没人用**的常量（典型假绿）。',
      );
    });

    test('③ 判据自检：提取函数只取这个实参，不吃整文件', () {
      final src = File('lib/shell.dart').readAsStringSync();
      final arg = _extractDelegatesArg(src);

      expect(arg.contains('WidgetsApp('), isFalse,
          reason: '★ 提取到的片段里含 `WidgetsApp(` ⇒ 切的范围太大，⑤ 会假绿');
      expect(arg.contains('class '), isFalse,
          reason: '★ 提取到的片段里含 `class ` ⇒ 切的范围太大');
      expect(arg.length, greaterThan(20),
          reason: '★ 提取到的片段只有 ${arg.length} 字符 —— 太小，可能切错位置');
    });
  });
}
