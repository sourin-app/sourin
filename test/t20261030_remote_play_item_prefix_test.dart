// ═══════════════════════════════════════════════════════════════════════
//  现场反馈批次 2026-10-30：P1 —— 遥控 play_item 聚合条目「找不到子站」
//  （手机端 id 带 provider 路由前缀 ⇒ 双前缀 ⇒ Rust 聚合 route 失败）
// ═══════════════════════════════════════════════════════════════════════
//
// # 真机读数（driver-ops 驱动器，.probe/play-driver/results/drive-20261029-234208.json）
// ```text
// play_attempts: [{provider:'tvbox_agg', id:'tvbox_agg:csp-4kzhinan-47098b5a::19106', ok:false}]
// ⇒ Rust：MediaId::new(provider, id) 把带前缀 id 原样当 native
//   ⇒ 聚合 route() 按 '::' 切出 child='tvbox_agg:csp-...' ⇒ 找不到子站
// ```
//
// # 修法
// ```text
// shell._openItemFromRemote 入口剥一次前缀（stripProviderRoutePrefix），
// getDetail / getEpisodes / PlayRequestData 三处全用剥过的 native ——
// 与 App 自己的搜索打开路径（search_page.dart `_open`）同一形状。
// ```
//
// # 故障注入（实测见笔记）
// ```text
// 注入：_openItemFromRemote 退回用原始 id（不剥）⇒ 组②接线断言红。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/shell.dart';

/// 剥注释（t61 同款状态机；`contains` 必须先剥注释 —— 本仓铁律⑤）
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (n.isNotEmpty) {
          out.write(n);
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
    if (c == '/' && n == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && n == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  group('① stripProviderRoutePrefix（纯函数，与 MediaId::parse split-once 同源）', () {
    test('聚合条目：剥掉 provider 前缀一次', () {
      expect(
        stripProviderRoutePrefix('tvbox_agg', 'tvbox_agg:csp-4kzhinan-47098b5a::19106'),
        'csp-4kzhinan-47098b5a::19106',
      );
    });

    test('只剥一次 —— native 里合法的 "::" 与子站原始 id 不能再动', () {
      expect(
        stripProviderRoutePrefix('tvbox_agg', 'tvbox_agg:csp-appget-97d9adc9::https://x.invalid/1.m3u8'),
        'csp-appget-97d9adc9::https://x.invalid/1.m3u8',
        reason: '子站原始 id 是 URL 的形态也不许坏',
      );
    });

    test('无前缀 / 空白 provider / 空串：原样返回（幂等、不空手返回空）', () {
      expect(stripProviderRoutePrefix('tvbox_agg', 'csp-x::1'), 'csp-x::1',
          reason: '已剥过的 id 再进来必须原样（幂等，防调用方重复剥）');
      expect(stripProviderRoutePrefix('', 'tvbox_agg:x'), 'tvbox_agg:x');
      expect(stripProviderRoutePrefix('tvbox_agg', ''), '');
    });

    test('非聚合源同样受益（id 恰好带 provider 前缀的复合形态）', () {
      expect(stripProviderRoutePrefix('srca', 'srca:57300'), '57300');
    });
  });

  group('② 生产接线（静态断言 —— play_item 全链路含 FFI，widget 测试不可达）', () {
    late String src;
    setUpAll(() {
      src = stripComments(File('lib/shell.dart').readAsStringSync());
    });

    test('★★ _openItemFromRemote 入口真调 stripProviderRoutePrefix', () {
      expect(src.contains('stripProviderRoutePrefix(provider, id)'), isTrue,
          reason: '剥前缀必须真的在 play_item 落地处被调用 —— '
              '只存在纯函数而没人调 = 用户看不到（本仓铁律：声明了不生效等于骗人）');
    });

    test('★★ 函数窗口内：getDetail / getEpisodes / PlayRequestData 都改用 nativeId', () {
      // ★ 窗口 = _openItemFromRemote 函数体（到类里下一个 @override 成员为止
      //   —— shell.dart 里还有别的合法 `getDetail(provider, id)` 调用点 ——
      //   续播去重那条的 id 本就是已切开的 native，不能误伤 ⇒ 钉窗口，不全文扫）。
      final start = src.indexOf('Future<void> _openItemFromRemote(');
      final end = src.indexOf('\n  }\n\n  @override', start);
      expect(start, greaterThan(0), reason: '窗口起点要能定位（函数被改名时本条红）');
      expect(end, greaterThan(start), reason: '窗口终点要能定位');
      final win = src.substring(start, end);

      expect(win.contains('stripProviderRoutePrefix(provider, id)'), isTrue,
          reason: '入口先剥（真机读数：不剥 ⇒ Rust「找不到子站」）');
      expect(win.contains('SourinApi.getDetail(provider, nativeId)'), isTrue,
          reason: '详情补齐的第一跳就得用 native —— 否则 FFI 侧照样找不到子站');
      expect(win.contains('SourinApi.getEpisodes(provider, nativeId, srcCode)'), isTrue,
          reason: '剧集这一跳同上');
      expect(win.contains('id: nativeId'), isTrue,
          reason: '会话 id（后续 resolveStream 走它）必须是 native，'
              '否则换源/续播键全带着坏前缀');
      expect(win.contains('SourinApi.getDetail(provider, id)'), isFalse,
          reason: '注入证据：三处退回原始 id 时本条红（改前形态不许回来）');
    });
  });
}
