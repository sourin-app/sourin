// ★★★ 守 `_SourinScrollBehavior` 的 arm64「内容区全空白」修复
//
// # 为什么需要这条门禁（这是一个**没有任何测试守护**的致命修复）
//
// `lib/shell.dart:1434` 的 `_SourinScrollBehavior` 修的是：
// ```text
// arm64 TV 上「内容区全空白」—— 界面框架都在，但内容区一片空白。
// 根因：overscroll 装饰层把内容裁掉了（decorationClipBehavior 默认值）
// 修法：把它降级成 Clip.none
// ```
//
// 证据：`.probe/t429_*`（7 段）+ `.probe/t435_*`（11 段），18 个探针点 18/18 全中。
//
// # 但这条修复**没有任何测试守护**
// ```text
// grep -rn "SourinScrollBehavior" test/   ⇒ 0 命中
// ```
// ⇒ 它只在 `shell.dart:2022` 被引用一次，删掉/改错不会让任何测试变红。
// ⇒ 而 M 批次（去 Material）要动 `MaterialApp` 和这个 ScrollBehavior ——
//    动它的时候如果没有门禁，改坏了只会表现为「arm64 用户看到空白」，
//    Windows 上一切正常 ⇒ **我们永远不会发现**。
//
// ⇒ 本门禁在动它**之前**先钉住它。这是"先补护栏再施工"。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

/// 剥掉 Dart 注释（`//` 与 `/* */`），只留可执行代码
///
/// ★ 为什么要剥：本仓多处注释里就写着 `MaterialScrollBehavior` / `Clip.none`
///   这些词（解释修复原理）。不剥的话，把实现删掉、只留注释，门禁仍然绿 ——
///   那是假绿。这个陷阱在 t73 上已经踩过一次。
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    // 行注释
    if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    // 块注释
    if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    // 字符串字面量：原样保留（否则会把 "//" 当注释）
    if (src[i] == "'" || src[i] == '"') {
      final q = src[i];
      out.write(src[i]);
      i++;
      while (i < src.length && src[i] != q) {
        if (src[i] == r'\' && i + 1 < src.length) {
          out.write(src[i]);
          i++;
        }
        out.write(src[i]);
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
      continue;
    }
    out.write(src[i]);
    i++;
  }
  return out.toString();
}

/// 真的挂到 App 上了吗 —— 判据是**包裹写法**本身：
/// `ScrollConfiguration(behavior: const _SourinScrollBehavior())`
///
/// ★★ 2026-10-21（PR #32 复核线程 1/9、9/9）：这里原来是
///   `shell.contains('_SourinScrollBehavior()')` —— 而类体里的构造函数声明
///   `const _SourinScrollBehavior();` **本身**就含这个子串
///   ⇒ 从 2026-10-18（M4 把 MaterialApp 换成 WidgetsApp）到 2026-10-21，
///   `ScrollConfiguration` 其实一直**没有被挂上**（arm64 修复实际失效），
///   而这条断言一直是绿的。
///   ⇒ 判据改成匹配「包裹写法」：构造函数声明不满足它，删掉挂载点必然红。
final RegExp _scrollMountRe = RegExp(
  r'ScrollConfiguration\(\s*behavior:\s*const\s+_SourinScrollBehavior\(\)',
);

bool _hasScrollConfigMount(String code) => _scrollMountRe.hasMatch(code);

void main() {
  final shell = _stripComments(_read('lib/shell.dart'));

  group('★ 判据自检（防正则空转 / 防被构造函数声明满足）', () {
    // ★ 没有这两条，「判据自己坏了」和「被测对象坏了」在输出上长得一样。
    //   本仓 PITFALLS A 组：判据必须有一条能证明它会红。
    test('坏样本必须判红：只有类声明、没有任何挂载点', () {
      const bad = '''
class _SourinScrollBehavior extends ScrollBehavior {
  const _SourinScrollBehavior();
}
''';
      expect(
        _hasScrollConfigMount(_stripComments(bad)),
        isFalse,
        reason: '★★★ 判据被构造函数声明满足了 —— 这正是 2026-10-18～10-21 '
            '那次假绿的形状。',
      );
    });

    test('好样本必须判绿：真的包了一层 ScrollConfiguration', () {
      const good = '''
child: ScrollConfiguration(
  behavior: const _SourinScrollBehavior(),
  child: WidgetsApp(),
),
''';
      expect(_hasScrollConfigMount(_stripComments(good)), isTrue);
    });
  });

  group('★★★ arm64「内容区全空白」修复必须保留（去 Material 时最容易丢的一条）', () {
    test('★★★ ScrollBehavior 类仍然存在且被真的挂上去', () {
      // ① 类定义还在
      expect(
        shell.contains('class _SourinScrollBehavior'),
        isTrue,
        reason: '★★★ `_SourinScrollBehavior` 类被删了。\n'
            '它修的是 arm64 TV「内容区全空白」——18 个探针点 18/18 全中。\n'
            '删了之后 Windows 上一切正常，只有 arm64 用户看到空白 ⇒ 我们不会发现。',
      );

      // ② 真的挂到 App 上（定义了但没挂 = 等于删了）
      //
      // ★★ 2026-10-22（PR #32 复核线程 1/9 的收尾）：这里原来写的是
      //   `shell.contains('_SourinScrollBehavior()')` —— 而类体里的构造函数
      //   声明 `const _SourinScrollBehavior();` **本身**就含这个子串
      //   ⇒ 把挂载点整段删掉，这条断言**照样绿**。
      //   （2026-10-18～10-21 那次假绿就是这个形状：断言被类声明满足了。）
      //   ⇒ 改成包裹写法判据（上面的 `_scrollMountRe`），构造函数不满足它。
      expect(
        _hasScrollConfigMount(shell),
        isTrue,
        reason: '★★★ 类还在，但 `ScrollConfiguration(behavior: const '
            '_SourinScrollBehavior())` 没有真的把 App 包起来 —— 效果等于删掉'
            '（arm64「内容区全空白」的修复失效）。',
      );

      // ③ 它必须真的改 decorationClipBehavior（不是只继承不覆写）
      expect(
        shell.contains('decorationClipBehavior: Clip.none'),
        isTrue,
        reason: '★★★ 修复的核心就是这一句：把 overscroll 装饰层的裁剪降级成 Clip.none。\n'
            '★ 字段真名是 `decorationClipBehavior`，不是 `clipBehavior`\n'
            '  （后者是已废弃 getter，见 widgets/scrollable_helpers.dart:87/96）。',
      );
    });

    test('★★★ 它必须真的覆写 buildOverscrollIndicator', () {
      expect(
        shell.contains('buildOverscrollIndicator'),
        isTrue,
        reason: '★★★ 只写 `Clip.none` 而不覆写 buildOverscrollIndicator 是无效的 —— '
            '那个 Clip 必须传进 super.buildOverscrollIndicator 才生效。',
      );
      expect(
        shell.contains('super.buildOverscrollIndicator'),
        isTrue,
        reason: '★★★ 覆写后必须把改过的 details 传回 super，否则等于自己重写了一遍装饰器逻辑。',
      );
    });

    test('★★★ 必须用 copyWith 而不是手写构造器搬字段', () {
      expect(
        shell.contains('.copyWith('),
        isTrue,
        reason: '★★★ `ScrollableDetails` 只有 4 个字段（direction/controller/physics/'
            'decorationClipBehavior）。手写构造器搬字段出过错：\n'
            '  ① 用错字段名 ② 多写了不存在的 restorationId\n'
            '`copyWith` 是 SDK 维护的，加字段时不会漏。\n'
            '★★ 但 **`copyWith` 存在 ≠ `copyWith` 里只有安全字段**：\n'
            '   `_WrappedScrollBehavior.shouldNotify` 对 `physics`/`platform` 是'
            '**按实例比较**的 ⇒ 往里塞「每次 build 新建」的实例会让每一帧都判'
            '"behavior 变了" ⇒ ScrollPosition 被重建 ⇒ 在飞的拖拽/惯性丢失。\n'
            '   实测证据：`.probe/item04-inject-physics.log`（`+4 -1`，'
            'offset 仍是 320.0 但 activity 从 null 变 IdleScrollActivity）。\n'
            '   ⇒ 下面那条判据（`copyWith` 里不许出现 physics:/platform:）守的就是它。',
      );
    });

    /*
     * ★★★ 2026-10-25（第 04 项注入红取证后补的判据）
     *
     * # 为什么需要它（上一组 6 条**一条都抓不到**这个形态）
     * ```text
     * 上面那条只断言 `.copyWith(` **存在** ⇒ 往实参里加 `physics: ClampingScrollPhysics()`
     * 它**照样绿**（判据是反向的）。而 zz_t1026 的 `same(position)` 虽然能抓，
     * 但那是**行为**测试（要真挂载真滚动），比源码门禁慢且晚。
     * ⇒ 这里补一条静态判据，与行为判据形成"双保险"。
     * ```
     *
     * # 注入实测（撤销验证，已恢复）
     * ```text
     * 往 `SourinHorizontalRail.build` 的 copyWith 里加一行
     *   `physics: ClampingScrollPhysics(),`
     * ⇒ zz_t1026: +4 -1（test:159 `expect(controller.position, same(position))` 红）
     *   红正文：offset 两边都是 320.0，但实例号 #685bc → #003b1、
     *   activity 从 null → IdleScrollActivity#ba29a（= 在飞活动被丢）
     * ⇒ 本判据同时变红。日志 `.probe/item04-inject-physics.log`。
     * ```
     *
     * ⚠️ **必须先剥注释**：本仓 `lib/ui/widgets/sourin_scroll_behavior.dart`
     *   的 doc 注释里**故意**写着 `physics: ClampingScrollPhysics()` 当反例（第 26 行），
     *   不剥就会恒红 —— 这正是本文件 `_stripComments` 存在的理由。
     */
    test('★★★ SourinHorizontalRail 的 copyWith 里不许出现 physics:/platform:', () {
      final src = _stripComments(_read('lib/ui/widgets/sourin_scroll_behavior.dart'));
      final at = src.indexOf('parent.copyWith(');
      expect(at, greaterThanOrEqualTo(0),
          reason: '前提：`SourinHorizontalRail` 里那次 `parent.copyWith(` 调用点还在'
              '（上面那条已钉"必须用 copyWith"）');
      // 取到该调用的实参串。本文件这次调用的实参里没有嵌套圆括号
      // （`{...parent.dragDevices, PointerDeviceKind.mouse}` / `scrollbars: false`），
      // 所以"到第一个右括号"就够；若将来实参里出现括号，改为括号配对扫描。
      final close = src.indexOf(')', at);
      expect(close, greaterThan(at), reason: '前提：copyWith 调用的右括号');
      final args = src.substring(at, close);
      for (final bad in const ['physics:', 'platform:']) {
        expect(args.contains(bad), isFalse,
            reason: '★★ `copyWith` 里出现 `$bad` ⇒ 每次 build 新建实例 ⇒ '
                '`shouldNotify` 按实例比较 ⇒ ScrollPosition 被重建（offset 保住但'
                '**在飞拖拽/惯性丢失**）。\n'
                '要么不加，要么加 `const` 实例。\n'
                '实测证据：`.probe/item04-inject-physics.log`。实参串：$args');
      }
      /*
       * ★ 阳性对照（防空转）：判据本身**确实**能看见 `physics:`。
       *   反面：把 `args` 错取成空串、或把 `contains` 写成恒 false ⇒ 这条红。
       */
      const injected = 'parent.copyWith(physics: ClampingScrollPhysics(), '
          'dragDevices: d, scrollbars: false)';
      expect(injected.contains('physics:'), isTrue,
          reason: '★ 阳性对照失败：注入形态（copyWith 里带 physics:）必须能被判据看见');
    });
  });

  group('★★★ 去 Material 的进度守卫（M 批次）', () {
    test('★★ shell.dart 里 Material 用量必须在**减少**，不许反弹', () {
      // 这是「进度守卫」而不是「必须为零」：
      // 完全归零需要先重建 Navigator / 本地化 / ScrollBehavior，
      // 那是一个跨多轮的工作。这里只钉「不许比当前更多」。
      final scaffoldCount = RegExp(r'\bScaffold\(').allMatches(shell).length;
      final materialCount = RegExp(r'\bMaterial\(').allMatches(shell).length;

      // ★ 2026-10-18 基线：Scaffold 1 处、Material 2 处
      //   如果这个数字变大，说明有人新写了 Material 组件 —— 与 M 批次目标相反
      expect(
        scaffoldCount,
        lessThanOrEqualTo(1),
        reason: '★★ shell.dart 里 Scaffold( 数量从 1 涨到了 $scaffoldCount。\n'
            'M 批次目标是**减少** Material 用量，新增是反方向。',
      );
      expect(
        materialCount,
        lessThanOrEqualTo(2),
        reason: '★★ shell.dart 里 Material( 数量从 2 涨到了 $materialCount。\n'
            '★ 注意其中一处是 `Material(type: MaterialType.transparency)`，\n'
            '  它是 InkWell 水波纹的**绘制面**（删掉会让水波纹静默消失）。\n'
            '  那一处要连同 InkWell 一起换，不能单独删。',
      );
    });
  });
}
