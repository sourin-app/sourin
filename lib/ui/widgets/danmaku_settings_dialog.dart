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
// # ★★★ 凭证从哪来（2026-10-11 Owner 反馈后：面板上**不再**有凭证输入框）
//
// 客户端**内置** dandanplay 官方凭证（构建期 `--dart-define` 注入：
// `DANDANPLAY_APP_ID` / `DANDANPLAY_APP_SECRET`，见 `.github/workflows/build.yml`；
// 仓库里**只有占位符 / 空串**，真值只在 CI Secrets 里）。
// 官方文档（doc.dandanplay.com/open/）明确允许开源客户端「用占位符，
// 构建时从机密读取后替换」⇒ 所以本次把面板上的 AppId / AppSecret 两个
// 输入框 + 那枚删除按钮**整节删除** —— 用户不必也不该手填。
// 需要换源时，面板里给的是两条**不用凭证**的路：本机弹弹play / B 站弹幕。
//
// 保留的只读链路（`DanmakuConfig` 的 getter / `usingBuiltin*` /
// `maskedAppId` / `isConfigured` / `statusText`）仍然是签名与状态展示的来源。
//
// # 为什么没配凭证也**照样**发请求
//
// 见 `lib/core/danmaku.dart` 里 `DandanplayClient` 的类注释：
// 本地短路会永久埋掉服务端给的**具体**原因（缺头 / 时间戳错 / AppId 无效 /
// 签名错），而那正是用户排错唯一能拿到的信息。
// ⇒ 所以本面板把 `DanmakuException.detail`（含 `X-Error-Message` 原文）
//   原样显示出来，**一个字都不改写**。
//
// # ⚠️ AppSecret 的存储（历史说明）
//
// 移除输入框**之前**，用户手填的 AppSecret 是**明文**存在数据目录的
// `ui-prefs.json` 里的。这些**用户自己填的旧值**不在本次清理范围内
// （Owner 原话「用户自己填的旧值不管」）—— 一旦落盘就仍然生效，
// 且优先于内置值（`DanmakuConfig` 优先级：用户覆盖 > 内置）。
// 迁移到系统凭据存储仍是**独立的一项工作**，不在本任务范围内。
//
// # 禁止 `package:flutter/material.dart`
//
// 项目用拆包后的 `material_ui`（见 `test/material_split_test.dart`）。

import 'package:material_ui/material_ui.dart';

import '../../core/danmaku.dart';
import '../tokens.dart';
import 'overlay_motion.dart';

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
  });

  /// 从当前偏好构造（打开面板时的初值）
  ///
  /// ★ 2026-10-11（Owner 反馈）：面板上的 AppId / AppSecret 输入框已整节删除
  /// ⇒ 这两个字段**不再用于渲染**，只是签名链路与宿主状态的只读回显
  /// （保留字段以免波及大量测试与 `copyWith`；签名读的是
  /// `DanmakuConfig.appId/appSecret` 生效值，与此处初值无关）。
  /// 记录生效值即可，不再有"内置生效就不预填"那套（那是为已删除的输入框服务的）。
  factory DanmakuSettingsState.fromPrefs() => DanmakuSettingsState(
    enabled: DanmakuConfig.enabled,
    appId: DanmakuConfig.appId,
    appSecret: DanmakuConfig.appSecret,
    fontScale: DanmakuConfig.fontScale,
    opacity: DanmakuConfig.opacity,
    speed: DanmakuConfig.speed,
    area: DanmakuConfig.area,
  );

  final bool enabled;
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

  /// 弹幕数据源状态行（T27-05）：「检测到本机弹弹play 未运行」或
  /// 「本机弹弹play（127.0.0.1:2080）已就绪」。空串 = 不显示该行。
  final String sourceLine;

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
    );
  }
}

/// 弹幕设置面板
///
/// 形态与 `PlayerSettingsSheet` **一致**（全屏 scrim + 居中卡片），
/// 因为它们在同一个页面里互为邻居 —— 用户不该为两个面板学两套操作。
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
    this.onHintAction,
    this.onChanged,
    this.fill = true,
  });

  final DanmakuSettingsState state;

  final ValueChanged<bool> onSetEnabled;
  final ValueChanged<double> onSetFontScale;
  final ValueChanged<double> onSetOpacity;
  final ValueChanged<double> onSetSpeed;
  final ValueChanged<double> onSetArea;

  /// 重新取一次弹幕（想重试时用）
  final VoidCallback onReload;

  final VoidCallback onClose;

  /// 打开「哔哩哔哩弹幕」面板（task-31 ④）。
  ///
  /// 传 null ⇒ 按钮**不画** —— 面板本身不认识 B 站，也不知道宿主有没有接。
  /// 这只是「另一个弹幕源」的入口，与 dandanplay 凭证同层。
  final VoidCallback? onOpenBili;

  /// 用户点了「中文指引」里的动作按钮（Owner 第 1 条）。
  ///
  /// 传 null ⇒ 那枚按钮**不画**（与 [onOpenBili] 同一条规矩：面板不认识
  /// 宿主的开关，也不该猜）。动作本身由宿主执行 —— 面板只负责把
  /// `DanmakuHint.action` 原样递出去。
  final ValueChanged<DanmakuHintAction>? onHintAction;

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
  late final TextEditingController _blockWords = TextEditingController(
    text: DanmakuConfig.blockWords.join('\n'),
  );

  @override
  void dispose() {
    _blockWords.dispose();
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
    final body = GestureDetector(
      // 点背景关闭（与播放页其它面板一致）
      onTap: widget.onClose,
      // ★ task-99：遮罩**淡入**（原来是一帧硬切 —— Owner 说的「生硬」）
      //   颜色/覆盖范围一字不改，动画结束后 Opacity 恒为 1.0。
      child: OverlayScrim(
        color: Colors.black.withValues(alpha: 0.72),
        child: Center(
          child: GestureDetector(
            // 卡片内部的点击不能穿透到背景（否则点滑块也会关掉面板）
            onTap: () {},
            // ★ task-99：卡片**淡入 + 轻微上浮**（24px，Motion.base）
            child: OverlayCardMotion(
              child: Container(
                width: 560,
                constraints: const BoxConstraints(maxHeight: 620),
                decoration: BoxDecoration(
                  color: DanmakuTextColors.panelBg.withValues(alpha: 0.98),
                  borderRadius: Radii.rLg,
                  border: Border.all(color: DanmakuTextColors.border),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(),
                    Flexible(
                      child: SingleChildScrollView(
                        clipBehavior: Clip.antiAlias,
                        padding: const EdgeInsets.fromLTRB(
                          Sp.x6,
                          0,
                          Sp.x6,
                          Sp.x4,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _statusSection(),
                            _divider(),
                            // ★ 「数据源」状态行（T27-05）—— 原来是凭证节的一部分，
                            //   凭证输入框整节删掉后单独保留（只读状态，与凭证无关）。
                            //   sourceLine 为空时 _sourceSection() 返回 SizedBox.shrink()。
                            _sourceSection(),
                            _divider(),
                            _switchSection(),
                            _divider(),
                            _displaySection(),
                            _divider(),
                            _filterSection(),
                            _divider(),
                            _requestSection(),
                            /*
                               * ★★ Owner 第 1 条：把 403/401 翻成**能照着做**的中文
                               *
                               * 位置有讲究：排在「服务端返回」**上面** ——
                               * 原文（Missing Authentication Headers）是证据，
                               * 中文指引是结论；用户先看到结论才知道证据在说什么。
                               */
                            if (s.error?.hint != null) ...[
                              _divider(),
                              _hintSection(s.error!.hint!),
                            ],
                            if (s.error != null) ...[
                              _divider(),
                              _errorSection(s.error!),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // ★ 默认形态与改前**逐像素相同**（只多一个局部变量）
    return widget.fill ? Positioned.fill(child: body) : body;
  }

  /// 面板标题 —— 缺陷 17：**细节说明的落点**
  ///
  /// ══════════════════════════════════════════════════════════════
  /// ★★★ 为什么这里要多一个副标题（2026-10-09 · 缺陷 17 / Lead 裁决）
  /// ══════════════════════════════════════════════════════════════
  /// 播放页底栏那枚 `Icons.tune` 按钮的 tooltip 改前是一长串：
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
  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x4, Sp.x3, Sp.x2),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '弹幕设置',
                  style: TextStyle(
                    color: DanmakuTextColors.body,
                    fontSize: FontSizes.lg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: Sp.x1),
                Text(
                  '显示 / 过滤 / 请求',
                  style: TextStyle(
                    color: DanmakuTextColors.muted,
                    fontSize: FontSizes.cap,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, color: DanmakuTextColors.body),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _divider() => const Padding(
    padding: EdgeInsets.symmetric(vertical: Sp.x4),
    child: Divider(height: 1, color: DanmakuTextColors.border),
  );

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
        style: const TextStyle(color: DanmakuTextColors.muted, fontSize: FontSizes.cap),
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
     * ★ 2026-10-11（Owner 反馈）：面板上的 AppId / AppSecret 输入框已整节移除
     *   ⇒ 判据不能再是 s.appId/s.appSecret（那两格**永远不会**再有用户输入）。
     *   改成看**生效**的凭证（用户旧覆盖 > 内置，见 DanmakuConfig.isConfigured）：
     *   - 有凭证（内置已注入，或用户以前填过并仍在生效）⇒ 如实说在用哪一份，
     *     且**绝口不提**"去输入框填"，因为已经没有输入框了；
     *   - 没凭证 ⇒ 只指两条**真实存在**的路（本机弹弹play / B 站弹幕），
     *     不再对用户说「还没填 AppId / AppSecret」。
     */
    if (!DanmakuConfig.isConfigured) {
      return '弹幕已开启，但凭证未就绪（本机弹弹play / B 站弹幕不需要凭证）';
    }
    if (DanmakuConfig.usingBuiltinAppId) {
      return '弹幕已开启（内置凭证 AppId ${DanmakuConfig.maskedAppId}）';
    }
    return '弹幕已开启（AppId ${DanmakuConfig.maskedAppId}）';
  }

  Widget _switchSection() {
    return Row(
      children: [
        Switch(value: widget.state.enabled, onChanged: widget.onSetEnabled),
        const SizedBox(width: Sp.x2),
        const Expanded(
          child: Text(
            '显示弹幕',
            style: TextStyle(color: DanmakuTextColors.secondary, fontSize: FontSizes.sm),
          ),
        ),
      ],
    );
  }

  /// 「数据源」状态行（T27-05）—— 本机跑着弹弹play 就优先用本地源（免签名），
  /// 没跑就退回官方 API。
  ///
  /// ★ 2026-10-11（Owner 反馈）：这里**原来**还挂着 dandanplay 开放平台的
  ///   AppId / AppSecret 两个输入框 + 那枚删除按钮。已整节移除 ——
  ///   客户端**内置了官方凭证**（构建期 `--dart-define` 注入，见
  ///   `.github/workflows/build.yml` 与 `DanmakuConfig.hasBuiltinCredentials`），
  ///   用户不必也不该手填；需要换源时用下面的「数据源」/ B 站弹幕两条路。
  ///   ⇒ 本方法现在只剩这一行**只读**状态，凭证相关的输入 UI 一概不画。
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
        _hint('弹幕从画面**顶部往下**能占用的高度比例（对齐 B 站）。'
            '默认 50% = 只占上半屏，下半屏留给画面与字幕；拖到 100% 才铺满全屏。'),
      ],
    );
  }

  /// ★★★ 2026-10-09 新增：屏蔽与分类开关（对齐 B 站的弹幕设置）
  ///
  /// Owner 原话：「弹幕管理 还要支持指定区域的屏幕不显示 大小 屏蔽 速度 等等,
  ///            这些都参考b站的弹幕设置就行了」
  ///
  /// 与上面「显示」那一节的分工：
  /// ```text
  /// 显示  ⇒ 字号/透明度/速度/占用区域（"长什么样"）
  /// 本节点 ⇒ 显示哪几类 + 屏蔽哪些词（"留哪些"）
  /// ```
  /// ⚠️ 与 B 站的差异：B 站把"显示类型"和"屏蔽类型"分成两处（容易让人困惑
  ///    为什么同一类要开关两次）。这里合并成一组三态开关：
  ///    关 = 不显示（等价于 B 站两个开关都关）。
  Widget _filterSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('显示哪些弹幕', note: '即时生效'),
        _typeSwitch('滚动弹幕', DanmakuConfig.showScroll, DanmakuConfig.setShowScroll),
        _typeSwitch('顶部弹幕', DanmakuConfig.showTop, DanmakuConfig.setShowTop),
        _typeSwitch('底部弹幕', DanmakuConfig.showBottom, DanmakuConfig.setShowBottom),
        _hint('关掉某一类 ⇒ 那一类的弹幕不再进入渲染（也不占轨道）'),
        const SizedBox(height: 8),
        _sectionTitle('屏蔽词', note: '每行一个'),
        _blockWordsField(),
        _typeSwitch('按正则匹配', DanmakuConfig.blockRegex, DanmakuConfig.setBlockRegex),
        _hint(
          DanmakuConfig.blockRegex
              ? '当前按正则解释（写错了会自动跳过那一条，不会屏蔽全部）'
              : '当前按"包含"匹配（勾上右边开关可改用正则）',
        ),
      ],
    );
  }

  /// 三类弹幕的显示开关
  Widget _typeSwitch(String label, bool value, void Function(bool) set) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: DanmakuTextColors.muted, fontSize: 13)),
          ),
          Switch(
            value: value,
            onChanged: (v) {
              set(v);
              // 立刻重建对话框，让开关与渲染同步（父层也会收到回调）
              widget.onChanged?.call();
            },
          ),
        ],
      ),
    );
  }

  /// 屏蔽词多行输入框
  ///
  /// ★ controller 由 State 持有（见 [_blockWords]），**不要**在 build 里 new：
  /// 每帧换 controller 会让输入框显示的值永远是偏好里的规范化文本，
  /// 用户连第二个词都敲不进去。
  Widget _blockWordsField() {
    return TextField(
      controller: _blockWords,
      maxLines: 4,
      minLines: 3,
      style: const TextStyle(color: DanmakuTextColors.muted, fontSize: 13),
      decoration: const InputDecoration(
        hintText: '例如：\n剧透\n前方高能',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (v) {
        DanmakuConfig.setBlockWords(v);
        widget.onChanged?.call();
      },
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

  Widget _requestSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('请求'),
        Row(
          children: [
            TextButton.icon(
              onPressed: s.loading ? null : widget.onReload,
              icon: const Icon(Icons.refresh, color: DanmakuTextColors.body, size: 18),
              label: const Text(
                '重新获取弹幕',
                style: TextStyle(color: DanmakuTextColors.body),
              ),
            ),
            if (s.loading) ...[
              const SizedBox(width: Sp.x3),
              const SizedBox(
                width: 16,
                height: 16,
                // T27-07：显式给色 —— body #E6E6E6 对面板底 #14161B ≥4.5:1（t27_w1 钉过）。
                child: CircularProgressIndicator(
                  color: DanmakuTextColors.body,
                  strokeWidth: 2,
                ),
              ),
            ],
            if (widget.onOpenBili != null) ...[
              const SizedBox(width: Sp.x3),
              TextButton.icon(
                onPressed: widget.onOpenBili,
                icon: const Icon(
                  Icons.play_circle_outline,
                  color: DanmakuTextColors.body,
                  size: 18,
                ),
                label: const Text(
                  '哔哩哔哩弹幕…',
                  style: TextStyle(color: DanmakuTextColors.body),
                ),
              ),
            ],
          ],
        ),
        _hint(
          '当前片源没有本地文件（播放的是流地址），拿不到文件哈希，'
          '所以只用片名去匹配 —— 匹配不到时会自动退到按番剧名 + 集数搜索。',
        ),
      ],
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
            const Icon(Icons.info_outline, size: 18, color: DanmakuTextColors.muted),
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
          style: const TextStyle(color: DanmakuTextColors.secondary, fontSize: FontSizes.sm),
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
            icon: const Icon(Icons.settings, size: 18),
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
            '这是凭证问题。面板上已经没有填写凭证的输入框了 —— 客户端**内置**了'
            '官方凭证，正常情况下不该出现这条。可行的一步：改用本机弹弹play'
            '（免签名）或 B 站弹幕，再点「重新获取弹幕」。',
          ),
      ],
    );
  }
}
