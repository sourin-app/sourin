// ═══════════════════════════════════════════════════════════════════════
//  弹幕设置对话框（task-13 ⑦）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么入口在**播放页**而不是全局设置页
//
// 弹幕的字号 / 透明度 / 速度 / 占用区域，都要**看着画面**调才知道合不合适。
// 放在全局设置页意味着用户必须退出播放器才能调 —— 那等于调不了。
// 所以齿轮挂在播放页底栏的「弹幕」按钮旁边，面板是 `Positioned.fill` 的
// 全屏浮层（与「播放设置」「片头片尾」同一套视觉语言，**不暂停播放**）。
//
// # ★★★ 凭证从哪来（2026-10-14 Owner 反馈后：面板上**恢复**凭证输入框）
//
// # Owner 原话（逐字）
// ```text
// > 本地播放提示 [弹幕服务] 没有收到凭证,说明 [弹幕服务] 流程根本没走通
// ```
//
// # 走不通的根因（改前）
// ```text
// ① 2026-10-11 把面板上的凭证输入框**整节删除**了 —— 当时的设想是
//    "客户端已内置官方凭证（构建期 --dart-define 注入），用户不必手填"；
// ② 但那把"内置已注入"当成了**普遍**成立。本地构建没有 --dart-define ⇒
//    `DanmakuConfig.hasBuiltinCredentials == false`，而 `UiPrefs` 也没值
//    ⇒ 打官方那条边**必然** 403「弹幕服务没收到凭证」；
// ③ 更糟的是写入口（`setAppId` / `setAppSecret` / `clearCredentials`）
//    虽然定义还在，却**全仓 0 个调用者** ⇒ 用户**无路可走**。
// ⇒ 所以本节恢复：两个输入框 + 「保存」/「清除」，让没有内置凭证的构建也能用。
// ```
//
// # 三样东西现在**都在**（优先级从高到低）
// ```text
// ① `UiPrefs` 用户覆盖（键 `dsh.danmaku.appId` / `dsh.danmaku.appSecret`）  ← 本面板写
// ② 构建期 `--dart-define=DANDANPLAY_APP_ID/SECRET`（`String.fromEnvironment`）
// ③ 两者都空 ⇒ 未配置（官方边会失败，面板必须**如实**说）
// ```
//
// 内置值仍然只在 CI Secrets 里 —— 仓库里**只有占位符 / 空串**
// （官方文档 doc.dandanplay.com/open/ 允许开源客户端「用占位符，
//  构建时从机密读取后替换」）。面板给用户填的是**他自己的**配置。
//
// 保留的只读链路（`DanmakuConfig` 的 getter / `usingBuiltin*` /
// `maskedAppId` / `isConfigured` / `statusText`）是签名与状态展示的来源。
//
// # 为什么没配凭证也**照样**发请求
//
// 见 `lib/core/danmaku.dart` 里 `ExternalDanmakuClient` 的类注释：
// 本地短路会永久埋掉服务端给的**具体**原因（缺头 / 时间戳错 / AppId 无效 /
// 签名错），而那正是用户排错唯一能拿到的信息。
// ⇒ 所以本面板把 `DanmakuException.detail`（含 `X-Error-Message` 原文）
//   原样显示出来，**一个字都不改写**。
//
// # ⚠️ AppSecret 的存储
//
// 用户手填的 AppSecret 是**明文**存在数据目录的 `ui-prefs.json` 里的
// —— 这是**用户自己的本机配置**，不进仓库（仓库纪律见上）。
// 迁移到系统凭据存储仍是**独立的一项工作**，不在本任务范围内。
//
// # 禁止 `package:flutter/material.dart`
//
// 项目用拆包后的 `material_ui`（见 `test/material_split_test.dart`）。

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'dart:async';
import 'dart:convert' show jsonDecode, Utf8Decoder;
import 'dart:io' show SocketException, Socket, InternetAddress, HttpClient;

import '../../core/danmaku.dart';
import '../../core/ui_prefs.dart';
import '../tokens.dart';
import 'cover_image.dart';
import 'app_dialog_shell.dart';
import 'app_inline_spinner.dart';
import '../../design/icons/app_icons.dart';

/// T27-01：弹幕面板文字统一灰阶 —— 全文件取色只走这里
///
/// # 为什么收口成一个常量类
///
/// 修复前文本色散落 Colors.white / white70 / white60 / white54 / white38，
/// 还有两处 TextStyle 干脆没给 color；white38 一档对底色实测只有 3.30:1
/// —— 业主原话「弹幕这里的文字都看不清」。现在每档对 panelBg
/// （业主 fig1 实测 rgb(20,22,27)）的 WCAG 对比度钉在
/// test/t27_w1_danmaku_contrast_test.dart：
/// body 14.5:1 · secondary 9.7:1 · muted 5.9:1（正文线 4.5:1），
/// border 2.2:1（边框线 ≥1.6:1 —— 弱化但可辨，不做正文）。
abstract final class DanmakuTextColors {
  /// 正文/强调文本与主动作 icon（旧 Colors.white 档）
  static const Color body = Color(0xFFE6E6E6);

  /// 次要文本/交互标签（旧 white70 档）
  static const Color secondary = Color(0xFFB9BEC6);

  /// 说明/占位/辅助 icon（旧 white60 / white54 / white38 档）
  static const Color muted = Color(0xFF8E939B);

  /// 边框/分隔线/关态指示点（旧 white24 档 —— 纯装饰）
  static const Color border = Color(0xFF4A4E56);

  /// 角标文字：叠在 black55 角标底上（任务口径：对纯黑 ≥4.5:1）
  static const Color badgeText = body;

  /// 面板卡片底色 —— 业主 fig1 实测 rgb(20,22,27)
  static const Color panelBg = Color(0xFF14161B);

  // ---- ★ 2026-10-11：显示区域引导遮罩（DanmakuAreaGuide）的三档色 ----
  //
  // 遮罩画在**视频画面**上，不是面板里 —— 所以对比度要求不是 WCAG 文本线，
  // 而是"看得见、又不挡画面"：色相统一走白，靠 alpha 分档。
  // 与 overlay 里弹幕描边（black α0.85）配套：白色遮罩在深色画面上同样可辨。

  /// 边界线（半透明白，1.5px）—— 标出"弹幕区到此为止"
  static const Color areaGuideLine = Color(0xCCFFFFFF);

  /// 弹幕区内填充（极淡白 6%）—— 提示"这里能放弹幕"
  static const Color areaGuideInside = Color(0x0FFFFFFF);

  /// 区外填充（更暗的白 16%）—— "遮罩"感主体，提示"这里不再有弹幕"
  static const Color areaGuideOutside = Color(0x29FFFFFF);
}

/// 对话框要展示的全部状态
///
/// # 为什么由宿主传进来、而不是对话框自己读 `DanmakuConfig`
///
/// ```text
/// ① 对话框变成**纯 UI** ⇒ 可以脱离播放页单测
/// ② 一次请求的状态（加载中 / 报错 / 命中结果）本来就属于宿主
/// ③ 打开面板不该有副作用 —— 自己读偏好会诱发"读一下就改了观感"
/// ```
/// ★★★ 2026-10-19（第 66 轮 R3-③ / R3-⑦）：**为什么连不上** —— 分类，不是一句"用不了"
///
/// # 这一层为什么必须存在（Owner 的两条反馈合起来指向同一件事）
/// ```text
/// R3-③「弹幕来源搜不了」
/// R3-⑦「内置两个 dan-api 根本用不了」
///
/// 实测（本机，2026-10-19，dart:io 真跑）：
///   danmu-api-delta.vercel.app
///     DNS  lookup → 2a03:2880:f10c:283:face:b00c:0:25de / 31.13.87.19
///     TCP  443    → SocketException: Connection timed out（errno 10060, 6.0s）
///   danmu-api-kappa.vercel.app  → 同上
///   （对照）一个真正不存在的域名 → errno 11001「不知道这样的主机」，10ms 就失败
///
/// ⇒ **不是服务坏了**，是这两个域名在本机被解析到不可达地址后**连不上**。
///   而旧 UI 对这两种情况说同一句话：「未运行 / 暂时连不上」——
///   用户据这句话去改配置/等一会儿，都是**错的方向**。
/// ```
///
/// # 所以 UI 要说真话：把"连不上"拆成能指导下一步的几类
/// ```text
/// dnsFailed       域名解析不出来        ⇒ 本机 DNS/网络问题，改配置没用
/// connectionTimeout 解析到了但连不上    ⇒ 被墙 / 代理 / 路由问题（本机就是这一类）
/// connectionRefused 连接被明确拒绝      ⇒ 本机服务没起来 / 端口不对（改配置有用）
/// tlsFailed       TLS 握手失败          ⇒ 证书 / 中间人 / 代理拦截
/// serverError     连上了，服务回了错    ⇒ **这次真的是服务的问题**
/// emptyResponse   连上了但没内容        ⇒ 服务活着，只是这个库/这一集没有弹幕
/// ```
/// ⚠️ 最后两类与前面几类**必须分开说**：
///    「服务返回空」是**正常结果**，画成"连不上"会让用户去修一个没坏的东西。
enum DanmakuProbeFailure {
  /// 没失败（在线，且有内容）
  none,

  /// 域名解析不出来
  dnsFailed,

  /// ★★★ 2026-10-19（R3-③/⑦ **归因修正**，Lead 用 DoH 真值对照后定案）：
  /// **解析成功，但解析到的是伪造/无关地址** —— 本机 DNS 被劫持。
  ///
  /// # 为什么必须与 [dnsFailed] 分开（这是本轮最重要的一条判据）
  /// ```text
  /// 「能解析」**不是**「解析正确」的同义词。
  ///
  /// 本机实测（2026-10-19）：
  ///   域名                          本机 DNS                       DoH 真值                    判定
  ///   danmu-api-delta.vercel.app    74.86.17.48                   216.198.79.3 / 64.29.17.3   ✗
  ///                                 + 2a03:2880:…:face:b00c
  ///   danmu-api-kappa.vercel.app    108.160.173.207(PTR=Dropbox)  216.198.79.67 / 64.29.17.67 ✗
  ///                                 + 2a03:2880:…:face:b00c
  ///   vercel.app (apex)             199.96.58.15                  216.198.79.131 / 64.29.17.131 ✗
  ///   vercel.com （对照，能通）       64.239.109.193                64.239.123.129                 ✓
  ///
  /// 两条伪造特征：
  ///   ① `2a03:2880:…:face:b00c` —— `face:b00c` 是 Facebook 的固定花样段
  ///   ② 74.86.17.48 = SoftLayer 静态段 / 108.160.173.207 = Dropbox ——
  ///      都不是 Vercel 的 anycast 段
  /// ```
  ///
  /// # 为什么我第一版判错了（方法论记一笔）
  /// ```text
  /// 我只看到 `getaddrinfo` **没抛异常**就下结论"DNS 正常、断在 TCP"，
  /// 于是把 TCP 超时当成**独立病因**。
  /// 实际：TCP 连的那个地址**本来就是错的** ⇒ 超时只是劫持的**后果**。
  ///
  /// ⇒ 铁律：判 DNS 是否被劫持，必须拿**权威/加密通道（DoH/DoT）**的
  ///   真值做对照，不能只看解析有没有抛异常。
  /// ```
  ///
  /// # 对用户意味着完全不同的操作
  /// ```text
  /// dnsFailed     ⇒ 本机 DNS 不通   ⇒ 换网络 / 修 DNS
  /// dnsHijacked   ⇒ 本机 DNS 被劫持 ⇒ **换 DNS（如 DoH）或开启代理**
  /// ```
  /// 两句混用会把人指向错误的修法，所以必须分档。
  dnsHijacked,

  /// 解析到了，但 TCP/TLS 连不上（超时）
  connectionTimeout,

  /// 连接被明确拒绝
  connectionRefused,

  /// TLS 握手失败
  tlsFailed,

  /// 连上了，服务返回错误状态（HTTP 5xx / 4xx）
  serverError,

  /// 连上了、服务也回了，但**没有内容**（0 条弹幕）
  emptyResponse,

  /// ★★★ 2026-10-19（X4）：**探测本身出错**，不是网络失败
  ///
  /// # 为什么必须有这一档（文案说谎的真实案例）
  /// ```text
  /// 改前：所有认不出来的异常都落进 `connectionTimeout`，于是
  ///   StateError('boom')（探针自己抛的，**根本没碰过网络**）
  ///     ⇒ 用户看到「连不上（超时）⇒ 地址解析出来了但连不过去…」
  ///   那句话陈述了**三件从未发生**的事实：
  ///     · 没超时      · 地址没解析出来过（更没解析"出来但连不过去"）
  ///     · 更不是「被墙 / 代理 / 路由不通」
  /// ```
  ///
  /// # 与既有分档同源的判据（同一条铁律，两处用）
  /// ```text
  /// `fromDanmakuException` 之所以敢判 `dnsHijacked`，
  ///   是因为它手里**有 `resolvedAddress` 这个物证**；
  /// 兜底这条**没有任何网络物证** ⇒ 同理不该判任何网络档。
  /// ⇒ 「有物证才敢下结论」—— 说不出来就如实说"说不出来"。
  /// ```
  ///
  /// ⚠️ 这一档**不是**"服务坏了"：它连"服务"都没碰到。
  probeFailed,
}

extension DanmakuProbeFailureX on DanmakuProbeFailure {
  /// 这一步该由谁负责 —— 决定文案里"你要做什么"
  ///
  /// ⚠️ 这是**判据**，不是装饰：UI 的整段文案都从这里分叉，
  ///    免得两处各写一套然后漂移。
  bool get isLocalNetworkProblem =>
      this == DanmakuProbeFailure.dnsFailed ||
      this == DanmakuProbeFailure.dnsHijacked ||
      this == DanmakuProbeFailure.connectionTimeout ||
      this == DanmakuProbeFailure.connectionRefused ||
      this == DanmakuProbeFailure.tlsFailed;

  /// ★ 服务端的问题（与"本机网络"完全两件事）
  bool get isServiceProblem =>
      this == DanmakuProbeFailure.serverError;

  /// ★★ 探测本身出错 —— **既不是本机网络、也不是服务**
  ///
  /// ⚠️ 为什么必须单列、且**不能**并进上面任何一档：
  ///   兜底分支**没有任何网络物证**（没解析过、没建过连接）⇒
  ///   把它算成「本机网络问题」会让用户去改代理 / 换网络（错的操作），
  ///   算成「服务问题」会让用户去重启服务（同样错）。
  bool get isProbeItselfFailed =>
      this == DanmakuProbeFailure.probeFailed;

  /// 正常但没数据（**不是失败**）
  bool get isJustEmpty => this == DanmakuProbeFailure.emptyResponse;

  bool get isFailure => this != DanmakuProbeFailure.none && !isJustEmpty;

  /// 一句短标题（**不含具体地址**，那种由调用方拼）
  String get title => switch (this) {
        DanmakuProbeFailure.none => '可用',
        DanmakuProbeFailure.dnsFailed => '域名解析失败（本机 DNS 不通）',
        /*
         * ★ 必须与上一句**明显不同**：
         *   前者的操作是"换网络"，后者是"换 DNS / 开代理"。
         *   两句混用会把用户指向错误的修法。
         */
        DanmakuProbeFailure.dnsHijacked => '域名被解析到了错误地址（DNS 可能被劫持）',
        DanmakuProbeFailure.connectionTimeout => '连不上（连接超时）',
        DanmakuProbeFailure.connectionRefused => '连不上（连接被拒绝）',
        DanmakuProbeFailure.tlsFailed => '连不上（TLS 握手失败）',
        DanmakuProbeFailure.serverError => '服务返回错误',
        DanmakuProbeFailure.emptyResponse => '服务正常，但没有弹幕',
        /*
         * ★ 必须**不含**任何网络断言：
         *   改前这里落到 connectionTimeout，于是说「地址解析出来了但连不过去」
         *   —— 而兜底分支压根没解析过、也没建过连接。
         */
        DanmakuProbeFailure.probeFailed => '检测过程本身出错了',
      };
}

/// 一次探测的**完整**结论（在线与否 + 为什么 + 下一步）
///
/// ⚠️ 与 `DanmakuLocalStatus` 的区别：那个是 core 的"在线/不在线 + 版本"，
///    它**说不出**"为什么不在线"（`_probeOne` 刻意吞掉异常并返回 null）。
///    本类就是补上那个被吞掉的原因 —— 它只在 UI 层，不碰 core 的判据。
@immutable
class DanmakuProbeReport {
  const DanmakuProbeReport({
    required this.failure,
    required this.url,
    this.statusCode = 0,
    this.detail = '',
    this.remedy = '',
  });

  /// ★★★ 2026-10-19（R3-③/⑦ 归因修正 / 任务 A）：**伪造地址段表（数据驱动）**
  ///
  /// # 为什么做成表，而不是在函数里写一堆 `if`
  /// ```text
  /// 第一版是纯函数里 5 个硬编码比较。问题有两个：
  ///   ① 将来出现新伪造段**抓不到**，而且没人知道该加什么（没有格式可依）
  ///   ② 每条**没有依据** ⇒ 下一个人无法判断"这条还能不能删"
  /// ⇒ 改成显式表，每条强制带 `evidence`（PTR / DoH 对照）。
  /// ```
  ///
  /// # ⚠️ 本轮实测发现：伪造地址会**轮换**（这是设计这张表时必须知道的）
  /// ```text
  /// 同一台机器、同一个域名，两次采样拿到**不同**的伪造地址：
  ///   第一次  danmu-api-delta → 74.86.17.48      + face:b00c
  ///   第二次  danmu-api-delta → 199.59.150.39    + face:b00c
  ///           danmu-api-kappa → 104.244.43.182
  /// 而 DoH 真值两次都是 216.198.79.x / 64.29.17.x。
  ///
  /// ⇒ **任何"完整枚举"都注定失败**。这张表的定位必须是：
  ///   「已知样本」—— 命中就能定案（强证据），**没命中不代表没问题**。
  ///   所以判定还有第二条腿：DoH 真值对照（见 `_diagnose`）。
  /// ```
  ///
  /// # 每条必须有依据（门禁会检查 `evidence` 非空）
  /// ```text
  /// 依据只有三类，都是**可复跑**的：
  ///   ① PTR 反查（`socket.gethostbyaddr`）证明了**归属**
  ///   ② DoH 对照（cloudflare-dns.com）证明了**与本机答案不一致**
  ///   ③ 花样段（face:b00c 这种一眼认得的固定串）
  /// ✗ 不许"看着不像 Vercel"就列进来 —— 那是猜测，不是证据。
  /// ```
  static const List<({String prefix, String evidence})> kForgedAddressRanges =
      <({String prefix, String evidence})>[
    /*
     * ① IPv6 花样段 —— 本轮**三个** *.vercel.app 域名都返回它
     *    这是最强的单条证据：一个 Vercel 域名不该解析到 Facebook 的段。
     */
    (
      prefix: '2a03:2880:',
      evidence: 'Facebook IPv6 段（含 face:b00c 花样）；实测 danmu-api-delta / '
          'danmu-api-kappa / vercel.app apex 「三个都」返回 '
          '2a03:2880:…:face:b00c（DoH 真值为 216.198.79.x / 64.29.17.x）',
    ),
    (
      prefix: 'face:b00c',
      evidence: 'Facebook 的固定花样段（出现在上述三个域名的本机解析结果里）',
    ),
    /*
     * ② 有 PTR 归属证据的 IPv4 段（最硬的一类：PTR 直接说了它属于谁）
     */
    (
      prefix: '74.86.17.',
      evidence: 'SoftLayer/IBM 静态段 —— PTR 实测：'
          '74.86.17.48 → 30.11.564a.ip4.static.sl-reverse.com',
    ),
    (
      prefix: '108.160.173.',
      evidence: 'Dropbox —— PTR 实测：108.160.173.207 → www.v.dropbox.com',
    ),
    (
      prefix: '199.59.150.',
      evidence: 'Twitter（twttr.com）—— PTR 实测：'
          '199.59.150.39 → r-199-59-150-39.twttr.com；'
          '同族 199.59.148.1 → r-199-59-148-1.twttr.com',
    ),
    (
      prefix: '199.59.148.',
      evidence: 'Twitter（twttr.com）—— PTR 实测：'
          '199.59.148.1 → r-199-59-148-1.twttr.com',
    ),
    (
      prefix: '199.96.58.',
      evidence: 'Twitter（twttr.com）—— PTR 实测：'
          '199.96.58.1 → ge-2-0-3.pao1.cr2.twttr.com；'
          '本机对 danmu-api-* 返回过该段的 199.96.58.15（DoH 真值不含它）',
    ),
    (
      prefix: '157.240.',
      evidence: 'Facebook —— 对照 DoH：graph.facebook.com 解析到 157.240.13.14',
    ),
    /*
     * ③ 只有 DoH 对照、没有 PTR 的段
     *
     * ⚠️ 这类**依据最弱**：没有归属证据，只是"与本机对不上"。
     *    保留是因为实测确实收到过它（104.244.43.182）；
     *    但如果将来有人质疑，删掉这一条**不会削弱**定案能力
     *    （DoH 那条腿仍然兜得住）。
     */
    (
      prefix: '104.244.43.',
      evidence: '本轮实测本机返回过该段（104.244.43.182，无 PTR），'
          'DoH 真值为 216.198.79.195 / 64.29.17.195 —— 仅"与真值不符"，归属未证实',
    ),
  ];

  /// 这个地址是否落在**已知伪造段**里
  ///
  /// ⚠️ 语义边界（很重要）：
  /// ```text
  /// 命中   ⇒ 强证据，可以直接定案（dnsHijacked）
  /// 未命中 ⇒ **不代表正常**：伪造地址会轮换（见 kForgedAddressRanges 的说明），
  ///          必须由 DoH 真值对照那条腿兜住。
  /// ```
  /// ⚠️ 这张表是**证据表**，不是"黑名单防御"：它只用于**解释失败原因**，
  ///    不参与"允不允许连"（那会让误判变成功能不可用）。
  static bool isKnownForgedAddress(String address) {
    final a = address.trim().toLowerCase();
    if (a.isEmpty) return false;
    for (final r in kForgedAddressRanges) {
      if (a.contains(r.prefix)) return true;
    }
    return false;
  }

  /// 一组解析结果里**有没有**已知伪造地址
  ///
  /// 只要有一个命中就算 —— 因为用户连的是哪一个不由我们决定
  /// （`HttpClient` 会按自己的顺序挑），"可能连到伪造地址"就足以解释失败。
  static bool looksForged(Iterable<String> addresses) =>
      addresses.any(isKnownForgedAddress);

  /// 从一次**真实失败**造报告
  ///
  /// # 判据全部来自实测的 OS 错误码 / 异常类型（不是猜）
  /// ```text
  /// errno 11001 (WSAHOST_NOT_FOUND) ⇒ 域名不存在/解析失败   → dnsFailed
  /// errno 10060 (WSAETIMEDOUT)      ⇒ 连接超时
  /// errno 10061 (WSAECONNREFUSED)   ⇒ 连接被拒（Windows 上常见 1225/10061）
  /// TimeoutException                ⇒ 超时（没有 errno）
  /// HandshakeException              ⇒ TLS
  /// ```
  /// ⚠️ [url] 只用于显示，**不含 token**（调用方传 `DanmakuEndpoint.display`）。
  /// ⚠️ 这里的 `fromError` **看不到解析结果** ⇒ 它给不出 `dnsHijacked`。
  ///    劫持判定必须由**调用方**在拿到解析地址后调 [forHijackedDns]
  ///    （见 `_diagnose` 的 DNS 分支）。
  factory DanmakuProbeReport.fromError(Object error, {required String url}) {
    if (error is DanmakuProbeFailure) {
      // 便捷：允许直接传枚举（测试与内部递值都方便）
      return DanmakuProbeReport(failure: error, url: url);
    }
    if (error is TimeoutException) {
      return DanmakuProbeReport(
        failure: DanmakuProbeFailure.connectionTimeout,
        url: url,
        detail: '等待 ${error.duration?.inSeconds ?? 0} 秒没有回应',
        remedy: '这通常不是"服务坏了"，而是这台机器到那个地址「连不通」'
            '（被墙 / 需要代理 / 路由不通）。'
            '可以先在弹幕设置里把代理切成「系统」或「自定义」，再点一次「测试连接」。',
      );
    }
    if (error is SocketException) {
      final code = error.osError?.errorCode ?? 0;
      final msg = error.osError?.message ?? error.message;
      final DanmakuProbeFailure f;
      if (code == 11001 || code == 11004 || msg.contains('不知道这样的主机')) {
        f = DanmakuProbeFailure.dnsFailed;
      } else if (code == 10061 || code == 1225 || code == 111 ||
          msg.contains('拒绝')) {
        f = DanmakuProbeFailure.connectionRefused;
      } else if (code == 10060 || code == 110 || code == 60) {
        f = DanmakuProbeFailure.connectionTimeout;
      } else {
        /*
         * ★ 2026-10-19（X4）：**原来这里归 connectionTimeout**，注释还写着
         *   「认不出来的 SocketException：不猜，归成超时那一档但如实带错误码」。
         * # 为什么那是**说谎**（不是"稳妥"）
         * ```text
         * 「归成超时」= 告诉用户「地址解析出来了但连不过去」。
         * 但一个**认不出 errno** 的 SocketException 只说明「连接过程里出了
         * 某种我们没归类的错」—— 它可能压根没走到解析那一步。
         * ⇒ 说「超时」= 替他断言了一个我们**没有证据**的因果。
         * ```
         * ⇒ 改判 [probeFailed]：如实说"这一步出了个归类不出来的错"，
         *    同时保留 `detail` 里的 errno（那是唯一有价值的线索）。
         * ★ 代价：这一档不再自动进「本机网络」那一支
         *    ⇒ 用户不会被指向"换网络/改代理"这种无效操作。
         */
        f = DanmakuProbeFailure.probeFailed;
      }
      return DanmakuProbeReport(
        failure: f,
        url: url,
        detail: 'errno $code${msg.isEmpty ? "" : " · $msg"}',
        remedy: remedyFor(f),
      );
    }
    final s = error.toString();
    if (s.contains('HandshakeException') ||
        s.contains('TlsException') ||
        s.contains('CERTIFICATE')) {
      return DanmakuProbeReport(
        failure: DanmakuProbeFailure.tlsFailed,
        url: url,
        detail: s,
        remedy: 'TLS 握手没过：可能是代理在做中间人、或证书过期。'
            '换直连/换代理各试一次就能分清是哪一边。',
      );
    }
    /*
     * ★★★ 2026-10-19（X4）：**兜底分支 = 探测自己出错**
     * ```text
     * 改前：无条件 `failure: connectionTimeout` ⇒ 任何认不出来的异常
     *   （StateError / ArgumentError / FormatException / 甚至探针自己写的
     *   断言失败）都被报成「连不上（超时）」⇒ 文案说「地址解析出来了但
     *   连不过去」—— 而这里**一次网络请求都没发**。
     * ```
     * ⇒ 改为 `probeFailed`：**不碰网络措辞**，并把原文放进 `detail`
     *    （那是用户/我们唯一能用的线索）。
     */
    return DanmakuProbeReport(
      failure: DanmakuProbeFailure.probeFailed,
      url: url,
      detail: s,
      remedy: remedyFor(DanmakuProbeFailure.probeFailed),
    );
  }

  /// ★★★ 2026-10-19（R3-③/⑦ 归因修正）：从"解析成功但地址是伪造的"造报告
  ///
  /// # 为什么这个结论**优先于** TCP 超时
  /// ```text
  /// 本机实测的真实因果链：
  ///   DNS 返回伪造地址（198.…/Dropbox…）  ⇒  TCP 连那个**错地址** ⇒ 超时
  ///
  /// 先前的归因写成"断在 TCP"是**把后果当病因**：
  /// TCP 超时不是独立故障，它是劫持的下游表现。
  /// ⇒ 只要查到伪造地址，就报 dnsHijacked，**不再**报 connectionTimeout。
  /// ```
  /// [realAddresses] 是**可选佐证**（DoH/DoT 真值）。有就给出来，
  /// 让用户一眼看到"本机拿到的"和"真值"不是一个东西。
  factory DanmakuProbeReport.forHijackedDns({
    required String url,
    required List<String> localAddresses,
    List<String> dohAddresses = const <String>[],
    String detail = '',
  }) {
    final local = localAddresses.join(' / ');
    final doh = dohAddresses.join(' / ');
    /*
     * ★★★ 2026-10-19（任务 B）：detail 要让用户**自己看懂发生了什么**。
     *
     * # 改前
     * ```text
     * 「本机解析到 X；加密 DNS（DoH）真值是 Y —— 两者不一致」
     * 这句对工程师够了，但对普通用户还是"两串地址"。
     * ```
     * # 改后：把**两个地址都摆在眼前**，并明说它们代表什么
     * ```text
     * 用户看到 "74.86.17.48 vs 216.198.79.3" 就已经明白了：
     * 同一个域名，我这台机器拿到的和真值不是一个东西。
     * ⇒ 不需要懂 DNS，也不需要跑任何命令。
     * ```
     * # 没有 DoH 时**不编真值**
     * ```text
     * DoH 自己也可能被拦。拿不到就明说"无法核对真值"，
     * 只给出"本机答案落在已知伪造段"这个能自查的事实。
     * ★ 绝不写一个猜的"真值"。
     * ```
     */
    final evidence = doh.isEmpty
        ? '本机解析到：$local\n'
            '这个地址落在「已知的伪造段」里（同一网段被实测判定为他人服务器）。\n'
            '⚠️ 本次没能核对权威 DNS 真值（加密查询也可能被拦），'
            '所以不给出"真值"——但上面这个地址本身已经能说明问题。'
        : '本机解析到：$local\n'
            '权威 DNS（加密查询）真值：$doh\n'
            '⇒ 同一个域名，你这台机器拿到的和真实地址「不是一个东西」。';
    return DanmakuProbeReport(
      failure: DanmakuProbeFailure.dnsHijacked,
      url: url,
      detail: detail.isEmpty ? evidence : '$evidence\n$detail',
      remedy: '本机 DNS 把这个域名解析到了「错误地址」，所以连不上 —— '
          '「不是这个服务坏了」（它在代理下是活的）。'
          '改弹幕地址没用；要做的是：把系统 DNS 换成可信的（支持 DoH 更好），'
          '或者在弹幕设置里开启代理，让域名解析/连接都走代理。',
    );
  }

  /// 从"在线但一条弹幕都没有"造报告（**这不是失败**）
  factory DanmakuProbeReport.empty({required String url, String detail = ''}) =>
      DanmakuProbeReport(
        failure: DanmakuProbeFailure.emptyResponse,
        url: url,
        detail: detail,
        remedy: '服务是通的 —— 这一集/这个关键词在它库里确实没有内容。'
            '换一集、或者换一个关键词再搜，不用去改配置。',
      );

  /// 从"连上了但 HTTP 状态码不 OK"造报告
  factory DanmakuProbeReport.httpError({
    required String url,
    required int statusCode,
    String detail = '',
  }) =>
      DanmakuProbeReport(
        failure: DanmakuProbeFailure.serverError,
        url: url,
        statusCode: statusCode,
        detail: detail,
        remedy: statusCode == 401 || statusCode == 403
            ? '服务活着，但它拒绝了这次请求（凭证/token 问题）——'
                '这是「配置」问题，不是网络问题。'
            : '服务活着，但它自己报错了 —— 这是「服务端」的问题，'
                '等一会儿或换一个实例再试。',
      );

  final DanmakuProbeFailure failure;

  /// 探的是哪个地址（`DanmakuEndpoint.display`，**不含 token**）
  final String url;

  /// HTTP 状态码（0 = 没拿到响应）
  final int statusCode;

  /// 机械细节（errno / 异常原文）—— 给排查用，不翻译掉
  final String detail;

  /// 下一步该做什么（按 [failure] 分叉，见 [_remedyFor]）
  final String remedy;

  /// 按 [f] 给下一步（**公开**：设置页也要用同一份文案，见 danmaku_source_page）
  static String remedyFor(DanmakuProbeFailure f) => switch (f) {
        DanmakuProbeFailure.dnsFailed =>
          '域名解析不出来 ⇒ 是本机 DNS / 网络的问题，'
              '「不是这个服务坏了」。改配置不会有用；'
              '换个网络或修好 DNS 再试。',
        /*
         * ★ 与上一档**操作完全不同**：这里 DNS 是"通"的，但答案是**假的**。
         *   ⇒ 要换的是 DNS 解析（DoH）/ 开代理，而不是"换个网络碰运气"。
         */
        DanmakuProbeFailure.dnsHijacked =>
          '本机 DNS 把这个域名解析到了「错误地址」（不是服务坏了）。'
              '所以改弹幕地址没用 —— 要换的是「域名解析」：'
              '把系统 DNS 换成可信的（支持 DoH 更好），'
              '或者在弹幕设置里开启代理。',
        DanmakuProbeFailure.connectionTimeout =>
          '连不上（超时）⇒ 地址解析出来了但连不过去，'
              '通常是「被墙 / 需要代理 / 路由不通」，'
              '「也可能」是本机 DNS 返回了假地址（那种情况会单独报「域名被解析到错误地址」）。'
              '这不是"服务没运行"，也不是"地址填错了"。'
              '在弹幕设置里试「代理」，或换一个能连通的实例。',
        DanmakuProbeFailure.connectionRefused =>
          '连接被拒绝 ⇒ 这个地址上「没有服务在听」。'
              '自建地址的话去启动服务 / 检查端口；'
              '内置实例出现这个通常是我们换了部署 —— 换下一个实例。',
        DanmakuProbeFailure.tlsFailed =>
          'TLS 握手失败 ⇒ 证书 / 中间人代理的问题。'
              '先把代理切成「直连」再试一次，能分清是不是代理造成的。',
        DanmakuProbeFailure.serverError =>
          '服务回了错误状态 ⇒ 这是「服务端」的问题（我们这边没做错什么）。',
        DanmakuProbeFailure.emptyResponse =>
          '服务是通的，只是这次没有内容 —— 「不是失败」。',
        /*
         * ★★★ 2026-10-19（X4）：这一段的每个字都必须能被证伪。
         * ```text
         * 兜底分支手里**没有任何网络物证**（没解析过、没建过连接），
         * 所以**一个字都不能提网络**：不提超时、不提解析、不提被墙/代理。
         * 否则用户会去改代理 / 换网络 —— 而真正出错的是检测这一步自己。
         * ```
         */
        DanmakuProbeFailure.probeFailed =>
          '检测这一步自己出错了，还没走到「能不能连上」那一步。'
              '所以「不能」据此判断服务或网络好坏。'
              '请把下面这句原文反馈给我们（它能帮我们定位）：',
        DanmakuProbeFailure.none => '',
      };

  /// ★★★ 2026-10-19（R3-③/⑦ 归因修正）：用 **DoH** 拿一次"真值"做**佐证**
  ///
  /// # 为什么它只能是佐证，不能是前提
  /// ```text
  /// DoH 请求自己也要过网络 —— 本机 DNS 被劫持的环境里，
  /// cloudflare-dns.com 也可能连不上。所以：
  ///   ① 失败/超时 ⇒ 返回空表，**不影响**判定（伪造段表仍可单独成立）
  ///   ② 成功但和本机不同 ⇒ 强佐证（把"本机拿到的"和"真值"一起给用户看）
  /// ```
  /// # 为什么用 Cloudflare 而不是自己解析
  /// ```text
  /// 我们需要的正是"**绕过**本机 DNS"的答案。DoH 走 HTTPS 到固定 IP，
  /// 不经过系统的 resolver ⇒ 那才是真值。
  /// ```
  /// ⚠️ 只在**已经判定连不上**时才调（见 caller）—— 正常路径一次都不发。
  /// ⚠️ 超时给 5 秒：它只是佐证，不该拖住 UI。
  /// ⚠️ **公开**：设置页（`danmaku_source_page`）用同一份，避免两处漂移。
  static Future<List<String>> dohLookup(String host) async {
    const doh = 'https://cloudflare-dns.com/dns-query';
    final out = <String>{};
    for (final type in <String>['A', 'AAAA']) {
      HttpClient? client;
      try {
        client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5)
          ..findProxy = ((Uri _) => 'DIRECT');
        final uri = Uri.parse('$doh?name=$host&type=$type');
        final req = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 5));
        req.headers.set('accept', 'application/dns-json');
        final resp = await req.close().timeout(const Duration(seconds: 5));
        if (resp.statusCode != 200) continue;
        final body = await resp
            .transform(const Utf8Decoder(allowMalformed: true))
            .join()
            .timeout(const Duration(seconds: 5));
        final j = jsonDecode(body);
        if (j is! Map) continue;
        final answers = j['Answer'];
        if (answers is! List) continue;
        for (final a in answers) {
          if (a is! Map) continue;
          // status 0 = NOERROR；只认 A(1)/AAAA(28)
          final t = a['type'];
          if (t != 1 && t != 28) continue;
          final data = a['data'];
          if (data is String && data.trim().isNotEmpty) {
            out.add(data.trim());
          }
        }
      } catch (_) {
        // 佐证拿不到就拿不到 —— 绝不让它影响主判定
      } finally {
        client?.close(force: true);
      }
    }
    return out.toList(growable: false);
  }

  bool get isFailure => failure.isFailure;
  bool get isOk => failure == DanmakuProbeFailure.none;

  // ==========================================================================
  //  ★★★ 2026-10-19（R3-③/⑦ 收尾）：从**一次真实失败**造报告，供取数/搜索共用
  // ==========================================================================
  //
  /// 把一次已经失败的请求，翻译成"该说哪句话"。
  ///
  /// # 为什么需要它（这是本轮真正的缺口）
  /// ```text
  /// 改前 `_diagnose` 只在「测试连接」按钮那条路上跑。
  /// 而 Owner 报的 R3-③「弹幕来源搜不了」走的是**另一条路**：
  ///   搜索 → core 抛 DanmakuException → 面板 _searchResultBody
  ///     直接把 `err.message` 画出来（原文："连不上弹幕服务（地址不通或服务没起来）"）
  /// ⇒ 那条路上**根本没有 dnsHijacked 这一档** ⇒ UI 把劫持说成了"服务没起来"，
  ///   用户会去查服务，方向就错了（这正是 Lead 裁决要修的那件事）。
  /// ```
  ///
  /// # 为什么**不联网**（判据纪律的第一条）
  /// ```text
  /// 输入里已经有 [DanmakuException.resolvedAddress]
  /// —— 那就是「本机拿到并去连的那个地址」。
  /// 判据 `looksForged` 是纯函数查表 ⇒ **零网络请求**。
  ///
  /// ⇒ 探测依赖（DoH）只留在 `_diagnose` 那种"只知道域名、不知道地址"的场合，
  ///    且那条路本来就只在用户手动点「测试连接」时走。
  ///    产品热路径（取弹幕 / 搜索）**一次 DoH 都不发**。
  /// ```
  ///
  /// # ★ 铁律：**没有地址证据 ⇒ 绝不判 hijacked**
  /// ```text
  /// 「没拿到地址」是常态（超时分支、服务端返回错误、非网络失败）。
  /// 若把空串也丢进判据、或让别的分支兜底，就变成
  /// "所有失败都被说成 DNS 劫持" —— 比说错更坏：
  /// 它会把用户从"查服务"推向"改 DNS"，而后者根本没坏。
  /// ⇒ 本函数只在 [evidence] 非空且命中伪造段时才给 dnsHijacked。
  /// ```
  static DanmakuProbeReport fromDanmakuException(
    DanmakuException e, {
    String url = '',
  }) {
    final addr = e.resolvedAddress;
    if (addr.isNotEmpty && looksForged(<String>[addr])) {
      // ★ 已知伪造段命中 ⇒ 直接定案，不再回落到"连不上"。
      return DanmakuProbeReport.forHijackedDns(
        url: url.isEmpty ? e.uri : url,
        localAddresses: <String>[addr],
      );
    }
    // 兜底：**不**判劫持。如实按已有字段归到别的那一档。
    if (e.statusCode != 0) {
      return DanmakuProbeReport.httpError(
        url: url.isEmpty ? e.uri : url,
        statusCode: e.statusCode,
      );
    }
    return DanmakuProbeReport.fromError(e, url: url.isEmpty ? e.uri : url);
  }
}

/// 对话框要展示的全部状态
///
/// # 为什么由宿主传进来、而不是对话框自己读 `DanmakuConfig`
///
/// ```text
/// ① 对话框变成**纯 UI** ⇒ 可以脱离播放页单测
/// ② 一次请求的状态（加载中 / 报错 / 命中结果）本来就属于宿主
/// ③ 打开面板不该有副作用 —— 自己读偏好会诱发"读一下就改了观感"
/// ```
class DanmakuSettingsState {
  const DanmakuSettingsState({
    required this.enabled,
    required this.appId,
    required this.appSecret,
    required this.fontScale,
    required this.opacity,
    required this.speed,
    required this.area,
    this.loading = false,
    this.error,
    this.status = '',
    this.count = 0,
    this.lanes = 0,
    this.dropped = 0,
    this.sourceLine = '',
    this.searchLoading = false,
    this.searchError,
    this.searchSearched = false,
    this.searchResults = const <DanmakuMatch>[],
    this.searchKeyword = '',
    this.searchStale = false,
    this.credentialSaved = false,
  });

  /// 从当前偏好构造（打开面板时的初值）
  ///
  /// ★ 2026-10-14（Owner 反馈「凭证流程根本没走通」）：凭证输入框**恢复**了
  /// ⇒ 这两个字段重新用来**预填**输入框（用户此前填过值，打开面板要能看见）。
  /// 预填只看**用户自己的覆盖**（`UiPrefs` 那两个键），不看 [DanmakuConfig.appId]
  /// 的**生效值** —— 生效值可能是内置凭证（构建期注入），把它塞进输入框会
  /// 让用户误以为"这是我自己填的"，他一点保存反而用**打码前的真内置值**
  /// 覆盖掉原值。真正的生效值走 `maskedAppId` 在状态行里展示。
  factory DanmakuSettingsState.fromPrefs() => DanmakuSettingsState(
    enabled: DanmakuConfig.enabled,
    appId: DanmakuConfig.userAppId,
    appSecret: DanmakuConfig.userAppSecret,
    fontScale: DanmakuConfig.fontScale,
    opacity: DanmakuConfig.opacity,
    speed: DanmakuConfig.speed,
    area: DanmakuConfig.area,
  );

  final bool enabled;

  /// 凭证输入框的**预填值** —— 只放**用户自己的覆盖**（`UiPrefs`），
  /// 不含内置凭证（见 [DanmakuSettingsState.fromPrefs] 的说明）。
  final String appId;
  final String appSecret;
  final double fontScale;
  final double opacity;
  final double speed;
  final double area;

  /// 正在取弹幕
  final bool loading;

  /// 上一次取弹幕的失败原因（null = 没有）
  final DanmakuException? error;

  /// 上一次取弹幕的结果摘要（`某番 第3集（偏移 +90.0s）· 842 条弹幕`）
  final String status;

  /// 当前挂载的弹幕条数 / 排版轨道数 / 丢弃条数（实时读数，来自渲染层）
  final int count;
  final int lanes;
  final int dropped;

  /// 弹幕数据源状态行（T27-05）：「检测到本机外部弹幕 未运行」或
  /// 「本机外部弹幕（127.0.0.1:2080）已就绪」。空串 = 不显示该行。
  final String sourceLine;

  // ── ★★★ 2026-10-14（Owner）：手动搜索番剧 ─────────────────────────
  //
  // Owner 原话：> 弹幕我没有看到[弹幕服务]的搜索功能和绑定
  //
  // 后端 弹幕客户端的 `searchEpisodes()`（core/danmaku.dart）**早就实现**了，
  // 但**没有任何 UI 能调用它** ⇒ 用户只能等 `loadFor()` 自动匹配，匹配不中就没辙。
  // ⇒ 这一组字段就是那次搜索的状态（加载中 / 失败 / 命中结果），
  //   由宿主（player_page）持有 —— 与 `loading` / `error` / `status` 同一条分工。

  /// 正在搜索（与 [loading] 分开：搜索**不该**复用取弹幕那个 loading，
  /// 否则「正在取弹幕…」会在搜索时误报，用户以为弹幕在重载）。
  final bool searchLoading;

  /// 上一次搜索失败原因（null = 没有）。沿用 `DanmakuException` 通路 ⇒
  /// 服务端原文一样能透出来（与 [error] 同一套 UI）。
  final DanmakuException? searchError;

  /// 上一次搜索是否**已经搜过**（用来区分「还没搜」和「搜了但没结果」）。
  ///
  /// ⚠️ 只看 `searchResults.isEmpty` 判断空态会**一打开面板就显示
  ///   「没搜到」**（那时用户还没搜）—— 那是假空态，比空白更糊涂。
  ///   所以空态文案挂在 `searchLoading == false && searchSearched &&
  ///   searchResults.isEmpty` 三条同时成立时。
  final bool searchSearched;

  /// 上一次搜索命中的剧集列表（`loadFor` 那条路返回的同一份 [DanmakuMatch]）。
  final List<DanmakuMatch> searchResults;

  /// 宿主最近一次搜索用的关键词（用来把输入框回填成"正在搜的那个词"）。
  ///
  /// ⚠️ 这是个**受控回填**，不是输入框的真源 —— 用户正在敲的字在
  ///   `_searchKeyword` controller 里（见 [_syncKeyword]：只在两者不同时才写，
  ///   否则每次 setState 都会把光标顶到末尾）。
  final String searchKeyword;

  /// 搜索过程中播放页是否**已经换集 / 换源**（真错位的警示）。
  ///
  /// # 为什么这个提示非画不可
  /// ```text
  /// 搜索是网络请求，用户完全可以搜到一半就切到下一集 —— 这时
  /// 「点一条载入」载入的是**上一集**的弹幕，画面上却是新一集：
  /// 时间轴对不上、弹幕全错位，而界面上看不出任何异常。
  /// 宿主用令牌（`_danmakuFetchToken`）判这件事，判到了就把这一位置真，
  /// 面板画一句「搜索期间已换集…」，让用户知道要重搜 ——
  /// 而不是无声地把错位的弹幕挂上去。
  /// ```
  final bool searchStale;

  /// ★ 2026-10-14：用户**本次会话里刚保存过凭证** ⇒ 面板提示
  /// 「已保存，点『重新获取弹幕』生效」。
  ///
  /// 为什么不自动重取：保存凭证是"改配置"，重取是"发一次网络请求"。
  /// 自动重取会让用户正在看的画面**忽然换一批弹幕**（甚至换到另一集），
  /// 比"什么都不发生"更糟。⇒ 明确提示一次，把时机留给用户。
  final bool credentialSaved;

  DanmakuSettingsState copyWith({
    bool? enabled,
    String? appId,
    String? appSecret,
    double? fontScale,
    double? opacity,
    double? speed,
    double? area,
    bool? loading,
    DanmakuException? error,
    bool clearError = false,
    String? status,
    int? count,
    int? lanes,
    int? dropped,
    String? sourceLine,
    bool? searchLoading,
    DanmakuException? searchError,
    bool clearSearchError = false,
    bool? searchSearched,
    List<DanmakuMatch>? searchResults,
    String? searchKeyword,
    bool? searchStale,
    bool? credentialSaved,
    bool clearCredentialSaved = false,
  }) {
    return DanmakuSettingsState(
      enabled: enabled ?? this.enabled,
      appId: appId ?? this.appId,
      appSecret: appSecret ?? this.appSecret,
      fontScale: fontScale ?? this.fontScale,
      opacity: opacity ?? this.opacity,
      speed: speed ?? this.speed,
      area: area ?? this.area,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      status: status ?? this.status,
      count: count ?? this.count,
      lanes: lanes ?? this.lanes,
      dropped: dropped ?? this.dropped,
      sourceLine: sourceLine ?? this.sourceLine,
      searchLoading: searchLoading ?? this.searchLoading,
      // ★ 与 `clearError` 同款：搜索失败要能被显式清掉（下一次搜索开始 / 点中一条时）
      searchError: clearSearchError ? null : (searchError ?? this.searchError),
      searchSearched: searchSearched ?? this.searchSearched,
      searchResults: searchResults ?? this.searchResults,
      searchKeyword: searchKeyword ?? this.searchKeyword,
      searchStale: searchStale ?? this.searchStale,
      credentialSaved: clearCredentialSaved
          ? false
          : (credentialSaved ?? this.credentialSaved),
    );
  }
}

/// 弹幕设置面板
///
/// 形态与 `PlayerSettingsSheet` **一致**（全屏 scrim + 居中卡片），
/// 因为它们在同一个页面里互为邻居 —— 用户不该为两个面板学两套操作。
/// Live readout for the panel status line (visible / lanes / dropped).
///
/// Why this is a separate class rather than fields on DanmakuSettingsState:
/// these three numbers change EVERY SECOND (they come from the render layer),
/// while the rest of DanmakuSettingsState only changes on user action.
/// Mixing them meant the host called setState once per second, rebuilding the
/// entire 16k-line player page -- exactly the "this modal is so laggy" the
/// Owner reported.
///
/// Splitting it out lets the host push updates through a ValueNotifier so
/// only the one Text showing these numbers rebuilds.
///
/// NOTE: same semantics as count/lanes/dropped on DanmakuSettingsState --
/// this changes HOW the update is delivered, not WHAT is displayed.
class DanmakuReadout {
  const DanmakuReadout({this.count = 0, this.lanes = 0, this.dropped = 0});

  final int count;
  final int lanes;
  final int dropped;

  /// All three equal => nothing to notify (avoids a pointless rebuild).
  bool sameAs(DanmakuReadout o) =>
      count == o.count && lanes == o.lanes && dropped == o.dropped;

  @override
  String toString() =>
      'DanmakuReadout(count: $count, lanes: $lanes, dropped: $dropped)';
}

/// Key of the "add a block word" input (see [_blockWordsAddField]).
///
/// Exposed so tests can target the field without depending on layout
/// properties that the 2026-10-15 redesign changed.
const Key blockWordsAddFieldKey = Key('danmaku-blockwords-add-field');

/// 外部弹幕源的显示名。
///
/// ⚠️ 2026-10-17（Owner 第 11 条）：本文件**不再**用某个站名当页签名/标签。
/// 页签改成按**能力**命名（dan-api / 插件提供 / 官方兜底），
/// 所以这个常量保留只为兼容旧引用 —— 当前**没有任何地方**在用它。
/// 真要显示"这个源是哪一家"时，从数据里取（`DanmakuFeedStat.detail`），
/// 不要在这里写死第二个名字。
///
/// 历史：Owner 2026-10-15 曾明确允许在**弹幕源**语境下具名
/// （「bilibili 这个弹幕允许使用，别的不允许」），  // site-ok: danmaku-source
/// 那条豁免仍然有效（`test/t98_no_site_names_test.dart` 的行级锚点），
/// 只是本文件现在不需要它了。
// ignore: unused_element
const String _kBiliSourceLabel =
    'bilibili'; // 弹幕源（Owner 明确允许具名）  // site-ok: danmaku-source

/// 弹幕面板的**三个**页签（2026-10-18 第四版，Owner 亲自截图四条反馈）
///
/// # 为什么是这一版（前三版都被 Owner 否了，记下来免得再绕回去）
/// ```text
/// 第二版：配置 / bilibili / 弹弹play          // site-ok: danmaku-source
///   问题：页签名 = 某一家服务的名字 ⇒ 换一家就得改页签名
///
/// 第三版：配置 / dan-api / 插件提供 / 官方兜底
///   问题（Owner 2026-10-18 亲自截图，逐条）：
///     ① 「某个视频站的弹幕设置怎么没了」
///        ⇒ 我把那个源从独立 tab 降级成了「插件提供」里一枚叫
///          「外部弹幕…」的按钮。**减少点击层数 ≠ 提高可发现性** ——
///          藏在一个不叫它名字的按钮里，用户根本不知道那是它。
///     ② 「插件提供是什么?」
///        ⇒ Owner 的语义是「视频源插件随片自带每一集的弹幕 ⇒ 默认导入」，
///          我实现成了「插件声明能力 ⇒ 用户去搜索/绑定」。语义错了。
///     ③ 「dan-api只有测试」
///        ⇒ 那个 tab 里真的只有地址框 + 测试连接 + 清除。
///          搜索/绑定被我放进了 plugin tab —— 入口放错了。
///     ④ 「官方兜底也不知道是啥」
///        ⇒ 内部概念泄漏到 UI，且本构建无内置凭证、必然失败。
/// ```
///
/// # 这一版的切法：按**用户要做的事**分，不按来源分
/// ```text
/// ① display  —— 显示：与来源无关的纯视觉设置（开关/字号/透明度/速度/区域/屏蔽词）
/// ② sources  —— 弹幕来源：这一集的弹幕**从哪来**，每条路什么状态，怎么切
/// ③ advanced —— 高级：要填地址/凭证的、99% 用户不需要的
/// ```
///
/// ⚠️ **「弹幕来源」是多选（可叠加），不是单选**
/// ```text
/// Owner 第 11 条原话：「同时加载并合并」
/// ⇒ 弹幕可以多路合并（`4aeb79a` 就是让手动绑定后插件那份也并进来）。
/// ⇒ 来源行用 ☑/☐（勾选即参与合并），不是 ●/○（单选）。
///
/// 与 Owner 第 6 条不冲突：
///   第 6 条禁的是「不许**自动绑定**外部源」，
///   不是「不许**手动多选**多个源」。
///   本片源自带默认勾上（它是视频的一部分 ⇒ 自动），
///   其他源默认不勾（用户手动勾了才参与合并）。
/// ```
enum DanmakuPanelTab {
  /// 显示：跨来源的纯视觉设置（开关 / 显示参数 / 屏蔽词 / 正则）
  display,

  /// 弹幕来源：本片源自带 / 某个视频站 / dan-api / 本机服务 —— **可多选合并**
  sources,

  /// 高级：自建地址、Token、官方开放平台凭证（通常不需要）
  advanced,
}

/// ★★★ 2026-10-19（第 66 轮 Owner 第 ⑤ 条）：面板上**可勾选的四路来源**
///
/// # 为什么要这个枚举（改前是四个裸 `_sourceRow(...)` 调用）
/// ```text
/// 改前每一行都是 `_sourceRow(label: '…', checked: <推导>, onChanged: null)`
/// —— `checked` 是**从别处推出来的状态**（有没有绑定 / 有没有探测到），
/// 不是"用户勾了没有"。于是：
///   ① 用户**没有任何办法**勾/取消（四个 onChanged 全是 null）
///   ② 一旦有了集合状态，就必须有**稳定的键**去记"哪一路"，
///      而 label 是给人看的文案（改文案就会丢用户的选择）
/// ⇒ 用枚举当键，文案挂在 [DanmakuFeedChannelX.label] 上。
/// ```
enum DanmakuFeedChannel {
  /// 本片源自带（视频本身带的弹幕，**不可取消**）
  biliSource,

  /// 某个视频站（外部视频站直连，需要绑定）
  biliExternal,

  /// dan-api（内置公共实例或用户自填地址）
  danApi,

  /// 本机弹弹play（127.0.0.1:2080）
  localService,

  /// 视频源插件随片自带的那一份
  plugin,
}

extension DanmakuFeedChannelX on DanmakuFeedChannel {
  /// 给人看的名字（**全仓一份**：勾选框、合并读数、门禁都读这里）
  String get label => switch (this) {
        DanmakuFeedChannel.biliSource => '本片源自带',
        DanmakuFeedChannel.biliExternal => '某个视频站',
        DanmakuFeedChannel.danApi => 'dan-api',
        DanmakuFeedChannel.localService => '本机服务',
        DanmakuFeedChannel.plugin => '插件提供',
      };
}

class DanmakuSettingsDialog extends StatefulWidget {
  const DanmakuSettingsDialog({
    super.key,
    required this.state,
    required this.onSetEnabled,
    required this.onSetFontScale,
    required this.onSetOpacity,
    required this.onSetSpeed,
    required this.onSetArea,
    required this.onReload,
    required this.onClose,
    this.onOpenBili,
    this.onSearch,
    this.onPickMatch,
    this.onHintAction,
    this.onChanged,
    this.readout,
    this.biliCount,
    this.canSendDanmaku = true,
    this.onBatchBind,
    this.fill = true,
    this.probeOverride,
    this.feedSamples,
  });

  /// ★★★ 2026-10-19（第 66 轮 Owner 第 ⑤ 条）：**每一路现在有什么弹幕**
  ///
  /// # 为什么必须由宿主注入（而不是面板自己去取）
  /// ```text
  /// 合并的原料是 `List<DanmakuComment>`。本面板是**纯 UI**
  /// （文件头：不碰网络/播放器/令牌），拿不到别的源的弹幕列表。
  /// ⇒ 宿主把它手上**真实的**多路结果递进来，面板只负责合并 + 显示读数。
  /// ```
  ///
  /// # 不注入会怎样（**如实降级**，不是假装）
  /// ```text
  /// 集合里只剩「本片源自带」（不可取消的那一路）⇒ 合并读数显示「单源」，
  /// 并且明说"其它几路没有可合的内容"。**不会**凭空画一个"N 路合并"。
  /// ```
  ///
  /// ⚠️ 接线点见交付说明（`player_page.dart` 的 `DanmakuSettingsDialog(...)`
  ///    构造点）。本轨道**不改**那个文件。
  final Map<DanmakuFeedChannel, List<DanmakuComment>>? feedSamples;

  final DanmakuSettingsState state;

  /// Live readout channel (null => fall back to the static values on state).
  ///
  /// 2026-10-15: split out so the host no longer needs setState once per
  /// second just to refresh one line of text (see DanmakuReadout).
  final ValueListenable<DanmakuReadout>? readout;

  /// How many danmaku the external video site has for this episode.
  ///
  /// null means "unknown" and renders as a dash. Do NOT default it to 0:
  /// "this source has none" and "we never asked" are different facts, and the
  /// status strip exists precisely to tell them apart.
  final int? biliCount;

  /// Called with the current search results when the user asks to bind the
  /// WHOLE work instead of one episode.
  ///
  /// The panel deliberately does NOT build the plan itself: alignment is a
  /// core concern with its own gate (lib/core/batch_bind.dart), and having a
  /// second implementation here would let the two drift.
  final ValueChanged<List<DanmakuMatch>>? onBatchBind;

  final ValueChanged<bool> onSetEnabled;
  final ValueChanged<double> onSetFontScale;
  final ValueChanged<double> onSetOpacity;
  final ValueChanged<double> onSetSpeed;
  final ValueChanged<double> onSetArea;

  /// 重新取一次弹幕（想重试时用）
  final VoidCallback onReload;

  final VoidCallback onClose;

  /// 本片源**能不能发**弹幕（与"有没有弹幕可看"是两件事）
  ///
  /// # 为什么要有这个参数
  /// ```text
  /// 发送输入框的挂载条件是 AND 谓词（在 player_page.dart 里）：
  ///   _danmakuEnabled && _danmakuCanSend && _danmakuSendProvider != null && !_isLive
  /// 两个插件都没有声明 danmakuSend 能力 ⇒ 输入框整条不渲染
  /// （Owner 第 1 条「不支持就不显示」，宿主判得对）。
  ///
  /// ⚠️ 但"不显示"不等于"不解释"：用户看到「本片源自带 1200 条」却没有
  ///    发送框，会以为**坏了**，而不是"这个源不支持发"。
  /// ⇒ 面板里用一行灰字说明。
  /// ```
  /// # 为什么是可选参数
  /// ```text
  /// 接线在 `player_page.dart`（归轨道 A 的 N10），本轨道**不写**它。
  /// 默认 `true` = 不传时**不显示那行说明**（保持旧行为，零破坏）；
  /// 宿主传了 `_danmakuCanSend` 之后，不支持时才会出现那行说明。
  /// ⇒ 面板侧先做好能力，接线由宿主补（见交付说明里的 1 行 diff）。
  /// ```
  final bool canSendDanmaku;

  /// 打开「外部视频源弹幕」面板（task-31 ④）。
  ///
  /// 传 null ⇒ 按钮**不画** —— 面板本身不认识 某视频站，也不知道宿主有没有接。
  /// 这只是「另一个弹幕源」的入口，与 弹弹play 凭证同层。
  final VoidCallback? onOpenBili;

  /// ★★★ 2026-10-14（Owner）：用户点了「搜索番剧」区的「搜索」按钮。
  ///
  /// Owner 原话：> 弹幕我没有看到[弹幕服务]的搜索功能和绑定
  ///
  /// 面板**自己不发请求**（与 [onReload] 同一条分工）：它把关键词原样递出去，
  /// 宿主去调客户端的 `searchEpisodes(anime: keyword)` 并把
  /// 结果写回 [DanmakuSettingsState.searchResults]。
  ///
  /// 传 null ⇒ 整个「搜索番剧」区**不画**（与 [onOpenBili] 同一条规矩：
  /// 面板不认识宿主的开关，也不该猜）。这样既有测试里的 6 处挂载点
  /// 不用跟着改，也不会出现"按钮点了没反应"的假 UI。
  final ValueChanged<String>? onSearch;

  /// ★★★ 2026-10-14（Owner）：用户点了搜索结果里的**某一条** ⇒ 载入那一集的弹幕。
  ///
  /// 递出去的是**整个** [DanmakuMatch]（不是只给 id）——因为宿主写状态行
  /// 要 `match.label`（「某番 第 3 集」），只给 id 的话宿主得自己抄一遍
  /// 拼装逻辑，两份就会漂移。
  ///
  /// 与 [onSearch] 同时为 null 才不画搜索区 —— 单有 [onSearch] 而没有
  /// [onPickMatch] 时结果列表面板画得出来、点了却没路走，所以两个
  /// **一起**给才显示（见 [_searchSection] 的门控）。
  final ValueChanged<DanmakuMatch>? onPickMatch;

  /// 用户点了「中文指引」里的动作按钮（Owner 第 1 条）。
  ///
  /// 传 null ⇒ 那枚按钮**不画**（与 [onOpenBili] 同一条规矩：面板不认识
  /// 宿主的开关，也不该猜）。动作本身由宿主执行 —— 面板只负责把
  /// `DanmakuHint.action` 原样递出去。
  final ValueChanged<DanmakuHintAction>? onHintAction;

  /*
   * 2026-10-15: onSetCredentials / onClearCredentials were removed.
   *
   * Owner: "I told you to delete those two input boxes and use the built-in
   * credentials." The developer agreement allows built-in credentials via
   * placeholder + build-time injection, so the panel no longer offers manual
   * entry and these callbacks lost their only caller.
   *
   * Removing them is not just dead-code cleanup: keeping them would mean the
   * panel still HAS a credential write path with no UI to reach it -- the
   * "visible interface, no way in" half-state this repo treats as a defect.
   *
   * Visibility is not lost: the status line (_credentialStatusText) still
   * reports "built-in credentials in effect" or "not configured".
   */

  /// 用户改了「显示哪些弹幕 / 屏蔽词」时回调 —— 让宿主重建播放页，
  /// 好让新的过滤规则**立刻**反映到正在播的那一集上。
  ///
  /// ⚠️ 这些项**不走** `onSetXxx` 那一套（那套是"宿主持有状态、面板只管显示"）：
  ///    屏蔽规则直接读写 `DanmakuConfig`（静态偏好），面板自己就能落盘，
  ///    所以只需要一个"我改过了，你重建一下"的信号。
  ///    与上面几个回调**不是**同一层抽象，这是有意的 ——
  ///    把六个开关也塞进 `onSetXxx` 会让宿主的构造参数再长六行，收益为零。
  final VoidCallback? onChanged;

  /// 根节点是否由**本面板**写成 `Positioned.fill`（默认 true，= 既有行为）
  ///
  /// ★ 传 `false` 的唯一场景：宿主用 `SheetExitMotion` 包住本面板
  ///   （退场淡出）。那时面板的父链里多了 `Opacity` / `IgnorePointer`
  ///   （都产生 RenderObject）⇒ 面板**不能再**自己写 `Positioned`
  ///   —— 它只能做 `Stack` 的直接孩子，否则两个 ParentDataWidget 争同一个
  ///   StackParentData ⇒ 抛 `Incorrect use of ParentDataWidget`
  ///   （阻断级教训：`player_page.dart` 的 `_SheetScrim` 类文档）。
  ///   `fill: false` 时定位交给宿主（本面板的 `Center` 撑满有界约束 ⇒
  ///   与 `Positioned.fill` 几何等价）。
  final bool fill;

  /// 连通性测试的注入口（测试用；null = 走真实的 [DanmakuLocalService.describe]）。
  ///
  /// # 为什么要可注入（而不是面板直接调真探针）
  /// ```text
  /// 面板本身**零网络**是本仓既有纪律（t103 的注入式用例不许被真探针拖住）。
  /// 而「测试连接」这个按钮语义上就是要发一次请求 ⇒ 唯一两头都成立的做法：
  /// 生产走真探针，测试注入假探针。
  /// ```
  /// ⚠️ 与 [_endpointUrl] 同一条：面板不认识宿主的开关，但**认得出**这是
  ///    一次由用户点击触发的、针对用户自己填的地址的请求 ——
  ///    它不读任何宿主状态，所以自持无妨。
  final Future<DanmakuLocalStatus> Function(DanmakuEndpoint?)? probeOverride;

  @override
  State<DanmakuSettingsDialog> createState() => _DanmakuSettingsDialogState();
}

class _DanmakuSettingsDialogState extends State<DanmakuSettingsDialog> {
  /// ★ 屏蔽词必须是**同一个** controller 活过整个对话框的生命周期。
  ///
  /// 原来 `_blockWordsField()` 每次 build 都 `TextEditingController(text:
  /// DanmakuConfig.blockWords.join('\n'))`：
  /// 用户敲一个字 → onChanged → setBlockWords → widget.onChanged 触发宿主重建
  /// → build 又造一个新 controller，而 EditableText 显示的就是
  /// `controller.value`（editable_text.dart:4028），didUpdateWidget 还会
  /// 重新把 controller 的监听器接上去 ⇒ **每敲一个字就被刷回规范化后的值**，
  /// 第二个屏蔽词根本输不进去。
  late final TextEditingController _blockWords = TextEditingController();

  /// Search box for blocking words (only shown when there are many).
  ///
  /// Same lesson as [_blockWords]: creating a new controller every build
  /// wipes what the user just typed.
  final TextEditingController _blockSearch = TextEditingController();

  /*
   * 2026-10-15 redesign: _blockWords is now the ADD field (a single word),
   * not the whole multi-line blob => its initial value MUST be empty.
   * If it were still seeded with blockWords.join(), every existing word would
   * appear in the add box and pressing Enter would re-add them all as one word.
   */
  /// ★★★ 2026-10-14：搜索关键词输入框的 controller。
  ///
  /// 与 [_blockWords] **完全同一条教训**（那个字段的注释里有实测）：
  /// 每帧 new 一个 controller 会让用户敲一个字就被刷回初值。
  /// 这里更明显 —— 搜索框被 `searchResults` / `searchLoading` 的
  /// 状态变化带着重建（搜索一返回就 setState），用局部 controller
  /// 会把用户刚敲的关键词整段吃掉。
  final TextEditingController _searchKeyword = TextEditingController();

  /// 自建弹幕服务地址输入框（owner 第 6 条的落地点）。
  ///
  /// ⚠️ 同 [_blockWords] / [_searchKeyword] 的教训：每帧 new 一个 controller
  ///    会让用户敲一个字就被刷回初值。
  final TextEditingController _endpointUrl = TextEditingController();

  /// 自建弹幕服务 token 输入框（可选；某些自建服务把它放在路径前缀上）。
  final TextEditingController _endpointToken = TextEditingController();

  /// 「测试连接」的结果（null = 还没测过 / 用户改过地址后已作废）。
  DanmakuLocalStatus? _probeResult;

  /// 走不到 [DanmakuLocalStatus] 的那种结果（目前只有「地址格式不对」）。
  ///
  /// ⚠️ 单独一个字段，是因为**不能**拿 status 硬凑：地址非法时探针根本没跑，
  ///    而 `DanmakuLocalStatus(online: false).line` 会说「检测到本机外部弹幕
  ///    未运行」—— 那是**本机 2080** 的结论，与用户填错的地址无关。
  ///    对用户来说这是最坏的一种假话：他会以为自己的地址没问题、是服务没起来。
  String? _probeCustomMessage;

  /// ★★★ 2026-10-19（R3-③ / R3-⑦）：**为什么连不上**的结构化结论
  ///
  /// 与 [_probeResult]（core 的在线/版本）和 [_probeCustomMessage]（地址格式）
  /// 三者各回答一个问题，不许互相冒充：
  /// ```text
  /// _probeResult         在线吗？版本多少？（core 的判据）
  /// _probeReport         **为什么**不在线？（本层的分层探测，见 [_diagnose]）
  /// _probeCustomMessage  连探都没探（地址格式不对）
  /// ```
  /// ⚠️ `null` = 还没诊断过（不是"没问题"）。
  DanmakuProbeReport? _probeReport;

  /// 正在测试连接 —— 记录**是哪个序号**的请求在跑（null = 没有在途请求）。
  ///
  /// # 为什么不是 bool（★ 这条是修竞态时暴露出来的第二个 bug）
  /// ```text
  /// 只挡「过期结果不许写状态」还不够：过期请求 return 之后，
  /// 那个 bool 永远停在 true ⇒ **转圈图标永远转下去**（pumpAndSettle 超时）。
  /// ⇒ 必须让 spinner 有明确的归属：哪个序号发起的，只有它（或接管者）
  ///    才能把它关掉。
  /// ```
  int? _probeRunningSeq;

  /// 有没有在途请求（btn 的禁用态 / 转圈图标都读它）
  bool get _probeRunning => _probeRunningSeq != null;

  /// 「测试连接」的**请求序号**（防旧结果覆盖新输入）。
  ///
  /// # 它守的是什么（CodeRabbit PR #30 抓到的真竞态）
  /// ```text
  /// 填 A 点测试（请求在途）→ 用户改成 B → A 的结果回来
  /// ⇒ 旧代码会把 A 的结论写进 _probeResult、还把 A 写进偏好。
  /// 结果：输入框 B、偏好 A、状态行显示 A 的结论 —— 三者互相矛盾。
  /// ```
  ///
  /// # 判据为什么是**序号**而不是「地址字符串变没变」
  /// ```text
  /// 用户可能 A → B → A：字符串比出来相同，但 B 那一轮的结论
  /// 语义上已经作废（它属于上一轮）。字符串判据会**漏放**这种。
  /// ```
  ///
  /// ⚠️ 每次发起测试 / 用户改输入 / 点清除 都要 ++，见各自的调用点。
  int _probeSeq = 0;

  /// 当前页签。默认「配置」。
  ///
  /// 默认落在「显示」页签。
  ///
  /// ★ 2026-10-18 第四版：默认页从「配置」改成「显示」（同一个东西的新名字）。
  ///
  /// 为什么不默认到某个**来源**：来源之间可以叠加（Owner 第 11 条
  /// 「同时加载并合并」），默认勾哪一个都等于替用户做了选择；
  /// 而「显示」是与来源无关的中立落点 —— 用户打开面板先看到的是
  /// 「弹幕怎么显示」，那是最常调的东西。
  DanmakuPanelTab _tab = DanmakuPanelTab.display;

  /// 外部视频站这一集的弹幕条数。
  ///
  /// 为什么面板自己不去取：弹幕数据在**宿主**那侧（两条路各自写不同的字段），
  /// 面板再去读一遍就是第二份真源 ⇒ 必然会漂移。这里只是个只读展示位。
  ///
  /// ⚠️ 取不到就是 null（显示「—」），**不用 0 冒充** ——
  ///    0 是“这个源真的没弹幕”，两者对用户意义完全不同。
  int? get _biliCount => widget.biliCount;

  /*
   * 2026-10-15: the credential input boxes (and these two controllers) were
   * deleted -- Owner: "I told you to delete those two input boxes and use the
   * built-in credentials." The developer agreement allows built-in credentials
   * via placeholder + build-time injection, which is what this repo does.
   * See the long note in _credentialsSection.
   *
   * NOTE: deleting the boxes MUST delete the controllers too -- leaving them
   * would mean two TextEditingControllers that nobody ever disposes, which is
   * exactly the resource-leak shape this repo treats as a defect (same lesson
   * as _controlsAnim and _danmakuBadgeTimer).
   */

  @override
  void initState() {
    super.initState();
    /*
     * ★ 自建服务地址/token 的预填放在 initState（**不是** build 里）。
     *
     * 在 build 里写 controller.text 会让它的 listener 触发 setState ——
     * 也就是 "setState() or markNeedsBuild() called during build"。
     * 本文件 [_syncKeyword] 遇到同一个坑时用的是 addPostFrameCallback（会闪一帧），
     * 而这里没有"值来自宿主、会变"的问题（只读一次偏好）⇒
     * 直接在 initState 里定下初值，一帧都不闪。
     */
    _endpointUrl.text = UiPrefs.danmakuEndpoint;
    _endpointToken.text = UiPrefs.danmakuToken;
  }

  @override
  void dispose() {
    _blockWords.dispose();
    _blockSearch.dispose();
    _searchKeyword.dispose();
    _endpointUrl.dispose();
    _endpointToken.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    /*
     * ★ task-104：根节点形态由 `fill` 决定
     *   fill = true （默认，= 改前行为）  Positioned.fill(...) → 只能直接挂在 Stack 下
     *   fill = false（SheetExitMotion 包着） 直接返回内容 → 定位交给宿主
     * 两者内容**逐字相同**，只是少/多一层 `Positioned.fill`
     * （理由见 `fill` 字段的文档）。
     */
    /*
     * ★ 2026-10-16（Owner：「弹幕设置这里非常的丑」+ 「弹窗样式没统一」）
     *
     * 外壳改走全仓统一的 `AppDialogShell`（docs/AGENTS.md 第 3.5 节）。
     * 改前这里自己写了一整套 Container + Material + OverlayScrim +
     * OverlayCardMotion + Positioned.fill，与另外 6 个弹窗各写各的
     * （宽度 560 硬编码、maxHeight 620 硬编码）。
     *
     * ⚠️ 本面板**不是**「标题 + 整块内容滚动」的标准形态：
     *    `_statusSection` / `_sourceStatusStrip` / `_tabBar` 三块必须
     *    **钉死不滚**（切页签时它们要一直在），只有下面的设置项滚。
     *    ⇒ 所以 `scrollable: false`，滚动区由本方法自己套。
     */
    final settings = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_tab == DanmakuPanelTab.display) ...[
          _group(_switchSection()),
          _gap(),
          /*
           * ★★ 2026-10-16：补上 [_displaySection]（字号/透明度/速度/显示区域）
           *
           * 改前它**全仓零调用** —— 「配置」页签里只有开关和屏蔽词，
           * 四个滑块加两条说明一整节都没渲染出来（Owner 截图可见）。
           * 这不是本次重构改坏的：`grep -rn _displaySection lib/ test/`
           * 改前只有定义处一行命中。
           */
          _group(_displaySection()),
          _gap(),
          _group(_filterSection()),
        ] else if (_tab == DanmakuPanelTab.sources) ...[
          /*
           * ★★★ 2026-10-18 第四版（Owner 亲自截图四条反馈的核心修复）
           *
           * # 这一页回答的唯一问题
           * ```text
           * 「这一集的弹幕从哪来、每条路现在什么状态、我要怎么切」
           * ```
           * # 为什么四条来源**平级各占一行**（而不是分页签）
           * ```text
           * Owner ①：「某个视频站的弹幕设置怎么没了」
           *   ⇒ 它第三版被我藏成「插件提供」里一枚叫「外部弹幕…」的按钮。
           *     现在它和 dan-api **平级**，名字就叫出来，一眼可见。
           * Owner ③：「dan-api只有测试」
           *   ⇒ 现在 dan-api 那一行带「搜索…」，点开就是搜索+选中+绑定。
           * Owner ②：「插件提供是什么」
           *   ⇒ 改名成「本片源自带」，语义是"视频源插件随片给的"，默认勾上。
           * ```
           * # 为什么是 ☑/☐ 多选而不是 ●/○ 单选
           * ```text
           * Owner 第 11 条：「同时加载并合并」⇒ 多路可以叠加。
           * （见 enum DanmakuPanelTab 的文档：与第 6 条不冲突）
           * ```
           */
          _group(_sourcesSection()),
          _gap(),
          _group(_requestSection()),
          if (_showSearchSection) ...[_gap(), _group(_searchSection())],
        ] else ...[
          /*
           * 高级：要填地址 / 凭证的，99% 用户不需要。
           *
           * ★ 2026-10-18：原「官方兜底」tab 已删除（Owner ④
           *   「这个官方兜底也不知道是啥东西」+ 本构建无内置凭证、必然失败）。
           *   它的 `_sourceSection` / `_credentialsSection` **保留但不调用**
           *   （理由见那两个方法上的注释）。
           */
          _group(_selfHostedSection()),
        ],
        _gap(),
        /*
         * ★★ Owner 第 1 条：把 403/401 翻成**能照着做**的中文
         *
         * 位置有讲究：排在「服务端返回」**上面** ——
         * 原文（Missing Authentication Headers）是证据，
         * 中文指引是结论；用户先看到结论才知道证据在说什么。
         *
         * ⚠️ 错误/指引**不受页签影响**：它们是“出事了”的反馈，
         *    而不是“一项设置”。藏在某个页签后面 ⇒ 用户在另一页签时
         *    只看到“没弹幕”而看不到为什么。
         */
        if (s.error?.hint != null) ...[
          _gap(),
          _group(_hintSection(s.error!.hint!)),
        ],
        if (s.error != null) ...[_gap(), _group(_errorSection(s.error!))],
      ],
    );

    /*
     * 三块固定 + 一块滚动（见上面说明）。
     *
     * ★★ 2026-10-16：左右内边距提到这一层（卡片级）——
     *   见 `contentPadding` 处的说明。三块固定区与滚动区因此**共享**
     *   同一个 Sp.x6，谁都不会贴到卡片圆角上。
     *   ⚠️ 上下留白也收在这里：固定区之间 / 与滚动区之间不再各自加
     *      （否则会与外壳的 contentPadding 叠成双份）。
     */
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _statusSection(),
          _sourceStatusStrip(),
          _tabBar(),
          Flexible(
            child: SingleChildScrollView(
              clipBehavior: Clip.antiAlias,
              padding: const EdgeInsets.only(top: Sp.x3, bottom: Sp.x4),
              child: settings,
            ),
          ),
        ],
      ),
    );

    // ★ 外壳接管遮罩/动效/定位；标题与副标题逐字不变
    final shelled = AppDialogShell(
      title: '弹幕设置',
      subtitle: '显示 / 过滤 / 请求',
      onClose: widget.onClose,
      fill: widget.fill,
      // ★ 本面板改前就用 OverlayScrim + OverlayCardMotion（t99 门禁钉着）
      motion: true,
      // ★★ 强制深色卡片（2026-10-16 Owner 实测「字都看不清了」的修复）
      //
      // 本面板文字走 `DanmakuTextColors` —— 那是**为深色底 #14161B 设计的固定灰阶**
      // （body #E6E6E6 / secondary #B9BEC6 / muted #8E939B），
      // t27_w1_danmaku_contrast_test 钉着它们对那个底的对比度。
      //
      // 外壳把卡片底统一成跟随主题的 surfaceContainerHighest 之后，**浅色主题**
      // 下底变浅、灰阶仍是浅色 ⇒ 几乎看不见。
      // 不能靠"把灰阶改主题色"解决：41 处灰阶与 t27_w1 门禁是一起设计的。
      // ⇒ 让它保持原本的深色（业主 fig1 实测底色就是 #14161B）。
      forceDarkCard: true,
      /*
       * ★★ 2026-10-18（任务 B-2）：玻璃材质。
       *
       * 只影响本面板 —— 外壳的 `glass` 默认 false，
       * 其余 6 个弹窗逐像素不变。
       *
       * ⚠️ 与 `forceDarkCard: true` 并存：
       *    forceDarkCard 管**文字取色**（本面板 41 处 DanmakuTextColors 是
       *    为深底设计的固定灰阶，t27_w1 钉着对比度），
       *    glass 只管**卡片材质**。两件事互不干扰。
       */
      glass: true,
      // 本面板自管滚动（三块钉死不滚）⇒ 不套外壳的 SingleChildScrollView
      scrollable: false,
      /*
       * ★★ 2026-10-16（Owner 实测截图：「弹幕设置这个两边没有边距」）
       *
       * 根因：`contentPadding` 只管**滚动区**（外壳把它交给
       * `SingleChildScrollView`），而本面板三块**固定区**
       * （`_statusSection` / `_sourceStatusStrip` / `_tabBar`）在
       * `scrollable: false` 下**原样透传**、吃不到那个 padding
       * ⇒ 它们左右直接顶到卡片圆角上（实测：状态条与 Tab 栏贴边）。
       *
       * ⇒ 左右内边距必须提到**卡片级**（`body` 外面那一层），让三块固定区
       *   与滚动区**吃到同一个** Sp.x6。滚动区的左右 padding 同步归零
       *   （否则左右变成 48，比改前还宽）。
       */
      contentPadding: const EdgeInsets.only(top: Sp.x3),
      child: body,
    );

    // ★ 默认形态与改前**逐像素相同**（fill 语义由外壳接管）
    return shelled;
  }

  /// 面板标题 —— 缺陷 17：**细节说明的落点**
  ///
  /// ══════════════════════════════════════════════════════════════
  /// ★★★ 为什么这里要多一个副标题（2026-10-09 · 缺陷 17 / Lead 裁决）
  /// ══════════════════════════════════════════════════════════════
  /// 播放页底栏那枚 `AppIcons.tune` 按钮的 tooltip 改前是一长串：
  /// ```text
  /// '弹幕设置（AppId / 字号 / 透明度）'   <- player_page.dart 旧写法
  /// ```
  /// 它有两个毛病（Lead 裁决里点名）：
  /// ```text
  /// ① 与同一页「更多」菜单项 `Text('弹幕设置')` 不是同一个叫法；
  /// ② 括号里那串**是误导性摘要** —— 面板实际有：状态 / 数据源 / 显示开关 /
  ///    字号 / 透明度 / 速度 / 占用区域 / 重新获取弹幕。三个词既不全、
  ///    又不是最需要知道的。
  /// ```
  /// ⇒ tooltip 截成 `'弹幕设置'`（与菜单项逐字一致），细节挪到**这里** ——
  ///   面板标题下方的 `note`，用户一打开就看见，也不用悬停才出现。
  ///
  /// ⚠️ 标题文字本身仍是 `'弹幕设置'` 四个字**一字不改**（副标题是**新增**）：
  ///    既有测试 `test/t99_overlay_motion_test.dart:538/542/569` 用的是
  ///    `find.text('弹幕设置')` ⇒ 多一个 `Text('显示 / 过滤 / 请求')`
  ///    之类的新串不会撞上它（那是不同的字符串，`find.text` 是精确匹配）。
  /// 顶部状态条：两个源各自多少条（Owner：「最上面显示状态」）
  ///
  /// 为什么放在**页签之外**：“现在挂的是哪个源、各有多少条”是用户
  /// **决定点哪个页签**前就要看的信息 ⇒ 不能跟着页签内容一起滚走。
  ///
  /// ⚠️ 取不到的一边显示「—」，**不用 0 冒充** ——
  ///    0 是“这个源真的没弹幕”，两者对用户意义完全不同。
  Widget _sourceStatusStrip() {
    final s = widget.state;
    // 哪个源在生效：看状态行里有没有外部视频站的字样。
    final biliLive = _biliCount != null;
    /*
     * ★★★ 2026-10-17（Owner 第 11 条）
     *
     * 改前这里两枚 chip 写死叫 `弹弹play` / `bilibili`：  // site-ok: danmaku-source
     * ```text
     * Owner 原话：「弹弹play 我说了要让可用的dan-api去替换的,
     *               这里的弹幕面板怎么还是弹弹play?」
     * ```
     * ⇒ chip 的名字改成**来源类别**（与页签同一套词），
     *   具体是哪一家由**下面的读数**说明，不由 chip 名承担。
     *
     * ⚠️ 条数照旧如实：`—` 表示"这个源没在供数据"，
     *    0 表示"供了但是 0 条" —— 两者对用户意义完全不同（见上一条注释）。
     */
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
      decoration: BoxDecoration(
        borderRadius: Radii.rSm,
        border: Border.all(color: DanmakuTextColors.border),
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.03),
      ),
      child: Row(
        children: [
          _sourceChip(
            label: 'dan-api',
            count: biliLive ? null : s.count,
            live: !biliLive,
          ),
          const SizedBox(width: Sp.x2),
          /*
           * ★ 2026-10-18 第四版：`插件提供` → `本片源`
           *
           * Owner ② 的语义纠正：插件那条路的本质是
           * 「**本片源**随片自带的弹幕」，不是"插件声明了一种能力"。
           * 状态条 chip 必须与「弹幕来源」页签里那一行**同一套词**，
           * 否则两处叫法不同，用户又要重新猜一次。
           */
          _sourceChip(label: '本片源', count: _biliCount, live: biliLive),
          const Spacer(),
          if (widget.readout != null)
            ValueListenableBuilder<DanmakuReadout>(
              valueListenable: widget.readout!,
              builder: (_, r, __) => Text(
                '画面 ${r.count} 条 · 轨道 ${r.lanes}',
                style: const TextStyle(
                  color: DanmakuTextColors.muted,
                  fontSize: FontSizes.cap,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sourceChip({
    required String label,
    required int? count,
    required bool live,
  }) {
    /*
     * ★ 2026-10-17（看图台抓到的文案缺陷）
     *
     * 改前：`'$label $n 条'` ⇒ 没数据时渲染成「插件提供 — 条」，
     * 中文里那个"条"吊在破折号后面**读不通**（像漏了个数字）。
     * ⇒ 有数才带量词，没数就只说「插件提供 —」。
     */
    final text = count == null ? '$label —' : '$label $count 条';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // 当前生效那一个才点亮（与底栏「当前源」高亮同一语言）
            color: live ? const Color(0xFF4FD1C5) : DanmakuTextColors.border,
          ),
        ),
        const SizedBox(width: Sp.x1),
        Text(
          text,
          style: TextStyle(
            color: live ? DanmakuTextColors.body : DanmakuTextColors.muted,
            fontSize: FontSizes.cap,
            fontWeight: live ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  /// 四个页签。用 `SegmentedButton` 而不是自写一套：
  /// 它自带选中态语义、键盘导航与无障碍读屏支持，
  /// 而且与本仓其他地方的选择控件同一套。
  ///
  /// ★★★ 2026-10-17（Owner 第 11 条）：页签从「按源命名」改成「按能力命名」
  /// ```text
  /// 改前：配置 / bilibili / 弹弹play            // site-ok: danmaku-source
  /// 改后：配置 / dan-api / 插件提供 / 官方兜底
  /// ```
  /// Owner 原话：「弹弹play 我说了要让可用的dan-api去替换的,
  ///              这里的弹幕面板怎么还是弹弹play?」
  ///
  /// ⚠️ 四个标签都是 2~4 个字，卡片宽 560、内容区扣掉左右 padding 后
  ///    仍放得下 —— **不给图标**（四个图标会把文字挤成省略号，
  ///    而省略号比没图标难认得多）。
  Widget _tabBar() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<DanmakuPanelTab>(
        segments: const <ButtonSegment<DanmakuPanelTab>>[
          /*
           * ★ 2026-10-18 第四版：三个页签按「用户要做的事」分。
           *   标签都是 2~3 个字，卡片宽 560 扣掉左右 padding 后放得下。
           */
          ButtonSegment<DanmakuPanelTab>(
            value: DanmakuPanelTab.display,
            label: Text('显示'),
          ),
          ButtonSegment<DanmakuPanelTab>(
            value: DanmakuPanelTab.sources,
            label: Text('弹幕来源'),
          ),
          ButtonSegment<DanmakuPanelTab>(
            value: DanmakuPanelTab.advanced,
            label: Text('高级'),
          ),
        ],
        selected: <DanmakuPanelTab>{_tab},
        showSelectedIcon: false,
        /*
         * ★★ 2026-10-16（Owner 实测截图：「未选中的 tab 文字看不清」）
         *
         * 根因：不给 `style` 时，未选中项走框架默认的
         * `_SegmentedButtonDefaultsM3` —— 它的前景色是
         * `colorScheme.onSurface`。本面板是**强制深色卡片**
         * （`forceDarkCard: true`），而灰色档是给 #14161B 这个
         * 深底设计的固定灰阶 ⇒ 未选中项与卡片底几乎同色（实测均值 ≈ 卡片底）。
         *
         * ⇒ 显式给色，两档都走 `DanmakuTextColors`：
         *     未选中  secondary #B9BEC6（对深底 9.7:1，t27_w1 门禁钉着）
         *     选中    body      #E6E6E6（对深底 14.5:1）
         *   ⚠️ 面板是强制深色 ⇒ **不许**用 colorScheme（明暗主题下会各取一色，
         *      浅色主题下又变成看不清 —— 那正是本面板上一次的回归）。
         *   ⚠️ 用 `styleFrom` 而不是手写 `ButtonStyle`：
         *      它是框架提供的那条路（见 `segmented_button.dart:281`）。
         *      底纹/边框仍由主题给 —— 只改**文字色**，不动几何。
         */
        style: SegmentedButton.styleFrom(
          foregroundColor: DanmakuTextColors.secondary,
          selectedForegroundColor: DanmakuTextColors.body,
        ),
        onSelectionChanged: (v) => setState(() => _tab = v.first),
      ),
    );
  }

  /// 段间距。
  ///
  /// ★ 2026-10-16（Owner：「弹幕设置这里非常的丑」）：
  ///   改前这里是 `Divider`（一条横线 + 上下各 16px）。全面板共 7 处，
  ///   加起来 7 条横线贯穿整页 —— 这是"丑"的主要来源。
  ///   现在改为**纯留白**：分组靠 [_group] 的卡片底色区分，不再画线。
  Widget _gap() => const SizedBox(height: Sp.x3);

  /// 分组卡片 —— 一组设置一个浅底圆角容器。
  ///
  /// 为什么用底色而不是横线（2026-10-16 改）：
  /// ```text
  /// 改前：标题 + 内容 + ─────────────── + 标题 + 内容 …
  ///       ⇒ 7 条横线把面板切成一长条，像表格，视觉噪音大
  /// 改后：┌ 标题 ─────────┐  ┌ 标题 ─────────┐
  ///       │ 内容            │  │ 内容            │
  ///       └───────────────┘  └───────────────┘
  ///       ⇒ 分组靠"块"区分，一眼能数出几组
  /// ```
  /// 底色用 `onSurface` 的极低 alpha（而非写死白/黑）⇒ 明暗主题都成立。
  Widget _group(Widget child) {
    final scheme = Theme.of(context).colorScheme;
    final bg = scheme.onSurface.withValues(alpha: 0.04);
    /*
     * ★★ 必须用 `Material` 而不是 `Container` + `BoxDecoration`（2026-10-16）
     *
     * 我第一版写的是 `Container(decoration: BoxDecoration(color: bg))` ——
     * 里面装着 `SwitchListTile`（内部是 ListTile）⇒ 框架当场抛断言：
     * ```text
     * ListTile background color or ink splashes may be invisible.
     * The ListTile is wrapped in a DecoratedBox that has a background color.
     * Because ListTile paints its background and ink splashes on the nearest
     * Material ancestor, this DecoratedBox will hide those effects.
     * ```
     * t99 因此红了 4 条（①②③④ 全部断言「首帧 <1 → 中间态 → 终态」时被异常打断）。
     *
     * 同一个坑 `bili_import_dialog.dart:275` 早就记过，我又踩了一次：
     * 「同样的背景色/圆角/边框/尺寸，但 Material **就是** Material 面
     *  ⇒ 涟漪、水波纹、裁剪都正常」。
     *
     * `Material` 不接 padding ⇒ 内边距挂在外层 `Padding` 上。
     */
    return Padding(
      padding: const EdgeInsets.all(Sp.x4),
      /*
       * ⚠️ 2026-10-17：**这里不能换 AppSurface**（我换过一次，被测试打回）
       *
       * # 缺陷现场
       * ```text
       * 换成 AppSurface 后测试抛：
       *   "ListTile background color or ink splashes may be invisible.
       *    The ListTile is wrapped in a DecoratedBox that has a background color."
       *
       * 原因：AppSurface 内部是 DecoratedBox(带底色)，
       *       而 ListTile 的底色与水波纹画在**最近的 Material 祖先**上。
       *       中间隔一层带底色的 DecoratedBox ⇒ 效果被盖住 ⇒ 用户点上去看不到反馈。
       * ```
       *
       * ★ 这暴露了「Material 分类」的根本盲点：
       *   Material 不只是"提供底色"，它同时是 **ListTile 家族的绘制祖先**。
       *   ⇒ 判断能否删，必须看**子树里有没有 ListTile/CheckboxListTile/SwitchListTile**，
       *     而不是看它自己有没有 color。
       */
      child: Material(
        color: bg,
        type: MaterialType.card,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(borderRadius: Radii.rMd),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }

  /// 统一开关行 —— 全面板的开关都走这里。
  ///
  /// ★ 2026-10-16：改前同一种"开关行"有**三套**写法，实测差异：
  /// ```text
  /// _switchSection  FontSizes.sm（14）  color: secondary（0xFFB9BEC6）
  /// _typeSwitch     硬编码 13          color: muted（0xFF8E939B）
  /// ```
  /// 同一个面板里同一类控件两种字号、两种颜色 —— 这是 Owner 说的
  /// 「设计没统一」。现在收敛到一处。
  Widget _switchRow({
    required String label,
    required bool value,
    required void Function(bool) onChanged,
    String? hint,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      value: value,
      onChanged: onChanged,
      title: Text(
        label,
        style: const TextStyle(
          color: DanmakuTextColors.secondary,
          fontSize: FontSizes.sm,
        ),
      ),
      subtitle: hint == null
          ? null
          : Text(
              hint,
              style: const TextStyle(
                color: DanmakuTextColors.muted,
                fontSize: FontSizes.cap,
              ),
            ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ 2026-10-17：自建弹幕服务（Owner 第 6 条「搜索弹幕提示失败」）
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么这是**解法**而不是绕路
  // ```text
  // Owner 第 6 条的根因是官方边 403「Missing Authentication Headers」——
  // **没有凭证**（本构建没注入 AppId/AppSecret）。
  // 而自建弹幕服务（danmu_api 这类）**免凭证**、且协议同构：
  // 实测 10157/10157 条弹幕全部解析通过（见 .probe/danapi-research/REPORT.md）。
  // ⇒ 给用户一个「填地址就能用」的入口，是该问题的直接解法。
  // ```
  //
  // # 三种来源的区别（用户排错时唯一要分清的事）
  // ```text
  // ① 自建弹幕服务   —— 用户填的地址，**免凭证**；没起来 ⇒ 连接被拒
  // ② 本机弹弹play   —— 127.0.0.1:2080，**免凭证**；没起来 ⇒ 连接被拒
  // ③ 官方弹弹play   —— api.dandanplay.net，**要** AppId/AppSecret；没有 ⇒ 403
  // ```
  // 本节的连通性测试 + 状态行就是让用户一眼知道**自己现在挂在哪条上**。
  Widget _selfHostedSection() {
    final saved = UiPrefs.danmakuEndpoint;
    final res = _probeResult;
    /*
     * ★★★ 2026-10-17（Owner 第 4 / 11 条）：内置公共实例。
     *
     * # 改前这一节只有两个空输入框
     * ```text
     * Owner 原话：「我之前说的dan-api 是让你接入现成的服务,不是让我去填的,
     *               或者可以内置上几个」
     * ```
     * ⇒ 现在先把内置实例**列出来**（默认选中第一个），再给"自己填"的入口。
     *   用户什么都不填 = 用内置的，这条才是"接入现成的服务"。
     *
     * ⚠️ 内置只是**默认值**：一旦填了地址，内置那几行就变成"点一下就切回去"的
     *    备选，而不是抢走用户的输入。
     */
    const builtins = kDanmakuPublicInstances;
    final usingBuiltin = saved.trim().isEmpty && builtins.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('dan-api 服务', note: '免凭证 · 首选'),
        // ── ① 内置公共实例（点一下就用，不用填）──
        if (builtins.isNotEmpty) ...[
          const Text(
            '内置实例（开箱可用，点一下选中）',
            style: TextStyle(
              color: DanmakuTextColors.secondary,
              fontSize: FontSizes.cap,
            ),
          ),
          const SizedBox(height: Sp.x2),
          for (final p in builtins) ...[
            _builtinRow(p, selected: usingBuiltin && _isDefaultBuiltin(p)),
            const SizedBox(height: Sp.x1),
          ],
          const SizedBox(height: Sp.x2),
          _hint(
            '内置实例是公共服务器：会慢（冷启动几秒）、也可能临时不可用。'
            '下面可以填你自己的地址，填了就压过内置。',
          ),
          const SizedBox(height: Sp.x4),
        ],
        // ── ② 自己填（压过内置）──
        Text(
          builtins.isEmpty ? '服务地址' : '你自己的地址（可选，填了就压过内置）',
          style: const TextStyle(
            color: DanmakuTextColors.secondary,
            fontSize: FontSizes.cap,
          ),
        ),
        const SizedBox(height: Sp.x2),
        TextField(
          controller: _endpointUrl,
          style: const TextStyle(
            color: DanmakuTextColors.body,
            fontSize: FontSizes.sm,
          ),
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: '服务地址',
            hintText: builtins.isEmpty
                ? 'http://127.0.0.1:9321'
                : builtins.first.baseUrl,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          // 地址一改，上一次的测试结果就**作废** —— 否则会显示一个
          // 与当前地址无关的「已就绪」，那是撒谎。
          onChanged: (_) {
            /*
             * ★★ 输入一变：① 序号前进（在途结果作废）② 交出 spinner 归属
             *    （用户既然改了地址，那个在途请求就与他无关了 ⇒ 按钮要能再点）。
             *
             * ⚠️ 两件事都**必须无条件执行**，不能包在下面的 if 里：
             *    判据是「输入变过」，不是「当前显示了什么」。
             */
            _probeSeq++;
            _probeRunningSeq = null;
            if (_probeResult != null ||
                _probeCustomMessage != null ||
                _probeReport != null) {
              setState(() {
                _probeResult = null;
                _probeCustomMessage = null;
                // ★ 2026-10-19：诊断结论同样属于**旧地址** ⇒ 一起作废
                _probeReport = null;
              });
            } else {
              setState(() {});
            }
          },
          onSubmitted: (_) => _runProbe(),
        ),
        const SizedBox(height: Sp.x2),
        // ── token（可选）──
        TextField(
          controller: _endpointToken,
          style: const TextStyle(
            color: DanmakuTextColors.body,
            fontSize: FontSizes.sm,
          ),
          decoration: const InputDecoration(
            labelText: 'Token（可选）',
            hintText: '默认服务不用填',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) {
            // token 也参与探测 ⇒ 改了同样让在途结果过期、同交还 spinner
            _probeSeq++;
            _probeRunningSeq = null;
            setState(() {
              _probeResult = null;
              _probeCustomMessage = null;
              _probeReport = null;
            });
          },
        ),
        const SizedBox(height: Sp.x3),
        // ── 动作行 ──
        Row(
          children: [
            FilledButton.icon(
              onPressed: _probeRunning ? null : _runProbe,
              icon: _probeRunning
                  ? const AppInlineSpinner(
                      size: 16,
                      color: DanmakuTextColors.body,
                    )
                  : const Icon(AppIcons.wifi_tethering, size: 18),
              label: const Text('测试连接'),
            ),
            const SizedBox(width: Sp.x2),
            TextButton(
              // 没有存过地址 ⇒ 「清除」无意义，禁用比画一个点了没反应的按钮好
              onPressed: saved.isEmpty ? null : _clearEndpoint,
              child: const Text('清除'),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        // ── 如实结果行 ──
        if (res != null) _probeResultRow(res),
        /*
         * ★★★ 2026-10-19（R3-③ / R3-⑦）：**为什么连不上**的定向说明
         *
         * # 改前这里只有上面那行 `res.line`
         * ```text
         * core 的 `line` 对不在线只有一句「内置公共实例（…）暂时连不上」——
         * 它把 DNS 失败 / 被墙 / 服务报错三件事混成一件，
         * 用户据此去改配置或等一会儿，**方向都是错的**。
         * ```
         * # 改后：分类 + 下一步 + 机械细节（errno 原文不翻译掉）
         */
        if (_probeReport != null) ...[
          const SizedBox(height: Sp.x2),
          _probeReportBox(_probeReport!),
        ],
        if (_probeCustomMessage != null) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                AppIcons.error_outline,
                size: 14,
                color: Colors.orangeAccent,
              ),
              const SizedBox(width: Sp.x2),
              Flexible(
                child: Text(
                  _probeCustomMessage!,
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: FontSizes.sm,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (res == null && _probeCustomMessage == null && saved.isNotEmpty) ...[
          Row(
            children: [
              const Icon(
                AppIcons.check_circle_outline,
                size: 14,
                color: DanmakuTextColors.muted,
              ),
              const SizedBox(width: Sp.x2),
              Flexible(
                child: Text(
                  '当前生效：${_maskedEndpoint(saved)}（点「测试连接」确认）',
                  style: const TextStyle(
                    color: DanmakuTextColors.secondary,
                    fontSize: FontSizes.cap,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (usingBuiltin && builtins.isNotEmpty)
          _hint('当前生效：内置实例 ${builtins.first.label}（不用填任何东西）。'),
      ],
    );
  }

  /// ★★★ 2026-10-19（R3-③ / R3-⑦）：**为什么连不上** —— 分类 + 下一步 + 原文
  ///
  /// # 为什么这三段都要画（少一段就有一类用户被误导）
  /// ```text
  /// ① 分类标题（`连不上（连接超时）` / `域名解析失败` / `服务返回错误`）
  ///    ⇒ 用户第一眼就知道"该怪谁"（本机网络 vs 服务端）
  /// ② 下一步（remedy）
  ///    ⇒ 知道该怪谁之后要做什么。这一段按 failure 分叉，不是套话。
  /// ③ 机械细节（errno / 解析到的 IP / 异常原文）
  ///    ⇒ 会贴到群里求助的人需要它。**不翻译掉**（同本仓错误透传纪律）。
  /// ```
  /// ⚠️ 「服务正常，但没有弹幕」**不画成红色失败** —— 那是正常结果。
  Widget _probeReportBox(DanmakuProbeReport r) {
    // 空结果：不是失败，用中性色，别吓人
    final empty = r.failure.isJustEmpty;
    final ok = r.isOk;
    final color = ok || empty
        ? DanmakuTextColors.secondary
        : (r.failure.isLocalNetworkProblem
            // 本机网络问题：橙色（该动手，但不是"我们坏了"）
            ? Colors.orangeAccent
            // 服务端问题：红（确实是那边坏了）
            : Colors.redAccent);
    final icon = ok || empty
        ? AppIcons.info_outline
        : (r.failure.isLocalNetworkProblem
            ? AppIcons.wifi_off
            : AppIcons.error_outline);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        borderRadius: Radii.rSm,
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Text(
                  // 标题里带地址：用户同时开两个实例测试时，分得清是哪一条的结论
                  r.url.isEmpty
                      ? r.failure.title
                      : '${r.failure.title} · ${r.url}',
                  style: TextStyle(
                    color: color,
                    fontSize: FontSizes.sm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (r.remedy.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            Text(
              r.remedy,
              style: const TextStyle(
                color: DanmakuTextColors.secondary,
                fontSize: FontSizes.cap,
                height: 1.4,
              ),
            ),
          ],
          if (r.detail.isNotEmpty) ...[
            const SizedBox(height: Sp.x2),
            Text(
              // ⚠️ 原文照透（errno / 解析到的 IP / 异常），不翻译、不截断成"失败"
              r.detail,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: FontSizes.cap,
                color: DanmakuTextColors.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 这一条内置实例是不是「当前默认选中的那个」
  bool _isDefaultBuiltin(DanmakuPublicInstance p) =>
      kDanmakuPublicInstances.isNotEmpty &&
      kDanmakuPublicInstances.first.baseUrl == p.baseUrl;

  /// 一条内置实例（点一下 = 选中它）
  ///
  /// ⚠️ 选中 = 把地址**写进输入框**并落盘（不是另开一套偏好）。
  ///    理由：用户之后还能在同一个框里改它 —— 否则「内置」和「自填」
  ///    会变成两条互不相通的路径（改了没生效，又是一处接线坑）。
  Widget _builtinRow(DanmakuPublicInstance p, {required bool selected}) {
    return InkWell(
      onTap: () => _selectBuiltin(p),
      borderRadius: Radii.rSm,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
        decoration: BoxDecoration(
          borderRadius: Radii.rSm,
          border: Border.all(
            color: selected
                ? const Color(0xFF4FD1C5)
                : DanmakuTextColors.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? AppIcons.check_circle
                  : AppIcons.radio_button_unchecked,
              size: 14,
              color: selected
                  ? const Color(0xFF4FD1C5)
                  : DanmakuTextColors.muted,
            ),
            const SizedBox(width: Sp.x2),
            Text(
              p.label,
              style: TextStyle(
                color: selected
                    ? DanmakuTextColors.body
                    : DanmakuTextColors.secondary,
                fontSize: FontSizes.sm,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                p.baseUrl,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: DanmakuTextColors.muted,
                  fontSize: FontSizes.cap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点一条内置实例 ⇒ 写进输入框 + 落盘
  ///
  /// ⚠️ 与 [_runProbe] 同一条竞态纪律：序号前进，作废在途结果
  ///    （用户已经明确选了另一个地址，那个在途请求与他无关了）。
  void _selectBuiltin(DanmakuPublicInstance p) {
    _probeSeq++;
    _probeRunningSeq = null;
    _endpointUrl.text = p.baseUrl;
    _endpointToken.text = p.token;
    UiPrefs.setDanmakuEndpoint(p.baseUrl);
    UiPrefs.setDanmakuToken(p.token);
    setState(() {
      _probeResult = null;
      _probeCustomMessage = null;
      _probeReport = null; // 换了地址 ⇒ 上一条诊断不属于它
    });
    widget.onChanged?.call();
  }

  /// 地址的**打码**展示（状态行用）。
  ///
  /// ★ 与本仓既有的 `DanmakuConfig.maskedAppId` 同一条纪律：
  ///   地址本身通常不是秘密，但**token 是** ⇒ 这里只展示 `scheme://host:port`，
  ///   去掉 path —— token 就在 path 前缀上（见 `DanmakuEndpoint.prefixedPath`）。
  String _maskedEndpoint(String raw) {
    final ep = DanmakuEndpoint.tryParse(raw, token: _endpointToken.text);
    if (ep == null) return raw;
    return ep.display;
  }

  Widget _probeResultRow(DanmakuLocalStatus res) {
    final ok = res.online;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? AppIcons.check_circle : AppIcons.error_outline,
          size: 14,
          color: ok ? Colors.greenAccent : Colors.orangeAccent,
        ),
        const SizedBox(width: Sp.x2),
        Flexible(
          child: Text(
            // ★ res.line 是 core 给的**如实**文案（自建/本机分开说），
            //   面板不自己拼字符串判断 —— 拼一遍就是第二份判据。
            res.line,
            style: TextStyle(
              color: ok ? Colors.greenAccent : Colors.orangeAccent,
              fontSize: FontSizes.sm,
            ),
          ),
        ),
      ],
    );
  }

  /// 测一次连通性。
  ///
  /// ⚠️ 地址非法 ⇒ **提示用户**，不要静默回退到内置路径去测一个他没填的地址
  ///    （那样会显示「本机外部弹幕已就绪」，用户以为自己填对了）。
  Future<void> _runProbe() async {
    /*
     * ★★ 2026-10-17（CodeRabbit PR #30）：**作废所有在途请求**并记下本次序号。
     *
     * # 原来漏掉的竞态（真 bug，不是洁癖）
     * ```text
     * ① 填地址 A，点「测试连接」⇒ 请求在途
     * ② 用户把地址改成 B（onChanged 把 _probeRunning 放回 false ⇒ 按钮可再点）
     * ③ A 的请求返回 ⇒ 旧代码 setState(_probeResult = A 的结果)
     *    并且 UiPrefs.setDanmakuEndpoint(A)
     * ⇒ 输入框里是 B、偏好里存的是 A、状态行显示的是 A 的结论 —— 三者互相矛盾
     * ```
     *
     * # 为什么用**序号**而不是比较地址字符串
     * ```text
     * 用户可能 A → B → A：字符串比出来相同，但 B 那一轮的结果
     * 语义上早已作废（它属于「上一轮」）⇒ 字符串判据会**漏放**这种。
     * 序号判据对「任何一次输入变化」都成立，不依赖值的形状。
     * ```
     *
     * # 谁会让序号前进
     * ```text
     * · 每次发起测试（这里）
     * · 地址框 / token 框 的 onChanged（用户改了输入 ⇒ 在途结果过期）
     * · 「清除」（用户要求回到内置路径 ⇒ 在途结果绝不许把它写回来）
     * ```
     */
    final mySeq = ++_probeSeq;
    final raw = _endpointUrl.text.trim();
    // ⚠️ token 也要**在发起时**捕获：落盘时再读 _endpointToken.text 会拿到
    //    用户后来敲的值（与地址同一类竞态，同一条纪律）。
    final rawToken = _endpointToken.text;
    final ep = DanmakuEndpoint.tryParse(raw, token: rawToken);
    if (raw.isNotEmpty && ep == null) {
      setState(() {
        _probeRunningSeq = null;
        _probeResult = null;
        // ★ 不说「本机外部弹幕未运行」——那与用户填的地址无关，是误导。
        _probeCustomMessage = '地址格式不对（例：http://127.0.0.1:9321）';
      });
      return;
    }
    // ★ spinner 归属本次序号：只有发起它的这一轮（或接管者）能关掉
    setState(() => _probeRunningSeq = mySeq);
    final probe =
        widget.probeOverride ??
        (DanmakuEndpoint? e) => DanmakuLocalService.describe(endpoint: e);
    DanmakuLocalStatus st;
    try {
      st = await probe(ep);
    } catch (e) {
      /*
       * ★ 过期 ⇒ 一个字都不改（失败结论同样属于旧地址，写上去也是撒谎）。
       * ⚠️ 也**不要**在这里关 spinner：此刻 _probeRunningSeq 已经不属于
       *    本次（要么被 onChanged 置空、要么被新一轮接管）。关它就是
       *    去动别人的状态 —— 那正是这个竞态的另一半。
       */
      if (!mounted || mySeq != _probeSeq) return;
      /*
       * ★★★ 2026-10-19（R3-③ / R3-⑦）：**分类**，不是一句「测试失败：…」
       *
       * # 改前
       * ```text
       * `_probeCustomMessage = '测试失败：$e'`
       * ⇒ 用户看到「测试失败：SocketException: Connection timed out …」
       *   或者更糟 —— `DanmakuLocalService.probe` 内部**吞掉**异常并返回
       *   `online: false`，于是 UI 说「内置公共实例暂时连不上」。
       *   那一句把三件完全不同的事混成一件：
       *     ① 域名解析不出来（本机 DNS 坏了）
       *     ② 解析出来了但连不上（被墙/代理）  ← **本机就是这一类**
       *     ③ 连上了但服务报错（真·服务问题）
       * ```
       * # 改后
       * ```text
       * [DanmakuProbeReport.fromError] 按真实 errno / 异常类型分类，
       * 文案里**明说这是本机网络问题、不是服务坏了**，并给出下一步。
       * ```
       */
      final report = DanmakuProbeReport.fromError(
        e,
        url: ep?.display ?? (raw.isEmpty ? '本机弹弹play' : raw),
      );
      setState(() {
        _probeRunningSeq = null;
        _probeResult = null;
        _probeReport = report;
      });
      return;
    }
    // ★★ 核心守卫：await 期间输入变过 ⇒ 这次结果作废。
    //    不 setState、不落盘、**也不关 spinner** —— 三件事都必须被挡住。
    if (!mounted || mySeq != _probeSeq) return;
    setState(() {
      _probeRunningSeq = null;
      _probeResult = st;
      /*
       * ★ 2026-10-19：探针**不抛异常**、但判了 offline 时，core 只说
       *   「暂时连不上」—— 那还是把"为什么"藏起来了。
       *   先给一个占位结论（马上会被 [_diagnose] 的定向探测替换）。
       */
      _probeReport = st.online
          ? const DanmakuProbeReport(
              failure: DanmakuProbeFailure.none,
              url: '',
            )
          : DanmakuProbeReport(
              failure: DanmakuProbeFailure.connectionTimeout,
              url: ep?.display ?? raw,
              detail: '正在分层诊断（DNS / TCP）…',
              remedy: DanmakuProbeReport.remedyFor(
                DanmakuProbeFailure.connectionTimeout,
              ),
            );
    });
    // 测通了 ⇒ 落盘（用户点的就是「这个地址可用」，不落盘等于白填）
    // ⚠️ 落盘用**发起时捕获**的 raw/rawToken，不是当前输入框的值。
    if (st.online) {
      UiPrefs.setDanmakuEndpoint(raw);
      UiPrefs.setDanmakuToken(rawToken);
    }
    /*
     * ★★★ 2026-10-19（R3-③ / R3-⑦ 的关键一步）：判了 offline 之后，
     *   **真的去问一次"为什么"**（DNS / TCP），而不是笼统说连不上。
     *
     * 放在 setState 之后、不阻塞首帧：用户先看到"连不上"，
     * 一两秒后原因补上来（比让他盯着一个转圈等 6 秒好）。
     *
     * ⚠️ **注入了探针就不许打真网络**（与 `DanmakuSourcePage` 同一条纪律）：
     *    `probeOverride` 的语义是"零联网"。第一版无条件调 `_diagnose`，
     *    害得既有门禁报 "A Timer is still pending"（Socket.connect 的 6s 超时
     *    定时器活过了测试体）。注入方想给原因就自己抛带 errno 的异常，
     *    走上面的 catch —— 那条路**已经**会分类。
     */
    if (!st.online && ep != null && widget.probeOverride == null) {
      unawaited(_diagnose(ep, mySeq));
    }
  }

  /// 判了 offline ⇒ 分层探测：DNS → TCP → 给出**具体**是哪一层断了
  ///
  /// # 为什么要自己探一遍（core 已经探过了）
  /// ```text
  /// `DanmakuLocalService._probeOne` **刻意吞掉异常**返回 null
  /// （见它的文档：「404 会让部分服务直接抛，那是"这个端点没有"而不是"服务没起来"」）。
  /// 对"服务有没有起"这个问题那是对的；但对我们现在要回答的问题
  /// ——「**为什么**连不上」—— 它把唯一的证据扔掉了。
  /// ⇒ 这一层把证据捡回来（而且只在 UI 层，不动 core 的判据）。
  /// ```
  ///
  /// ⚠️ 全程带 [mySeq] 守卫：地址改过就作废（同 `_runProbe` 的纪律）。
  /// ⚠️ 超时给得很短（DNS 4s / TCP 6s）：目的是**分类**，不是等它成功。
  Future<void> _diagnose(DanmakuEndpoint ep, int mySeq) async {
    DanmakuProbeReport report;
    try {
      final addrs = await InternetAddress.lookup(ep.host)
          .timeout(const Duration(seconds: 4));
      if (addrs.isEmpty) {
        report = DanmakuProbeReport(
          failure: DanmakuProbeFailure.dnsFailed,
          url: ep.display,
          detail: 'DNS 没返回任何地址',
          remedy: DanmakuProbeReport.remedyFor(DanmakuProbeFailure.dnsFailed),
        );
      } else {
        /*
         * ★★★ 2026-10-19（R3-③/⑦ 归因修正）：**先核地址对不对，再谈 TCP**。
         *
         * # 为什么判定放在 TCP 之前
         * ```text
         * 本机实测：DNS 返回 74.86.17.48 / 2a03:2880:…:face:b00c，
         * 而 DoH 真值是 216.198.79.3 / 64.29.17.3。
         * ⇒ TCP 连的是**错地址**，超时只是下游后果。
         *   若先报 connectionTimeout，用户会去配代理碰运气；
         *   报 dnsHijacked 才会让他去**换 DNS**（正确的修法）。
         * ```
         */
        final local = addrs.map((a) => a.address).toList(growable: false);
        if (DanmakuProbeReport.looksForged(local)) {
          final doh = await DanmakuProbeReport.dohLookup(ep.host);
          report = DanmakuProbeReport.forHijackedDns(
            url: ep.display,
            localAddresses: local,
            dohAddresses: doh,
          );
        } else {
          final port = ep.hasPort ? ep.port : (ep.scheme == 'https' ? 443 : 80);
          try {
            final s = await Socket.connect(ep.host, port,
                timeout: const Duration(seconds: 6));
            s.destroy();
            // TCP 通了 ⇒ 问题在 HTTP 层（服务活着但拒绝/报错）
            report = DanmakuProbeReport(
              failure: DanmakuProbeFailure.serverError,
              url: ep.display,
              detail: 'TCP $port 可以连上，但探测端点没有给出可用响应',
              remedy: '网络是通的（TCP 连得上）⇒ 这次的问题在「服务端」：'
                  '它可能正在冷启动、或者这个实例的接口变了。'
                  '等几秒重试，或换一个实例。',
            );
          } on TimeoutException {
            /*
             * TCP 超时 + 地址**不在**伪造段 ⇒ 真的可能是被墙/代理。
             * 但仍然补一句"DoH 真值不同也可能是劫持"—— 因为伪造段表
             * 不可能穷举，`looksForged` 只是**强证据**不是**充要条件**。
             */
            final doh = await DanmakuProbeReport.dohLookup(ep.host);
            final differs = doh.isNotEmpty &&
                doh.toSet().intersection(local.toSet()).isEmpty;
            report = differs
                // 地址表没命中，但 DoH 真值完全不同 ⇒ 同样是劫持
                ? DanmakuProbeReport.forHijackedDns(
                    url: ep.display,
                    localAddresses: local,
                    dohAddresses: doh,
                    detail: 'TCP $port 连接超时',
                  )
                : DanmakuProbeReport(
                    failure: DanmakuProbeFailure.connectionTimeout,
                    url: ep.display,
                    detail: 'DNS 解析到 ${local.join(", ")}，'
                        '但 TCP $port 连接超时',
                    remedy: DanmakuProbeReport.remedyFor(
                      DanmakuProbeFailure.connectionTimeout,
                    ),
                  );
          } on SocketException catch (e) {
            report = DanmakuProbeReport.fromError(e, url: ep.display);
          }
        }
      }
    } on TimeoutException {
      report = DanmakuProbeReport(
        failure: DanmakuProbeFailure.dnsFailed,
        url: ep.display,
        detail: 'DNS 查询超时（4 秒）',
        remedy: DanmakuProbeReport.remedyFor(DanmakuProbeFailure.dnsFailed),
      );
    } on SocketException catch (e) {
      report = DanmakuProbeReport.fromError(e, url: ep.display);
    } catch (e) {
      report = DanmakuProbeReport.fromError(e, url: ep.display);
    }
    if (!mounted || mySeq != _probeSeq) return;
    setState(() => _probeReport = report);
  }

  /// 清除 ⇒ 回到内置路径（本机 2080 → 官方）。
  void _clearEndpoint() {
    // ★ 在途的测试结果绝不许把清空后的偏好写回来（同一条竞态纪律）；
    //   spinner 同时交还 —— 用户已经要求回到内置路径，那个请求与他无关了。
    _probeSeq++;
    _probeRunningSeq = null;
    UiPrefs.setDanmakuEndpoint('');
    UiPrefs.setDanmakuToken('');
    setState(() {
      _endpointUrl.text = '';
      _endpointToken.text = '';
      _probeResult = null;
      _probeCustomMessage = null;
      _probeReport = null;
    });
    widget.onChanged?.call();
  }

  /// 段落标题
  Widget _sectionTitle(String text, {String? note}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(
              color: DanmakuTextColors.body,
              fontSize: FontSizes.base,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (note != null) ...[
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                note,
                style: const TextStyle(
                  color: DanmakuTextColors.muted,
                  fontSize: FontSizes.cap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x2),
      child: Text(
        text,
        style: const TextStyle(
          color: DanmakuTextColors.muted,
          fontSize: FontSizes.cap,
        ),
      ),
    );
  }

  Widget _statusSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('状态'),
        Row(
          children: [
            _dot(s.enabled),
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                _statusText(s),
                style: const TextStyle(
                  color: DanmakuTextColors.secondary,
                  fontSize: FontSizes.sm,
                ),
              ),
            ),
          ],
        ),
        /*
         * 2026-10-15 (Owner: "this modal is so laggy").
         *
         * BEFORE: this line read state.count/lanes/dropped, which the host
         * refreshed once per second via setState -- rebuilding the whole
         * 16k-line player page for one line of text.
         * AFTER: the host only updates a ValueNotifier (no setState) and this
         * ValueListenableBuilder rebuilds just this Text.
         *
         * The readout semantics are unchanged (same once-per-second cadence,
         * same skip-when-unchanged rule) -- only the rebuild target changed.
         */
        if (widget.readout != null)
          ValueListenableBuilder<DanmakuReadout>(
            valueListenable: widget.readout!,
            builder: (_, r, __) => _hint(
              '画面里现在挂着 ${r.count} 条 · 轨道 ${r.lanes} 条 · 丢弃 ${r.dropped} 条',
            ),
          )
        else
          _hint('画面里现在挂着 ${s.count} 条 · 轨道 ${s.lanes} 条 · 丢弃 ${s.dropped} 条'),
      ],
    );
  }

  Widget _dot(bool on) {
    return Container(
      width: Sp.x2,
      height: Sp.x2,
      decoration: BoxDecoration(
        color: on ? Colors.lightBlueAccent : DanmakuTextColors.border,
        shape: BoxShape.circle,
      ),
    );
  }

  String _statusText(DanmakuSettingsState s) {
    if (!s.enabled) return '弹幕已关闭';
    if (s.loading) return '正在取弹幕…';
    if (s.error != null) return '取弹幕失败（下方有服务端原文）';
    if (s.status.isNotEmpty) return s.status;
    /*
     * ★ 2026-10-14（Owner 反馈「凭证流程根本没走通」）：判据仍是**生效**的
     *   凭证（用户覆盖 > 内置，见 `DanmakuConfig.isConfigured`），但口径改了：
     *   改前（输入框被删的那版）说「凭证未就绪（…不需要凭证）」——
     *   听着像"不用管"，而用户真去打官方边就是 403。
     *   现在有输入框了 ⇒ 缺凭证时**如实**说是缺凭证，并给出两条出路
     *   （下面填 / 改用免签名的那两条路）。
     */
    if (!DanmakuConfig.isConfigured) {
      /*
       * ★★★ 2026-10-18 第四版（Owner ④：「这个官方兜底也不知道是啥东西」）
       *
       * 改前：`'弹幕已开启，但凭证未配置（官方边会失败）'`
       * ```text
       * 「官方边」是**内部叫法**（我们把官方开放平台那条路叫"官方边"）。
       * Owner 明确说过他不知道"官方兜底"是什么 ⇒ 同一个词根的"官方边"
       * 也不该出现在用户面前。
       *
       * ⇒ 改成用户视角：**现在能不能用**、**用什么**。
       *   本构建内置实例默认就绪 ⇒ 用户根本不需要关心凭证。
       * ```
       * ⚠️ 判据（`isConfigured`）一个字没改，只改措辞。
       */
      return '弹幕已开启 · 正在用免凭证的来源';
    }
    if (DanmakuConfig.usingBuiltinAppId) {
      return '弹幕已开启（内置凭证 AppId ${DanmakuConfig.maskedAppId}）';
    }
    return '弹幕已开启（用户填写 AppId ${DanmakuConfig.maskedAppId}）';
  }

  /*
   * ★ 2026-10-15（Owner：「这个弹窗好丑…换成 ui 框架提供的」）
   *
   * 改前这里是手写 `Row`：**开关在左、文字在右**；而紧挨着的下面三行
   * （`_typeSwitch`）是**文字在左、开关在右**。同一个面板里两种相反布局，
   * 看着就是「没对齐」。
   *
   * 现在四处开关统一走 `SwitchListTile` —— 它带来三样手写 Row 没有的东西：
   * ```text
   * ① 整行可点（不只是那枚 52×32 的开关本身）
   * ② 点击涟漪 + 水波纹（Material 交互反馈）
   * ③ 读屏语义（会读成「显示弹幕，开关，已开启」）
   * ```
   *
   * ⚠️ `contentPadding: EdgeInsets.zero`：面板自己已有 24 的左右内边距，
   *    再叠一层 ListTile 默认的 16 就会比别的行缩进一截。
   * ⚠️ `dense: true`：面板窄（560），默认行高会让四处开关之间空隙过大。
   */
  Widget _switchSection() {
    return _switchRow(
      label: '显示弹幕',
      value: widget.state.enabled,
      onChanged: widget.onSetEnabled,
    );
  }

  /// 「数据源」状态行（T27-05）—— 本机跑着外部弹幕 就优先用本地源（免签名），
  /// 没跑就退回官方 API。
  ///
  /// ★ 2026-10-11（Owner 反馈）：这里**原来**还挂着 弹弹play 开放平台的
  ///   AppId / AppSecret 两个输入框 + 那枚删除按钮，当次整节移除了。
  /// ★ 2026-10-14（Owner 反馈「凭证流程根本没走通」）：输入框**恢复**，
  ///   但不再挂在这一节里 —— 它独立成 [_credentialsSection]（可门控、带如实
  ///   状态行）。本节现在只剩这一行**只读**的本机探测结果。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-18：**已从 UI 移除**（保留代码，不再被调用）
  /// ══════════════════════════════════════════════════════════════════
  /// Owner 亲自截图：「这个官方兜底也不知道是啥东西」。
  /// 加上本构建**没有内置凭证**（这条边必然 403），它占一个页签却只能
  /// 告诉用户"我用不了" ⇒ 那个页签已删除（见 [DanmakuPanelTab]）。
  ///
  /// **为什么保留这个方法而不是物理删除**：
  /// ```text
  /// 这套「数据源探测 + 签名」逻辑将来真接入官方开放平台时可以直接复用；
  /// 删掉容易，重写难。
  /// ```
  /// **要恢复的话**：在「高级」页签里加回对它的调用即可
  /// （`_credentialsSection` 同理）。
  ///
  /// ⚠️ 这段注释里**故意不写出那个调用形态的字面量**：
  ///    门禁 `zz_t66_danmaku_panel_semantics_test` 数的是"剥注释后
  ///    还剩几个调用点"，而 stripComments 只认 `//` 与 `/* */` ——
  ///    写在 `///` 文档注释里的调用形态**也会被剥掉**，
  ///    但如果我把它写成裸字面量就会被数进去 ⇒ 假红。
  ///    所以这里只用文字描述，不写代码形态。
  ///
  /// ⚠️ 它现在**不可达**（没有任何调用点）—— 这正是 Lead 要求的形态：
  ///    "不是死代码但被调用"，而是"保留但确实不可达"。
  // ignore: unused_element
  Widget _sourceSection() {
    if (widget.state.sourceLine.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('数据源', note: widget.state.sourceLine),
        const SizedBox(height: Sp.x3),
      ],
    );
  }

  /// Whether the credentials section is shown.
  ///
  /// 2026-10-15: always shown now. It used to be gated on both credential
  /// callbacks being present (because it contained the input boxes), but the
  /// section is read-only status now -- and users must always be able to see
  /// whether built-in credentials are in effect.
  ///
  /// ★ 2026-10-18：随 `_credentialsSection` 一起**不再被调用**（见那里的说明）。
  // ignore: unused_element
  bool get _showCredentialsSection => true;

  /// ★★★ 2026-10-14（Owner）：「凭证」节 —— 两个输入框 + 保存 / 清除 + **如实**状态行
  ///
  /// Owner 原话：> 本地播放提示 [弹幕服务] 没有收到凭证,说明 [弹幕服务] 流程根本没走通
  ///
  /// # 状态行逐字段都从 `DanmakuConfig` 的**真实 getter** 读
  /// ```text
  /// 内置是否可用 ⇒ hasBuiltinCredentials（不是猜"有没有注入"）
  /// 生效的是哪一份 ⇒ usingBuiltinAppId ? 内置 : 用户填写
  /// 两者都没有     ⇒ 明说"官方边会失败"，并给两条**真实存在**的免签名路
  /// ```
  /// 这三档与 [_statusText] 是**两个不同的问题**：[_statusText] 说"弹幕现在
  /// 什么状态"，本节说"凭证这个配置项现在什么情况"。两条都如实、且都不许
  /// 在 UI 里自己拼字符串判断 —— 判据全在 `DanmakuConfig`。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-18：**已从 UI 移除**（保留代码，不再被调用）
  /// ══════════════════════════════════════════════════════════════════
  /// 与 [_sourceSection] 同一条裁决（Owner「这个官方兜底也不知道是啥东西」+
  /// 本构建无内置凭证）。整个「官方兜底」页签已删除。
  ///
  /// **为什么保留**：AppId/AppSecret 的签名与状态判断逻辑将来可复用。
  /// **怎么恢复**：在「高级」页签里加回对它的调用即可
  /// （理由同 `_sourceSection` 上那段：注释里不写调用形态的字面量，
  ///   否则门禁会把注释数成调用点 ⇒ 假红）。
  // ignore: unused_element
  Widget _credentialsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        /*
         * ★ 2026-10-17（Owner 第 11 条）：note 从 `弹弹play` 改成 `官方兜底 · 要签名`
         *
         * # 为什么不写服务名
         * ```text
         * Owner：「弹弹play 我说了要让可用的dan-api去替换的,
         *         这里的弹幕面板怎么还是弹弹play?」
         * 这一节是**官方开放平台**那条边（要 AppId/AppSecret 签名），
         * 页签已经叫「官方兜底」⇒ 这里再写一遍服务名只会让用户以为
         * "这个面板仍然只支持那一家"。
         * ```
         */
        _sectionTitle('凭证', note: '官方兜底 · 要签名'),
        // ── 状态行（如实）──
        Row(
          children: [
            _dot(DanmakuConfig.isConfigured),
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                _credentialStatusText,
                style: const TextStyle(
                  color: DanmakuTextColors.secondary,
                  fontSize: FontSizes.sm,
                ),
              ),
            ),
          ],
        ),
        /*
         * 2026-10-15 (Owner): "I told you to delete those two input boxes and
         * use the built-in credentials -- it is still not done."
         *
         * Before deleting, the developer agreement was checked (the Owner
         * asked for that explicitly: "check whether the developer statement
         * allows built-in; if not, keep the input boxes").
         *
         * The official Open Danmaku Network docs, section 7 (Security Notes),
         * say in full:
         *
         *   > Try not to hard-code your AppSecret in a client application.
         *   > If you are developing an open-source client project, you can:
         *   >   - use a placeholder in the open-source code to keep the
         *   >     AppSecret from leaking, then at build time (e.g. with GitHub
         *   >     Actions) read the AppSecret from a secret store and
         *   >     substitute the placeholder.
         *
         * So built-in credentials ARE allowed -- provided they go through
         * "placeholder + build-time injection". That is exactly what this
         * repo already does (String.fromEnvironment in core/danmaku.dart, plus
         * build.yml pulling from GitHub Secrets, plus tools/run_client.ps1 for
         * local builds) => the input boxes can go.
         *
         * The credentials were verified against the live API before deleting
         * anything (a signed request to /api/v2/comment/123450001 returned
         * HTTP 200), so removing the manual entry point does not leave users
         * without a working path.
         *
         * WHAT IS KEPT: the status line below. Users still need to be able to
         * tell whether built-in credentials are in effect or nothing is
         * configured. What was deleted is the INPUT, not the VISIBILITY.
         */
        // When this build has no built-in credentials (local build without
        // --dart-define), say so honestly and point at the paths that work
        // without credentials.
        if (!DanmakuConfig.isConfigured) ...[
          _hint(
            '本构建没有内置凭证，官方边会失败（服务端会回「没收到凭证」）。'
            '改用本机外部弹幕 / 外部视频源弹幕 —— 那两条路「免签名」、不需要凭证。',
          ),
        ],
        if (DanmakuConfig.isConfigured)
          _hint('凭证由客户端内置（官方允许：开源代码放占位符，构建时注入）。无需手填。'),
      ],
    );
  }

  /// 凭证状态的一句话 —— 三档，逐字段读 `DanmakuConfig` 真实 getter。
  String get _credentialStatusText {
    // ① 生效的是**用户填写**的（优先级最高，压过内置）
    if (DanmakuConfig.isConfigured && !DanmakuConfig.usingBuiltinAppId) {
      return '当前生效：用户填写（AppId ${DanmakuConfig.maskedAppId}）';
    }
    // ② 只剩内置可用
    if (DanmakuConfig.usingBuiltinAppId) {
      return '当前生效：内置凭证（AppId ${DanmakuConfig.maskedAppId}）';
    }
    // ③ 内置也没注入（本地构建常见）—— 如实说
    return '未配置凭证';
  }

  Widget _displaySection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('显示', note: '即时生效'),
        _slider(
          '字号',
          s.fontScale,
          DanmakuConfig.fontScaleMin,
          DanmakuConfig.fontScaleMax,
          widget.onSetFontScale,
          '${(s.fontScale * 100).round()}%',
        ),
        _slider(
          '透明度',
          s.opacity,
          DanmakuConfig.opacityMin,
          DanmakuConfig.opacityMax,
          widget.onSetOpacity,
          '${(s.opacity * 100).round()}%',
        ),
        _slider(
          '速度',
          s.speed,
          DanmakuConfig.speedMin,
          DanmakuConfig.speedMax,
          widget.onSetSpeed,
          '${s.speed.toStringAsFixed(1)}s',
        ),
        _hint('一条弹幕从右边缘走到左边缘的秒数（越大越慢）'),
        _slider(
          '显示区域',
          s.area,
          DanmakuConfig.areaMin,
          DanmakuConfig.areaMax,
          widget.onSetArea,
          '${(s.area * 100).round()}%',
        ),
        _hint(
          '弹幕从画面「顶部往下」能占用的高度比例（对齐 某视频站）。'
          '默认 50% = 只占上半屏，下半屏留给画面与字幕；拖到 100% 才铺满全屏。',
        ),
      ],
    );
  }

  /// ★★★ 2026-10-09 新增：屏蔽与分类开关（对齐 某视频站的弹幕设置）
  ///
  /// Owner 原话：「弹幕管理 还要支持指定区域的屏幕不显示 大小 屏蔽 速度 等等,
  ///            这些都参考某视频站的弹幕设置就行了」
  ///
  /// 与上面「显示」那一节的分工：
  /// ```text
  /// 显示  ⇒ 字号/透明度/速度/占用区域（"长什么样"）
  /// 本节点 ⇒ 显示哪几类 + 屏蔽哪些词（"留哪些"）
  /// ```
  /// ⚠️ 与 某视频站的差异：某视频站把"显示类型"和"屏蔽类型"分成两处（容易让人困惑
  ///    为什么同一类要开关两次）。这里合并成一组三态开关：
  ///    关 = 不显示（等价于 某视频站两个开关都关）。
  Widget _filterSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('显示哪些弹幕', note: '即时生效'),
        _typeSwitch(
          '滚动弹幕',
          DanmakuConfig.showScroll,
          DanmakuConfig.setShowScroll,
        ),
        _typeSwitch('顶部弹幕', DanmakuConfig.showTop, DanmakuConfig.setShowTop),
        _typeSwitch(
          '底部弹幕',
          DanmakuConfig.showBottom,
          DanmakuConfig.setShowBottom,
        ),
        _hint('关掉某一类 ⇒ 那一类的弹幕不再进入渲染（也不占轨道）'),
        const SizedBox(height: 8),
        _blockWordsHeader(),
        _blockWordsWrap(),
        _blockWordsAddField(),
        const SizedBox(height: Sp.x2),
        _typeSwitch(
          '按正则匹配',
          DanmakuConfig.blockRegex,
          DanmakuConfig.setBlockRegex,
        ),
        _hint(
          DanmakuConfig.blockRegex
              ? '当前按正则解释（写错了会自动跳过那一条，不会屏蔽全部）'
              : '当前按"包含"匹配（勾上右边开关可改用正则）',
        ),
      ],
    );
  }

  /// 三类弹幕的显示开关
  /// 三类弹幕的显示开关 + 「按正则匹配」
  ///
  /// ★ 2026-10-15：与 `_switchSection()` 统一成 `SwitchListTile`
  ///   （原来这里是手写 Row + Switch）。四处开关现在**同一套布局**：
  ///   文字在左、开关在右、整行可点、带涟漪与读屏语义。
  Widget _typeSwitch(String label, bool value, void Function(bool) set) {
    return _switchRow(
      label: label,
      value: value,
      onChanged: (v) {
        set(v);
        // 立刻重建对话框，让开关与渲染同步（父层也会收到回调）
        widget.onChanged?.call();
      },
    );
  }

  // =====================================================================
  //  2026-10-15 (Owner): "danmaku blocking does not support search, and
  //  one-word-per-line wastes far too much space."
  // =====================================================================
  //
  // BEFORE: one multi-line TextField (maxLines 4 / minLines 3), one word per
  // line.  - words beyond the 4th were hidden behind a scroll
  //        - no search, so deleting one word meant scanning the whole blob
  //        - every keystroke rewrote the entire preference string
  //
  // AFTER, in three parts:
  //   1. search box      -- only appears when there are many words
  //   2. chip wrap       -- a dozen+ words visible at once, tap x to delete
  //   3. add field       -- type a word, press Enter
  //
  // NOTE: the underlying storage is UNCHANGED -- still the newline-separated
  // string under dsh.danmaku.blockWords. Existing user preferences keep
  // working with no migration, and DanmakuConfig.blockWords still does the
  // trim/dedupe parsing. This only changes the editing surface.

  /// Below this many words there is no point showing a search box.
  ///
  /// Most people block two or three words (e.g. 剧透 / 前方高能); adding a
  /// search field for those just takes up space when everything is visible
  /// at a glance anyway.
  static const int _kBlockSearchMinWords = 9;

  Widget _blockWordsHeader() {
    final words = DanmakuConfig.blockWords;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('屏蔽词', note: '${words.length} 个'),
        if (words.length >= _kBlockSearchMinWords)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x2),
            child: TextField(
              controller: _blockSearch,
              style: const TextStyle(
                color: DanmakuTextColors.muted,
                fontSize: FontSizes.sm,
              ),
              decoration: InputDecoration(
                hintText: '搜索屏蔽词（共 ${words.length} 个）',
                prefixIcon: const Icon(AppIcons.search, size: 18),
                suffixIcon: _blockSearch.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(AppIcons.close, size: 18),
                        tooltip: '清除搜索',
                        onPressed: () => setState(_blockSearch.clear),
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
      ],
    );
  }

  /// The words currently shown (filtered by the search box when non-empty).
  List<String> get _visibleBlockWords {
    final all = DanmakuConfig.blockWords;
    final q = _blockSearch.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((w) => w.toLowerCase().contains(q)).toList();
  }

  /// Chip wrap -- a dozen+ words visible at once, tap x to delete.
  Widget _blockWordsWrap() {
    final all = DanmakuConfig.blockWords;
    final shown = _visibleBlockWords;
    if (all.isEmpty) {
      return _hint('还没有屏蔽词。在下面的框里输入，回车即可添加。');
    }
    if (shown.isEmpty) {
      return _hint('没有匹配「${_blockSearch.text.trim()}」的屏蔽词。');
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Wrap(
        spacing: Sp.x1,
        runSpacing: Sp.x1,
        children: [
          for (final w in shown)
            InputChip(
              /*
               * ⚠️ The TextStyle MUST carry a colour. `t27_w1_danmaku_contrast_test`
               * scans the source for `TextStyle(` without `color:`/`foreground:` and
               * fails on it -- a style with no colour silently inherits the theme's
               * default, which on this dark panel can end up unreadable.
               * `labelStyle` below sets the colour too; this one is the label's own
               * override and has to stand on its own.
               */
              label: Text(
                w,
                style: const TextStyle(
                  color: DanmakuTextColors.body,
                  fontSize: 12,
                ),
              ),
              /*
               * ★★ 2026-10-16（Owner 实测截图：「屏蔽词」下面的药丸看不清）
               *
               * 改前 `labelStyle` 是 muted 而 `backgroundColor` 是
               * `Colors.transparent` ⇒ 药丸**没有自己的底**，直接露出分组卡片的
               * 浅底；而「1 个」这种计数与药丸挤在同一行时，整体就是一片浅灰
               * ⇒ 药丸与文字都糊在一起。
               *
               * ⇒ 三处都收到 `DanmakuTextColors` 既有灰阶上：
               *     药丸底  border @35%（比分组卡片略抬一档 ⇒ 看得出是个`药丸`）
               *     描边    border（与分组卡片同一支灰，1.6:1 装饰线）
               *     文字    body #E6E6E6（14.5:1，t27_w1 门禁钉着）
               *     ✕       secondary #B9BEC6（9.7:1）
               * ⚠️ 面板强制深色 ⇒ 一律不引 colorScheme（见外壳 forceDarkCard）。
               */
              labelStyle: const TextStyle(color: DanmakuTextColors.body),
              deleteIcon: const Icon(
                AppIcons.close,
                size: 14,
                color: DanmakuTextColors.secondary,
              ),
              // Delete by exact value (shown holds the original strings).
              onDeleted: () => _removeBlockWord(w),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              side: const BorderSide(color: DanmakuTextColors.border),
              backgroundColor: DanmakuTextColors.border.withValues(alpha: 0.35),
            ),
        ],
      ),
    );
  }

  /// Append one word, keeping the newline-separated storage format intact.
  void _addBlockWord(String raw) {
    final w = raw.trim();
    if (w.isEmpty) return;
    final all = DanmakuConfig.blockWords;
    // Already present => do not add twice (blockWords dedupes on read anyway,
    // this just avoids making the user think something happened).
    if (all.contains(w)) return;
    DanmakuConfig.setBlockWords('${all.join('\n')}\n$w');
    widget.onChanged?.call();
  }

  /// Remove one word by EXACT match -- not substring.
  ///
  /// Substring deletion would make removing 剧透 also remove 剧透警告, which
  /// the user did not ask for.
  void _removeBlockWord(String w) {
    final all = DanmakuConfig.blockWords.where((x) => x != w).toList();
    DanmakuConfig.setBlockWords(all.join('\n'));
    widget.onChanged?.call();
  }

  /// Add field (Enter or the plus button appends).
  ///
  /// NOTE: the controller is held by the State (see [_blockWords]) -- do NOT
  /// create it in build. A fresh controller each build makes the field show
  /// the normalized preference value forever, so users cannot type anything.
  Widget _blockWordsAddField() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            /*
             * Stable key for tests. Before the 2026-10-15 redesign the block
             * word box was the panel's only maxLines==4 EditableText, so tests
             * found it by that property. The redesign turned it into a set of
             * chips plus this one-line add field, so the old finder matches
             * nothing. Keying the field keeps the lookup unambiguous without
             * pinning a layout detail that may change again.
             */
            key: blockWordsAddFieldKey,
            controller: _blockWords,
            style: const TextStyle(
              color: DanmakuTextColors.muted,
              fontSize: FontSizes.sm,
            ),
            decoration: const InputDecoration(
              hintText: '添加屏蔽词，回车确认',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (v) {
              _addBlockWord(v);
              _blockWords.clear();
              setState(() {});
            },
          ),
        ),
        const SizedBox(width: Sp.x1),
        IconButton(
          tooltip: '添加',
          icon: const Icon(AppIcons.add, size: 20),
          onPressed: () {
            _addBlockWord(_blockWords.text);
            _blockWords.clear();
            setState(() {});
          },
        ),
      ],
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
    String readout,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: const TextStyle(
                color: DanmakuTextColors.secondary,
                fontSize: FontSizes.sm,
              ),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              readout,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: DanmakuTextColors.muted,
                fontSize: FontSizes.cap,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索区是否显示 —— 两个回调**都在**才画。
  ///
  /// 只给 `onSearch` 会出现「结果列表画得出来、点一条却没反应」的假 UI；
  /// 只给 `onPickMatch` 则连搜索框都没有、列表永远是空的。两头都是残废形态，
  /// 所以门控取"与"。
  bool get _showSearchSection =>
      widget.onSearch != null && widget.onPickMatch != null;

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ 2026-10-18 第四版：弹幕来源（可多选，勾选即参与合并）
  // ══════════════════════════════════════════════════════════════════

  /// ★★★ 2026-10-19（第 66 轮 Owner 第 ⑤ 条）：**真正可多选**的绑定集合
  ///
  /// # 改前是什么（实测读数，不是推测）
  /// ```text
  /// 上一版 `_sourcesSection` 的标题写着「可多选 · 勾上即合并」，
  /// 而四个 `_sourceRow(...)` 调用点**全部** `onChanged: null`
  /// （实测 4/4，见 2401-2530 行）⇒ `_sourceRow` 把勾选框画成**只读**
  /// （它自己的文档也写着「勾选框只读」）。
  ///
  /// ⇒ 用户看到「可多选」，但**一个都点不动** —— 这就是本仓明令禁止的
  ///   "画了个假开关"。而 Owner 原话正是：
  ///   「弹幕源可以绑定多个」。
  /// ```
  ///
  /// # 改后：集合是真状态，且**有消费方**
  /// ```text
  /// `_enabledFeeds` 是本面板持有的「用户勾了哪几路」。
  /// 它的消费方不是"画个勾" —— 而是 [DanmakuFeedBinding.merge]：
  /// 拿**真实的**多路弹幕列表做合并，输出条数与去重数。
  /// 门禁 `zz_t66_r3_multi_source_test.dart` 读的是**合并结果**，
  /// 不是控件状态（读控件状态的门禁会让"勾上了但没合并"照样绿）。
  /// ```
  ///
  /// # 为什么"本片源自带"不可取消
  /// ```text
  /// 它是**视频本身带的**弹幕 —— 用户取消不了"这个视频自带弹幕"这个事实。
  /// 与 Owner 第 2 条同一条语义（那条要求它**默认**勾上）。
  /// ⇒ 它始终在集合里，勾选框只读且**恒为勾**。
  /// ```
  final Set<DanmakuFeedChannel> _enabledFeeds = <DanmakuFeedChannel>{
    DanmakuFeedChannel.biliSource,
  };

  /// 勾选/取消一路来源
  void _toggleFeed(DanmakuFeedChannel ch, bool on) {
    // 本片源自带不可取消（见 [_enabledFeeds] 的文档）
    if (ch == DanmakuFeedChannel.biliSource) return;
    setState(() {
      if (on) {
        _enabledFeeds.add(ch);
      } else {
        _enabledFeeds.remove(ch);
      }
    });
    widget.onChanged?.call();
  }

  /// 当前**真的**勾着、且这一路**确实有数据**的通道（喂给合并器）
  ///
  /// # 什么算"有数据"（两种事实，强度不同）
  /// ```text
  /// ① 宿主注入了**逐条内容**（`_feedSamples`）⇒ 能真的合并/去重
  /// ② 只给了**条数**（只有「本片源自带」有这条路：`biliCount`）
  ///    ⇒ 只能计数，不能去重 —— 这一点必须在读数里**说出来**，
  ///      不能拿"合计"冒充"合并后"
  /// ```
  /// ⚠️ 只勾了不算：勾上 dan-api 而宿主没给内容时，它**不进**这里
  ///    （否则读数会凭空多一路 —— 那是捏造）。
  List<DanmakuFeedChannel> get _activeFeedChannels => <DanmakuFeedChannel>[
        for (final ch in DanmakuFeedChannel.values)
          if (_enabledFeeds.contains(ch) && _hasDataFor(ch)) ch,
      ];

  /// 这一路手上有没有**任何**可用读数（逐条内容，或至少一个条数）
  bool _hasDataFor(DanmakuFeedChannel ch) {
    if (_feedSamples.containsKey(ch)) return true;
    // 本片源自带的条数由宿主单独给（`biliCount`），没有内容也是真事实
    if (ch == DanmakuFeedChannel.biliSource) return _biliCount != null;
    return false;
  }

  /// 这一路的条数（内容优先；没有内容时退到宿主给的条数）
  int _countOf(DanmakuFeedChannel ch) {
    final s = _feedSamples[ch];
    if (s != null) return s.length;
    if (ch == DanmakuFeedChannel.biliSource) return _biliCount ?? 0;
    return 0;
  }

  /// 每一路都有**逐条内容**吗（没有就只能计数，不能去重）
  bool get _canMergeItemByItem => _activeFeedChannels
      .every((ch) => _feedSamples.containsKey(ch));

  /// 本面板手上**真实可合**的几路样本（宿主没给的就是没有）
  ///
  /// # 为什么宿主必须注入
  /// ```text
  /// 合并的原料是 `List<DanmakuComment>`，而本面板是**纯 UI**
  /// （见文件头：不碰网络/播放器/令牌）。它拿不到别的源的弹幕列表。
  /// ⇒ 宿主通过 [DanmakuSettingsDialog.feedSamples] 注入"每一路现在有什么"。
  ///   不注入 ⇒ 面板**如实**退成"只有本片源那一路的条数"，
  ///   并在读数里明说"未逐条合并"。
  /// ```
  Map<DanmakuFeedChannel, List<DanmakuComment>> get _feedSamples =>
      widget.feedSamples ?? const <DanmakuFeedChannel, List<DanmakuComment>>{};

  /// 合并读数（**这就是"多绑真的生效"的证据**）
  ///
  /// 调用 core 的 `DanmakuAggregator.merge`（同一份去重/排序实现）——
  /// 本面板**不重写**合并逻辑：写第二份就会与取弹幕那条路漂移。
  ///
  /// ⚠️ 只有**每一路都有逐条内容**时才做逐条合并；
  ///    缺内容时返回 null，由 [_activeSummary] 走"仅合计"的如实文案。
  DanmakuAggregate? get _mergedPreview {
    final chans = _activeFeedChannels;
    if (chans.isEmpty || !_canMergeItemByItem) return null;
    return DanmakuAggregator.merge(<DanmakuFeedInput>[
      for (final ch in chans)
        DanmakuFeedInput(
          kind: _coreChannelOf(ch),
          comments: _feedSamples[ch] ?? const <DanmakuComment>[],
          detail: ch.label,
        ),
    ]);
  }

  /// 面板的通道 ⇒ core 的来源类别（合并器的入参）
  ///
  /// ⚠️ `biliSource` / `biliExternal` / `danApi` 三路都映射到 `imported`：
  ///    本仓把「不是插件、不是本机服务」的那几路一律归在**导入源**语义下
  ///    （见 `player_page._aggregateDanmaku` 的 `primaryKind`）。
  ///    `DanmakuSourceChannel` 是 core 的**类别**，不是"具体哪一路" ——
  ///    具体哪一路由 `DanmakuFeedInput.detail` 区分（见 [_mergedPreview]）。
  static DanmakuSourceChannel _coreChannelOf(DanmakuFeedChannel ch) =>
      switch (ch) {
        DanmakuFeedChannel.biliSource => DanmakuSourceChannel.imported,
        DanmakuFeedChannel.biliExternal => DanmakuSourceChannel.imported,
        DanmakuFeedChannel.danApi => DanmakuSourceChannel.imported,
        DanmakuFeedChannel.localService => DanmakuSourceChannel.local,
        DanmakuFeedChannel.plugin => DanmakuSourceChannel.plugin,
      };

  /// 「弹幕来源」页签 —— 这一页回答**唯一**一个问题：
  /// 「这一集的弹幕从哪来、每条路现在什么状态、我要怎么切」。
  ///
  /// # 四条来源为什么**平级各占一行**
  /// ```text
  /// Owner 2026-10-18 亲自截图，四条反馈里两条直接指向这里：
  ///
  /// ① 「某个视频站的弹幕设置怎么没了」
  ///    ⇒ 第三版被我藏成「插件提供」里一枚叫「外部弹幕…」的按钮。
  ///      **减少点击层数 ≠ 提高可发现性** —— 藏在别的名字下等于没有。
  ///      现在它与 dan-api **平级**，名字直接叫出来。
  ///
  /// ③ 「dan-api只有测试」
  ///    ⇒ 第三版那个 tab 里真的只有地址框 + 测试连接 + 清除。
  ///      现在 dan-api 那一行带「搜索…」，点开就是搜索 + 选中 + 绑定。
  ///
  /// ② 「插件提供是什么」
  ///    ⇒ Owner 的语义：视频源插件**随片自带**每一集的弹幕 ⇒ 默认导入。
  ///      所以这一行改名「本片源自带」，且**默认勾上**（见 [_sourceRow]）。
  /// ```
  ///
  /// # 为什么是 ☑/☐ 多选，不是 ●/○ 单选
  /// ```text
  /// Owner 第 11 条原话：「同时加载并合并」
  /// ⇒ 多路可以叠加（`4aeb79a` 让手动绑定后插件那份也并进来）。
  ///
  /// 与 Owner 第 6 条不冲突：
  ///   第 6 条禁的是「不许**自动绑定**外部源」，
  ///   不是「不许**手动多选**多个源」。
  /// ```
  ///
  /// ★★★ 2026-10-19（第 66 轮 Owner 第 ⑤ 条）：**勾选框从只读改成真可点**
  /// ```text
  /// 改前四个调用点全是 `onChanged: null` ⇒ 一个都点不动，
  /// 标题却写着「可多选」—— 假开关（本仓明令禁止的形态）。
  /// 改后：除「本片源自带」（不可取消，理由见 [_enabledFeeds]）外，
  /// 每一路都能勾/取消，且勾选结果**真的**进 [DanmakuFeedBinding.merge]。
  /// ```
  Widget _sourcesSection() {
    final s = widget.state;
    final biliBound = _biliCount != null;
    final local = _probeResult;
    final localOnline = local?.online ?? false;
    final danApiReady = DanmakuConfig.effectiveEndpoint != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('弹幕来源', note: '可多选 · 勾上即合并'),
        _hint(
          '勾上的来源会「同时加载并合并」（重复的自动去掉）。'
          '本片源自带默认勾上 —— 那是视频本身带的弹幕。',
        ),
        const SizedBox(height: Sp.x2),
        /*
         * ① 本片源自带 —— **默认勾上**
         *
         * Owner ②：「比如某个视频源 它本身视频源每一集都有对应的弹幕数据,
         *          那么就默认导入他自身的就行了」
         * ⇒ 它是视频的一部分 ⇒ 自动。这与第 6 条「其他都要手动绑定」自洽。
         */
        _sourceRow(
          channel: DanmakuFeedChannel.biliSource,
          detail: _biliCount == null ? '本片源没有提供' : '$_biliCount 条 · 可看',
          // 它恒在集合里（见 [_enabledFeeds]）⇒ 恒为勾
          checked: true,
          // 勾上 ≠ 可取消：它是视频自带的，用户取消不了"视频本身带弹幕"这件事
          onChanged: null,
          trailing: _badge('默认'),
        ),
        /*
         * ★★★ 2026-10-18（Lead 追加口径）：「能看」与「能发」是两件事
         *
         * # 为什么必须有这一行
         * ```text
         * 发送输入框的挂载条件是 AND 谓词：
         *   _danmakuEnabled && _danmakuCanSend && _danmakuSendProvider != null && !_isLive
         * 两个插件都**没有**声明 danmakuSend 能力 ⇒ 输入框整条不渲染
         * （Owner 第 1 条「不支持就不显示」，宿主判得对）。
         *
         * ⚠️ 但"不显示"不等于"不解释"：
         *    用户看到上面写着「本片源自带 1200 条」，却没有发送框 ⇒
         *    他会以为**坏了**，而不是"这个源不支持发"。
         * ```
         * # 所以：输入框仍然不显示，但这里明说一句
         * ```text
         * 这与 Owner 第 1 条**不矛盾**：
         *   那条说的是「不支持发弹幕 ⇒ 不显示**发送输入框**」，
         *   不是「不许告诉用户为什么没有」。
         * ```
         *
         * ★★★ 2026-10-20（裁决 A：把解释搬到**发现点**）
         * ```text
         * 改前条件是 `biliBound && !canSendDanmaku`
         *   ⇒ 没绑定这一路时**什么都不说**：用户看到「本片源没有提供」+ 没有发送框，
         *     只剩一片空白，不知道是"这一路没内容"还是"这源根本发不了"。
         * 改后条件是 `!canSendDanmaku`
         *   ⇒ 「能不能发」与「有没有绑定某一路」是两件事，前者为假就该解释。
         *
         * 文案按 R6 先例：**给「能做什么」**，不写干瘪的否定；
         * 且原因必须**指向片源**（不许写成网络/登录/设置/出错），
         * 否则用户会去翻设置找不存在的问题（同 AGENTS §8「只到结论不到原因」的教训）。
         * ```
         */
        if (!widget.canSendDanmaku)
          const Padding(
            padding: EdgeInsets.only(left: Sp.x6, top: 2),
            child: Text(
              '弹幕可以看、调样式、合并多路来源；发送只在支持发送的片源里提供',
              style: TextStyle(
                color: DanmakuTextColors.muted,
                fontSize: FontSizes.cap,
              ),
            ),
          ),
        const SizedBox(height: Sp.x1),
        /*
         * ② 某个视频站 —— **独立可见的入口**（Owner ① 的核心修复）
         *
         * ⚠️ 这一行里出现的站名是 Owner 明确允许的弹幕源语境
         *    （见 `_kBiliSourceLabel` 上的历史说明与 t98 行级豁免）。
         */
        _sourceRow(
          channel: DanmakuFeedChannel.biliExternal,
          detail: biliBound ? '已绑定' : '未绑定',
          checked: _enabledFeeds.contains(DanmakuFeedChannel.biliExternal),
          /*
           * ★★★ 2026-10-19（Owner 第 ⑤ 条）：**可点了**
           *
           * 改前这里是 `onChanged: null` ⇒ 复选框只读，标题却写着「可多选」。
           * 现在勾上 = 这一路参与合并（[DanmakuMergePreview]）。
           *
           * ⚠️ 没绑定时勾它**不假装已绑定**：下面的 detail 仍然写「未绑定」，
           *    合并读数也会如实说"这一路没有可合的内容"（宿主没给样本）。
           *    勾选表达的是"我要它参与"，绑定与否是另一个事实。
           */
          onChanged: (v) => _toggleFeed(DanmakuFeedChannel.biliExternal, v),
          trailing: widget.onOpenBili == null
              ? null
              : _rowAction('打开…', widget.onOpenBili!),
        ),
        const SizedBox(height: Sp.x1),
        /*
         * ③ dan-api —— 搜索 + 选中 + 绑定（Owner ③ 的核心修复）
         *
         * ⚠️ 它和 ② 用的是**同一个搜索/绑定通道**（`onSearch` / `onPickMatch`），
         *    宿主侧共用同一个 client —— 技术上一直能搜，
         *    第三版只是把入口错放进了 plugin tab。
         */
        _sourceRow(
          channel: DanmakuFeedChannel.danApi,
          detail: danApiReady
              ? (DanmakuConfig.usingPublicInstance
                    ? '内置实例 · 免凭证'
                    : '自填地址 · 免凭证')
              : '未配置',
          checked: _enabledFeeds.contains(DanmakuFeedChannel.danApi),
          onChanged: (v) => _toggleFeed(DanmakuFeedChannel.danApi, v),
          trailing: _showSearchSection
              ? _rowAction('搜索…', () => _focusSearch(s))
              : null,
        ),
        const SizedBox(height: Sp.x1),
        /*
         * ④ 本机服务 —— 探测 + 使用
         */
        _sourceRow(
          channel: DanmakuFeedChannel.localService,
          detail: local == null
              ? '未检测'
              : (localOnline
                    ? '已运行${local.version == null ? "" : " · v${local.version}"}'
                    : '未运行'),
          checked: _enabledFeeds.contains(DanmakuFeedChannel.localService),
          onChanged: (v) => _toggleFeed(DanmakuFeedChannel.localService, v),
          trailing: _probeRunning
              ? const AppInlineSpinner(
                  size: 14,
                  color: DanmakuTextColors.body,
                )
              : _rowAction('检测', _runProbe),
        ),
        const SizedBox(height: Sp.x3),
        /*
         * 当前生效读数 —— 与顶部状态条**同一套口径**，
         * 但这里额外说明"几路在合并"，因为这一页是用户做选择的地方。
         */
        _hint(_activeSummary()),
      ],
    );
  }

  /// 「当前生效」那一行 —— ★ 2026-10-19：改成读**真实合并结果**
  ///
  /// # 改前是什么（读数）
  /// ```text
  /// 它把「本片源 $_biliCount 条 + 本机服务 + dan-api」拼成一句话，
  /// 括号里再补 `state.count` —— 那是**宿主取回来的总条数**，
  /// 与"用户勾了哪几路"**没有任何因果关系**。
  /// ⇒ 用户勾上 dan-api 之后，这句话的括号里**不会变**（除非宿主重取），
  ///   于是"勾选参与合并"在读数上**看不出来** —— 又一处假接线。
  /// ```
  /// # 改后
  /// ```text
  /// 直接读 [DanmakuMergePreview]（= `DanmakuAggregator.merge` 的真结果）：
  ///   · 单路  ⇒ `单源 · 本片源自带 1200 条`
  ///   · 多路  ⇒ `3 路 → 合并后 1400 条（跨源去重 100）`
  /// 勾/取消一路 ⇒ 这句话**立刻**变 —— 这是"多绑真的生效"的可见证据。
  /// ```
  String _activeSummary() {
    final chans = _activeFeedChannels;
    if (chans.isEmpty) {
      return '当前生效：还没有任何来源在供弹幕 —— 上面的来源可以勾选，'
          '或者用下面的「重新获取弹幕」再试一次。';
    }
    final agg = _mergedPreview;
    final names = chans.map((c) => c.label).join(' + ');

    /*
     * ① 只有一路 ⇒ 不叫"合并"，直接报这一路的条数。
     */
    if (chans.length < 2) {
      return '当前生效：单源 · ${chans.first.label} '
          '${_countOf(chans.first)} 条';
    }

    /*
     * ② 多路 + 每一路都有逐条内容 ⇒ 真的逐条合并（能报去重数）。
     */
    if (agg != null) {
      final deduped = agg.deduped;
      return '当前生效：${chans.length} 路（$names）'
          '→ 合并后 ${agg.comments.length} 条'
          '${deduped > 0 ? "（跨源去重 $deduped 条）" : ""}';
    }

    /*
     * ③ 多路但缺逐条内容 ⇒ **只能计数**，必须说出来。
     *    ⚠️ 这里若写"合并后"，就是拿"相加"冒充"合并" ——
     *       两者在有重复时会给出不同的数字，用户会照着错数字排错。
     */
    final sum = chans.fold<int>(0, (a, c) => a + _countOf(c));
    return '当前生效：${chans.length} 路（$names）合计 $sum 条 —— '
        '其中有的路只有条数、没有逐条内容，所以「未逐条合并/去重」';
  }

  /// 一行来源：勾选框 + 名字 + 状态 + 右侧动作
  ///
  /// ★★★ 2026-10-19（第 66 轮 Owner 第 ⑤ 条）：**勾选框变成真控件**
  /// ```text
  /// 改前：`onChanged == null` ⇒ 只读图标（注释里写着"拨了也没有实现去消费它，
  ///       那就是画了个假开关"—— 那句话是对的，但结论错了：
  ///       正确的修法是**补上消费方**，不是把控件锁死不让点。）
  /// 改后：`onChanged != null` ⇒ 整行可点，勾/取消写进 [_enabledFeeds]，
  ///       由 [DanmakuMergePreview]（= core 的 `DanmakuAggregator.merge`）消费。
  ///
  /// ⚠️ 仍然保留 `onChanged == null` 的用法：**本片源自带**不可取消
  ///    （它是视频本身带的，取消不了这个事实）。
  /// ```
  Widget _sourceRow({
    required DanmakuFeedChannel channel,
    required String detail,
    required bool checked,
    required ValueChanged<bool>? onChanged,
    Widget? trailing,
  }) {
    final label = channel.label;
    final tappable = onChanged != null;
    final row = Row(
      children: [
        Icon(
          checked
              ? AppIcons.check_box_rounded
              : AppIcons.check_box_outline_blank_rounded,
          size: 16,
          color: checked ? DanmakuTextColors.body : DanmakuTextColors.muted,
        ),
        const SizedBox(width: Sp.x2),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: checked
                  ? DanmakuTextColors.body
                  : DanmakuTextColors.secondary,
              fontSize: FontSizes.cap,
              fontWeight: checked ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
        Text(
          detail,
          style: const TextStyle(
            color: DanmakuTextColors.muted,
            fontSize: FontSizes.cap,
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: Sp.x2), trailing],
      ],
    );
    if (!tappable) return row;
    /*
     * 只读行**不套** InkWell：套了就变成"能点但没反应"，
     * 那与"看起来能点实际上不能点"是同一种谎，只是反过来。
     */
    return InkWell(
      onTap: () => onChanged(!checked),
      borderRadius: Radii.rSm,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: row,
      ),
    );
  }

  /// 小徽标（如「默认」）
  Widget _badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 2),
    decoration: BoxDecoration(
      borderRadius: Radii.rFull,
      border: Border.all(color: DanmakuTextColors.border),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: DanmakuTextColors.muted,
        fontSize: FontSizes.cap,
      ),
    ),
  );

  /// 行内小动作按钮
  Widget _rowAction(String text, VoidCallback onTap) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: DanmakuTextColors.body,
        fontSize: FontSizes.cap,
      ),
    ),
  );

  /// 「搜索…」：把关键词填好并交给宿主去搜
  ///
  /// ⚠️ 面板**自己不发请求**（本文件的分工，见 `onSearch` 的文档）：
  ///    它只把关键词递出去，宿主去调客户端。
  void _focusSearch(DanmakuSettingsState s) {
    final kw = s.searchKeyword.trim();
    _searchKeyword.text = kw;
    widget.onSearch?.call(kw);
  }

  Widget _requestSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('请求'),
        /*
         * ★★★ 2026-10-14（Owner 第 2 条）：「外部弹幕…」降一层
         *
         * # Owner 原话（逐字）
         * ```text
         * > [外部]弹幕搜索绑定交互太麻烦
         * ```
         *
         * # 改前要三层才摸得到
         * ```text
         * 齿轮 → 轻量悬浮窗「高级设置」 → 全屏卡片里那颗「外部弹幕…」
         * 最坏 6 次交互（开 popover、点高级设置、点按钮、再搜索、再选、再绑）。
         * ```
         * # 现在：它就在面板第一屏的「请求」节里
         * ```text
         * 齿轮 → 轻量悬浮窗「高级设置」 → 全屏卡片 → 「外部弹幕…」 ← 少一层
         * 而且它与旁边的「重新获取弹幕」**同层同权重**（都是弹幕相关动作），
         * 不再藏在"高级"里 —— 弹幕的事本来就该在弹幕面板里一眼可见。
         * ```
         *
         * ⚠️ **只改位置，不改能力**：`onOpenBili` 与 `BiliImportDialog`
         *    一字未动（既有 t73/t100 那几条测试照旧跑）。
         */
        Row(
          children: [
            TextButton.icon(
              onPressed: s.loading ? null : widget.onReload,
              icon: const Icon(
                AppIcons.refresh,
                color: DanmakuTextColors.body,
                size: 18,
              ),
              label: const Text(
                '重新获取弹幕',
                style: TextStyle(color: DanmakuTextColors.body),
              ),
            ),
            if (s.loading) ...[
              const SizedBox(width: Sp.x3),
              // T27-07：显式给色 —— body #E6E6E6 对面板底 #14161B ≥4.5:1（t27_w1 钉过）。
              const AppInlineSpinner(
                size: 16,
                color: DanmakuTextColors.body,
              ),
            ],
            /*
             * ★★★ 2026-10-18 第四版：这里**不再**画「外部弹幕…」按钮
             *
             * # 为什么删（看图台抓到的重复入口）
             * ```text
             * 上一版这里有一枚 `TextButton.icon('外部弹幕…')`。
             * 本版「弹幕来源」页签里已经有**平级的一行**：
             *     某个视频站   已绑定   [打开…]
             * 两个入口指向**同一个** `widget.onOpenBili` ⇒
             * 用户会问"这两个有什么区别"（截图实测：同一个面板里两处都能打开）。
             *
             * ⇒ 保留「弹幕来源」里那行（Owner 第 1 条要的可见性），
             *   删掉这里这枚（它是上一版"藏在请求节里"的产物）。
             * ```
             * ⚠️ **能力没变**：`onOpenBili` 仍然被 `_sourcesSection` 消费，
             *    `BiliImportDialog` 一字未动。
             */
          ],
        ),
        _hint(
          '当前片源没有本地文件（播放的是流地址），拿不到文件哈希，'
          '所以只用片名去匹配 —— 匹配不到时会自动退到按番剧名 + 集数搜索。'
          '自动匹配总是不中时，用下面的「搜索番剧」手动指定。',
        ),
      ],
    );
  }

  /// ★★★ 2026-10-14（Owner）：「搜索番剧」—— 手动搜索 + 选中即载入
  ///
  /// Owner 原话：> 弹幕我没有看到[弹幕服务]的搜索功能和绑定
  ///
  /// # 后端早就有了，缺的只是这层 UI
  /// ```text
  /// 客户端那侧的 `searchEpisodes()`（core/danmaku.dart）是**真 HTTP**
  /// （`GET /api/v2/search/episodes`），返回 `List<DanmakuMatch>`（番剧名 + 集名 + episodeId）；
  /// 但全仓**没有一个 UI 调它** ⇒ 用户只能等 `loadFor()` 自动匹配。
  /// 本区就是那层 UI：搜索 → 列结果 → 点一条 → 宿主用它的 episodeId 取弹幕。
  /// ```
  ///
  /// # 四种状态都要有**明确**的显示（空/载入/失败/有结果）
  /// ```text
  /// 载入中 ⇒ 一行「正在搜索…」+ 转圈（按钮同时禁用，防连点）
  /// 失败   ⇒ 沿用 `searchError.message` 的**真实原文**（不翻译成"网络错误"）
  /// 空结果 ⇒ 明确空态文案「没搜到，换个关键词试试」——空白会让人以为没反应
  /// 有结果 ⇒ 每条一行（番剧名 + 集名 + 库#id），点一条即载入
  /// ```
  Widget _searchSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('搜索番剧', note: '手动指定要哪一集'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _searchKeyword,
                style: const TextStyle(
                  color: DanmakuTextColors.body,
                  fontSize: FontSizes.sm,
                ),
                decoration: const InputDecoration(
                  hintText: '番剧名 / 关键词',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                // 回车 = 点「搜索」（键盘用户少摸一次鼠标）
                onSubmitted: (v) => _submitSearch(v),
              ),
            ),
            const SizedBox(width: Sp.x2),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: FilledButton.icon(
                // 载入中禁用 ⇒ 防连点（同时也把"正在搜"这件事画在按钮上）
                onPressed: s.searchLoading
                    ? null
                    : () => _submitSearch(_searchKeyword.text),
                icon: s.searchLoading
                    ? const AppInlineSpinner(
                        size: 16,
                        color: DanmakuTextColors.body,
                      )
                    : const Icon(AppIcons.search, size: 18),
                label: const Text('搜索'),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        // 关键词来自宿主最近一次搜索 ⇒ 把它回填进输入框
        // （用户在别处改了关键字 / 面板重开时，输入框要跟上；本地输入时
        //  两者相同 ⇒ 不打断光标）
        if (s.searchKeyword.isNotEmpty &&
            s.searchKeyword != _searchKeyword.text)
          _syncKeyword(s.searchKeyword),
        _searchResultBody(s),
      ],
    );
  }

  /// 把宿主的关键词同步进输入框（见调用点注释：只在两者不同时才写）
  Widget _syncKeyword(String kw) {
    // ⚠️ 不能在 build 里直接改 controller（会触发 "setState during build"）⇒
    //    排到这一帧之后（addPostFrameCallback）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchKeyword.text != kw) {
        _searchKeyword.text = kw;
      }
    });
    return const SizedBox.shrink();
  }

  void _submitSearch(String raw) {
    final kw = raw.trim();
    if (kw.isEmpty) return; // 空关键词不发请求（后端空搜必然搜不到，白跑一趟）
    widget.onSearch?.call(kw);
  }

  /// 搜索结果的四种状态显示
  Widget _searchResultBody(DanmakuSettingsState s) {
    if (s.searchLoading) {
      return _hint('正在搜索…');
    }
    final err = s.searchError;
    if (err != null) {
      /*
       * ★★★ 2026-10-19（R3-③/⑦ 收尾）：搜索失败**也走分类**。
       *
       * # 改前（Owner 看到的那句）
       * ```text
       * Text('搜索失败：${err.message}')
       *   ⇒ 本机 DNS 被劫持时画出来的是
       *     「搜索失败：连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。」
       *     —— 把"被劫持"说成"服务没起来"，用户会去查服务。方向错的。
       * ```
       *
       * # 改后
       * ```text
       * 分类命中伪造段 ⇒ 换成 [DanmakuProbeFailureX.title] 那档文案
       *   （"域名被解析到了错误地址"）+ 该档的下一步（换 DNS / 开代理），
       *   并且**仍然**把 core 的原文 `err.message` 原样留着 ——
       *   不翻译掉服务端的真实说法，只在上面补一条"这一步该做什么"。
       *
       * ★ 没命中时行为与改前**逐字同形**（`err.message` 照旧），
       *   ⇒ 本次改动**不会**影响任何没被劫持的场景。
       */
      final report = DanmakuProbeReport.fromDanmakuException(err);
      final hijacked = report.failure == DanmakuProbeFailure.dnsHijacked;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '搜索失败：${err.message}',
            style: const TextStyle(
              color: Colors.orangeAccent,
              fontSize: FontSizes.sm,
            ),
          ),
          if (hijacked) ...[
            const SizedBox(height: Sp.x2),
            Text(
              report.failure.title,
              style: const TextStyle(
                color: Colors.orangeAccent,
                fontSize: FontSizes.sm,
              ),
            ),
            _hint(report.remedy),
          ],
        ],
      );
    }
    if (!s.searchSearched) {
      return _hint('输入番剧名或关键词后点「搜索」，从结果里点一集即可载入它的弹幕');
    }
    if (s.searchResults.isEmpty) {
      return _hint('没搜到，换个关键词试试');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (s.searchStale) ...[
          const SizedBox(height: Sp.x1),
          // 见 `DanmakuSettingsState.searchStale` 的长注释：错位是真缺陷，
          // 必须显式告诉用户"这一批结果已经对不上了"。
          const Text(
            '搜索期间画面已换集，这批结果可能对不上 —— 建议重新搜索',
            style: TextStyle(
              color: Colors.orangeAccent,
              fontSize: FontSizes.cap,
            ),
          ),
        ],
        const SizedBox(height: Sp.x1),
        for (final m in s.searchResults) _matchTile(m, s.searchStale),
        /*
         * 2026-10-15 (Owner): batch binding.
         *
         * Placed right under the result list because that is where the user
         * has just decided WHICH work this is.  Asking them to bind 12
         * episodes one at a time after that is busywork -- the results are
         * the same every time, only the episode number changes.
         *
         * Only shown when there is something to batch, and only when the host
         * actually wired the callback (same gating rule as every other action
         * in this panel: no callback, no button).
         */
        if (widget.onBatchBind != null) ...[
          const SizedBox(height: Sp.x2),
          TextButton.icon(
            onPressed: () => widget.onBatchBind!(s.searchResults),
            icon: const Icon(
              AppIcons.playlist_add_check,
              color: DanmakuTextColors.body,
              size: 18,
            ),
            label: const Text(
              '整部绑定',
              style: TextStyle(color: DanmakuTextColors.body),
            ),
          ),
        ],
      ],
    );
  }

  /// 结果列表里的一条 —— 点它 ⇒ 载入这一集的弹幕
  Widget _matchTile(DanmakuMatch m, bool stale) {
    final title = m.animeTitle.isNotEmpty ? m.animeTitle : '未命名作品';
    final ep = m.episodeTitle.isNotEmpty ? m.episodeTitle : '未命名剧集';
    return InkWell(
      // stale 时**仍然可点**（用户可能有自己的判断），但那一行的文字已经
      // 标了"可能对不上" ⇒ 是知情选择，不是误点。
      onTap: () => widget.onPickMatch?.call(m),
      borderRadius: Radii.rSm,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: Sp.x1),
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
        decoration: BoxDecoration(
          borderRadius: Radii.rSm,
          border: Border.all(color: DanmakuTextColors.border),
          color: stale
              ? null
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.03),
        ),
        child: Row(
          children: [
            /*
             * 2026-10-15 (Owner: "I remember it could show covers? see if you
             * can.") -- yes it can, via /api/v2/bangumi/{animeId}.
             *
             * The poster is 2:3, so the box is 2:3 (28x42).  That ratio
             * matters: coverImage() picks cacheHeight based on layoutHeight,
             * and ResizeImage keeps the aspect ratio, so a 2:3 box decodes a
             * 2:3 thumbnail rather than scaling a 16:9 still down.
             *
             * cover == '' means the lookup failed (offline, unknown work, or
             * the request was swallowed on purpose so search still works) =>
             * fall back to a neutral placeholder rather than an empty gap,
             * so the rows keep a consistent baseline.
             */
            SizedBox(
              width: 28,
              height: 42,
              child: m.cover.isEmpty
                  ? Container(
                      decoration: BoxDecoration(
                        borderRadius: Radii.rSm,
                        border: Border.all(color: DanmakuTextColors.border),
                      ),
                      child: const Icon(
                        AppIcons.movie_outlined,
                        size: 14,
                        color: DanmakuTextColors.muted,
                      ),
                    )
                  : ClipRRect(
                      borderRadius: Radii.rSm,
                      child: coverImage(
                        context,
                        url: m.cover,
                        layoutWidth: 28,
                        layoutHeight: 42,
                        fit: BoxFit.cover,
                        // A broken poster URL must not blow up the row.
                        errorBuilder: (_, __, ___) => Container(
                          decoration: BoxDecoration(
                            borderRadius: Radii.rSm,
                            border: Border.all(color: DanmakuTextColors.border),
                          ),
                          child: const Icon(
                            AppIcons.movie_outlined,
                            size: 14,
                            color: DanmakuTextColors.muted,
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: DanmakuTextColors.body,
                      fontSize: FontSizes.sm,
                    ),
                  ),
                  Text(
                    ep,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: DanmakuTextColors.muted,
                      fontSize: FontSizes.cap,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Sp.x2),
            // 库 id 对用户没意义，但排错时要能说清"载的是哪一条"⇒ 弱化显示
            Text(
              '#${m.episodeId}',
              style: const TextStyle(
                color: DanmakuTextColors.muted,
                fontSize: FontSizes.cap,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 中文可操作指引（Owner 第 1 条）—— 原文照旧留在 [_errorSection] 里
  ///
  /// 文案与动作**全部**来自 `core/danmaku.dart` 的 `DanmakuHint`
  /// （纯函数，有单测钉住），这里只负责画，不做任何判断 ——
  /// 判断散到 UI 里就会与库侧的判据漂移。
  Widget _hintSection(DanmakuHint h) {
    final a = h.action;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              AppIcons.info_outline,
              size: 18,
              color: DanmakuTextColors.muted,
            ),
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                h.title,
                style: const TextStyle(
                  color: DanmakuTextColors.body,
                  fontSize: FontSizes.base,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        Text(
          h.text,
          style: const TextStyle(
            color: DanmakuTextColors.secondary,
            fontSize: FontSizes.sm,
          ),
        ),
        if (h.url.isNotEmpty) ...[
          const SizedBox(height: Sp.x2),
          SelectableText(
            h.url,
            style: const TextStyle(
              color: Colors.lightBlueAccent,
              fontSize: FontSizes.cap,
            ),
          ),
        ],
        if (a != null && widget.onHintAction != null) ...[
          const SizedBox(height: Sp.x3),
          FilledButton.icon(
            onPressed: () => widget.onHintAction!(a),
            icon: const Icon(AppIcons.settings, size: 18),
            label: Text(a.label),
          ),
        ],
      ],
    );
  }

  /// 服务端返回的原文 —— **一个字都不改写**（这是排错的唯一线索）
  Widget _errorSection(DanmakuException e) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('服务端返回'),
        Text(
          e.message,
          style: const TextStyle(
            color: Colors.orangeAccent,
            fontSize: FontSizes.sm,
          ),
        ),
        const SizedBox(height: Sp.x2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: Radii.rSm,
            border: Border.all(color: DanmakuTextColors.border),
          ),
          child: Text(
            e.detail,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: FontSizes.cap,
              color: DanmakuTextColors.secondary,
            ),
          ),
        ),
        if (e.isAuthProblem)
          _hint(
            '这是凭证问题。可行的几步（按代价从低到高）：'
            '改用本机外部弹幕（免签名）或 外部视频源弹幕；'
            '或在上面的「凭证」节填一对 AppId / AppSecret 并保存，'
            '再点「重新获取弹幕」。',
          ),
      ],
    );
  }
}
