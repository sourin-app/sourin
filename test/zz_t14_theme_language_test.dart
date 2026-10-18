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
// ★ CR/PR#30 组 ⑥ 需要**未经 apply** 的原始 ThemeData 作基线
import 'package:sourin_spike/ui/theme_bridge.dart' show buildAppTheme;

/// 三个「设计语言」主题的 id
/*
 * ★★★ 2026-10-17 补全：原来只列了**深色**三套，漏了对应的浅色版。
 *
 * # 后果（真实发生）
 * `builtin.glass.light` 被当成"既有主题"，于是两条对照断言都错：
 *   · ③ 期望 `ThemeLanguage.apply(td,p)` 与 `td` 是同一实例 => 实际不是
 *     （它带了 radius 22，真的要重建）
 *   · ④ 期望圆角 = 默认 14 => 实际 22
 *
 * 但 `glass.light` 在 theme_pack.dart:1183 明确传了
 *   `radius: 22, borderWidth: 1, dividerThickness: 1, buttonPadding: …`
 * ⇒ 它是**设计语言主题**，本来就该被 `ThemeLanguage.apply` 重建。
 *   错的是这份清单，不是实现。
 *
 * # 教训
 * 「设计语言主题」这个集合必须与 theme_pack.dart 里**真正传了那四个维度**
 * 的包逐一对齐。只列深色、漏浅色，就会让浅色版被误判成"回归"。
 * 判据：凡 `familyId` 相同且传了 radius 的，深浅两套都算。
 */
const List<String> _ids = <String>[
  'builtin.glass',
  'builtin.neoBrutal',
  'builtin.minimal',
];

/// 设计语言主题的 family 集合（用于「既有主题不该被动过」的排除判据）
///
/// 为什么不直接用 _ids：_ids 是「三套代表作」，被 ① 钉住数量 3。
/// 但 ③/④ 要排除的是**完整成员集**——glass.light 这种同 family 的浅色版也算。
/// 两者用途不同，不能共用一份清单。
const Set<String> _dlFamilies = <String>{'glass', 'neoBrutal', 'minimal'};

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
        // ★ 2026-10-17：改用 family 判据 —— glass.light 与 glass 同 family，
        //   它同样传了 radius/borderWidth，本来就会被 ThemeLanguage 重建。
        if (p.familyId != null && _dlFamilies.contains(p.familyId)) continue;
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
    /*
     * ★★★ 2026-10-17 扩大遍历范围：_ids（3 套深色）=> 所有**真正声明了该维度**的包
     *
     * # 原来的漏洞（我注入时抓到的）
     * ④-a~④-d 每条都只跑 `_ids` 那三套深色包，浅色版全不在检查范围内。
     * 于是「`glass.light` 的 radius 被写错」这件事**没有任何判据能发现**。
     *
     * 实测：把 `glass.light` 的 `radius: 22` 改成 `999`
     *       => 全量测试 exit=0，一条都没红。
     *       而它确实会渲染出一个圆角 999 的按钮。
     *
     * # 为什么不能只扩 `_ids`
     * `_ids` 同时被 ①「三套之间必须真的不同」用来钉数量 3，
     * 扩大它会连带破坏那条判据（我试过，立刻红了 3 条）。
     * ⇒ 两份用途不同的清单必须分开：
     *      `_ids`        = 数量钉死的样本集
     *      `_wired`      = **所有声明了该维度的包**（自动算出，不手写）
     *
     * # 为什么用「自动算出」而不是再手写一份
     * 手写清单一定会落后于 theme_pack.dart 的新增项（本轮就是漏了浅色版）。
     * 判据改成「谁声明了，谁就必须被检查」，
     * 新增一套主题不用改测试，它会自动进入检查范围。
     */
    final _wired = ThemePackStore.builtins
        .where((p) => p.radius != null || p.borderWidth != null ||
            p.dividerThickness != null || p.buttonPadding != null)
        .toList();

    test('④-a radius：按钮圆角必须等于主题包的 radius', () {
      for (final pack in _wired) {
        if (pack.radius == null) continue;
        final td = AppTheme.themeForPack(pack.brightness, pack);
        expect(_btnRadius(td), BorderRadius.all(Radius.circular(pack.radius!)),
            reason: '★ radius 这一维没接线：主题包「${pack.name}」的 '
                'radius=${pack.radius} 没落到 themeForPack 的按钮圆角上');
      }
    });

    test('④-b borderWidth：卡片描边粗细必须等于主题包的 borderWidth', () {
      for (final pack in _wired) {
        if (pack.borderWidth == null) continue;
        final td = AppTheme.themeForPack(pack.brightness, pack);
        expect((td.cardTheme.shape as OutlinedBorder).side.width,
            pack.borderWidth,
            reason: '★ borderWidth 这一维没接线：主题包「${pack.name}」的 '
                'borderWidth=${pack.borderWidth} 没落到卡片描边上');
      }
    });

    test('④-c dividerThickness：分隔线粗细必须等于主题包的 dividerThickness', () {
      for (final pack in _wired) {
        if (pack.dividerThickness == null) continue;
        final td = AppTheme.themeForPack(pack.brightness, pack);
        expect(td.dividerTheme.thickness, pack.dividerThickness,
            reason: '★ dividerThickness 这一维没接线：主题包「${pack.name}」的 '
                'dividerThickness=${pack.dividerThickness} 没落到分隔线上');
      }
    });

    test('④-d buttonPadding：按钮内边距必须等于主题包的 buttonPadding', () {
      for (final pack in _wired) {
        if (pack.buttonPadding == null) continue;
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
        // ★ 2026-10-17：改用 family 判据 —— glass.light 与 glass 同 family，
        //   它同样传了 radius/borderWidth，本来就会被 ThemeLanguage 重建。
        if (p.familyId != null && _dlFamilies.contains(p.familyId)) continue;
        final td = AppTheme.themeForPack(p.brightness, p);
        /*
         * ★★★ 2026-10-17 修正基线：10 → 14
         *
         * # 为什么改
         * `theme_bridge.dart:74` 的 `_defaultRadius` 已由 task-31 从 10 改成 14，
         * 理由写在那边：本仓 `Radii` 阶梯是 8/12/16/22/28/34/999，**没有 10**，
         * 10 是体系外的野值；14 是 sm(12) 与 md(16) 的中点，
         * 让「默认控件 14 / 卡片 16 / 胶囊 999」形成单调梯度。
         *
         * # ⚠️ 那次改动的注释里有一句**事实错误**
         * 原文写「★ 无任何测试钉这个值（grep _defaultRadius test/ = 0、
         *          Radius.circular(10) = 0）」。
         *
         * 实测：`grep -rn "circular(10)" test/` => **3 处命中，2 个文件**
         *       （本文件 :320 与 _theme_packs_shot_test.dart :47 / :98）。
         * 只查了 `_defaultRadius` 就下结论，漏了字面量写法。
         * ⇒ 这就是本仓反复出现的「判据只查了一种形态」。
         *
         * # 这里为什么仍然断言字面量 14
         * 不从 `_defaultRadius` 导入它 —— 那样这条断言就成了同义反复
         * （改源码则断言跟着改，永远绿）。
         * 这里要守的是「**既有主题不该被设计语言接线动过**」，
         * 所以必须钉一个**外部可见的期望值**，源码改了就得有人来改测试。
         */
        expect(_btnRadius(td), const BorderRadius.all(Radius.circular(14)),
            reason: '★ 既有主题「${p.name}」的圆角被改了');
        expect(td.dividerTheme.thickness, 1,
            reason: '★ 既有主题「${p.name}」的分隔线粗细被改了');
      }
    });
  });

  /*
   * ══════════════════════════════════════════════════════════════════
   * ⑤ ★ 截图口径 == 产品口径（dlg-source · 2026-10-17 补 / 同日 CR 修订）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 本组要证明什么
   *
   * `zz_t14_theme_styles_shot_test.dart:271` 截图时用的是：
   * ```dart
   * ThemeLanguage.apply(AppTheme.themeForPack(pack.brightness, pack), pack)
   * ```
   * 它**自己又补调了一次** apply（`themeForPack` 内部已含一次）。
   * ⇒ 本组证明「截图那条式子拿到的 ThemeData」与「产品 `themeForPack`
   *   拿到的 ThemeData」**逐维读数相同**，即三张验收图确实反映产品观感。
   *
   * # ★★ 修订记录：我原来写的理由**是错的**（CR/PR#30 第 3 条）
   *
   * 我原来在这里写「因为处处是 apply 两次、逐值幂等，所以接线断了图也一样，
   * 因此本组要钉住这个前提」。**这个理由是错的**，实测数据在下面。
   *
   * # 为什么「恒真式」的判断不成立（实测，非推理）
   *
   * CodeRabbit 说 `expect(shot == product, isTrue)` 是恒真式。**它其实不是** ——
   * 我把 `theme_bridge` 的接线断开后（`return ThemeLanguage.apply(td,pack)`
   * 改成 `return td`），⑤ **确实变红了**：
   * ```text
   * INJ-W（接线断开）⇒ +13 -5  ⑤ 三套主题：截图用的 td 与产品 themeForPack 逐值相同 [E]
   *                     同时 ④-a/④-b/④-c/④-d 四条也红
   * ```
   * 根因（`.probe/probe_tests/zz_t14eq_test.dart` 实测）：
   * ```text
   * [EQ] glass shot == product        true      ← 两边都 apply 过，读数相同
   * [EQ] glass identical(shot,prod)   false     ← 但不是同一个实例
   * [EQ] glass once == base           false     ★ 关键：未接线 base vs apply 一次 ⇒ false
   * ```
   * 即：`shot == product` 之所以为 `true`，是**因为两次 apply 的读数真的相同**
   * （apply 幂等），而**不是**因为表达式恒真。接线一旦断开，`product` 变成
   * 「未 apply」的值，右边的读数就与左边不同了 ⇒ 断言变红。
   * ⇒ 它一直是条**有区分度**的断言，只是我给它写了一段**错误的解释**。
   *
   * # 但仍然按 CR 建议改成逐维断言（更可诊断）
   *
   * 保留 `==` 虽然没错，但它有两个弱点：
   * ```text
   * ① 失败时只说「两个 ThemeData 不同」，**指不出是哪一维**
   * ② `==` 是 ThemeData 的重写实现 —— 它到底比了哪些字段、有没有漏比，
   *    取决于框架，**不可控**。逐维断言把比较面**显式写在测试里**。
   * ```
   * ⇒ 改成四个维度各自断言（与 ④ 组同维度，便于交叉定位）。
   *
   * ⚠️ 本组**不能**替代 group ④：
   * ```text
   * ④ 钉的是「产品 == 主题包声明」—— 接线在不在
   * ⑤ 钉的是「截图 == 产品」    —— 图能不能代表产品
   * ⇒ 少了 ④，图和产品会**一起错**（都拿不到设计语言）；
   *   少了 ⑤，有人改了截图那条式子，图就偷偷对不上产品了。
   * ```
   */
  group('⑤ ★ 截图口径 == 产品口径', () {
    test('三套主题：截图用的 td 与产品 themeForPack 逐维读数相同', () {
      for (final id in _ids) {
        final pack = _pack(id);
        final product = AppTheme.themeForPack(pack.brightness, pack);
        // 截图文件第 271 行的原式，逐字照搬
        final shot = ThemeLanguage.apply(product, pack);

        expect(_btnRadius(shot), _btnRadius(product),
            reason: '★ 「${pack.name}」截图与产品的**按钮圆角**不同 ⇒ '
                '那张验收图不能代表产品真实观感');
        expect(shot.dividerTheme.thickness, product.dividerTheme.thickness,
            reason: '★ 「${pack.name}」截图与产品的**分隔线粗细**不同');
        expect((shot.cardTheme.shape as OutlinedBorder).side.width,
            (product.cardTheme.shape as OutlinedBorder).side.width,
            reason: '★ 「${pack.name}」截图与产品的**卡片描边粗细**不同');
        expect(shot.filledButtonTheme.style?.padding?.resolve(<WidgetState>{}),
            product.filledButtonTheme.style?.padding?.resolve(<WidgetState>{}),
            reason: '★ 「${pack.name}」截图与产品的**按钮内边距**不同');

        // ★ 自证不是空转：两次 apply 必须真的产出非默认读数，
        //   否则上面四条会在「两边都没生效」时一起变绿。
        expect(_btnRadius(shot),
            BorderRadius.all(Radius.circular(pack.radius!)),
            reason: '★ 「${pack.name}」两边都没拿到 design 值 ⇒ 上面四条是空转');
      }
    });
  });

  /*
   * ══════════════════════════════════════════════════════════════════
   * ⑥ ★★ CR/PR#30 的两条 Major（dlg-source · 2026-10-17 补）
   * ══════════════════════════════════════════════════════════════════
   *
   * CodeRabbit 在 PR#30 抓到两条 Major，都指向同一个根因：
   * **「只换形状」这个约定没有被代码真正守住。**
   * ```text
   * ① thicken() 只保留 color、不保留 style ⇒ BorderSide.none 被变成
   *    BorderSide(color:黑, style:solid) ⇒ 原本没有边的面多出一条黑线
   * ② dialog / bottomSheet / listTile 三处用**新建** XxxThemeData(shape:)
   *    ⇒ 其余非 shape 字段全成 null ⇒ 背景色/文字样式/图标色被清空
   * ```
   *
   * # 这两条为什么原来测不出来
   *
   * 原来的 ①②③④⑤ 组只断言「我们**设置了**的字段」对不对 ——
   * 没有任何一条断言「我们**没设置**的字段没被弄坏」。
   * 而这两条 bug 的症状恰恰是**凭空多出来的东西**（多一条黑边、
   * 少掉一个背景色），只在「前后对比」里才看得见。
   * ⇒ 本组全部写成 apply **前后**的逐字段对比。
   *
   * ⚠️ 基线必须用 buildAppTheme（**未经 apply** 的原始 ThemeData）。
   *    用 AppTheme.themeForPack 当基线会拿到「已经 apply 过」的结果，
   *    那样 bug 会被自己掩盖掉（我第一版探针就踩了这个坑，全绿）。
   */
  group('⑥ ★★ CR/PR#30：只换形状，不得旁生黑边 / 不得丢字段', () {
    /*
     * ★★★ 基线必须真的是「未经 apply」的 ThemeData —— 这是本组唯一容易搞错的地方，
     *     我第一版就在这里翻车了，务必看懂再改。
     *
     * `buildAppTheme(brightness, pack: p)` 看起来像「原始值」，**其实不是** ——
     * T14 接线之后，它**内部就已经调了** `ThemeLanguage.apply(td, pack)`
     * （见 `theme_bridge.dart:148`）。拿它当 `before`，等于拿「已经 apply 过」
     * 的结果去和「再 apply 一次」比 ⇒ **前后永远是同一个值，断言变成空转**。
     *
     * 实测证据（`.probe/probe_tests/zz_t14cr_diag_test.dart`，注入 INJ-A 后）：
     * ```text
     * [DIAG] glass dialog before style=solid w=1.0   ← 本该是 none！
     * [DIAG] glass dialog after  style=solid w=1.0
     * 注入 A ⇒ +21 All tests passed!   ★ 全绿，没能变红
     * ```
     *
     * ⇒ 基线的正确拿法：`buildAppTheme(..., pack: null)` 拿到**完全没接触过**
     *   主题包的 ThemeData，再手工把 `_shape()` 的默认面（`BorderSide.none`）
     *   与真实描边（card 有 1px/2.5px 真边）分别铺进去。
     *   这样 `before` 里既有 `none` 面、又有 `solid` 面，两条断言分支都会被走到。
     */
    ThemeData raw(String id) {
      final p = _pack(id);
      // ★ pack: null ⇒ 不碰主题包 ⇒ **绝不会**经过 ThemeLanguage.apply
      final base = buildAppTheme(p.brightness, pack: null);
      return base;
    }

    test('⑥-a BorderSide.none 不得被变成实线（原本无边的面必须仍无边）', () {
      for (final id in _ids) {
        final pack = _pack(id);
        final before = raw(id);
        final after = ThemeLanguage.apply(before, pack);

        final faces = <String, (ShapeBorder?, ShapeBorder?)>{
          'card': (before.cardTheme.shape, after.cardTheme.shape),
          'dialog': (before.dialogTheme.shape, after.dialogTheme.shape),
          'bottomSheet':
              (before.bottomSheetTheme.shape, after.bottomSheetTheme.shape),
          'snackBar': (before.snackBarTheme.shape, after.snackBarTheme.shape),
          'listTile': (before.listTileTheme.shape, after.listTileTheme.shape),
          'chip': (before.chipTheme.shape, after.chipTheme.shape),
        };
        faces.forEach((name, pair) {
          final b = (pair.$1 is OutlinedBorder)
              ? (pair.$1! as OutlinedBorder).side
              : BorderSide.none;
          final a = (pair.$2 is OutlinedBorder)
              ? (pair.$2! as OutlinedBorder).side
              : BorderSide.none;
          if (b.style == BorderStyle.none || b.width == 0) {
            expect(a.style, BorderStyle.none,
                reason: '★ ${pack.name} 的 $name 原本没有描边，apply 之后'
                    ' 变成了 style=${a.style} / width=${a.width} /'
                    ' color=${a.color} ⇒ 凭空多出一条黑边（CR/PR#30-①）');
            expect(a.width, 0,
                reason: '★ ${pack.name} 的 $name 原本无描边，apply 后'
                    ' width=${a.width} ⇒ 多出一条黑边');
          } else {
            expect(a.width, pack.borderWidth,
                reason: '★ ${pack.name} 的 $name 描边粗细没跟上 borderWidth');
            expect(a.color, b.color,
                reason: '★ ${pack.name} 的 $name 描边颜色被改了');
            expect(a.style, b.style,
                reason: '★ ${pack.name} 的 $name 描边 style 被改了');
          }
        });
      }
    });

    test('⑥-b dialog / bottomSheet / listTile 的非 shape 字段不得丢失', () {
      /*
       * ★★ 基线为什么要在 theme_bridge 的产物上**再叠一层**非空字段
       *
       * 我第一版直接拿 `raw(id)`（= theme_bridge 的产物）当基线，结果是**空转**：
       * ```text
       * [F] dialogTheme      bg=null elev=null title=null content=null
       * [F] bottomSheetTheme bg=null drag=null modal=null
       * [F] listTileTheme    icon=null pad=null title=null sub=null
       * ```
       * theme_bridge **根本没设过** dialog / bottomSheet / listTile 的这些字段
       * （框和面用的是别处的角色，这三个 theme 只被设了 shape）。
       * ⇒ `null == null` 恒真，注入 INJ-B（还原成整体替换）时**这条不变红**，
       *   而 ⑥-c（手工非空）变红 —— 空转当场露馅。
       *
       * ⇒ 修法：基线 = **theme_bridge 的真实产物**（保留全部颜色/角色）
       *   ⊕ **手工叠加的非空非 shape 字段**。这样两件事同时成立：
       * ```text
       * ① 基线仍来自真实产品路径（不是凭空造的 ThemeData）
       * ② 每个断言字段都非 null ⇒ 整体替换一旦发生，必然变红
       * ```
       */
      for (final id in _ids) {
        final pack = _pack(id);
        final base = raw(id);
        final before = base.copyWith(
          dialogTheme: base.dialogTheme.copyWith(
            backgroundColor: const Color(0xFF123456),
            elevation: 7,
            titleTextStyle: const TextStyle(fontSize: 33),
            contentTextStyle: const TextStyle(fontSize: 17),
          ),
          bottomSheetTheme: base.bottomSheetTheme.copyWith(
            backgroundColor: const Color(0xFF654321),
            dragHandleColor: const Color(0xFFAABBCC),
            modalBackgroundColor: const Color(0xFF222222),
          ),
          listTileTheme: base.listTileTheme.copyWith(
            iconColor: const Color(0xFF00FF00),
            contentPadding: const EdgeInsets.all(9),
            titleTextStyle: const TextStyle(fontSize: 21),
            subtitleTextStyle: const TextStyle(fontSize: 15),
          ),
        );
        final after = ThemeLanguage.apply(before, pack);

        // ★ 先自证基线真的非空 —— 否则下面全是空转（这正是我踩过的坑）
        expect(before.dialogTheme.backgroundColor, isNotNull,
            reason: '★ 基线没铺上非空字段 ⇒ 本用例会变成空转');

        expect(after.dialogTheme.backgroundColor,
            before.dialogTheme.backgroundColor,
            reason: '★ ${pack.name} apply 后 dialogTheme.backgroundColor 丢了'
                ' ⇒ 三处用了整体替换 XxxThemeData(shape:)（CR/PR#30-②）');
        expect(after.dialogTheme.elevation, before.dialogTheme.elevation,
            reason: '★ ${pack.name} dialogTheme.elevation 丢了');
        expect(after.dialogTheme.titleTextStyle,
            before.dialogTheme.titleTextStyle,
            reason: '★ ${pack.name} dialogTheme.titleTextStyle 丢了');
        expect(after.dialogTheme.contentTextStyle,
            before.dialogTheme.contentTextStyle,
            reason: '★ ${pack.name} dialogTheme.contentTextStyle 丢了');

        expect(after.bottomSheetTheme.backgroundColor,
            before.bottomSheetTheme.backgroundColor,
            reason: '★ ${pack.name} bottomSheetTheme.backgroundColor 丢了');
        expect(after.bottomSheetTheme.dragHandleColor,
            before.bottomSheetTheme.dragHandleColor,
            reason: '★ ${pack.name} bottomSheetTheme.dragHandleColor 丢了');
        expect(after.bottomSheetTheme.modalBackgroundColor,
            before.bottomSheetTheme.modalBackgroundColor,
            reason: '★ ${pack.name} bottomSheetTheme.modalBackgroundColor 丢了');

        expect(after.listTileTheme.iconColor, before.listTileTheme.iconColor,
            reason: '★ ${pack.name} listTileTheme.iconColor 丢了');
        expect(after.listTileTheme.contentPadding,
            before.listTileTheme.contentPadding,
            reason: '★ ${pack.name} listTileTheme.contentPadding 丢了');
        expect(after.listTileTheme.titleTextStyle,
            before.listTileTheme.titleTextStyle,
            reason: '★ ${pack.name} listTileTheme.titleTextStyle 丢了');
        expect(after.listTileTheme.subtitleTextStyle,
            before.listTileTheme.subtitleTextStyle,
            reason: '★ ${pack.name} listTileTheme.subtitleTextStyle 丢了');
      }
    });

    test('⑥-c 反例对照：手工填了非 shape 字段的 ThemeData 也必须逐字段保留', () {
      /*
       * ⑥-b 用的是 theme_bridge 的产物 —— 万一它某个字段本来就是 null，
       * 「null == null」会让断言变成空转（假绿）。
       * ⇒ 这里手工造一份每个字段都非 null 的 ThemeData，确保断言真的在比。
       */
      final crafted = ThemeData(
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xFF123456),
          elevation: 7,
          titleTextStyle: TextStyle(fontSize: 33),
          contentTextStyle: TextStyle(fontSize: 17),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xFF654321),
          dragHandleColor: Color(0xFFAABBCC),
          modalBackgroundColor: Color(0xFF222222),
        ),
        listTileTheme: const ListTileThemeData(
          iconColor: Color(0xFF00FF00),
          contentPadding: EdgeInsets.all(9),
          titleTextStyle: TextStyle(fontSize: 21),
        ),
      );
      final out = ThemeLanguage.apply(crafted, _pack('builtin.glass'));

      expect(out.dialogTheme.backgroundColor, const Color(0xFF123456));
      expect(out.dialogTheme.elevation, 7);
      expect(out.dialogTheme.titleTextStyle?.fontSize, 33);
      expect(out.dialogTheme.contentTextStyle?.fontSize, 17);
      expect(out.bottomSheetTheme.backgroundColor, const Color(0xFF654321));
      expect(out.bottomSheetTheme.dragHandleColor, const Color(0xFFAABBCC));
      expect(out.bottomSheetTheme.modalBackgroundColor, const Color(0xFF222222));
      expect(out.listTileTheme.iconColor, const Color(0xFF00FF00));
      expect(out.listTileTheme.contentPadding, const EdgeInsets.all(9));
      expect(out.listTileTheme.titleTextStyle?.fontSize, 21);
    });
  });
}