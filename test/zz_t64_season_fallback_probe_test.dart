@Tags(['needs-network'])
/*
 * ⚠️ 2026-10-18（round-65）：补 `needs-network` 标签。
 *
 * 本文件是**真网络探针** —— 真发 HTTP 打外部站点，断言的是
 * 「这条链路现在通不通」，不是产品逻辑。
 *
 * CI runner 出网受限 ⇒ 请求打不通 ⇒ 断言报
 * ```text
 * Expected: not null
 *   Actual: <null>
 * ```
 * 与被测代码对错无关。实测 macOS job：3795 通过 / 3 失败，
 * 3 条全是这一类。
 *
 * 手动跑：
 * ```powershell
 * flutter test <本文件> --run-skipped --tags needs-network --concurrency=1
 * ```
 */
// 2026-10-17（task-32 ①）★ 直接验证 Lead 新加的 **season 兜底分支**
//
// # 为什么必须伪造 search 失败
// ```text
// 本机实测（zz_t64_search_diag_test）：searchVideos 用产品那套 UA+Referer **成功**
//   （20 条）。而 season 兜底只在 `hits.isEmpty` 时进入 ——
// 所以**真实网络下这个分支根本走不到**，用它做真机验证等于什么都没验。
// ----------------
// ⚠️ 一个容易搞错的对照：我第一版诊断脚本用 desktop UA + www Referer 打
//    search/type 得到 412，于是误以为「search 全挂」。实际产品用的是
//    mobile UA + search.bilibili.com Referer ⇒ 200。**412 是我自己那次请求的**，
//    不是产品的。这条差别很重要，不能拿它当"search 挂了"的证据。
// ```
//
// ⇒ 本文件用**子类只覆写 searchVideos 让它抛**，season 那两个接口**真发 HTTP**。
//   这样命中的就是 Lead 写的 `if (hits.isEmpty) { _autoBindViaSeason(...) }` 分支。
// ignore_for_file: avoid_print
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/bili/bili_bind.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 只让**视频搜索**失败（模拟 search/type 被风控 412）；
/// season 搜索与 seasonInfo **完全走真网络**（父类实现）。
class _SearchBlockedApi extends BiliApi {
  @override
  Future<List<BiliSearchItem>> searchVideos(String keyword, {int page = 1}) async {
    throw DanmakuException('某视频站接口返回 HTTP 412', statusCode: 412);
  }
}

Future<bool> _online() async {
  try {
    final r = await (await io.HttpClient()
            .getUrl(Uri.parse('https://api.bilibili.com/pgc/view/web/season?season_id=26801'))
        .timeout(const Duration(seconds: 10)))
        .close();
    await r.drain<void>();
    return r.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  test('★★ search 不可用时，season 兜底必须接管并给出 cid', () async {
    if (!await _online()) {
      markTestSkipped('bilibili season 接口不可达');
      return;
    }

    UiPrefs.debugResetForTest(<String, String>{});
    addTearDown(() => UiPrefs.debugResetForTest());

    final outcome = await autoBindBySearch(
      api: _SearchBlockedApi(),
      provider: 'cycani',
      id: 't64-season-fallback',
      localTitle: '鬼灭之刃',
      episodeTitles: const <String>['第01集', '第02集', '第03集'],
    );

    expect(outcome, isNotNull, reason: '★ search 失败时 season 兜底必须接管');
    print('[FALLBACK] reason = ${outcome!.reason}');
    print('[FALLBACK] score  = ${outcome.score}');
    print('[FALLBACK] title  = ${outcome.binding.title}');
    print('[FALLBACK] bvid   = ${outcome.binding.bvid}');
    print('[FALLBACK] eps    = ${outcome.binding.episodeCount}');
    for (final e in outcome.binding.episodes.take(3)) {
      print('[FALLBACK]   ep#${e.episodeIndex} page=${e.page} cid=${e.cid} part=${e.part}');
    }

    // ① 必须是**season 那条分支**，不是普通搜索（否则证明不了新代码）
    expect(outcome.reason, contains('season 链路'),
        reason: '★ 必须是 season 兜底分支（实测 reason=${outcome.reason}）');
    // ② 必须真有 cid（弹幕靠它）
    final cid = outcome.binding.cidFor(0);
    print('[FALLBACK] 第1集 cid = $cid');
    expect(cid, greaterThan(0), reason: '★ 必须有 cid 才能取弹幕 XML');
    // ③ 自动绑定不许冒充手动（否则以后自动流程不敢更新它）
    expect(outcome.binding.manual, isFalse,
        reason: '★ season 兜底是自动匹配，manual 必须 false');
    // ④ 整季都该有 cid（Lead 的实现是逐集取 cid 并跳过 cid<=0）
    expect(outcome.binding.episodes.length, greaterThan(1),
        reason: '★ 整季应有多集，不是只绑 1 集');
  }, timeout: const Timeout(Duration(seconds: 120)));
}
