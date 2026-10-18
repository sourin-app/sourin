// ═══════════════════════════════════════════════════════════════════════
//  轨道 E · M1 —— 语义色层（AppSemanticColors）门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
//
// Owner 已定路线：**彻底不用 Material 组件，全部自建 / 玻璃**。
// 那么语义色层必须先从 Material 里断出来 —— 否则换组件时颜色会
// 跟着 `ColorScheme` 一起消失，那时候再回头补就是「白干两遍」。
//
// # 四条判据（每条都能红）
// ```text
// ① 深/浅两套下 10 个角色**全部非空**（构造函数 required 已保证，
//    但派生公式可能算出与背景同值的"隐形"色 ⇒ 要单独查可见性）
// ② 两套的**主色不同**（否则"切明暗"等于没切）
// ③ app_colors.dart **不 import material_ui**（判在剥注释后的文本上）
// ④ 派生与现网 theme_bridge 的字面量**对齐**（不许在这一层偷偷换色）
// ```
//
// ⚠️ ③ 为什么必须剥注释再判：本仓注释里大量引用"不许 import material_ui"
//    这句话本身（本文件头就是），不剥就会**假红** —— 这条正是上一轮
//    轨道 C 踩过的坑（`_healthToken?.cancel()` 出现两次 ⇒ 删了仍绿）。
//    反过来，正向断言（"必须存在 X"）不剥注释则会**假绿**。
//    ⇒ 凡是字符串/类名断言，一律在剥注释后的文本上判。

import 'dart:io';
import 'dart:ui' show Brightness, Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/design/theme/app_theme_data.dart';
import 'package:sourin_spike/ui/app_typeface.dart';
import 'package:sourin_spike/ui/theme/app_colors.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

// ══════════════════════════════════════════════════════════════════════
//  剥注释（块注释 + 行注释；保留字符串字面量）
// ══════════════════════════════════════════════════════════════════════
//
// ★ 与 provider_import_test.dart 的 `_code` **不同**：那个是纯正则替换，
//   会把字符串里的 `//`（如 'http://…'）也吃掉。本文件的判据含
//   `import 'package:material_ui/material_ui.dart';` 这种**带引号**的串，
//   所以必须按 Dart 词法走一遍，引号内的内容原样保留。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }

    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i = (i + 2).clamp(0, src.length);
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 对比度（WCAG）
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

String hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

/// 从主题包算一套语义色（与 AppThemeData 内部同一路径）
AppSemanticColors colorsOfPack(ThemePack p) => AppThemeData(
      palette: p.palette,
      typeface: AppTypeface.forPlatform(p.brightness),
      pack: p,
    ).colors;

/// 取一个**确定**的深色包 / 浅色包（不依赖用户当前选择）
ThemePack darkPack() =>
    ThemePackStore.builtins.firstWhere((p) => p.brightness == Brightness.dark);
ThemePack lightPack() =>
    ThemePackStore.builtins.firstWhere((p) => p.brightness == Brightness.light);

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 两套明暗：角色齐全 + 真的看得见
  // ═══════════════════════════════════════════════════════════════════
  group('① 十个语义角色在深/浅两套下都成立', () {
    /// 十个角色名 → 取值
    Map<String, Color> roles(AppSemanticColors c) => {
          'primary': c.primary,
          'onPrimary': c.onPrimary,
          'surface': c.surface,
          'onSurface': c.onSurface,
          'onSurfaceVariant': c.onSurfaceVariant,
          'outline': c.outline,
          'outlineVariant': c.outlineVariant,
          'error': c.error,
          'surfaceContainer': c.surfaceContainer,
          'surfaceContainerHigh': c.surfaceContainerHigh,
        };

    test('★ 深色：十角色齐全，且亮度方向正确', () {
      final c = colorsOfPack(darkPack());
      final r = roles(c);

      expect(r.length, 10, reason: '角色数量必须是 10（少一个就是漏角色）');

      // 构造是 required，理论上不可能 null；这里断的是**语义**：
      // 深色主题必须真的是深色（surface 比 onSurface 暗），
      // 否则"深色"这个名字是假的。
      expect(c.brightness, Brightness.dark);
      expect(
        c.surface.computeLuminance() < c.onSurface.computeLuminance(),
        isTrue,
        reason: '★★ 深色主题里 surface=${hex(c.surface)} 必须比 '
            'onSurface=${hex(c.onSurface)} 暗 —— 反了就是"浅色冒充深色"',
      );
    });

    test('★ 浅色：十角色齐全，且亮度方向正确', () {
      final c = colorsOfPack(lightPack());
      final r = roles(c);

      expect(r.length, 10);
      expect(c.brightness, Brightness.light);
      expect(
        c.surface.computeLuminance() > c.onSurface.computeLuminance(),
        isTrue,
        reason: '★★ 浅色主题里 surface=${hex(c.surface)} 必须比 '
            'onSurface=${hex(c.onSurface)} 亮 —— 反了就是"深色冒充浅色"',
      );
    });

    test('★★ 容器两档不能塌进背景（否则"抬升"是假的）', () {
      // 这条是 task-31 那个坑的通用化：浅色下曾出现
      // surfaceContainer = #F7F8FB 对页面底 #EEF0F6 只有 1.02:1 ⇒ 看不见。
      for (final entry in {
        'dark': colorsOfPack(darkPack()),
        'light': colorsOfPack(lightPack()),
      }.entries) {
        final c = entry.value;

        // ① surfaceContainer 必须能从 surface 里分出来
        expect(
          c.surfaceContainer == c.surface,
          isFalse,
          reason: '★★ [${entry.key}] surfaceContainer 与 surface 同值 '
              '（${hex(c.surface)}）⇒ 这一档完全看不见，"抬升"是假的',
        );

        /*
         * ② surfaceContainerHigh 也**必须**与 surface 分得开
         *
         * ⚠️ 2026-10-18（故障注入抓到的**假绿**，已修）：
         *
         * 第一版这里写的是
         *     expect(highsDiffer || containersDiffer, isTrue)
         * 注入「把 surfaceContainerHigh 写死成 surface」之后它**仍然是绿的** ——
         * 因为 `containersDiffer` 单独为真就把整个 `||` 满足了。
         * 于是「High 档塌进背景」这个缺陷被完全遮住。
         *
         * ⇒ 两档各自独立断言，不许用 `||` 互相兜底。
         *   教训与上一轮同源：**判据不许有"任一满足即可"的兜底**，
         *   那等于给某一档开后门。
         */
        expect(
          c.surfaceContainerHigh == c.surface,
          isFalse,
          reason: '★★ [${entry.key}] surfaceContainerHigh 与 surface 同值 '
              '（${hex(c.surface)}）⇒ 最高一档容器完全看不见。'
              '（⚠️ 不许用 `||` 跟另一档互相兜底 —— 那会把本缺陷遮住）',
        );

        // ③ 两档**之间**允许同值（浅色体系里抬升就是"更白"，card 已是白）
        //    这里只记录事实，不断言它们必须不同。

      }
    });

    test('★★ onPrimary 在白与黑两种极端下都不能与 primary 撞成同色', () {
      for (final entry in {
        'dark': colorsOfPack(darkPack()),
        'light': colorsOfPack(lightPack()),
      }.entries) {
        final c = entry.value;
        expect(
          c.onPrimary == c.primary,
          isFalse,
          reason: '★★ [${entry.key}] onPrimary 与 primary 同值（${hex(c.primary)}）'
              '⇒ 按钮上的字与底完全融为一体',
        );
        // 至少要 3:1（WCAG 对图形元素 / 大字的下限）
        expect(
          contrast(c.primary, c.onPrimary),
          greaterThanOrEqualTo(3.0),
          reason: '★★ [${entry.key}] primary=${hex(c.primary)} 与 '
              'onPrimary=${hex(c.onPrimary)} 对比度 '
              '${contrast(c.primary, c.onPrimary).toStringAsFixed(2)}:1 < 3:1',
        );
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 深/浅两套必须真的不同
  // ═══════════════════════════════════════════════════════════════════
  group('② 深色与浅色是两套，不是同一套换名', () {
    test('★★ 主色不同（Owner 要的是"切明暗品牌色跟着明暗走"）', () {
      final d = colorsOfPack(darkPack());
      final l = colorsOfPack(lightPack());

      expect(d.primary != l.primary, isTrue,
          reason: '★★ 深色 primary=${hex(d.primary)} 与浅色 '
              'primary=${hex(l.primary)} **相同** ⇒ 明暗切换在主色上看不出变化');

      expect(d.surface != l.surface, isTrue,
          reason: '★★ 两套的 surface 相同（${hex(d.surface)}）⇒ 整页底色没变');
      expect(d.onSurface != l.onSurface, isTrue,
          reason: '★★ 两套的 onSurface 相同（${hex(d.onSurface)}）⇒ 正文色没变');
    });

    test('★ brightness 也必须是两档', () {
      expect(colorsOfPack(darkPack()).brightness, Brightness.dark);
      expect(colorsOfPack(lightPack()).brightness, Brightness.light);
      expect(colorsOfPack(darkPack()).isDark, isTrue);
      expect(colorsOfPack(lightPack()).isDark, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 不依赖 Material（本层存在的**全部理由**）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 语义色层与 Material 断开', () {
    late String code;

    setUpAll(() {
      // ★ 必须剥注释：本文件与 app_colors.dart 的注释里都大量写着
      //   "不许 import material_ui" 这句话本身。
      code = stripComments(
        File('lib/ui/theme/app_colors.dart').readAsStringSync(),
      );
    });

    test('★★★ app_colors.dart 不许 import material_ui', () {
      expect(
        code.contains('package:material_ui/material_ui.dart'),
        isFalse,
        reason: '★★★ 语义色层是整个"摘掉 Material"工程的**地基** —— '
            '它一旦 import material_ui，上层再怎么改都没断干净',
      );
      // 连 flutter/widgets 也不许（它会把 Widget/Theme 一并拖进来）
      expect(
        code.contains('package:flutter/widgets.dart'),
        isFalse,
        reason: '★★ 本层只需要 dart:ui 的 Color 与 foundation 的 @immutable；'
            'widgets 会把整棵 Widget 树的概念拖进来',
      );
    });

    test('★★ 但它必须真的用到 dart:ui 的 Color（否则是空文件假绿）', () {
      // 反向对照：如果哪天有人把这个文件清空，上面那条 isFalse 会**假绿**
      expect(code.contains('import \'dart:ui\''), isTrue,
          reason: '★ 必须 import dart:ui');
      expect(code.contains('class AppSemanticColors'), isTrue,
          reason: '★ 类本体必须在');
      expect(code.contains('factory AppSemanticColors.derive'), isTrue,
          reason: '★ 派生工厂必须在（它是"从 theme_pack 取值"的唯一入口）');
      // 十个角色名都要出现（少一个就是漏角色，而 required 构造会屏蔽它）
      for (final role in const [
        'primary', 'onPrimary', 'surface', 'onSurface', 'onSurfaceVariant',
        'outline', 'outlineVariant', 'error', 'surfaceContainer',
        'surfaceContainerHigh',
      ]) {
        expect(code.contains('this.$role'), isTrue,
            reason: '★ 构造函数里必须收 $role');
      }
    });

    test('★ AppThemeScope 提供 .colors（新的取色入口）', () {
      final themeData =
          stripComments(File('lib/design/theme/app_theme_data.dart')
              .readAsStringSync());
      final scope = stripComments(
          File('lib/design/theme/app_theme.dart').readAsStringSync());

      /*
       * ⚠️ 判据只要求「有一个叫 colors 的成员暴露出去」，**不**锁死它是
       *    getter 还是 late final 字段 —— 那是实现细节，锁死会让将来的
       *    性能优化（比如改成缓存 getter）莫名其妙变红。
       *    实测当前实现是 `late final AppSemanticColors colors = …`。
       */
      expect(
        RegExp(r'\bAppSemanticColors\s+colors\b').hasMatch(themeData),
        isTrue,
        reason: '★ AppThemeData 必须暴露 colors 供 AppTheme.of(context).colors 取',
      );
      expect(scope.contains('static AppThemeData of(BuildContext context)'),
          isTrue,
          reason: '★ AppTheme.of 必须在（取色入口）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 派生与现网对齐（不许在这一层偷偷换色）
  // ═══════════════════════════════════════════════════════════════════
  group('④ 派生公式与现网 theme_bridge 的字面量对齐', () {
    test('★★ 默认深色包：outline 与现网 #222222 差 <= 2/255', () {
      /*
       * 现网 theme_bridge.dart:577 写的是 `const borderSolid = Color(0xFF222222)`，
       * 注释说明它是「按背景 #0A0A0A 把 border(白10%) 合成成实色」。
       * 我们这里用**真的公式**（alphaBlend(border, background)）算，
       * 实测得 #232323 —— 差 1/255，肉眼无差。
       *
       * ⚠️ 为什么容差是 2 而不是 0：现网那个是**手算**的字面量，
       *    公式必然给出相近但不必完全相同的值。若将来有人把公式改坏
       *    （比如把 alphaBlend 写成 lerp），差值会远超 2，这条就会红。
       */
      final c = colorsOfPack(ThemePackStore.builtins.first);
      const nowOutline = Color(0xFF222222);
      final dr = (c.outline.r * 255).round() - (nowOutline.r * 255).round();
      expect(dr.abs(), lessThanOrEqualTo(2),
          reason: '★ 派生 outline=${hex(c.outline)} 与现网 #222222 差 $dr/255 '
              '（容差 2）—— 超过说明派生公式被改坏了');
    });

    test('★★ 默认深色包：surfaceContainer 与现网 #111111 差 <= 2/255', () {
      // 现网 theme_bridge.dart:586 `surfaceContainer: Color(0xFF111111)`
      final c = colorsOfPack(ThemePackStore.builtins.first);
      const nowContainer = Color(0xFF111111);
      final dr = (c.surfaceContainer.r * 255).round() - (nowContainer.r * 255).round();
      expect(dr.abs(), lessThanOrEqualTo(2),
          reason: '★ 派生 surfaceContainer=${hex(c.surfaceContainer)} '
              '与现网 #111111 差 $dr/255（容差 2）');
    });

    test('★★★ 浅色下 surfaceContainer **必须**是 card，不许是 lerp 出来的灰', () {
      /*
       * 这是本文件最重要的一条 —— 它守的是 task-31 修过的**真实回归**。
       *
       * # 实测（.probe/probe_e_colors_packs_test.dart）
       * ```text
       * dayint 包 bg=#EEF0F6 card=#FFFFFF
       *   lerp(bg,card,0.5) = #F7F8FB   对 bg 只有 1.02:1  ← task-31 判死的旧值
       *   card              = #FFFFFF   对 bg 1.16:1        ← 现行正确值
       * ```
       * # 为什么不能两档共用一个公式
       * ```text
       * 深色的"抬升" = 在暗底上提亮（lerp 方向正确）
       * 浅色的"抬升" = 更白（bg 是浅灰、card 是纯白，lerp 只会得到中间灰）
       * ⇒ 方向相反，共用必然有一边错。
       * ```
       */
      final c = colorsOfPack(lightPack());
      final card = lightPack().palette.card;

      expect(c.surfaceContainer, card,
          reason: '★★★ 浅色下 surfaceContainer 必须 == card（${hex(card)}），'
              '实际是 ${hex(c.surfaceContainer)}。'
              '若等于 lerp 出来的 ${hex(Color.lerp(c.surface, card, 0.5)!)}，'
              '就是 task-31 那个「1.02:1 看不见」的回归');

      // 并且它必须真的与背景分得开
      expect(
        contrast(c.surfaceContainer, c.surface),
        greaterThan(1.05),
        reason: '★★ 浅色 surfaceContainer 对 surface 对比 '
            '${contrast(c.surfaceContainer, c.surface).toStringAsFixed(3)}:1 '
            '— 必须 > 1.05 才看得见（1.02 就是 task-31 判死的值）',
      );
    });

    test('★★ 16 个内置主题包全部能派生出合法的十角色', () {
      /*
       * 只测两套默认包会漏掉「某套主题的 border 是半透明 / card 与 bg 同值」
       * 这类边角。内置包共 16 个，全跑一遍。
       */
      expect(ThemePackStore.builtins.length, greaterThanOrEqualTo(16),
          reason: '★ 内置包数量变了（当前应 >= 16）—— 若确实增删了，改这个数');

      for (final p in ThemePackStore.builtins) {
        final c = colorsOfPack(p);
        final where = '（包 ${p.id}）';

        expect(c.brightness, p.brightness, reason: '明暗必须跟着包走 $where');
        expect(c.borderIsOpaque, isTrue,
            reason: '★★ outline 必须是不透明实色 $where —— '
                '半透明描边会随底下是什么而变（同一个包在卡片上和页面底上画出两种线）');

        // 容器两档都不许与 surface 撞（撞了就看不见）
        expect(c.surfaceContainer != c.surface, isTrue,
            reason: '★★ $where surfaceContainer 与 surface 同值 ${hex(c.surface)}');
        expect(c.surfaceContainerHigh != c.surface, isTrue,
            reason: '★★ $where surfaceContainerHigh 与 surface 同值');

        // 正文对背景必须可读（WCAG AA 4.5）—— 这是主题包本身的契约，
        // 由 theme_invariants_test 守着；这里顺带确认派生**没有破坏**它。
        expect(
          contrast(c.onSurface, c.surface),
          greaterThanOrEqualTo(4.5),
          reason: '★★ $where 正文对背景 ${contrast(c.onSurface, c.surface).toStringAsFixed(2)}:1 < 4.5',
        );
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 值语义（避免整棵树无谓重绘）
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ AppSemanticColors 必须有值语义', () {
    test('★★ 同一个包的两次派生必须 == 且 hashCode 相同', () {
      /*
       * AppThemeData.colors 是 late final，**同一个实例**只算一次；
       * 但两个值相等的 AppThemeData（不同实例）会各算一次。
       * 如果 AppSemanticColors 用引用相等，`updateShouldNotify` 里的
       * `data != oldWidget.data` 会因为"每次都新建"而永远为 true
       * ⇒ 整棵树无谓重绘。
       */
      final a = colorsOfPack(darkPack());
      final b = colorsOfPack(darkPack());
      expect(identical(a, b), isFalse, reason: '前提：两个不同实例');
      expect(a, b, reason: '★★ 值相等的两个派生必须 ==');
      expect(a.hashCode, b.hashCode, reason: '★ hashCode 必须一致');
    });

    test('★ 不同包的派生必须 !=', () {
      final d = colorsOfPack(darkPack());
      final l = colorsOfPack(lightPack());
      expect(d == l, isFalse, reason: '深/浅两套不可能相等');
    });
  });
}

/// 测试辅助：判断 outline 是否不透明
extension on AppSemanticColors {
  bool get borderIsOpaque => outline.a >= 0.999 && outlineVariant.a >= 0.999;
}
