// ═══════════════════════════════════════════════════════════════════════
//  二级页：弹幕源（dan-api / 自建弹幕服务）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这一页（Owner 第 7 条）
//
// Owner 原话：
// > 配置页没看到,既然弹弹play不行,就换成dan-api
//
// 而实测现状是：**能力早就全实现了，但用户找不到**
// ```text
// lib/core/danmaku.dart:1569      DanmakuEndpoint（baseUrl + 可选 token）
// lib/core/ui_prefs.dart:248/266  dsh.danmaku.endpoint / .token 两个偏好键
// widgets/danmaku_settings_dialog.dart  地址框 + token 框 + 测试连接按钮
// ```
// ★ 但它们只出现在**播放页 → 弹幕面板**这个二级弹窗里，
//   用户在**设置页**从头翻到尾都看不到一个「弹幕」字样。
//
// # 为什么是「新开一个二级页」而不是把输入框搬进设置页一级
// ```text
// A. 直接把两个 TextField 放进一级列表
//    ✗ 一级页是一列「入口行」，行高 ~56；塞输入框会破坏整页节奏
//    ✗ 地址 + token + 测试 + 状态是四个控件，一级页放不下
// B. ★ 一级页放一条**入口行**（带实时状态副标题），点进本页配置
//    ✓ 与「JS 插件」「Emby」「直播分组」同一范式，用户已经会点
//    ✓ 副标题直接显示当前状态 ⇒ 「已配置 / 未配置」在一级页就可见
// ```
// ⇒ 选 B。Owner 要的是「能被发现」，一条带状态的入口行就满足，
//   不必为了「在一级页」牺牲可编辑性。
//
// # 与播放页那个弹幕面板的关系
// ```text
// 本页      = 配置（地址 / token / 测试 / 状态），从**设置页**进
// 弹幕面板  = 播放时的观感调节 + 取弹幕，从**播放页**进
// 两者共用 DanmakuEndpoint / UiPrefs 同一份真相，不各存一份。
// ```
// ⚠️ 因此本页与那个面板的 `_selfHostedSection` 是**有意重复**的表单：
//    面板那次是在播放中打开（要能边看边调），本页是静态配置。
//    抽成共享 widget 会把两个不同的使用场景硬绑在一起，得不偿失 ——
//    但两者**读写同一对偏好键**，所以改哪边都立刻生效。

import 'package:material_ui/material_ui.dart';

import '../../core/danmaku.dart';
import '../../core/ui_prefs.dart';
import '../tokens.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';
import '../../design/icons/app_icons.dart';

class DanmakuSourcePage extends StatefulWidget {
  const DanmakuSourcePage({super.key, this.probeOverride});

  /// 测试注入口：替换真实网络探测（同弹幕面板的同名参数）
  final Future<DanmakuLocalStatus> Function(DanmakuEndpoint?)? probeOverride;

  @override
  State<DanmakuSourcePage> createState() => _DanmakuSourcePageState();
}

class _DanmakuSourcePageState extends State<DanmakuSourcePage> {
  late final TextEditingController _url;
  late final TextEditingController _token;

  /// 上一次「测试连接」的结果
  DanmakuLocalStatus? _result;

  /// 走不到 [DanmakuLocalStatus] 的那种失败（地址格式不对 / 探针自身异常）
  String? _why;

  /// 在途请求的序号。null = 没有在途请求。
  ///
  /// # 为什么是序号而不是 bool（与弹幕面板同一条教训）
  /// ```text
  /// 用户填 A 点测试 → 改成 B → A 的结果回来
  /// ⇒ 会把 A 的结论写进状态行、还把 A 存进偏好
  /// ⇒ 输入框是 B、偏好是 A、状态行显示 A 的结论，三者互相矛盾
  /// ```
  int _seq = 0;
  int? _runningSeq;

  bool get _running => _runningSeq != null;

  /// 弹幕代理：当前模式（三态）
  ///
  /// ★ 独立于 [_url]（自建服务地址）—— 两件事：
  ///   `_url` 决定「连哪个弹幕服务器」，本项决定「怎么连到它」。
  ///   一个网络的屏蔽可能只针对前者，也可能只针对后者，必须分开配。
  late DanmakuProxyMode _proxyMode;

  /// 自定义代理地址（仅 [_proxyMode] == custom 时有意义）
  late final TextEditingController _proxyUrl;

  @override
  void initState() {
    super.initState();
    // 打开时用**已保存**的值初始化 ⇒ 用户能看到自己上次配的是什么
    _url = TextEditingController(text: UiPrefs.danmakuEndpoint);
    _token = TextEditingController(text: UiPrefs.danmakuToken);
    final proxy = currentDanmakuProxySetting();
    _proxyMode = proxy.mode;
    _proxyUrl = TextEditingController(text: proxy.url);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _proxyUrl.dispose();
    super.dispose();
  }

  /// 切换代理模式并**立即落盘**
  ///
  /// ★ 为什么不用"保存"按钮：这个页面其它项（地址/令牌）走的是显式保存，
  ///   但那是因为它们需要"测试连接"这个动作配合。
  ///   代理三态是**单选**，选中即生效最符合直觉，
  ///   而且切换后要**立刻**影响下一次弹幕请求（不需要重开页面）。
  void _setProxy(DanmakuProxyMode? m) {
    if (m == null) return;
    setState(() => _proxyMode = m);
    UiPrefs.setDanmakuProxy(mode: m.name, url: _proxyUrl.text);
  }

  /// 地址输入变化 ⇒ 落盘（仅 custom 模式时才有输入框）
  void _saveProxyUrl() {
    UiPrefs.setDanmakuProxy(mode: _proxyMode.name, url: _proxyUrl.text);
    setState(() {});  // 让诊断行进更新
  }

  /// 输入一变 ⇒ 上次的测试结果立刻作废（否则会显示与当前输入无关的结论）
  void _invalidate() {
    _seq++;
    _runningSeq = null;
    setState(() {
      _result = null;
      _why = null;
    });
  }

  Future<void> _probe() async {
    final mySeq = ++_seq;
    final rawUrl = _url.text.trim();
    // ⚠️ token 也要**在发起时**捕获（落盘时再读会拿到用户后来敲的值）
    final rawToken = _token.text;
    final ep = DanmakuEndpoint.tryParse(rawUrl, token: rawToken);

    if (rawUrl.isNotEmpty && ep == null) {
      setState(() {
        _runningSeq = null;
        _result = null;
        _why = '地址格式不对（例：http://127.0.0.1:9321）';
      });
      return;
    }

    setState(() => _runningSeq = mySeq);
    final probe = widget.probeOverride ??
        (DanmakuEndpoint? e) => DanmakuLocalService.describe(endpoint: e);

    DanmakuLocalStatus st;
    try {
      st = await probe(ep);
    } catch (e) {
      // 过期 ⇒ 一个字都不改（失败结论同样属于旧输入）
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _runningSeq = null;
        _result = null;
        _why = '测试失败：$e';
      });
      return;
    }

    // ★ 核心守卫：await 期间输入变过 ⇒ 本次结果作废（不写状态、不落盘）
    if (!mounted || mySeq != _seq) return;
    setState(() {
      _runningSeq = null;
      _result = st;
    });

    // 测通了才落盘 —— 用户点「测试连接」的语义就是「这个地址可用」。
    // ⚠️ 落盘用**发起时捕获**的 rawUrl/rawToken。
    if (st.online) {
      UiPrefs.setDanmakuEndpoint(rawUrl);
      UiPrefs.setDanmakuToken(rawToken);
    }
  }

  /// 清除 ⇒ 回到内置路径（本机弹弹play → 官方）
  void _clear() {
    _seq++;
    _runningSeq = null;
    UiPrefs.setDanmakuEndpoint('');
    UiPrefs.setDanmakuToken('');
    setState(() {
      _url.text = '';
      _token.text = '';
      _result = null;
      _why = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const builtins = kDanmakuPublicInstances;
    final savedRaw = UiPrefs.danmakuEndpoint.trim();
    final usingBuiltin = savedRaw.isEmpty && builtins.isNotEmpty;
    return SettingsSubPage(
      title: '弹幕源',
      subtitle: 'dan-api（内置公共实例 · 免凭证）· 连不上时自动回退',
      children: [
        // ── ① 内置公共实例（Owner 第 4 条：不该让用户去填）──
        if (builtins.isNotEmpty) ...[
          SettingsBlock(
            title: '内置实例',
            trailing: Text(
              '开箱可用',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
            children: [
              for (final p in builtins) ...[
                _BuiltinTile(
                  instance: p,
                  selected: usingBuiltin && _isFirst(p),
                  onTap: () => _pickBuiltin(p),
                ),
                const SizedBox(height: Sp.x2),
              ],
              _hint(
                '公共服务器：会慢（冷启动几秒）、也可能临时不可用。'
                '点一下即选中；想用别的就填下面那一栏，填了就压过内置。',
              ),
            ],
          ),
          const SizedBox(height: Sp.x5),
        ],
        SettingsBlock(
          title: '连接',
          trailing: Text(
            '免凭证',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
          children: [
            _StatusLine(
              result: _result,
              why: _why,
              running: _running,
              hasAddress: _url.text.trim().isNotEmpty,
            ),
            const SizedBox(height: Sp.x5),
            _label(builtins.isEmpty ? '服务地址' : '你自己的地址（可选，填了就压过内置）'),
            const SizedBox(height: Sp.x2),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
              decoration: InputDecoration(
                hintText:
                    builtins.isEmpty ? 'http://127.0.0.1:9321' : builtins.first.baseUrl,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => _invalidate(),
              onSubmitted: (_) => _probe(),
            ),
            const SizedBox(height: Sp.x2),
            _hint('填你自建 dan-api 服务的地址。本机默认就是 9321 端口。'),
            const SizedBox(height: Sp.x5),
            _label('Token（可选）'),
            const SizedBox(height: Sp.x2),
            TextField(
              controller: _token,
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
              decoration: const InputDecoration(
                hintText: '默认服务不用填',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => _invalidate(),
              onSubmitted: (_) => _probe(),
            ),
            const SizedBox(height: Sp.x2),
            _hint('服务端设了 TOKEN 才要填；默认配置可以留空。'),
            const SizedBox(height: Sp.x6),
            Wrap(
              spacing: Sp.x3,
              runSpacing: Sp.x2,
              children: [
                FilledButton.icon(
                  onPressed: _running ? null : _probe,
                  icon: _running
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            /*
                             * ★ 2026-10-17：必须显式给色（被 t27_w7 门禁抓出）
                             *
                             * 这个圈画在 **FilledButton 的填充底**上（主色），
                             * 不给色就会落到 progressIndicatorTheme 兜底 ——
                             * 那个兜底是给"页面底色"配的，压在按钮主色上会看不见。
                             *
                             * ⇒ 用 onPrimary（按钮上的前景色），与按钮文字同色。
                             */
                            color: Theme.of(context).colorScheme.onPrimary,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(AppIcons.wifi_tethering, size: 18),
                  label: Text(_running ? '测试中…' : '测试连接'),
                ),
                TextButton.icon(
                  onPressed: _running ? null : _clear,
                  icon: const Icon(AppIcons.delete_outline, size: 18),
                  label: const Text('清除'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: Sp.x5),
        SettingsBlock(
          title: '没有可用实例？',
          children: [
            _hint('dan-api 是开源的自建弹幕服务（免凭证），可以自己跑一份。'),
            const SizedBox(height: Sp.x2),
            _hint(
              '它把各站弹幕抓下来、按弹弹play 协议吐出来，'
              '所以本客户端不用改任何协议就能用。',
            ),
            const SizedBox(height: Sp.x3),
            _hint(
              '什么都不配也能用：先用内置公共实例；'
              '内置也不通时，才退回本机弹弹play / 官方接口。',
            ),
          ],
        ),
        const SizedBox(height: Sp.x5),
        SettingsBlock(
          title: '网络代理',
          children: [
            _hint(
              '弹幕服务器在某些网络下会被屏蔽或连不上。'
              '这里决定弹幕请求怎么走 —— 与视频源自己的代理是两回事。',
            ),
            const SizedBox(height: Sp.x3),
            /*
             * ★ 用 `RadioGroup` 包住，而不是每个 tile 传 groupValue/onChanged
             *
             * 那两个参数在 Flutter v3.32.0 后**已废弃**（`deprecated_member_use`），
             * 新 API 要求由 `RadioGroup` 祖先统一持有 groupValue 与回调
             * ⇒ 每个 tile 只留 `value` + 展示内容。
             *
             * ★ 键盘可达性不变：`RadioListTile` 内部仍是同一个
             *   `InkWell` + `Focus`，方向键在组内移动焦点的行为由
             *   `RadioGroup` 统一分发，与旧 API 一致。
             */
            RadioGroup<DanmakuProxyMode>(
              groupValue: _proxyMode,
              onChanged: _setProxy,
              child: const Column(
                children: [
                  RadioListTile<DanmakuProxyMode>(
                    value: DanmakuProxyMode.direct,
                    title: Text('直连'),
                    subtitle: Text('不经过代理，也不受系统代理设置影响'),
                    dense: true,
                  ),
                  RadioListTile<DanmakuProxyMode>(
                    value: DanmakuProxyMode.system,
                    title: Text('跟随系统代理'),
                    subtitle: Text('读取环境变量里的 HTTP_PROXY / HTTPS_PROXY'),
                    dense: true,
                  ),
                  RadioListTile<DanmakuProxyMode>(
                    value: DanmakuProxyMode.custom,
                    title: Text('自定义代理'),
                    // ★ 提前说清不支持 socks —— 写在副标题里，
                    //   而不是等用户填完再报"地址无效"（那时他会反复改 host/port）
                    subtitle: Text(
                        '只让弹幕请求走这个地址（填 HTTP 代理，不支持 socks）'),
                    dense: true,
                  ),
                ],
              ),
            ),
            // ★ 地址框**只在自定义**时出现 ——
            //   其它模式留着它会让用户以为"填了就生效"，而实际没被用上
            if (_proxyMode == DanmakuProxyMode.custom) ...[
              const SizedBox(height: Sp.x2),
              TextField(
                controller: _proxyUrl,
                decoration: const InputDecoration(
                  labelText: '代理地址',
                  hintText: 'http://127.0.0.1:7890',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _saveProxyUrl(),
              ),
            ],
            const SizedBox(height: Sp.x2),
            /*
             * ★ 诊断行必须在**三种模式下都显示**
             *
             * 存在的理由：`custom` 但地址写坏时，解析会**退回显式直连**
             * （见 danmaku.dart 的 `resolveDanmakuFindProxy`）。
             * 若不显示，用户看到的是"我配了代理却没生效"，
             * 而这种失败和"代理本身不通"表现完全不同，没法排查。
             */
            _hint('当前：${diagnoseDanmakuProxy(mode: _proxyMode, url: _proxyUrl.text)}'),
          ],
        ),
      ],
    );
  }

  bool _isFirst(DanmakuPublicInstance p) =>
      kDanmakuPublicInstances.isNotEmpty &&
      kDanmakuPublicInstances.first.baseUrl == p.baseUrl;

  /// 点一条内置实例 ⇒ 写进输入框 + 落盘
  ///
  /// ⚠️ 与 [_probe] 同一条竞态纪律：序号前进，作废在途结果。
  void _pickBuiltin(DanmakuPublicInstance p) {
    _seq++;
    _runningSeq = null;
    _url.text = p.baseUrl;
    _token.text = p.token;
    UiPrefs.setDanmakuEndpoint(p.baseUrl);
    UiPrefs.setDanmakuToken(p.token);
    setState(() {
      _result = null;
      _why = null;
    });
  }

  Widget _label(String text) => Text(
        text,
        style: TextStyle(
          fontSize: FontSizes.sm,
          fontWeight: FontWeights.semibold,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );

  Widget _hint(String text) => Text(
        text,
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
}

/// 一条内置公共实例（点一下即选中）
class _BuiltinTile extends StatelessWidget {
  const _BuiltinTile({
    required this.instance,
    required this.selected,
    required this.onTap,
  });

  final DanmakuPublicInstance instance;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? AppIcons.check_circle : AppIcons.radio_button_unchecked,
              size: 18,
              color: selected ? colors.primary : colors.onSurfaceVariant,
            ),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    instance.label,
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      fontWeight:
                          selected ? FontWeights.semibold : FontWeights.regular,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: Sp.x1),
                  Text(
                    instance.baseUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 状态行：未配置 / 已保存 / 在线 / 离线 / 测试中
class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.result,
    required this.why,
    required this.running,
    required this.hasAddress,
  });

  final DanmakuLocalStatus? result;
  final String? why;
  final bool running;

  /// 地址框里有没有字
  ///
  /// # 为什么状态行需要知道这件事（真 UX 缺陷，不是洁癖）
  /// 地址框**空着**时点「测试连接」，探的是**本机弹弹play（2080）**，
  /// 于是状态行写成「检测到本机外部弹幕 未运行」——
  /// 这句话本身是真的，但用户刚在「服务地址」这一栏里点了按钮，
  /// 会以为那是**他填的地址**的结论，而他其实什么都没填。
  /// ⇒ 地址为空时**明说**「测的是本机弹弹play」，不让它冒充 dan-api 的结论。
  final bool hasAddress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final saved = UiPrefs.danmakuEndpoint;

    final IconData icon;
    final Color color;
    final String text;

    if (running) {
      icon = AppIcons.hourglass_top;
      color = colors.onSurfaceVariant;
      text = '正在测试…';
    } else if (why != null) {
      icon = AppIcons.error_outline;
      color = colors.error;
      text = why!;
    } else if (result != null) {
      icon = result!.online ? AppIcons.check_circle : AppIcons.cloud_off;
      color = result!.online ? colors.primary : colors.error;
      /*
       * ⚠️ 地址为空时，探测打的是**本机弹弹play（2080）**。
       *    此时若直接显示 result.line（「本机外部弹幕 未运行」），
       *    用户会把它当成自己刚填地址的结论 —— 而他什么都没填。
       *    ⇒ 前缀一句说明，把「测的是谁」讲清楚。
       */
      text = hasAddress ? result!.line : '（地址为空，测的是本机弹弹play）${result!.line}';
    } else if (!hasAddress && saved.isEmpty) {
      /*
       * 地址空、也没存过 ⇒ 什么都不用测，直接说清楚现在是哪条路。
       * ⚠️ 这一支必须排在 saved.isNotEmpty 之前：用户可能存了值又手动清空
       *    输入框，那时该按「没填」处理。
       */
      icon = AppIcons.info_outline;
      color = colors.onSurfaceVariant;
      text = '未配置 —— 现在用的是本机弹弹play / 官方接口。'
          '填上 dan-api 地址后点「测试连接」。';
    } else if (saved.isNotEmpty) {
      // 存过但这次还没测 ⇒ 明说「已保存」，别让用户以为没生效
      icon = AppIcons.bookmark_outline;
      color = colors.onSurfaceVariant;
      text = '已保存（未测试）：$saved';
    } else {
      // 填了地址但还没点测试（hasAddress=true 且什么都没测过）
      icon = AppIcons.edit_outlined;
      color = colors.onSurfaceVariant;
      text = '填好地址后点「测试连接」确认它能用。';
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: Sp.x2),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: FontSizes.sm, color: color),
          ),
        ),
      ],
    );
  }
}