// ═══════════════════════════════════════════════════════════════════════
//  N4-1 中文输入定位探针 —— 「合成到了窗口，但没落到 EditableText」到底卡在哪一段
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 的原话（逐字）
// ```text
// 英文可以，中文不行，有的时候输入框还会出现 打着打着 就只能输入英文了
// ```
//
// # 已经**不用再查**的两层（前置取证，别重复劳动）
// ```text
// ① 页面层不拦中文：test/zz_n4_1_ime_composition_test.dart（+2/-0；注入"只允许 ASCII"真红）
// ② 窗口层收到了完整合成：%TEMP%\sourin_ime.log 里 6 次
//    WM_IME_STARTCOMPOSITION → WM_IME_COMPOSITION(lparam=0x800 RESULTSTR) → WM_IME_ENDCOMPOSITION
//    且 SourinChildWndProc 对 WM_IME_* 只记日志、**原样 CallWindowProcW** 交回引擎
//    （见 win32_window.cpp:2062-2133；只有 WM_NCHITTEST/WM_SETCURSOR 的边框带才 return）
// ⇒ 剩下的未知**只在一段**：引擎拿到 RESULTSTR 之后，Dart 的 EditableText 有没有收到 / 有没有被抹掉。
// ```
//
// # 这个探针回答什么（三条，必须一次跑完就能分开）
// ```text
// A) 中文**根本没到** controller（cjk=0 且 len 不变）
//    ⇒ 断在「引擎 → Dart」，页面层无辜；修在引擎/平台层（本仓只能绕，改不了引擎）
// B) 中文到了 controller，但**随后又被抹掉**（先 cjk>0，几毫秒后 len 回到 0）
//    ⇒ 断在「谁在改 controller」，能在 Dart 里修（有据可查的那一处）
// C) 静态页能打、**每秒重建**的页打不了（或反过来）
//    ⇒ 断在「宿主重建」，能在播放页/页面层修（不需要动引擎）
// ```
//
// # 为什么必须**同屏放三个输入区**（这是本探针的核心手法）
// ```text
// ① 静态区：真 DanmakuSearchPage（与生产同构造参数），**完全不重建**
// ② 重建区：同一个页面，但宿主持有 `Timer.periodic(1s) → setState`
//            —— 精确复刻"播放页每秒 tick"这一条嫌疑（不带播放器，隔离变量）
// ③ 对照区：一个最朴素的 TextField（本探针自己持有 controller/FocusNode）
//            —— 它不经过本仓任何页面代码。它若也打不了中文 ⇒ 与页面无关（引擎/OS 层）
// ⇒ 三个区逐一对打，就能把"页面 / 宿主重建 / 引擎"三选一钉死。
// ```
//
// # 它**不**做什么（边界，别把本文件读成"修好了"）
// ```text
// · 不改生产代码：`lib/ui/danmaku_search_page.dart`、`lib/shell.dart`、`rust/**`、
//   `windows/runner/**` 一律**只读**（写入范围属别人）。
// · 不记录**任何明文输入**：只记长度 / composing 区间 / ASCII 与 CJK 的**计数**
//   —— 与 `win32_window.cpp` 那条"只记消息类型、不记内容"的隐私口径一致。
// · 不做"模拟输入"：合成信号必须由 Owner 用真输入法打出（假事件测不出 IME 真行为）。
// · 它自己**不能**证明"引擎有没有往通道里发东西"（Dart 侧拿不到 TextInput 通道的
//   出站消息：`TextInput.setInputControl` 是**独占**替换，装上去会把真输入打断），
//   所以改用"controller 是否变化 + 英文是否照常"来**反证**连接是活的。
//   ★ 连接开关的**近似观测**：`NODE` 行的 `hasPrimaryFocus` 真假切换
//     ≈ 引擎 `TextInput.setClient` / `TextInput.clearClient` 的时间点
//     （`EditableText._openInputConnection` 由焦点驱动，见 editable_text.dart:3500-3510）；
//     这是**代理指标**，不是通道录包，读的时候按"近似"对待。
// ```
//
// # 怎么跑（Owner 只需一次）
// ```text
// flutter build windows --release -t lib/probe_ime_trace.dart
// （在**仓库根**启动产物，`.probe` 是相对 cwd 的）
// 然后：
//   ① 点「静态」区里的关键词框 → 打 "abc"（确认英文进去）→ 再打两个中文并选词
//   ② 切到「每秒重建」区 → 同样各打一次英文 / 中文
//   ③ 在底部「对照框」里再打一次中文
//   ④ 看窗口底部的实时日志（也可看 .probe/n4-1-ime/n4-1-trace.log）
// ```
//
// # 日志怎么读（只看三处）
// ```text
// BIND      field=page-static/page-ticking/probe   controller=/focus= 的 identityHashCode
// EDIT      field=… len=N composing=a..b ascii=N cjk=N Δ=±N
//           —— composing 有效 = 输入法"正在合成"；cjk>0 = 中文**已经在 Dart 手里**了
// FOCUS/KILL/focusNode … 谁在什么时候拿走焦点（"打着打着退化"多半在这里有痕迹）
// ⇒ 判读表见 `.probe/n4-1-ime-locate.md` 第 3 节。
// ```

import 'dart:async';
import 'core/ime_fallback.dart';
import 'dart:io';

import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter/services.dart' show HardwareKeyboard, KeyEvent;
import 'package:material_ui/material_ui.dart';

import 'core/danmaku.dart';
import 'ui/danmaku_search_page.dart';
import 'ui/widgets/bili_import_dialog.dart';
import 'ui/widgets/danmaku_settings_dialog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 探针要能看见「兜底插进来」这件事，所以也装通道
  installImeFallbackChannel();
  runApp(const _ImeProbeApp());
}

// ═══════════════════════════════════════════════════════════════════════
//  追踪器（纯观察：只读 controller / focusNode，不写回任何值）
// ═══════════════════════════════════════════════════════════════════════
class ImeTrace with WidgetsBindingObserver {
  ImeTrace._();

  static final ImeTrace instance = ImeTrace._();

  /// 屏幕上的实时日志（最近 14 行）；`ValueNotifier` 让面板自己重建
  final ValueNotifier<List<String>> tail = ValueNotifier<List<String>>(<String>[]);

  IOSink? _sink;
  Timer? _snap;

  /// 已绑定的 controller / focusNode（**按身份**去重：`identical`）
  final List<TextEditingController> _ctrls = <TextEditingController>[];
  final List<FocusNode> _nodes = <FocusNode>[];
  final Map<TextEditingController, TextEditingValue> _last =
      <TextEditingController, TextEditingValue>{};
  final Map<TextEditingController, String> _fieldOf = <TextEditingController, String>{};

  /// 当前激活的是哪个区（由 UI 设置；日志里带出来，读数不会串台）
  String pane = 'static';

  /// 探针自己的对照框（用来把"页面字段"和"非页面字段"分开）
  TextEditingController? probeCtrl;
  FocusNode? probeNode;

  void setProbeField(TextEditingController c, FocusNode n) {
    probeCtrl = c;
    probeNode = n;
  }

  Future<void> start() async {
    final dir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}.probe'
      '${Platform.pathSeparator}n4-1-ime',
    );
    await dir.create(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}n4-1-trace.log');
    _sink = f.openWrite(mode: FileMode.write);
    line('BOOT', 'trace file=${f.path}');
    line('BOOT', 'cwd=${Directory.current.path}');

    WidgetsBinding.instance.addObserver(this);
    // 焦点：谁拿走焦点，"打着打着退化"多半有痕迹
    FocusManager.instance.addListener(() {
      final f = FocusManager.instance.primaryFocus;
      line('FOCUS', 'primary=${f?.debugLabel ?? f?.runtimeType.toString() ?? "null"} '
          'pane=$pane');
    });
    // 键盘：与 C++ 的 WM_KEYDOWN 对齐（本函数返回 false = 只观察、不消费）
    HardwareKeyboard.instance.addHandler((KeyEvent e) {
      line('KEY', '${e.runtimeType} ${e.logicalKey.keyLabel} pane=$pane');
      return false;
    });
    // 每 2s 复扫一次（页面可能被挂/卸；重建区每秒 setState，identity 会变）
    _snap = Timer.periodic(const Duration(seconds: 2), (_) => scan());
    scan();
  }

  void stop() {
    _snap?.cancel();
    _sink?.flush();
    _sink?.close();
    _sink = null;
  }

  /// 打一行日志：`hh:mm:ss.SSS KIND msg`
  void line(String kind, String msg) {
    final now = DateTime.now();
    final ts = '${_p2(now.hour)}:${_p2(now.minute)}:${_p2(now.second)}'
        '.${now.millisecond.toString().padLeft(3, '0')}';
    final s = '$ts $kind $msg';
    // ignore: avoid_print
    print('[N4-1] $s');
    try {
      _sink?.writeln(s);
      _sink?.flush();
    } catch (_) {
      // 写盘失败不影响观察（屏幕上的 tail 仍在）
    }
    final t = <String>[...tail.value, s];
    final next = t.length > 14 ? t.sublist(t.length - 14) : t;
    /*
     * ★ 构建期不能直接 notify：`EditableText` 在它自己的 `initState`/`didUpdateWidget`
     *   里也会改 controller（例如本页 initState 会预填剧名），那一瞬间我们若
     *   `tail.value = …` ⇒ 面板 `markNeedsBuild()` 落在 build 阶段 ⇒
     *   debug 下直接抛 "setState() or markNeedsBuild() called during build"。
     * ⇒ 判一次调度阶段：帧中排队到帧后，其余立刻发。
     */
    final phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        tail.value = next;
      });
    } else {
      tail.value = next;
    }
  }

  static String _p2(int v) => v.toString().padLeft(2, '0');

  /// 走一遍元素树，绑定**新出现的** EditableText
  void scan() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;
    var found = 0;
    void walk(Element e) {
      final w = e.widget;
      if (w is EditableText) {
        found++;
        _bind(w);
      }
      e.visitChildren(walk);
    }

    walk(root);
    _state(found);
  }

  int _found = 0;
  void _state(int found) {
    if (found == _found) return;
    _found = found;
    line('SCAN', 'mounted EditableText=$found pane=$pane');
  }

  void _bind(EditableText w) {
    final c = w.controller;
    final n = w.focusNode;
    final isProbe = probeCtrl != null && identical(c, probeCtrl);
    final name = isProbe
        ? 'probe'
        : (pane == 'ticking' ? 'page-ticking' : 'page-static');
    if (!_ctrls.any((x) => identical(x, c))) {
      _ctrls.add(c);
      _fieldOf[c] = name;
      _last[c] = c.value;
      line('BIND', 'field=$name controller=#${identityHashCode(c)} '
          'focus=#${identityHashCode(n)} initialLen=${c.value.text.length}');
      if (isProbe) {
        probeNode = n;
      }
      c.addListener(() => _onEdit(c));
      // ★ focusNode 也按身份去重：同一 node 复用到新 controller 时不重复挂监听
      if (!_nodes.any((x) => identical(x, n))) {
        _nodes.add(n);
        n.addListener(() => _onFocusNode(c, n));
      }
    } else if (_fieldOf[c] != name) {
      // 同一个 controller 换了归属（重建区/静态区共用？理论上不会）—— 记一笔免得读数串台
      _fieldOf[c] = name;
      line('REBIND', 'field=$name controller=#${identityHashCode(c)}');
    }
  }

  void _onFocusNode(TextEditingController c, FocusNode n) {
    line('NODE', 'field=${_fieldOf[c]} hasFocus=${n.hasFocus} '
        'hasPrimaryFocus=${n.hasPrimaryFocus} pane=$pane');
  }

  /// controller 每次变化：长度 / composing / ASCII 与 CJK 计数（**不记明文**）
  void _onEdit(TextEditingController c) {
    final v = c.value;
    final prev = _last[c];
    _last[c] = v;

    final len = v.text.length;
    final prevLen = prev?.text.length ?? 0;
    final comp = v.composing;
    final compStr = comp.isValid && !comp.isCollapsed
        ? '${comp.start}..${comp.end}'
        : 'none';

    var ascii = 0;
    var cjk = 0;
    var other = 0;
    for (final r in v.text.runes) {
      if (r < 0x80) {
        ascii++;
      } else if (_isCjk(r)) {
        cjk++;
      } else {
        other++;
      }
    }
    line(
      'EDIT',
      'field=${_fieldOf[c]} len=$len Δ=${len - prevLen} composing=$compStr '
      'ascii=$ascii cjk=$cjk other=$other '
      'sel=${v.selection.start}..${v.selection.end} pane=$pane',
    );
  }

  static bool _isCjk(int r) =>
      (r >= 0x4E00 && r <= 0x9FFF) || // 基本汉字
      (r >= 0x3400 && r <= 0x4DBF) || // 扩展 A
      (r >= 0x3000 && r <= 0x303F) || // 中文标点
      (r >= 0xFF00 && r <= 0xFFEF); // 全角

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    line('LIFE', '$state pane=$pane');
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  UI：三个输入区 + 实时日志
// ═══════════════════════════════════════════════════════════════════════
class _ImeProbeApp extends StatefulWidget {
  const _ImeProbeApp();

  @override
  State<_ImeProbeApp> createState() => _ImeProbeAppState();
}

class _ImeProbeAppState extends State<_ImeProbeApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ImeTrace.instance.start();
    });
  }

  @override
  void dispose() {
    ImeTrace.instance.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _ImeProbeHome(),
    );
  }
}

class _ImeProbeHome extends StatefulWidget {
  const _ImeProbeHome();

  @override
  State<_ImeProbeHome> createState() => _ImeProbeHomeState();
}

class _ImeProbeHomeState extends State<_ImeProbeHome> {
  /// `static` = 不重建；`ticking` = 每秒 setState（复刻播放页 tick）
  String _pane = 'static';

  final _probeCtrl = TextEditingController();
  final _probeNode = FocusNode(debugLabel: 'probe-field');
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    ImeTrace.instance.setProbeField(_probeCtrl, _probeNode);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _probeCtrl.dispose();
    _probeNode.dispose();
    super.dispose();
  }

  void _setPane(String p) {
    if (p == _pane) return;
    setState(() => _pane = p);
    ImeTrace.instance.pane = p;
    ImeTrace.instance.line('PANE', 'switch -> $p');
    if (p == 'ticking') {
      _startTick();
    } else {
      _stopTick();
    }
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _pane != 'ticking') return;
      // ★ 这就是"播放页每秒重建"的最小复刻：只 setState，不换 key、不换 controller
      setState(() {});
    });
  }

  void _stopTick() {
    _tick?.cancel();
    _tick = null;
  }

  @override
  Widget build(BuildContext context) {
    // 每次 build 都**新建** widget（生产里播放页 setState 也是这样）——
    // State 与 controller 都在页面内部，`_keyword` 是 State 字段 ⇒ 不该丢。
    final page = DanmakuSearchPage(
      state: _settingsState,
      biliState: const BiliImportState(),
      draft: _draft,
      workTitle: 'N4-1 探针（示例作品）',
      localTitles: const <String>['第1集', '第2集', '第3集'],
      onSearch: (kw) => ImeTrace.instance.line(
        'SEARCH',
        'keyword.len=${kw.length} cjk=${kw.runes.where(ImeTrace._isCjk).length} '
            'pane=${ImeTrace.instance.pane}',
      ),
      onBiliSearch: (_) {},
      onPickMatch: (_) {},
      onBatchBind: (_) {},
      onBiliImport: (_) {},
      onBiliSelectPage: (_) {},
      onClose: () {},
    );

    return Scaffold(
      body: Column(
        children: <Widget>[
          _bar(),
          Expanded(
            child: KeyedSubtree(
              // key 用 pane：切区时**换掉整棵**，避免旧 State 串到新场景
              key: ValueKey<String>('pane-$_pane'),
              child: page,
            ),
          ),
          _probeField(),
          _logPanel(),
        ],
      ),
    );
  }

  Widget _bar() {
    return Container(
      color: const Color(0xFF1B1B1B),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: <Widget>[
          const Text('N4-1 IME 探针', style: TextStyle(color: Colors.white)),
          const SizedBox(width: 16),
          _seg('静态（不重建）', 'static'),
          const SizedBox(width: 8),
          _seg('每秒重建', 'ticking'),
          const Spacer(),
          Text(
            '现在：$_pane',
            style: const TextStyle(color: Color(0xFF8BC34A)),
          ),
        ],
      ),
    );
  }

  Widget _seg(String label, String value) {
    final on = _pane == value;
    return GestureDetector(
      onTap: () => _setPane(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: on ? const Color(0xFF2E7D32) : const Color(0xFF333333),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ),
    );
  }

  Widget _probeField() {
    return Container(
      color: const Color(0xFF101010),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: <Widget>[
          const Text('对照框（探针自有，不经本仓页面代码）：',
              style: TextStyle(color: Color(0xFFFFC107), fontSize: 12)),
          Expanded(
            child: TextField(
              controller: _probeCtrl,
              focusNode: _probeNode,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '在这里打中文，看 EDIT field=probe 那几行',
                hintStyle: TextStyle(color: Color(0xFF666666), fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _logPanel() {
    return Container(
      height: 190,
      color: const Color(0xFF000000),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: ValueListenableBuilder<List<String>>(
        valueListenable: ImeTrace.instance.tail,
        builder: (BuildContext context, List<String> lines, _) {
          return ListView.builder(
            reverse: true,
            itemCount: lines.length,
            itemBuilder: (BuildContext context, int i) {
              final s = lines[lines.length - 1 - i];
              return Text(
                s,
                style: const TextStyle(
                  color: Color(0xFF9CCC65),
                  fontSize: 10.5,
                  fontFamily: 'Consolas',
                ),
              );
            },
          );
        },
      ),
    );
  }

  // ── 给页面喂的最小状态（与生产同形状，避免"探针里能打、生产不能"的假象）────
  static const DanmakuSettingsState _settingsState = DanmakuSettingsState(
    enabled: true,
    appId: '',
    appSecret: '',
    fontScale: 1,
    opacity: 1,
    speed: 1,
    area: 1,
    searchSearched: false,
    searchStale: false,
    searchResults: <DanmakuMatch>[],
  );

  final DanmakuSearchDraft _draft = DanmakuSearchDraft(keyword: '');
}
