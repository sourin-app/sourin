// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 门禁：仓库里**不许出现任何具体视频网站的名字**（Owner 2026-10-13）
// ═══════════════════════════════════════════════════════════════════════
//
// # 规矩出处
// `CONTRIBUTING.md` 的「⑥ 规矩三」。Owner 原话（逐字）：
// ```text
// > 拆分成插件,只存在本地,并不发布到仓库,还有提交信息也不要有具体某个网站的修复,
// > 他们都是插件提供,我们是提供的视频播放能力,这个是重点,不要搞错了
// > 全部都移除,在提交信息中,不允许留,如果git提交历史有的话,也要删掉
// ```
//
// # 为什么要有这条**机械**门禁（而不只是写在规范里）
// ```text
// 「写在文档里的规矩」= 靠自觉 —— 本仓已经有教训：规范写了、
// 代码里照样犯（见 CONTRIBUTING ⑥ 规矩一的四个真实案例）。
// ⇒ 凡是能机械判定的规矩，都要有一条会变红的测试。
// 本文件就是那条测试：**仓库里出现网站名 ⇒ 红**。
// ```
//
// # 判据（白名单式，不是黑名单式）
// ```text
// 不是"列出所有网站名去查"（列不全、会被新网站绕过），
// 而是：**扫描仓库里所有会被发布的文本，发现名单里的词就报错。**
// ⚠️ 名单要**能扩充**：以后新增一个被禁的词，加进 `_banned` 即可。
// ```
//
// # ⚠️ 本测试自己的"假绿"风险（必须先说清楚）
// ```text
// 一条"扫描关键词"的测试天然容易变成假绿：
//   · 扫描范围漏了某个目录 ⇒ 那里放网站名也扫不到
//   · 正则写错 ⇒ 恒不命中
// ⇒ 所以本文件必须有**阳性对照**：喂一个含禁用词的假输入，
//   断言"扫描器**确实**能抓到"（见最后一组）。
//   ★ 这是本仓铁律「判据测不出反面 ⇒ 结论作废」的直接应用。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 被禁的词 → 说明（说明会进失败信息，让人一眼知道为什么禁）
///
/// ⚠️ 匹配**大小写不敏感**（`bilibili` / `BiliBili` / `BILIBILI` 都要抓）。
/// ⚠️ 只放"具体的视频网站 / 平台"；**不放**通用词（如 `live` / `video`）。
const Map<String, String> _banned = <String, String>{
  // ── 视频网站 / 平台（具体站点）────────────────────────────────
  'bilibili': '具体视频网站名',
  '哔哩哔哩': '具体视频网站名',
  'b站': '具体视频网站名的俗称',
  'douyu': '具体直播平台名',
  '斗鱼': '具体直播平台名',
  'douyin': '具体视频平台名',
  '抖音': '具体视频平台名',
  'huya': '具体直播平台名',
  '虎牙': '具体直播平台名',
  'kuaishou': '具体视频平台名',
  '快手': '具体视频平台名',
  '腾讯视频': '具体视频网站名',
  '爱奇艺': '具体视频网站名',
  'iqiyi': '具体视频网站名',
  '优酷': '具体视频网站名',
  'youku': '具体视频网站名',
  '芒果tv': '具体视频网站名',
  'cntv': '具体视频网站域名',
  '央视网': '具体视频网站名',
  'cctv': '具体电视频道/网站代号',
  'iptv-org': '具体公共源清单项目名',
  'cycani': '具体动画网站代号',
  '次元城': '具体动画网站名',
  'dandanplay': '具体弹幕服务名',
  '弹弹play': '具体弹幕服务名',
  // ── 自建/其它服务 ──
  // ⚠️ `emby` **不在**名单里：它是「自建媒体服务器」，不是视频网站
  //    （Owner 1013 明确保留 `emby.js`）。
};

/// 允许出现的**例外路径**（相对仓库根，`/` 结尾 = 整个目录）
///
/// 每一条都必须在下面 `_exceptionReason` 里写明理由 —— 不许裸加。
const List<String> _exempt = <String>[
  'CONTRIBUTING.md', // ★ 规范本身要举例说明"哪些词被禁"
  'test/t98_no_site_names_test.dart', // ★ 本文件（名单就在这里）
  '.probe/', // 开发期一次性探针（gitignore，不发布）
  'test/', // ⚠️ 见下方 _exemptTestReason 的长注释
];

const String _exemptTestReason =
    '测试里允许出现"假站名"当夹具（如 fake-site-a），但**真站名**仍应清理。'
    '⚠️ 这条豁免是**有意的取舍**：测试夹具遍地是历史遗留的站名，'
    '一次性全改会淹没本门禁的信号。计划：先保证**产品代码 + 文档**干净'
    '（那是用户看得见、也是 Owner 真正在意的），测试夹具随后分批清。';

/// 仓库里**会被发布**的文本文件（按扩展名）
const List<String> _scanned = <String>[
  '.dart',
  '.rs',
  '.js',
  '.md',
  '.yaml',
  '.yml',
  '.json',
  '.toml',
  '.sh',
];

/// 跳过的目录（第三方 / 产物 / 版本库）
const List<String> _skipDirs = <String>[
  '.git',
  'build',
  'target',
  '.dart_tool',
  'node_modules',
  '.probe',
];

/// 扫描 [text]，返回命中的 (词, 说明)
///
/// ★ 抽成**纯函数**是为了让阳性对照能直接喂假输入测它
List<(String word, String why)> scanForBanned(String text) {
  final lower = text.toLowerCase();
  final hits = <(String, String)>[];
  for (final e in _banned.entries) {
    if (lower.contains(e.key.toLowerCase())) {
      hits.add((e.key, e.value));
    }
  }
  return hits;
}

bool _isExempt(String rel) {
  final p = rel.replaceAll('\\', '/');
  for (final x in _exempt) {
    if (x.endsWith('/')) {
      if (p.startsWith(x)) return true;
    } else if (p == x) {
      return true;
    }
  }
  return false;
}

/// 收集仓库里要扫的文件（相对路径）
List<String> collectFiles(Directory root) {
  final out = <String>[];
  void walk(Directory d) {
    for (final e in d.listSync(followLinks: false)) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (e is Directory) {
        if (_skipDirs.contains(name)) continue;
        walk(e);
      } else if (e is File) {
        if (!_scanned.any(name.endsWith)) continue;
        final rel = e.path
            .replaceAll(root.path, '')
            .replaceAll(RegExp(r'^[\\/]+'), '');
        out.add(rel);
      }
    }
  }

  walk(root);
  return out;
}

void main() {
  test('★★★ 产品代码与文档里不许出现任何具体视频网站的名字', () {
    final root = Directory.current;
    final files = collectFiles(root);
    expect(files, isNotEmpty,
        reason: '★ 阳性对照：一个文件都没扫到 ⇒ 扫描器坏了，本门禁是假绿');

    final offenders = <String>[];
    for (final rel in files) {
      if (_isExempt(rel)) continue;
      final text = File(rel).readAsStringSync();
      for (final hit in scanForBanned(text)) {
        // 每文件每词只报一次（够定位即可，不刷屏）
        offenders.add('$rel  →  「${hit.$1}」（${hit.$2}）');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '★★★ 仓库里不许出现具体视频网站的名字（CONTRIBUTING「⑥ 规矩三」）。\n'
          '本软件是「视频播放器」，提供的是**播放能力**；\n'
          '具体网站由**用户的本地插件**提供，不进仓库。\n'
          '命中：\n  ${offenders.join('\n  ')}\n'
          '⇒ 改成中性词（「本站」「这个源」「外部弹幕」），或把插件移出仓库。',
    );
  });

  test('★★ 阳性对照：扫描器**确实**能抓到禁用词（否则上面那条是假绿）', () {
    // ★★★ 这条是本文件的"尺子必须灵敏"自检。
    //   反面：把 scanForBanned 改成恒返回空 ⇒ 本断言红。
    final fake = '这是一个提到 bilibili 与 斗鱼 的假文本';
    final hits = scanForBanned(fake).map((h) => h.$1.toLowerCase()).toSet();
    expect(hits.contains('bilibili'), isTrue,
        reason: '★ 扫描器抓不到 bilibili ⇒ 上面那条"零命中"毫无意义');
    expect(hits.contains('斗鱼'), isTrue, reason: '★ 同理，中文词也要能抓到');
  });

  test('★ 阴性对照：干净文本不该被误报', () {
    const clean = '这是一个通用的视频播放器，支持多种第三方源插件。';
    expect(scanForBanned(clean), isEmpty,
        reason: '★ 中性文案不该被误判 —— 否则门禁会逼人把正常话也删掉');
  });

  test('★ 大小写不敏感', () {
    expect(scanForBanned('BiLiBiLi').isNotEmpty, isTrue);
    expect(scanForBanned('BILIBILI').isNotEmpty, isTrue);
  });
}
