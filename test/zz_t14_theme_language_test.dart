// ═══════════════════════════════════════════════════════════════════════
//  设计语言层测试（T5+T14）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件在钉什么
//
// `ThemePack` 上那四个「设计语言」维度（radius / borderWidth /
// dividerThickness / buttonPadding）**必须真的落到 ThemeData 上** ——
// 否则就是本仓已经有过的那种假接口：
// ```text
// buttonPadding 字段在 theme_pack.dart 里存在了很久（能解析、能序列化、
// 能导出 JSON），但**全仓没有任何一处读它** ⇒ 用户在主题包里写了
// "buttonPadding": {...} 却什么都不发生，而且**不报错**。
// ```
// ⇒ 判据分三层：
// ```text
// ① 三个内置设计语言主题**确实声明了**四个维度（不是漏写）
// ② ThemeLanguage.apply 真的把值写进了 ThemeData（逐项读回来比对）
// ③ ★ 反面：默认值 ⇒ 原样返回（既有 6 套主题与"跟随系统"零变化）
// ```
// 第 ③ 条是本文件最重要的一条 —— 没有它，一次"顺手美化"就可能让
// 既有 6 套主题的观感悄悄变掉，而所有测试仍然全绿。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme/theme_language.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

/// 三个「设计语言」主题的 id
const List<String> _ids = <String>[
  'builtin.glass',
  'builtin.neoBrutal',
  'builtin.minimal',
];

ThemePack _pack(String id) =>
    ThemePackStore.builtins.firstWhere((p) => p.id == id);

/// 取出按钮当前的圆角
///
/// ⚠️ 不能直接读 `.borderRadius` —— `OutlinedBorder` 这个基类**没有**
///    这个 getter（只有 `RoundedRectangleBorder` / `RoundedSuperellipseBorder`
///    这类具体类型才有）。本仓用的是后者，所以按具体类型取。
/// ⚠️ 返回类型是 `BorderRadiusGeometry`（不是 `BorderRadius`）——
///    `RoundedSuperellipseBorder.borderRadius` 声明的是前者。
///    本仓实际塞进去的是 `BorderRadius.all(...)`，相等性判断照样成立。
BorderRadiusGeometry? _btnRadius(ThemeData td) {
  final s = td.filledButtonTheme.style?.shape?.resolve(<WidgetState>{});
  if (s is RoundedSuperellipseBorder) return s.borderRadius;
  if (s is RoundedRectangleBorder) return s.borderRadius;
  return null;
}

void main() {
  group('① 三套设计语言主题都声明了四个维度', () {
    for (final id in _ids) {
      test(id, () {
        final p = _pack(id);
        expect(p.radius, isNotNull, reason: '$id 没写 radius ⇒ 退回默认圆角');
        expect(p.borderWidth, isNotNull, reason: '$id 没写 borderWidth');
        expect(p.dividerThickness, isNotNull,
            reason: '$id 没写 dividerThickness');
        expect(p.buttonPadding, isNotNull,
            reason: '$id 没写 buttonPadding');
      });
    }

    test('★ 三套之间必须**真的不同**（不是复制粘贴改了名字）', () {
      /*
       * # 判据为什么是"整条签名唯一"而不是"每个维度三值互不相同"
       *
       * 我第一版写的是后者，它当场红了：
       * ```text
       * borderWidth = 1.0 / 2.5 / 1.0   ⇒ 只有 2 个不同值
       * ```
       * 但**这不是缺陷** —— 发丝线就是发丝线，"液态玻璃"和"极简留白"
       * 都用 1px 是设计上正确的选择（两套的差别在圆角 22 vs 4、
       * 深色 vs 浅色、冰蓝 vs 墨绿）。要求每个维度三值互不相同，
       * 等于逼我为了过测试去写一个不该存在的 1.5px。
       *
       * ⇒ 改成：**四维 + 配色的整条签名**必须两两不同。
       *   这既拦得住"复制粘贴改了名字"（签名会完全相同），
       *   又不逼设计去做无意义的取差。
       */
      String sig(ThemePack p) => [
            p.radius,
            p.borderWidth,
            p.dividerThickness,
            p.buttonPadding.toString(),
            p.palette.background.toARGB32().toRadixString(16),
            p.palette.primary.toARGB32().toRadixString(16),
            p.palette.card.toARGB32().toRadixString(16),
            p.brightness.name,
          ].join('|');

      final sigs = _ids.map((i) => sig(_pack(i))).toList();
      expect(sigs.toSet().length, 3,
          reason: '★ 有三套主题的"设计语言签名"完全相同（配色 + 圆角 + '
              '描边 + 分隔线 + 按钮内边距都一样）⇒ 它们看起来会是同一个 App：'
              '${sigs.join("  ///  ")}');

      // ★ 再加一条硬的：圆角与配色**必须**三值互不相同 ——
      //   这两个是肉眼第一眼看到的维度，它们重复了才是真的"像同一个 App"。
      expect(_ids.map((i) => _pack(i).radius).toSet().length, 3,
          reason: '★ 三套的圆角有重复 ⇒ 形状语言没分开（圆角是差异最大的维度）');
      expect(_ids.map((i) => _pack(i).palette.background).toSet().length, 3,
          reason: '★ 三套的底色有重复');
      expect(_ids.map((i) => _pack(i).palette.primary).toSet().length, 3,
          reason: '★ 三套的主色有重复');
    });
    test('液态玻璃：圆角 22 / 1px / 松按钮', () {
      final pack = _pack('builtin.glass');
      final td =
          ThemeLanguage.apply(AppTheme.themeForPack(pack.brightness, pack), pack);

      expect(_btnRadius(td), const BorderRadius.all(Radius.circular(22)));
      expect(td.filledButtonTheme.style?.padding?.resolve(<WidgetState>{}),
          const EdgeInsets.symmetric(horizontal: 16, vertical: 12));
      expect(td.dividerTheme.thickness, 1);
      expect((td.cardTheme.shape as OutlinedBorder).side.width, 1);
    });

    test('新粗野主义：圆角 0 / 2.5px / 厚重按钮 / 3px 分隔线', () {
      final pack = _pack('builtin.neoBrutal');
      final td =
          ThemeLanguage.apply(AppTheme.themeForPack(pack.brightness, pack), pack);

      expect(_btnRadius(td), const BorderRadius.all(Radius.circular(0)));
      expect(td.filledButtonTheme.style?.padding?.resolve(<WidgetState>{}),
          const EdgeInsets.symmetric(horizontal: 18, vertical: 14));
      expect(td.dividerTheme.thickness, 3);
      // ★ 2.5px 是"硬边"语言的核心，也是本套与另外两套最大的区别
      expect((td.cardTheme.shape as OutlinedBorder).side.width, 2.5);
      expect(
          td.outlinedButtonTheme.style?.side?.resolve(<WidgetState>{})?.width, 2.5,
          reason: '描边按钮的边必须跟着 borderWidth 走，'
              '否则"卡片 2.5px、按钮 1px"会显得没做完');
    });

    test('极简留白：圆角 4 / 1px / 紧按钮', () {
      final pack = _pack('builtin.minimal');
      final td =
          ThemeLanguage.apply(AppTheme.themeForPack(pack.brightness, pack), pack);

      expect(_btnRadius(td), const BorderRadius.all(Radius.circular(4)));
      expect(td.filledButtonTheme.style?.padding?.resolve(<WidgetState>{}),
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10));
      expect(td.dividerTheme.thickness, 1);
    });

    test('★ 幂等：apply 两次与一次**读数完全相同**', () {
      /*
       * # 为什么要钉这条
       *
       * 接线后 `theme_bridge.buildAppTheme` 自己会 apply 一次；而展示页
       * 截图测试为了"看到接线后的真实观感"，在拿到 themeForPack 之后
       * **又** apply 了一次（在 Lead 接线之前的那段时间里，第一次 apply
       * 还不存在，那次调用是必须的）。
       * ⇒ 两条路径都会存在，所以"重复 apply"必须是安全的。
       *
       * ⚠️ 判据是**逐值读数相同**，不是 `identical` / `==` ——
       *    `WidgetStateProperty.all(...)` 每次都新建实例且不重写 `==`，
       *    所以两个 ThemeData **不会** `==`。那不影响渲染（值一样），
       *    但把 `==` 写成断言会得到一条**假红**。这里如实按读数比。
       */
      final pack = _pack('builtin.neoBrutal');
      final once = ThemeLanguage.apply(
          AppTheme.themeForPack(pack.brightness, pack), pack);
      final twice = ThemeLanguage.apply(once, pack);

      expect(_btnRadius(twice), _btnRadius(once));
      expect(twice.filledButtonTheme.style?.padding?.resolve(<WidgetState>{}),
          once.filledButtonTheme.style?.padding?.resolve(<WidgetState>{}));
      expect(twice.dividerTheme.thickness, once.dividerTheme.thickness);
      expect((twice.cardTheme.shape as OutlinedBorder).side.width,
          (once.cardTheme.shape as OutlinedBorder).side.width);
      expect((twice.cardTheme.shape as OutlinedBorder).side.color,
          (once.cardTheme.shape as OutlinedBorder).side.color);
      expect(twice.outlinedButtonTheme.style?.side?.resolve(<WidgetState>{})?.width,
          once.outlinedButtonTheme.style?.side?.resolve(<WidgetState>{})?.width);
    });

    test('★ 描边的**颜色**必须保留（只换粗细）', () {
      final pack = _pack('builtin.neoBrutal');
      final before = AppTheme.themeForPack(pack.brightness, pack);
      final after = ThemeLanguage.apply(before, pack);
      final c0 = (before.cardTheme.shape as OutlinedBorder).side.color;
      final c1 = (after.cardTheme.shape as OutlinedBorder).side.color;
      expect(c1, c0,
          reason: '覆盖描边时把颜色一起换掉 = 卡片描边变黑/变透明，'
              '这是"顺手改一处"最容易踩的坑');
    });
  });

  group('③ ★ 默认值 ⇒ 原样返回（既有主题零变化）', () {
    test('pack = null（跟随系统 / 明暗三态）', () {
      final td = AppTheme.themeForPack(Brightness.dark, null);
      expect(identical(ThemeLanguage.apply(td, null), td), isTrue,
          reason: '★ 没有主题包时必须**原样返回**（同一个实例）—— '
              '重建一遍会丢掉 shape 上原有的 side，是实打实的观感差异');
    });

    test('既有主题（四个维度全 null）也不重建', () {
      final pack = _pack('builtin.midnight');
      final td = AppTheme.themeForPack(pack.brightness, pack);
      expect(ThemeLanguage.of(pack).isDefault, isTrue);
      expect(identical(ThemeLanguage.apply(td, pack), td), isTrue);
    });

    test('既有 6 套主题的 ThemeData 与"没接线"时逐值相同', () {
      for (final p in ThemePackStore.builtins) {
        if (_ids.contains(p.id)) continue;
        final base = AppTheme.themeForPack(p.brightness, p);
        expect(identical(ThemeLanguage.apply(base, p), base), isTrue,
            reason: '★ 既有主题「${p.name}」被这次改动影响了 —— '
                '那正是"顺手美化"造成的静默回归');
      }
    });
  });

  /*
   * ══════════════════════════════════════════════════════════════════
   * ④ ★★★ 接线门禁（dlg-source · 2026-10-17 补）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么必须单独有这一组（这是本文件原来最大的洞）
   *
   * 上面 ①②③ 组全部是自己调 ThemeLanguage.apply(...) 来验的：
   * ```dart
   * ThemeLanguage.apply(AppTheme.themeForPack(pack.brightness, pack), pack)
   * ```
   * 那只能证明 apply 这个函数本身写对了，完全不能证明
   * theme_bridge.buildAppTheme 真的调了它。
   *
   * ★ 这不是理论担心 —— 我实测过故障注入（把 buildAppTheme 末尾的
   *   `return ThemeLanguage.apply(td, pack)` 换成 `return td`）：
   * ```text
   * 注入后跑本文件 + theme_regression + theme_tokens ⇒ 00:01 +34 All tests passed!
   * ```
   * **全绿**。也就是说接线一旦被谁删掉，上面三组一条都不会红，
   * 而用户看到的是「主题包里写的 borderWidth / dividerThickness /
   * buttonPadding 全都不生效」—— 正是本仓最忌讳的假接口。
   *
   * # 判据为什么是「读 themeForPack 的结果」而不是「grep 源码里有没有 apply」
   *
   * 源码匹配是假绿重灾区（注释里写一句就过）。这里读的是
   * **产品公开入口 AppTheme.themeForPack 的真实返回值** —— 与用户
   * 实际拿到的那套 ThemeData 同源，接线断了必然变红。
   */
  group('④ ★★★ 接线：themeForPack 必须真的带上四个设计语言维度', () {
    /*
     * ★ 四个维度**各自一个 test**（Lead 2026-10-17 复查时点名要求的）。
     *
     * # 为什么不能只写一条综合断言
     *
     * 我第一版把四维塞进**同一个** `test(...)` 里，跑起来只有
     * 「三套设计语言主题：design 值必须出现在 themeForPack 的结果里」
     * 这**一条**会红。虽然每条 expect 的 reason 都写了维度名，
     * 但**测试粒度**上分辨不出来 —— 将来某一维单独断线时，
     * 报告里看到的是「那一条又红了」，而不是「borderWidth 断了」。
     *
     * ⇒ 拆成四维独立：某维断线 ⇒ **只有它那一维**的用例红，指名道姓。
     *
     * ⚠️ 四者都**只调产品入口** `AppTheme.themeForPack`，绝不自己 apply。
     */
    test('④-a radius：按钮圆角必须等于主题包的 radius', () {
      for (final id in _ids) {
        final pack = _pack(id);
        final td = AppTheme.themeForPack(pack.brightness, pack);
        expect(_btnRadius(td), BorderRadius.all(Radius.circular(pack.radius!)),
            reason: '★ radius 这一维没接线：主题包「${pack.name}」的 '
                'radius=${pack.radius} 没落到 themeForPack 的按钮圆角上');
      }
    });

    test('④-b borderWidth：卡片描边粗细必须等于主题包的 borderWidth', () {
      for (final id in _ids) {
        final pack = _pack(id);
        final td = AppTheme.themeForPack(pack.brightness, pack);
        expect((td.cardTheme.shape as OutlinedBorder).side.width,
            pack.borderWidth,
            reason: '★ borderWidth 这一维没接线：主题包「${pack.name}」的 '
                'borderWidth=${pack.borderWidth} 没落到卡片描边上');
      }
    });

    test('④-c dividerThickness：分隔线粗细必须等于主题包的 dividerThickness', () {
      for (final id in _ids) {
        final pack = _pack(id);
        final td = AppTheme.themeForPack(pack.brightness, pack);
        expect(td.dividerTheme.thickness, pack.dividerThickness,
            reason: '★ dividerThickness 这一维没接线：主题包「${pack.name}」的 '
                'dividerThickness=${pack.dividerThickness} 没落到分隔线上');
      }
    });

    test('④-d buttonPadding：按钮内边距必须等于主题包的 buttonPadding', () {
      for (final id in _ids) {
        final pack = _pack(id);
        final td = AppTheme.themeForPack(pack.brightness, pack);
        expect(td.filledButtonTheme.style?.padding?.resolve(<WidgetState>{}),
            pack.buttonPadding,
            reason: '★ buttonPadding 这一维没接线：主题包「${pack.name}」的 '
                'buttonPadding=${pack.buttonPadding} 没落到按钮内边距上');
      }
    });

    test('★ 对照组：既有主题经 themeForPack 后确实没被动过', () {
      /*
       * 与上面四条互为对照：设计语言主题必须变，既有主题必须不变。
       * 少了这一条，一个「对所有主题都无脑重建」的实现也能让上面变绿。
       */
      for (final p in ThemePackStore.builtins) {
        if (_ids.contains(p.id)) continue;
        final td = AppTheme.themeForPack(p.brightness, p);
        expect(_btnRadius(td), const BorderRadius.all(Radius.circular(10)),
            reason: '★ 既有主题「${p.name}」的圆角被改了');
        expect(td.dividerTheme.thickness, 1,
            reason: '★ 既有主题「${p.name}」的分隔线粗细被改了');
      }
    });
  });

  /*
   * ══════════════════════════════════════════════════════════════════
   * ⑤ ★ 截图口径 == 产品口径（dlg-source · 2026-10-17 补）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么还要这一组
   *
   * `zz_t14_theme_styles_shot_test.dart:271` 截图的主题是：
   * ```dart
   * ThemeLanguage.apply(AppTheme.themeForPack(pack.brightness, pack), pack)
   * ```
   * 它**自己补调了一次 apply**。那个文件里写的理由是「接线后这里是 apply
   * 两次、逐值幂等，所以接线前后图是同一张」—— 那个理由**本身是对的**，
   * 但它有个副作用：**那张图无法用来证明接线**（断线与不断线，图一模一样）。
   *
   * ⇒ 本组把那个隐含前提**显式钉住**：证明截图用的 td 与产品
   *   `themeForPack` 的返回值**逐值相同**。
   *   有了它，三张验收图才是**产品真实渲染**的证据，而不是「测试里
   *   自己拼出来的一套近似值」。
   *
   * ⚠️ 这条**不能**替代 group ④：本组钉的是「图 == 产品」，
   *    ④ 钉的是「产品 == 主题包声明」。两者缺一不可 ——
   *    少了 ④，图和产品一起错；少了本组，图对不上产品。
   */
  group('⑤ ★ 截图口径 == 产品口径', () {
    test('三套主题：截图用的 td 与产品 themeForPack 逐值相同（apply 幂等）', () {
      for (final id in _ids) {
        final pack = _pack(id);
        final product = AppTheme.themeForPack(pack.brightness, pack);
        // 截图文件第 271 行的原式，逐字照搬
        final shot = ThemeLanguage.apply(product, pack);
        expect(shot == product, isTrue,
            reason: '★ 「${pack.name}」截图用的 ThemeData 与产品 themeForPack '
                '不一致 ⇒ 三张验收图**不能**代表产品真实观感');
      }
    });
  });
}
