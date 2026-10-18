// 门禁：WidgetsApp 的 localizationsDelegates 必须提供 MaterialLocalizations。
//
// ## 为什么需要这条
//
// 2026-10-18（M4）把 `MaterialApp` 换成 `WidgetsApp` 时，delegates 只放了
// Widgets / Cupertino 两个，**漏了 Material 的**。
// 结果：真机隔离启动，`showUpdateDialog` 一开就崩：
//
// ```text
// Unhandled Exception: Null check operator used on a null value
// #0  MaterialLocalizations.of (material_ui/src/material_localizations.dart:718)
// #1  new DialogRoute        (material_ui/src/dialog.dart:1906)
// #5  showAppDialog          (ui/widgets/overlay_motion.dart:324)
// ```
//
// 根因是「写了理由但没接线」：注释里写着「保留 material_ui 是因为
// DialogRoute 要读 MaterialLocalizations 接口」，理由对，但 delegate 没上树。
//
// ## 这条门禁守什么
//
// ① `lib/shell.dart` 的 `localizationsDelegates` 列表里**必须**有
//    一个 Material 的 delegate（`DefaultMaterialLocalizations` 或
//    `GlobalMaterialLocalizations`）。
// ② `lib/` 里任何 `showAppDialog` / `showDialog` 的调用点，都必须能在
//    同一棵树里找到 Material delegate —— 这条通过 ① 保证。
//
// ## 怎么验证它真的会红
//
// 把 `DefaultMaterialLocalizations.delegate,` 这一行删掉 ⇒ 必须变红。
// 见提交信息里的注入读数。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从 `lib/shell.dart` 源码里取出 `localizationsDelegates:` 之后的那段列表。
///
/// ★ 不用裸 `indexOf` 找 delegate 名 —— 文件里有多处注释引用这些名字
/// （本轮已踩过「命中注释」的坑），所以先定位 `localizationsDelegates:`，
/// 再只取它后面的方括号内容。
String _extractDelegatesBlock(String src) {
  // 剔除注释行，避免命中注释里的引用
  final lines = src.split('\n');
  final code = StringBuffer();
  for (final line in lines) {
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

  final key = 'localizationsDelegates:';
  final i = clean.indexOf(key);
  expect(i, greaterThan(0),
      reason: '★ 找不到 `$key` —— 判据失效，'
          '说明 WidgetsApp 的构造参数名变了，本门禁需要更新');

  final open = clean.indexOf('[', i);
  expect(open, greaterThan(0), reason: '★ `localizationsDelegates:` 后面没有 `[`');

  // 从 `[` 开始做括号配对，取到匹配的 `]`
  var depth = 0;
  var close = -1;
  for (var p = open; p < clean.length; p++) {
    final c = clean[p];
    if (c == '[') depth++;
    if (c == ']') {
      depth--;
      if (depth == 0) {
        close = p;
        break;
      }
    }
  }
  expect(close, greaterThan(open),
      reason: '★ 方括号没配对 —— 源码结构异常');

  return clean.substring(open, close + 1);
}

void main() {
  late String shellSrc;

  setUpAll(() {
    final f = File('lib/shell.dart');
    expect(f.existsSync(), isTrue, reason: '★ lib/shell.dart 不存在');
    shellSrc = f.readAsStringSync();
  });

  group('★★★ MaterialLocalizations 必须真的挂在树上', () {
    test('① localizationsDelegates 里含 Material 的 delegate', () {
      final block = _extractDelegatesBlock(shellSrc);

      // ★ 三种都算合格，因为它们都实现 material_ui 的 MaterialLocalizations：
      //   · _AnyLocaleMaterialDelegate  ← 本仓自建（无条件支持任何 locale）
      //   · DefaultMaterialLocalizations
      //   · GlobalMaterialLocalizations
      final hasMaterial = block.contains('_AnyLocaleMaterialDelegate') ||
          block.contains('DefaultMaterialLocalizations') ||
          block.contains('GlobalMaterialLocalizations');

      expect(hasMaterial, isTrue,
          reason: '★★★ `localizationsDelegates` 里没有 Material 的 delegate。\n'
              '后果：`showDialog` / `showAppDialog` / `DialogRoute` 一开就抛\n'
              '  `Null check operator used on a null value`\n'
              '  （MaterialLocalizations.of 拿到 null）\n'
              '本轮真机实测过：启动后第一次弹更新窗就崩。');
    });

    test('①b ★ delegate 必须对 zh_CN 也返回 true（否则中文下仍为 null）', () {
      // ★★★ 这是本组最关键的断言 —— 我第一版只加了
      //   `DefaultMaterialLocalizations.delegate`，它在 zh_CN 下**不加载**，
      //   真机复验仍然崩。原因：material_ui-1.6.0:726
      //     bool isSupported(Locale locale) => locale.languageCode == 'en';
      //
      // ★ 第二版门禁只断言"用的是 _AnyLocaleMaterialDelegate"，结果
      //   注入「换回 Default 版」和「把 isSupported 改成只认 en」都**没红**
      //   ⇒ 那条门禁太浅。本版改成**直接读 delegate 类的 isSupported 实现**：
      //   必须是无条件的 `=> true`（或 `return true`）。
      final block = _extractDelegatesBlock(shellSrc);

      // 1) 找出门禁块里用的是哪个 delegate 类
      final usesAnyLocale = block.contains('_AnyLocaleMaterialDelegate');

      if (usesAnyLocale) {
        // 2) 直接读那个类的 isSupported 实现 —— 必须无条件 true
        final clsIdx = shellSrc.indexOf('class _AnyLocaleMaterialDelegate');
        expect(clsIdx, greaterThan(0),
            reason: '★ 门禁块引用了 `_AnyLocaleMaterialDelegate`，'
                '但源码里找不到它的类定义');

        // 取类定义之后的 2000 字符，足够覆盖 isSupported
        final clsBody = shellSrc.substring(
            clsIdx, (clsIdx + 2000).clamp(0, shellSrc.length));

        // 剔除注释行，避免命中注释里写的 `languageCode == 'en'`
        final codeOnly = clsBody
            .split('\n')
            .where((l) {
              final t = l.trimLeft();
              return !(t.startsWith('*') ||
                  t.startsWith('//') ||
                  t.startsWith('/*') ||
                  t.startsWith('*/'));
            })
            .join('\n');

        final isSupportedIdx = codeOnly.indexOf('isSupported');
        expect(isSupportedIdx, greaterThan(0),
            reason: '★ `_AnyLocaleMaterialDelegate` 里找不到 `isSupported`');

        final isSupportedBody = codeOnly.substring(
            isSupportedIdx,
            (isSupportedIdx + 200).clamp(0, codeOnly.length));

        // ★ 核心判据：isSupported 里**不许**出现 locale 条件判断
        expect(isSupportedBody.contains('languageCode'), isFalse,
            reason: '★★★ `_AnyLocaleMaterialDelegate.isSupported` 里出现了 '
                '`languageCode` —— 说明它对 locale 做了条件判断。\n'
                '本仓 supportedLocales 首选 zh_CN，一旦这里只认 en，'
                '这个 delegate 在中文环境下**不会加载** ⇒ 弹窗仍会崩。\n'
                '它必须是 `=> true`。');
        expect(isSupportedBody.contains('=='), isFalse,
            reason: '★★★ `_AnyLocaleMaterialDelegate.isSupported` 里出现了 '
                '`==` —— 可能对 locale 做了相等比较。必须是 `=> true`。');
        expect(isSupportedBody.contains('true'), isTrue,
            reason: '★ `isSupported` 里没有 `true` —— 它不是无条件支持');
      } else {
        // 只用了 Default/Global 版 ⇒ 必须证明 supportedLocales 里**只有一个**
        // 中文 locale 能被它匹配到…… 这是做不到的，所以直接判不合格。
        expect(false, isTrue,
            reason: '★★★ `localizationsDelegates` 里没有 `_AnyLocaleMaterialDelegate`。\n'
                '`DefaultMaterialLocalizations.delegate.isSupported` 只认 '
                '`languageCode == \'en\'`（material_ui-1.6.0:726），\n'
                '而本仓 `supportedLocales` 首选 `zh_CN`。\n'
                '★ 实测：只加 Default 版，真机仍然崩在 '
                '`MaterialLocalizations.of` 的 null check。\n'
                '⇒ 必须用 `_AnyLocaleMaterialDelegate`（无条件 true）。');
      }
    });

    test('② 三个 delegate 都在（Material + Widgets + Cupertino）', () {
      final block = _extractDelegatesBlock(shellSrc);

      // ★ 分别断言，任何一个缺失都单独报出来，方便定位
      expect(
          block.contains('MaterialLocalizations') ||
              block.contains('_AnyLocaleMaterialDelegate'),
          isTrue,
          reason: '★ 缺 Material delegate');
      expect(block.contains('GlobalWidgetsLocalizations'), isTrue,
          reason: '★ 缺 Widgets delegate（文本方向 LTR/RTL 需要）');
      expect(block.contains('GlobalCupertinoLocalizations'), isTrue,
          reason: '★ 缺 Cupertino delegate（第三方 Cupertino 组件需要）');
    });

    test('③ 阴性对照：这个提取函数确实只取 delegate 块，不吃整文件', () {
      // ★ 如果 _extractDelegatesBlock 写错（比如返回整个文件），
      //   上面两条就会因为"文件里别处提到过 MaterialLocalizations"而假绿。
      //   这里断言：返回的块**不含** `WidgetsApp(` 和 `class ` ——
      //   证明它切的是参数列表，不是整个文件。
      final block = _extractDelegatesBlock(shellSrc);

      expect(block.contains('WidgetsApp('), isFalse,
          reason: '★ 提取到的块里含 `WidgetsApp(` ⇒ 切的范围太大，'
              '本组断言会假绿');
      expect(block.contains('class '), isFalse,
          reason: '★ 提取到的块里含 `class ` ⇒ 切的范围太大');

      // 而且它必须真的有内容（不是空串）
      expect(block.length, greaterThan(40),
          reason: '★ 提取到的块只有 ${block.length} 字符 —— 太小，可能是空列表');
      expect(block.contains('delegate'), isTrue,
          reason: '★ 提取到的块里没有 `delegate` 字样 —— 切错位置了');
    });
  });
}
