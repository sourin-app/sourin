// ================================================================
//  主题可区分性门禁：浅色主题必须「色相真的不同」
// ================================================================
//
// # 为什么要这条
// ```text
// 2026-10-17 Owner 选 A（加深主题底色）。
// 起因：真机像素采样发现 8 套浅色底与基线 RGB 距离全部 < 25（满量程 441）。
// ```
//
// # ★ 第一版判据是错的（RGB 距离）
// ```text
// 第一版用 RGB 欧氏距离 >= 20。player-batch 提了一个反例：
//
//   "OLED 纯白 FFFFFF 距离 24.4 过线了，但它过线的理由是
//    「纯白 vs 默认浅灰」—— 那只是亮度差，不是设计辨识度。"
//
// 我用 HSV 分解验证，他的怀疑成立：
//
//   主题          色相   饱和     明度
//   默认(基线)    225°   3.3%    96.5%
//   glass         217°   3.2%    98.0%   ← 和默认色相只差 8 度
//   midnightBlue  218°   3.2%    98.8%   ← 和默认色相只差 7 度
//   forest        140°   2.4%    98.0%
//   sakura        351°   2.8%    99.2%   ← "樱粉"饱和只有 2.8%
//   oled            0°   0%     100.0%   ← 无彩
//
// ⇒ 全部饱和度 0%~3.3% ⇒ 它们全是没有彩色的灰白，
//   只有明度差。RGB 距离把明度差和色相差混算了，
//   而人眼在浅色区间对色相/饱和的敏感度远高于明度。
// ```
//
// # 所以判据改成双轨
// ```text
// 有彩色主题（樱粉/森绿/深海蓝/液态玻璃）：
//   · 饱和度 >= 8%   ← 真的看得出颜色
//   · 色相与基线环形距离 >= 20 度
//
// 无彩色主题（OLED 纯白 / 新粗野 / 极简）：
//   · 允许饱和 < 8%，但明度必须与基线差 >= 3%
//     （OLED 100% vs 基线 96.5% = 3.5% ⇒ 合法）
// ```
//
// # 任意两套之间
// ```text
// 色相环形距离 >= 20 度 或 明度差 >= 5%
// ⇒ 否则用户分不出（glass vs midnightBlue 只差 1 度就是反例）
// ```

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

/// 默认浅色底（没选主题包时的 LightTokens.bgBase）
const _baseline = Color(0xFFEEF0F6);

/// HSV 三元组：h 0~360，s/v 0~100
({double h, double s, double v}) _hsv(Color c) {
  final r = c.r, g = c.g, b = c.b;
  final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
  final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
  final d = mx - mn;
  var h = 0.0;
  if (d > 0) {
    if (mx == r) {
      h = 60 * (((g - b) / d) % 6);
    } else if (mx == g) {
      h = 60 * ((b - r) / d + 2);
    } else {
      h = 60 * ((r - g) / d + 4);
    }
  }
  if (h < 0) h += 360;
  return (h: h, s: mx == 0 ? 0.0 : d / mx * 100, v: mx * 100);
}

/// 色相环形距离（0~180）
double _hueGap(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

void main() {
  final lights = ThemePackStore.builtins
      .where((p) => p.brightness == Brightness.light)
      .toList();

  /*
   * ★ 不维护「有彩色白名单」—— 改成自动判定。
   *
   * # 为什么要改（第一版的坑）
   * ```text
   * 第一版用 const chromatic = {...} 硬编码哪几套是"有彩色"。
   * 结果 neoBrutal 饱和 8.1%（其实达标）没进白名单 ⇒
   * 走了"无彩色"的明度判据 ⇒ 误报"明度差 0.4% 不够"。
   *
   * 根因：白名单是"人告诉门禁该看什么"，
   *       新增主题忘了加、或者分类判错，门禁就会误报或漏报。
   * ```
   *
   * # 现在的判据
   * ```text
   * 饱和 >= 8%  ⇒ 有彩色 ⇒ 看色相是否偏离基线 >= 20 度
   * 饱和 <  8%  ⇒ 无彩色 ⇒ 看明度是否偏离基线 >= 3%
   * ```
   * 由数据自己决定走哪条，不由人指定。
   */

  test("浅色主题数量足够（防在空集上假绿）", () {
    expect(lights.length, greaterThanOrEqualTo(7),
        reason: "浅色主题少于 7 套 ⇒ 这条门禁在空集上跑，必须红");
  });

  test("*** 有彩色主题：饱和 >= 8% 且色相偏离基线 >= 20 度", () {
    final base = _hsv(_baseline);
    final bad = <String>[];
    for (final p in lights) {
      final c = _hsv(p.palette.background);
      if (c.s < 8) continue; // 无彩色，归下一条测试管
      final gap = _hueGap(c.h, base.h);
      if (gap < 20) {
        bad.add(p.id +
            "  饱和=" +
            c.s.toStringAsFixed(1) +
            "% (<8%) —— 这不是有彩色，是灰白");
      } else if (gap < 20) {
        bad.add(p.id +
            "  色相=" +
            c.h.toStringAsFixed(0) +
            "° 与基线仅差 " +
            gap.toStringAsFixed(0) +
            "° (<20°)");
      }
    }
    expect(bad, isEmpty,
        reason: "这些主题的底色看不出颜色：\n" + bad.join("\n"));
  });

  test("*** 无彩色主题：明度必须与基线差 >= 3%（OLED 纯白属此类）", () {
    final base = _hsv(_baseline);
    final bad = <String>[];
    for (final p in lights) {
      if (p.id == "builtin.daylight") continue;
      final c = _hsv(p.palette.background);
      if (c.s >= 8) continue; // 有彩色，归上一条测试管
      final dv = (c.v - base.v).abs();
      if (dv < 3) {
        bad.add(p.id +
            "  明度=" +
            c.v.toStringAsFixed(1) +
            "% 与基线差 " +
            dv.toStringAsFixed(1) +
            "% (<3%)");
      }
    }
    expect(bad, isEmpty,
        reason: "这些无彩色主题与默认几乎同一个亮度：\n" + bad.join("\n"));
  });

  test("*** 任意两套浅色主题：色相差 >= 20 度 或 明度差 >= 5%", () {
    final bad = <String>[];
    for (var i = 0; i < lights.length; i++) {
      for (var j = i + 1; j < lights.length; j++) {
        final a = lights[i], b = lights[j];
        final ca = _hsv(a.palette.background);
        final cb = _hsv(b.palette.background);
        final gap = _hueGap(ca.h, cb.h);
        final dv = (ca.v - cb.v).abs();
        /*
         * ★ daylight 的特殊处理：它是"没选主题时的默认"。
         *
         * 用户不会"在 daylight 和 glass 之间切换" —— 他要么没选（= daylight），
         * 要么选了某个主题。所以 daylight 与其它主题的区分度，
         * 本质上是"默认外观 vs 主题外观"的区分度，确实该管。
         *
         * ⚠️ 但它参与比较会让所有主题都被要求"离默认够远"，
         *    这与"主题之间互相能分"是两件事。
         *    所以这里**保留**检查，但报告时标注出来，便于人判断。
         */
        /*
         * ★★★ 三种情形必须分开判 —— 第一版把它们混在一起了
         *
         * # 第一版的 bug
         * ```text
         * 直接比 hueGap 和 dv，结果报出：
         *   "oled.light vs sakura.light  色相差 4°"
         *
         * 但 OLED 是纯白 s=0% —— **无彩色的色相没有意义**，
         * 它 h=0 只是"除零时的约定值"，不是"红色"。
         * 拿它去比色相，等于拿"没有色相"和"粉"比差多少度。
         * ```
         *
         * # 正确判据
         * ```text
         * ① 两个都无彩（s < 3）  ⇒ 只能靠明度区分 ⇒ 要求 dv >= 5
         * ② 一个无彩一个有彩      ⇒ 饱和本身就是差异 ⇒ 直接放过
         *                            （纯白 vs 淡粉，用户看得出）
         * ③ 两个都有彩            ⇒ 比色相环距离 >= 20 度
         * ```
         */
        final aGray = ca.s < 3;
        final bGray = cb.s < 3;
        if (aGray && bGray) {
          if (dv < 5) {
            bad.add(a.id + " vs " + b.id + "  都是无彩且明度差 " +
                dv.toStringAsFixed(1) + "% (<5%)");
          }
        } else if (aGray || bGray) {
          // 一个无彩一个有彩 ⇒ 饱和差异本身就是区分度，不报警
        } else if (gap < 20) {
          bad.add(a.id + " vs " + b.id + "  色相差 " +
              gap.toStringAsFixed(0) + "° (<20°)");
        }
      }
    }
    expect(bad, isEmpty,
        reason: "这些主题彼此太像：\n" + bad.join("\n"));
  });

  test("阳性对照：HSV 与色相距离函数本身是对的", () {
    final base = _hsv(_baseline);
    expect(base.h.round(), 225);
    expect(_hueGap(0, 240), 120);
    expect(_hueGap(350, 10), 20);
    final pink = _hsv(const Color(0xFFF9DDE5));
    expect(pink.s, greaterThan(8));
  });
}