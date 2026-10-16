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
  '芒果tv': '具��视频网站名',
  'cntv': '具体视频网站域名',
  '央视网': '具体视频网站名',
  'cctv': '具体电视频道/网站代号',
  'iptv-org': '具体公共源清单项目名',
  /*
   * ★★★ 2026-10-14：`iptv` / `tvbox` **不禁**（我一度加进去，又撤回）。
   *
   * # 判据边界（Owner 只针对「**对接的某个具体的视频网站**」）
   * ```text
   * · `iptv`  = **协议名**（Internet Protocol Television），
   *             本项目用它指"从公共 m3u 清单取直播"—— 不是某个网站。
   * · `tvbox` = **配置格式/生态名**（一份描述 sites/lives/parses 的 JSON），
   *             本项目**自己解析**它 ⇒ 与 `emby`（自建媒体服务器）同类。
   * ⇒ 两者都不是"某个具体的视频网站" ⇒ **不在禁名单**。
   * ```
   * ★ 但我**保留了 `iptv-org`**：那是一个**具体的公共清单项目**（指向具体来源）。
   *
   * ⚠️ 教训（与本文件里"弹幕服务"那次同一种错）：
   *    **判据要锚在"具体视频网站"上**，别扩大到"任何出现过的人名/项目名/协议名"
   *    —— 扩大会把协议名、配置格式名也卷进来，那是**过度删改**
   *    （同轮的 `弹弹play` 就是这么被我误伤的，已撤回）。
   */
  'cycani': '具体动画网站代号',
  '次元城': '具体动画网站名',
  /*
   * ⚠️⚠️ 2026-10-14 Owner 澄清：**弹幕服务不算「视频网站」**，不删。
   *
   * Owner 原话（逐字）：
   * ```text
   * > 弹弹play这种不用删除的,只有对接的某个具体的网站和视频网站
   * > 这种才需要删除
   * ```
   *
   * # 判据（本名单的**唯一**准入标准）
   * ```text
   * 禁 = 本软件**对接的、具体的视频网站**（用户在那儿看视频/直播）。
   * 放 = 弹幕服务 / 自建媒体服务器 / 通用协议 —— 它们不是"视频网站"。
   * ```
   * ⇒ 我一度把弹幕服务也加进名单（**过严**），已移除：
   *   `dandanplay` / `弹弹play` 不再被禁。
   */
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
  '.dsh_baseline_hashes.json', // ★ 本机基线哈希缓存（gitignore，不发布）
  'test/', // ⚠️ 见下方 _exemptTestReason 的长注释
];

const String _exemptTestReason =
    '测试里允许出现"假站名"当夹具（如 fake-site-a），但**真站名**仍应清理。'
    '⚠️ 这条豁免是**有意的取舍**：测试夹具遍地是历史遗留的站名，'
    '一次性全改会淹没本门禁的信号。计划：先保证**产品代码 + 文档**干净'
    '（那是用户看得见、也是 Owner 真正在意的），测试夹具随后分批清。';

/// 允许出现的**具体行**（比整文件豁免精确得多）。
///
/// 每条 = (文件相对路径子串, 该行必须包含的唯一子串, 理由)。
/// ★ 只有**真正负载、必须逐字保留**的字符串才配得上行级豁免 ——
///   不是"懒得改"，而是"改了会坏"。
/// ★ 豁免只对**那一行**生效：同文件里其它新加的站名照样报。
const List<(String fileSubstr, String lineMarker, String why)> _exemptLines =
    <(String, String, String)>[
  (
    'rust/sourin_core/src/state.rs',
    'bilibili-live.js',
    '真实迁移：老用户数据目录里可能还留着这个**历史文件名**，'
        '不删会与用户自己的插件重复注册。它只在"删除/探测老文件"路径上出现，'
        '不是产品文案、不对外可见。'
  ),
  (
    'rust/sourin_core/src/state.rs',
    '@id bilibili-live',
    '同上：测试模拟"老用户升级"时铺的旧文件骨架，必须用真实的历史 @id，'
        '否则测不出"旧文件被清掉"。'
  ),
  (
    'rust/sourin_core/src/state.rs',
    "id: 'bilibili-live'",
    '同上：旧文件骨架里插件对象的 @id 必须逐字是历史值（同一条迁移测试）。'
  ),
  (
    'rust/sourin_core/src/state.rs',
    'x == "bilibili-live"',
    '同上：断言"遗留的旧源不再出现"，必须逐字写历史 @id。'
  ),
  // ── 运行期**必需的真实 API 主机名**（删/改 ⇒ 功能坏死）──────────────
  //
  // ★ 这一类与上面的"品牌名"性质不同：它们是**客户端真正要连的端点**，
  //   不是"支持某站"的文案。删掉或换成假域名 ⇒ 弹幕/视频接口直接拿不到数据
  //   （且不会有编译错误，是**静默功能坏死**）。
  //   ⇒ 按 Owner 口径「不许为了删而删功能」，这些字符串**必须逐字保留**。
  //   ★ 只豁免**含该主机名的那一行**；同文件别处提到站名的文案照样被抓。
  (
    'lib/core/bili/bili_api.dart',
    'bilibili.',
    '视频源弹幕导入用到的**真实 API 主机名**（api./comment./search./www.）：'
        '换假域名 ⇒ 取流与弹幕静默失效。不是"支持某站"的文案。'
  ),
  (
    'lib/core/bili/bili_bind.dart',
    'bilibili.',
    '同上：绑定逻辑里引用的真实端点（comment. 弹幕 XML）。'
  ),
  (
    'lib/core/dlna/referer_proxy.dart',
    'bilibili.',
    '同上：防盗链 Referer 的**真实域名示例**（DLNA 转发的运行期参数）。'
  ),
  (
    'lib/ui/widgets/bili_import_dialog.dart',
    'bilibili.',
    '同上：输入框 placeholder 展示的**真实链接形态**（用户要照着填）。'
  ),
  (
    'lib/ui/widgets/plugin_edit_dialog.dart',
    'bilibili.',
    '同上：注释里举例说明"上游来源 URL"的真实形态（`const API = ...`）。'
  ),
  (
    'lib/probe_cast.dart',
    'bilibili.',
    '同上：DLNA 探针里的真实 Referer 域名。'
  ),
  (
    'rust/sourin_core/tests/t525_qr_login.rs',
    'bilibili',
    '★ 集成测试的**夹具引用**：它从用户本机 `%APPDATA%\\...\\plugins\\` '
        '只读复制那份插件的**真实文件名**（`bilibili.js`），并用它的**真实 @id** '
        '调命令层 —— 这不是产品文案，改名会让测试读不到夹具。'
        '（夹具缺席时该测试跳过，见文件内的 skip 分支。）'
  ),
  /*
   * ★★★ 2026-10-15（Owner 口径，逐字）
   * ```text
   * > bilibili这个弹幕允许使用,别的bilibili不允许
   * ```
   *
   * # 为什么这条与上面那些**性质不同**
   * ```text
   * 名单的准入标准是「本软件**对接的具体视频网站**」（用户在那儿看视频/直播）。
   * 而这里指的是**弹幕来源** —— 与 `弹弹play` 同类。
   * Owner 2026-10-14 已经说过弹幕服务不算视频网站、不删；10-15 又明确了这一条。
   * ```
   *
   * ⚠️ 仍然只豁免**含该标记的那一行**，且行内必须同时出现「弹幕」二字：
   *    同一个文件里写别的站名（或把 bilibili 当视频网站用）**照样会被抓**。
   *    这是「精确到行」而不是「整文件放行」。
   */
  (
    'lib/ui/widgets/danmaku_settings_dialog.dart',
    'site-ok: danmaku-source',
    '★ 弹幕源标记：Owner 2026-10-15 明确「bilibili 这个**弹幕**允许使用」'
        '（与弹弹play 同类，不是“对接的视频网站”）。'
        '⚠️ 锚串必须是**唯一**的 `site-ok: danmaku-source`，不能是「弹幕」二字 ——'
        '2026-10-16 实测：「弹幕」在该文件里到处都是，'
        '写成「弹幕」等于**整文件放行**（注入一行 `douyu` + 「弹幕」照样绿），'
        '而注释却声称「把站名当视频网站用照样会被抓」= 假绿。'
  ),
  /*
   * 下面两条是**存量**命中（HEAD 里就有，不是本轮新增），
   * 属于表里早已存在的「真实文件名 / 真实 MediaId」这一类：
   * 改名会让插件认不出自己、或让测试读不到夹具 ⇒ 宁可逐行豁免。
   */
  (
    'lib/ui/player_page.dart',
    'bilibili.js',
    '★ 真实**插件文件名**：这一行记录的是当时实测用的哪份插件（证据出处），'
        '不是产品文案。同类条目已有先例（t525_qr_login）。'
  ),
  (
    'rust/sourin_core/tests/zz_t1015_bili_audio_url.rs',
    'bilibili',
    '★ 同上（存量）：这个回归测试引用的是**插件文件名**（bilibili.js）与'
        '**真实 MediaId**（`MediaId::new("bilibili", ...)`）——后者是插件自己写进来的标识，'
        '改成别的字串就接不上插件。不是产品文案。'
  ),
];

/// 该行是否命中某条行级豁免
/// 测试可见版本：给「豁免宽度」的自检用（见 ★★★ 行级豁免那条用例）。
///
/// ⚠️ 存在的意义就是让那条用例能**直接**问「这一行会不会被豁免」，
///    而不必真的往产品文件里插脏数据（插脏数据会污染工作区）。
bool isExemptLineForTest(String rel, String line) => _isExemptLine(rel, line);

bool _isExemptLine(String rel, String line) {
  final p = rel.replaceAll('\\', '/');
  for (final e in _exemptLines) {
    if (p.contains(e.$1) && line.contains(e.$2)) return true;
  }
  return false;
}

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

/// 跳过的目录（第三方 / 产物 / 版本库 / 本机 agent 工具）
const List<String> _skipDirs = <String>[
  '.git',
  'build',
  'target',
  '.dart_tool',
  'node_modules',
  '.probe',
  // ★ 以下都是**本机 agent/开发工具目录**，不是仓库内容、也不随包发布：
  //   · `.claude/`      —— 本机 Claude 会话产物（报告、worktree、缓存）
  //   · `.probe_i12/`  等 —— 开发期一次性探针（已在 .gitignore）
  //   · `.local/`       —— 本机临时脚本/中间文件
  //   ⇒ 跳过它们，否则本门禁会被工具产物淹没（假阳性）。
  '.claude',
  '.local',
  '.probe_i12',
  '.probe_i56',
];

/// 扫描 [text]，返回命中的 (词, 说明)
///
/// ★ 抽成**纯函数**是为了让阳性对照能直接喂假输入测它
List<(String word, String why)> scanForBanned(String text) {
  final lower = text.toLowerCase();
  /*
   * ★★★ 2026-10-14（CR #27）：匹配前**剥掉所有空白**。
   *
   * # 为什么（实测漏报）
   * ```text
   * README 里写的是「B 站」（**B 与站之间有空格**），而名单里的键是 `b站`
   * ⇒ 原来的 `lower.contains('b站')` **匹配不到** ⇒ 漏报。
   * ★ 中文文本里"在词中间插一个空格"是**常见排版**（尤其英文缩写+中文），
   *   所以按"逐字连续"匹配会系统性漏掉这一类。
   * ```
   * ⇒ 把两边都**去掉空白**再比。代价：理论上会多报"跨词的偶然相邻"
   *   （如「…A 站B 站…」这类），但那本来就该人工看一眼，**漏报更糟**。
   * ⚠️ 行级豁免的 `lineMarker` 匹配**不**做这个处理（它要精确到行）。
   */
  final compact = lower.replaceAll(RegExp(r'\s+'), '');
  final hits = <(String, String)>[];
  for (final e in _banned.entries) {
    final key = e.key.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (compact.contains(key)) {
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
      final raw = File(rel).readAsStringSync();
      final lines = raw.split('\n');

      /*
       * ★★★ 2026-10-14（CR #27）：**先扫整个文件**，再逐行定位。
       *
       * # CR 指出的覆盖漏洞（属实）
       * ```text
       * 原实现先 `split('\n')` 再逐行 `scanForBanned(line)`
       * ⇒ 跨行的词被切成两截，**匹配不到**：
       *    `B\n站` ⇒ 第一行只有 `B`、第二行只有 `站` ⇒ 都不含 `b站` ⇒ **静默放行**。
       * 而本门禁声明要扫"所有可发布文本"、`_scanned` 也含 `.md`
       * ⇒ 这不是"可接受的误报取舍"，是**真漏报**（强制门禁不能有空子）。
       * ```
       * # 修法：两道扫描，各取所长
       * ```text
       * ① 整文件扫（上下文连续）⇒ **能捕到跨行拼接**。
       *    ⚠️ 必须先把"行级豁免行"上的内容剔掉（换成空串、保持行数），
       *       否则豁免失效。
       * ② 逐行扫（精确到行）⇒ 报警时能点名是哪一行。
       * ⇒ 两道都报一遍（去重），既不漏也能定位。
       * ```
       */
      final exemptLineFlags = <bool>[
        for (final line in lines) _isExemptLine(rel, line),
      ];
      final wholeForScan = <String>[
        for (var i = 0; i < lines.length; i++)
          if (!exemptLineFlags[i]) lines[i],
      ].join('\n');

      final reported = <String>{};
      // ① 整文件扫描（捕跨行）
      for (final hit in scanForBanned(wholeForScan)) {
        reported.add('$rel  →  「${hit.$1}」（${hit.$2}）'
            '（整文件命中；若行内找不到，多半是**跨行拼接**）');
      }
      // ② 逐行扫描（精确定位）
      for (var i = 0; i < lines.length; i++) {
        if (exemptLineFlags[i]) continue;
        for (final hit in scanForBanned(lines[i])) {
          reported.add('$rel:${i + 1}  →  「${hit.$1}」（${hit.$2}）');
        }
      }
      offenders.addAll(reported);
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

  test('★★ 阳性对照：行级豁免**精确到行** —— 非豁免行仍会被抓到', () {
    // ★ 反面：把 _isExemptLine 改成恒返回 true ⇒ 本断言红。
    final rel = 'rust/sourin_core/src/state.rs';
    // ① 命中豁免的那一行 ⇒ 被放过
    expect(
      _isExemptLine(rel, 'let legacy = plugins_dir(data_dir).join("bilibili-live.js");'),
      isTrue,
      reason: '★ 迁移路径的**历史文件名**那一行应当被豁免',
    );
    // ② ★ 同文件里**别的一行**（没有豁免 marker）带着站名 ⇒ 仍必须被抓到
    expect(
      _isExemptLine(rel, '// 我们以前支持过 bilibili，后来删了'),
      isFalse,
      reason: '★★ 豁免只对那一行生效 —— 同文件新加的站名不能被一起放过',
    );
    // ③ 换个文件、同样的行内容 ⇒ 不豁免
    expect(
      _isExemptLine('lib/foo.dart', 'String.fromEnvironment("DANDANPLAY_APP_ID")'),
      isFalse,
      reason: '★ 豁免绑到具体文件，不能跨文件生效',
    );
  });

  test('★★★ 行级豁免必须是**唯一锚串**，不许被常见词放大成整文件放行', () {
    /*
     * # 这条防的是什么（2026-10-16 实测）
     *
     * `danmaku_settings_dialog.dart` 的豁免标记原来是「弹幕」二字。
     * 但该文件**本身就是弹幕面板**，几乎每行都含「弹幕」⇒
     * 实际效果是**整文件放行**，而注释却声称「把站名当视频网站用照样会被抓」。
     *
     * ```text
     * 实测：往该文件插一行 `// 去 douyu 看直播，弹幕也在那`
     *   改前 → 门禁**照样绿**（假绿）
     *   改后 → 门禁变红，并点名 douyu
     * ```
     *
     * ⇒ 锚串收紧为 `site-ok: danmaku-source`，只给**确实该豁免的那几行**加。
     */
    const rel = 'lib/ui/widgets/danmaku_settings_dialog.dart';

    // ① 带锚串的行：该豁免
    expect(
        isExemptLineForTest(rel, "const String _k = 'bilibili';  // site-ok: danmaku-source"),
        isTrue,
        reason: '★ 明确标了锚串的行应当被豁免');

    // ② ★ 关键：只有「弹幕」二字、没有锚串 ⇒ **不许**豁免
    expect(isExemptLineForTest(rel, '// 去 douyu 看直播，弹幕也在那'), isFalse,
        reason: '★★ 只凭「弹幕」二字就豁免 = 整文件放行；这条必须为 false，'
            '否则任何站名只要同行带「弹幕」就混进来');

    // ③ 同一文件里，普通行含站名 ⇒ 不许豁免
    expect(isExemptLineForTest(rel, "final url = 'https://bilibili.com/x';"), isFalse,
        reason: '★ 没标锚串的行必须照抓');
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

  test('★★★ 跨行拼接也要抓到（CR #27 的判据）', () {
    /*
     * CR 给的可验证判据：把 `B\n站` 放进一个非豁免文件 ⇒ 门禁**必须**报命中。
     *
     * # 为什么单测这一条（而不是真的去写一个临时文件）
     * ```text
     * 本文件测的是 `scanForBanned`（纯函数）—— 而"整文件扫"那道之所以能捕到
     * 跨行，是因为**调用前先把整篇 join('\n') 再整体喂进去**（见上一条用例）。
     * ⇒ 这里直接喂"含换行的整篇文本"，等价于那道整文件扫描。
     * ```
     * ★ 反面：把 `scanForBanned` 改回"只逐字连续匹配且不剥空白"
     *   ⇒ 本断言红（`B\n站` 剥空白后是 `b站`，必须命中）。
     */
    expect(
      scanForBanned('这是 B\n站 的内容').isNotEmpty,
      isTrue,
      reason: '★★★ 跨行 B\n站 必须被整文件扫描捕到 —— '
          '原实现「先按行切、再逐行匹配」，'
          '会把 B 与 站 分到两行 ⇒ **静默放行**',
    );
    // 阳性对照：确认"换行本身"不是唯一原因 —— 同一段不换行也要命中
    expect(scanForBanned('这是 B站 的内容').isNotEmpty, isTrue);
  });
}
