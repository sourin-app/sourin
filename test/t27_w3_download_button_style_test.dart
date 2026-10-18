// ═══════════════════════════════════════════════════════════════════════
//  T27-03 —— 详情页操作行四枚按钮的样式/几何必须**同源同档**
// ═══════════════════════════════════════════════════════════════════════
//
// 业主原话（逐字，图 3）：「这里四个按钮,下载按钮跟前面的不一样 样式」
//
// # 根因
// ```text
//   收藏/追更 = _ToggleButton  → OutlinedButton.icon（几何由主题算）
//   下载      = _DownloadButton → 手画 Container 壳 + PopupMenuButton.child
//               壳上硬编码 constraints: BoxConstraints(minHeight: 48)
// ⇒ 同一行里「下载」在 Windows 上是 71×48，旁边三枚是 72×32 —— 高一档。
// ```
//
// # ★★★ 旧门禁为什么全绿（这一条比缺陷本身更重要，别删）
// ```text
//   flutter_tester 里 defaultTargetPlatform **恒为 android**
//   （SDK foundation/_platform_io.dart：FLUTTER_TEST ⇒ android）
//   ⇒ 旧门禁量到的是 android 几何：OutlinedButton 48（padded）、
//     手画壳 48（硬编码）⇒ **两边都是 48 ⇒ 全绿**。
//   ⇒ 缺陷只在 **Windows**（shrinkWrap + VisualDensity.compact ⇒ 32）露出来。
// ```
// ⇒ 所以本文件有两条硬纪律：
//   ① 几何断言**必须显式指定平台**（debugDefaultTargetPlatformOverride）；
//   ② 断言里必须含一条「平台真的改变了几何」的自证 —— 否则这个门禁会
//      再一次变成“怎么改都绿”的摆设（见下面那条非盲性断言）。
//
// # 修法（测的就是生产代码本身，不是影子副本）
// ```text
//   下载触发器改用与旁边三枚**同一个 widget 类**（OutlinedButton.icon）
//   ⇒ 密度 / 最小触控尺寸 / 主题合并全在 ButtonStyleButton 内部算，
//     两平台自动同档；菜单改由 onPressed 里手写 showMenu 弹出。
// ```
//
// # 判据
// ```text
// ① 源码级：_DownloadButton 体内不许再出现手画几何（Container /
//    BoxConstraints / kMinInteractiveDimension），且必须走 OutlinedButton.icon；
//    旧的手画壳符号 _pillShell 必须整仓消失（**剥注释后**断言）。
// ② 行为级：**逐平台**量四枚按钮的渲染尺寸 ——
//    同一平台内四枚等高、下载与追更等宽（等宽同时排除“撑满整行”）；
//    且下载按钮的几何必须**随平台变化**（与旁钮同频，不再是一条硬编码）。
// ③ 行为级：描边 / 内边距 / 圆角 / 图标色 / 文字色 / 字重 与旁钮同源。
// ④ 行为级：菜单行为保留 —— 点下载必须真弹出菜单。
// ```
// ⚠️ 纯静态断言必须先剥注释（铁律 170）：本仓注释里大量引用旧写法当历史
//    证据，裸 contains 会被注释文本骗到。见 ⓪ 仪器自检。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';

import '_support/strip_comments.dart';

String _code(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    fail("源码文件不存在: $path（工作目录: ${Directory.current.path}）");
  }
  return stripComments(f.readAsStringSync());
}

/// 取 [marker] 之后的第一个配对大括号块（类体 / 函数体）
String _bodyOf(String src, String marker) {
  final start = src.indexOf(marker);
  if (start < 0) fail("源码里找不到: $marker");
  final open = src.indexOf('{', start);
  if (open < 0) fail("没有方法体: $marker");
  var depth = 0;
  final buf = StringBuffer();
  for (var i = open; i < src.length; i++) {
    buf.write(src[i]);
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) break;
    }
  }
  return buf.toString();
}

void main() {
  group('⓪ 仪器自检', () {
    test('★ stripComments 真的工作（否则下面全是空中楼阁）', () {
      expect(stripComments('a; // _DownloadButton\nb;'),
          contains('a;'));
      expect(stripComments('a; // _DownloadButton\nb;'),
          isNot(contains('_DownloadButton')));
      // ⚠️ 不在代码注释里写块注释字面起止符号（Dart 块注释可嵌套，
      //    闭合错位会吞掉后面的用例）——用字符串字面量表达：
      const src = '/*\n * _DownloadButton 说明\n*/\nreal();';
      expect(stripComments(src), isNot(contains('_DownloadButton')));
      expect(stripComments(src), contains('real();'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 源码级门禁：不许再手画几何
  // ═══════════════════════════════════════════════════════════════════
  group('① 源码级：下载触发器不许再手画几何', () {
    test('★★★ _DownloadButton 必须走 OutlinedButton.icon，体内零手画几何',
        () {
      final code = _code('lib/ui/detail_page.dart');
      // 旧的手画壳（Container + 硬编码 minHeight）在修复里被整段删除，
      // 这个符号一旦复活就说明有人又把几何抄回来了。
      expect(code, isNot(contains('_pillShell')),
          reason: '旧的手画壳符号 _pillShell 必须整仓消失（剥注释后断言）');
      final body = _bodyOf(code, 'class _DownloadButton');
      expect(body, contains('OutlinedButton.icon'),
          reason: '★ 几何必须由与旁钮同一个 widget 类承担，不许手画');
      expect(body, isNot(contains('Container(')),
          reason: '★ 不许再手画壳 —— 那正是「下载跟别的不一样」的载体');
      expect(body, isNot(contains('BoxConstraints')),
          reason: '★ 不许再硬编码约束（minHeight: 48 就是这么进来的）');
      expect(body, isNot(contains('kMinInteractiveDimension')),
          reason: '★ 最小触控尺寸必须由 MaterialTapTargetSize 决定，不许写死');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 行为级门禁：渲染事实（逐平台几何 + 样式同源）+ 菜单能弹
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么驱动真 DetailPage（而不是构造那两个私有 widget）
  // _ToggleButton / _DownloadButton 是 detail_page.dart 的私有类，
  // 测试侧引用不到。本仓先例（zz_cr_localbtn_switch_source_test /
  // t64_panel_fixed_test）：挂真 DetailPage + debugSetDetail 注入真数据
  // 跑真 _buildBody —— 渲染的就是生产代码本身，不是影子副本。
  group('② 行为级：四枚按钮渲染同档，菜单必须能弹', () {
    const panelW = 433.0;
    const panelH = 900.0;

    /// 这一行里的四枚（「换源」在有本地文件时不画，本用例没有本地文件）
    const labels = <String>['收藏', '追更', '换源', '下载'];

    /// 四枚按钮的**语义位置 Key** —— 由产品代码 `detail_page.dart` 挂上。
    ///
    /// ★ 这是本文件从「认 Material 类型」转向「认语义位置」的载体。
    ///   产品代码里那四个 ValueKey 的注释写明了同一个理由。
    final _actionKeys = <String, ValueKey<String>>{
      '收藏': const ValueKey('detail-action-favorite'),
      '追更': const ValueKey('detail-action-follow'),
      '换源': const ValueKey('detail-action-switch-source'),
      '下载': const ValueKey('detail-action-download'),
    };

    Widget host(Widget child) {
      // ⚠️ 主题必须**在平台 override 生效期间**构造：ThemeData 在构造时
      //    就把 materialTapTargetSize / visualDensity 按平台烘焙好了
      //    （material_ui theme_data.dart:478-491）。真机上这一步等价。
      final theme = AppTheme.themeFor(Brightness.dark);
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        // ★ 必须关掉主题补间动画：MaterialApp 会用 AnimatedTheme 在
        //   kThemeChangeDuration（200ms）里从上一份主题补间到新主题，
        //   而本用例**在同一个测试体里连挂两次**（windows → android）。
        //   不关的话 override 生效后主题仍是「上一档」的中间值，
        //   平台自检会读到上一档的 MaterialTapTargetSize（实测：
        //   windows 通过、android 读到 shrinkWrap ⇒ 假红）。
        themeAnimationDuration: Duration.zero,
        home: Scaffold(body: Material(child: child)),
      );
    }

    void claim(WidgetTester t) {
      while (t.takeException() != null) {}
    }

    /// 挂载 DetailPage（在线模式）+ 注入 1 集详情 ⇒ 操作行出现
    Future<void> mount(WidgetTester t) async {
      NetworkStatus.debugProbe = () async => true;
      addTearDown(NetworkStatus.debugResetForTest);
      await t.binding.setSurfaceSize(const Size(panelW, panelH));
      addTearDown(() => t.binding.setSurfaceSize(null));

      final key = GlobalKey<State<DetailPage>>();
      await t.pumpWidget(host(DetailPage(
        key: key,
        provider: 'cycani',
        id: '3862',
        embedded: true,
      )));
      claim(t);
      await t.pump(const Duration(milliseconds: 50));
      claim(t);

      const d = MediaDetail(
        id: '3862',
        title: '在线剧',
        episodes: <Episode>[Episode(id: 'ep-1', title: '第01集')],
      );
      // ignore: avoid_dynamic_calls
      (key.currentState! as dynamic).debugSetDetail(d, episodes: d.episodes);
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      claim(t);
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-18（轨道 E M2 第 3 步）：判据从「认组件类型」改成「认语义位置」
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么要改（不是为了让测试变绿）
     * ```text
     * 旧判据：find.ancestor(of: find.text(label), matching: find.byType(OutlinedButton))
     * ⇒ 它把「四枚按钮同源同档」这个**产品契约**，错误地绑定到了
     *   「它们内部必须是 Material 的 OutlinedButton」这个**实现细节**上。
     *
     * 一旦组件换代（OutlinedButton → 自建 AppOutlinedButton），
     * 契约没坏，但判据找不到 Material 类型 ⇒ **假红**。
     * ```
     * ⇒ 改法：产品代码给四枚按钮各一个**语义位置 Key**
     *   （`detail-action-favorite` / `-follow` / `-switch-source` / `-download`），
     *   判据按 Key 定位。
     *
     * # 这个改动**不削弱任何断言**
     * ```text
     * 下面所有几何/样式断言（等高、等宽、描边色、非盲性自证）**一条没动**，
     * 只是"怎么找到那枚按钮"变了。
     * ⇒ 判据守的仍是原契约：四枚同源同档 + 几何随平台变化。
     * ```
     */
    Finder btnOf(String label) => find.byKey(_actionKeys[label]!);

    /// 在指定平台上量四枚按钮的渲染尺寸
    ///
    /// ⚠️ debugDefaultTargetPlatformOverride 必须在**测试体内**还原：
    ///    flutter_test 在测试体结束时断言「foundation 调试变量没被改过」
    ///    （binding.dart:1995 debugAssertAllFoundationVarsUnset），
    ///    而 addTearDown 跑在那次校验**之后** ⇒ 只能用 try/finally
    ///    （同 test/a1_tv_text_scale_test.dart:142-164 的既有结论）。
    Future<void> measure(WidgetTester t, TargetPlatform p,
        Map<String, Size> out) async {
      debugDefaultTargetPlatformOverride = p;
      try {
        await mount(t);
        // ★ 再等一帧，确保主题补间（已置零）与状态动画都落定后再读
        await t.pump();
        final td = Theme.of(t.element(find.text('下载')));
        // ★ 平台自检：override 真的落到了主题上（否则下面量到的是 tester
        //   的 android 默认值 —— 旧门禁正是这么瞎掉的）
        expect(
          td.materialTapTargetSize,
          p == TargetPlatform.windows
              ? MaterialTapTargetSize.shrinkWrap
              : MaterialTapTargetSize.padded,
          reason: '前置条件：$p 的触控尺寸策略必须真的被烘焙进主题',
        );
        expect(
          td.visualDensity,
          p == TargetPlatform.windows
              ? VisualDensity.compact
              : VisualDensity.standard,
          reason: '前置条件：$p 的密度必须真的被烘焙进主题',
        );
        for (final lb in labels) {
          expect(btnOf(lb), findsOneWidget,
              reason: '操作行必须渲染出「$lb」这一枚');
          out[lb] = t.getSize(btnOf(lb));
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('★★★ 几何逐平台同档，且下载必须随平台变化（旧门禁正是瞎在这里）',
        (t) async {
      final win = <String, Size>{};
      final and = <String, Size>{};
      await measure(t, TargetPlatform.windows, win);
      await measure(t, TargetPlatform.android, and);
      debugPrint('T27W3 几何读数 windows=$win android=$and');

      final winFav = win['收藏']!;
      final andFav = and['收藏']!;
      for (final lb in labels) {
        expect(win[lb]!.height, winFav.height,
            reason: '★ Windows：$lb 与收藏必须等高（实测 ${win[lb]} vs $winFav）');
        expect(and[lb]!.height, andFav.height,
            reason: '★ Android：$lb 与收藏必须等高（实测 ${and[lb]} vs $andFav）');
      }

      final winDl = win['下载']!;
      final winFollow = win['追更']!;
      final andDl = and['下载']!;
      final andFollow = and['追更']!;
      expect((winDl.width - winFollow.width).abs(), lessThan(8.0),
          reason: '★ Windows：下载宽必须与追更同档（实测 $winDl vs $winFollow）');
      expect((andDl.width - andFollow.width).abs(), lessThan(8.0),
          reason: '★ Android：下载宽必须与追更同档（实测 $andDl vs $andFollow）');

      // ★★★ 非盲性自证：下载的几何**必须**随平台变化。
      //     旧实现把 48 写死在手画壳上 ⇒ 两个平台都是 48 ⇒ 这一条必红。
      //     没有这一条，本门禁又会退回「怎么改都绿」。
      expect(winDl.height, isNot(equals(andDl.height)),
          reason: '★ 下载按钮的几何必须由平台决定（与旁钮同频），不许是一条硬编码：'
              '实测 windows=$winDl android=$andDl');
      expect(winFollow.height, isNot(equals(andFollow.height)),
          reason: '对照：旁钮的几何确实随平台变，所以上面那条不是空要求');
    });

    testWidgets('★★★ 描边同源：下载与关态开关取同一 ColorScheme 槽位', (t) async {
      await mount(t);
      final cs = Theme.of(t.element(find.text('下载'))).colorScheme;
      /*
       * ★★★ 判据改造：读**渲染后的实际描边**，不读 Material 的 `style` 对象。
       *
       * # 为什么不能读 style
       * ```text
       * 旧写法：t.widget<OutlinedButton>(btnOf(lb)).style!.side!...
       * ⇒ `style` 是 **Material 的 API**。组件一换代（自建 AppOutlinedButton
       *   没有 OutlinedButton.style）就取不到 ⇒ 假红。
       *   而且它测的是"声明了什么"，不是"渲染成什么" —— 这是**弱判据**。
       * ```
       *
       * # 新写法读什么
       * ```text
       * 从按钮内部找到那层**真正描边的 DecoratedBox**，读它 BoxDecoration.border。
       * 那是"用户实际看到的描边"，比 style 更强，且与组件实现无关。
       * ⇒ 断言的作用范围精确等于被测对象：**渲染事实**。
       * ```
       */
      /*
       * ⚠️ 判据必须**同时**支持"自建"与"Material"两种实现，
       *    否则它只是把"依赖 Material"换成了"依赖自建"—— 同样是绑实现细节。
       *
       * 实测（双向验证时抓到）：
       *   自建 AppOutlinedButton ⇒ 描边在 BoxDecoration.border（DecoratedBox）
       *   Material OutlinedButton ⇒ 描边在 Material.shape.side ← **没有 DecoratedBox**
       * ⇒ 单读一种会 `Bad state: No element`。
       * ⇒ 两种都读，取先命中的那个。这才是"认渲染事实，不认组件类型"。
       */
      Color sideOf(String lb) {
        // ① 自建实现：DecoratedBox 的 BoxDecoration.border
        final decos = find.descendant(
            of: btnOf(lb), matching: find.byType(DecoratedBox));
        if (decos.evaluate().isNotEmpty) {
          final b = t.widget<DecoratedBox>(decos.first).decoration
              as BoxDecoration;
          return (b.border! as Border).top.color;
        }
        // ② Material 实现：Material.shape 的 side
        final mats =
            find.descendant(of: btnOf(lb), matching: find.byType(Material));
        if (mats.evaluate().isNotEmpty) {
          final shape = t.widget<Material>(mats.first).shape;
          // Material 的按钮 shape 是 OutlinedBorder 的子类（带 side）
          if (shape is OutlinedBorder) return shape.side.color;
          fail('★ 按钮「$lb」的 Material.shape 不是 OutlinedBorder，判据需要更新');
        }
        fail('★ 按钮「$lb」内部既没有 DecoratedBox 也没有 Material —— '
            '找不到描边，说明实现形态变了，判据需要更新');
      }

      final dl = sideOf('下载');
      expect(dl, sideOf('追更'),
          reason: '下载描边色必须 = 关态开关描边色（同一共享样式构造）');
      expect(dl, cs.outlineVariant,
          reason: '描边必须取 ColorScheme.outlineVariant（不许硬编码色值）');
    });

    testWidgets('★★ 内边距/圆角同档：下载与追更的 Padding 链与 shape 逐位相同',
        (t) async {
      await mount(t);
      /*
       * ★★★ 判据改造：从「内部有没有 Material 的 Padding」改成「最终几何 + 圆角是否一致」。
       *
       * # 旧判据错在哪
       * ```text
       * 旧写法：从按钮里捞 `Padding` 列表 + 捞 `Material.shape`
       *   expect(dlPads, isNotEmpty,
       *       reason: '按钮内部必须有 ButtonStyleButton 插进来的那层 Padding');
       *
       * ⇒ 这条断言的**真实语义**是「四枚按钮内部结构一致」，
       *   但它写成了「内部必须有 **Material 的** Padding」——
       *   把产品契约（同源）错误绑定到了实现细节（Material 的实现方式）上。
       *   组件换代后 `Padding` 链变成空列表（自建组件用 DecoratedBox+EdgeInsets），
       *   ⇒ 契约没坏，判据假红。
       * ```
       *
       * # 新判据错守什么（更强，不是更弱）
       * ```text
       * ① 四枚按钮的**最终渲染尺寸**逐值相同（下载 vs 追更）
       * ② 四枚按钮的**圆角半径**逐值相同（读渲染后的 BoxDecoration）
       * ③ 四枚按钮的**内边距**逐值相同（读渲染后的 Padding，不看是谁插的）
       * ⇒ 这三条合起来 = 「同源同档」这个产品契约，且与组件实现无关。
       * ```
       */
      EdgeInsetsGeometry padsOf(String lb) {
        final pads = t
            .widgetList<Padding>(
                find.descendant(of: btnOf(lb), matching: find.byType(Padding)))
            .map((p) => p.padding)
            .where((p) => p != EdgeInsets.zero)
            .toList();
        expect(pads, isNotEmpty, reason: '按钮内部必须有内边距（否则内容贴边）');
        return pads.first;
      }

      /// 圆角半径 —— 同样要兼容两种实现（理由见 [sideOf]）
      double radiusOf(String lb) {
        final decos = find.descendant(
            of: btnOf(lb), matching: find.byType(DecoratedBox));
        if (decos.evaluate().isNotEmpty) {
          final b =
              t.widget<DecoratedBox>(decos.first).decoration as BoxDecoration;
          return (b.borderRadius! as BorderRadius).topLeft.x;
        }
        final mats =
            find.descendant(of: btnOf(lb), matching: find.byType(Material));
        if (mats.evaluate().isNotEmpty) {
          final shape = t.widget<Material>(mats.first).shape;
          if (shape is RoundedRectangleBorder) {
            final br = shape.borderRadius;
            if (br is BorderRadius) return br.topLeft.x;
          }
          // StadiumBorder / ContinuousRectangleBorder 等 ⇒ 无法给出单一半径
          return -1;
        }
        fail('★ 按钮「$lb」找不到圆角信息，判据需要更新');
      }

      final dlPads = padsOf('下载');
      final followPads = padsOf('追更');
      debugPrint('T27W3 内边距读数 下载=$dlPads 追更=$followPads');
      expect(dlPads, followPads,
          reason: '★ 内边距必须与旁钮逐位相同（同一档，与谁插的无关）');
      expect(radiusOf('下载'), radiusOf('追更'),
          reason: '★ 圆角半径必须与旁钮逐位相同（渲染后的实际值）');

      // ★ 尺寸也一并钉住（这是「同档」最直接的证据）
      expect(t.getSize(btnOf('下载')), t.getSize(btnOf('追更')),
          reason: '★ 下载与追更的渲染尺寸必须逐值相同');
    });

    testWidgets('★★ 图标/文字色同源，且四枚都取自调色板', (t) async {
      await mount(t);
      final cs = Theme.of(t.element(find.text('下载'))).colorScheme;
      Color? effText(String lb) {
        final f = find.text(lb);
        expect(f, findsOneWidget, reason: '『$lb』必须渲染出来');
        final rich = t
            .widgetList<RichText>(
                find.descendant(of: f, matching: find.byType(RichText)))
            .firstWhere((w) => w.text.toPlainText() == lb);
        return rich.text.style?.color;
      }

      final dlText = effText('下载');
      final dlIcon = t.widget<Icon>(find.byIcon(Icons.download_outlined));
      expect(dlIcon.color, isNotNull,
          reason: '图标色必须显式来自共享样式构造（不许靠默认继承）');
      expect(dlIcon.size, 16.0, reason: '图标尺寸必须与旁钮同档（16）');
      expect(dlIcon.color, dlText,
          reason: '★ 图标色与文字色必须同源（修复前是两处独立硬编码）');
      // ★ 真·同源三兄弟：下载 / 收藏 / 追更 —— 都由本文件的共享样式构造取色
      for (final lb in <String>['追更', '收藏']) {
        expect(dlText, effText(lb),
            reason: '★ 同一行的这三枚按钮文字色必须完全一致（业主：「样式不一样」）；'
                '实测 下载=$dlText $lb=${effText(lb)}');
      }
      expect(dlText, cs.onSurfaceVariant,
          reason: '文字色必须取 ColorScheme.onSurfaceVariant（不许硬编码色值）');

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ Owner 1011 反馈③：「换源」已被**收编**进共享构造，四枚必须同色
       * ══════════════════════════════════════════════════════════════════
       *
       * # 这段注释原来是反的（记录了一次判据反转，别照着旧版回退）
       * ```text
       * 旧版这里断言的是 `swap, isNot(dlText)` —— 把「换源与三兄弟不同色」
       *   当成**如实备案**钉住。那在当时是"如实"，但不是"对"：
       *   Owner 真机图（5.png，y≈266-287 那一排）像素实测：
       *     收藏 (112,114,122) 灰 / 追更中 (59,111,224) 蓝（激活态）
       *     换源 (30,32,40) ★深 / 下载 (112,114,122) 灰
       *   ⇒ 真正**脱离同组**的正是「换源」那枚深色。
       * ```
       *
       * # Owner 的裁决
       * ```text
       * 四枚统一成**次要文字色**（onSurfaceVariant，即那支灰）——
       * 它们是同级的次要操作，不该抢详情区标题的视觉重心。
       * ⇒ 换源补上 `style: OutlinedButton.styleFrom(foregroundColor: _pillForeground(…))`，
       *   与另外三枚**逐字同源**。
       * ```
       */
      final swap = effText('换源');
      expect(swap, isNotNull, reason: '换源必须渲染出文字色');
      expect(swap, dlText,
          reason: '★ Owner 1011 反馈③：换源必须与另外三枚**同色**'
              '（修前它是主题 foregroundColor 的深色，实测 换源=$swap 下载=$dlText）');
      expect(swap, cs.onSurfaceVariant,
          reason: '换源也必须取 ColorScheme.onSurfaceVariant（不许吃主题默认值）');
    });

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ Owner 1011 反馈③后半：**字重**必须与旁钮同档
     * ══════════════════════════════════════════════════════════════════
     *
     * # Owner 原话（逐字）
     * ```text
     * > 这个下载按钮跟同一组的按钮大小不一致
     * ```
     *
     * # 为什么「比盒子尺寸」的门禁全绿却放过了它
     * ```text
     * 那些门禁比的是：border 色 / padding / 圆角 / **盒子**高 / 盒子宽 /
     *   字号 / 行高 —— 全是**盒子与部分样式**维度。
     * 而缺陷在**字重**：下载 w400 vs 收藏·追更 w500（主题 btnText）。
     * 同字号下字重差一档 ⇒ 笔画细一档 ⇒ 一眼看出不是一套；
     * 但**文本框宽几乎不变**（实测 28.5 vs 28.0）
     *   ⇒ 任何只比尺寸的门禁都抓不到。
     * ```
     *
     * # 判据形态：读**有效渲染样式**（RichText 上解析后的 weight），
     *   而不是 widget 上那份手写的 TextStyle
     * ```text
     * 手写 style 里读到的 weight 是「本 widget 自己声明了什么」；
     * 只有主题合并后的 RichText.style 才是「用户真正看到的」。
     * ⇒ 必须用后者（本仓铁律：门禁要测渲染事实，不测声明）。
     * ```
     */
    testWidgets('★★★ 字重同档：下载与收藏/追更的有效字重必须相等', (t) async {
      await mount(t);

      /// 有效字重：从 label 的 Text 往下找那条内容匹配的 RichText
      FontWeight? effWeight(String label) {
        final f = find.text(label);
        expect(f, findsOneWidget, reason: '『$label』必须渲染出来');
        final rich = t
            .widgetList<RichText>(
                find.descendant(of: f, matching: find.byType(RichText)))
            .firstWhere((w) => w.text.toPlainText() == label);
        return rich.text.style?.fontWeight;
      }

      final dl = effWeight('下载');
      final fav = effWeight('收藏');
      final follow = effWeight('追更');
      debugPrint('T27W3 字重读数：下载=$dl 收藏=$fav 追更=$follow');

      expect(dl, isNotNull, reason: '下载文字必须有明确字重（不许靠默认继承）');
      expect(dl, fav,
          reason: '★ 下载与收藏**有效字重**必须相等'
              '（修前 下载=$dl vs 收藏=$fav —— 同字号下细一档，肉眼可见）');
      expect(dl, follow, reason: '下载与追更的有效字重必须相等');
    });

    testWidgets('★★★ 菜单行为保留：点下载弹两项，选「下载本集」后菜单关闭', (t) async {
      await mount(t);
      await t.tap(find.text('下载'));
      await t.pumpAndSettle();

      expect(find.text('下载本集'), findsOneWidget,
          reason: '菜单必须弹得出（按钮自己 onPressed 里手写 showMenu）');
      expect(find.text('下载全部集（1 集）'), findsOneWidget);

      await t.tap(find.text('下载本集'));
      // ⚠️ 不能 pumpAndSettle：选中 → _downloadCurrent → _enqueueOne
      //    → DownloadQueue._run → DLL 缺失失败 → _flash 的 2400ms
      //    Future.delayed 是真实 timer，settle 会一直死等它。改成
      //    「先 pump 一帧让菜单收场，再把 2400ms timer 排干」。
      await t.pump();
      await t.pump(const Duration(milliseconds: 2600));
      expect(find.text('下载本集'), findsNothing,
          reason: '选中后菜单必须关闭 —— 返回值真的接到了（DetailPage._downloadCurrent）');
    });
  });
}
