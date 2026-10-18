// ═══════════════════════════════════════════════════════════════════════
//  纯前端偏好存储 —— 对齐原版的 localStorage 用法
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不用 shared_preferences
//
// 原版注释说明了这类数据的性质：
// > 用 localStorage 而非后台库：这是**纯前端展示偏好**，
// > 丢了最多是回到默认源，不值得为它加表和同步。
//
// Flutter 侧的对应物是 `shared_preferences`，但它是一个**平台插件**
// （Windows 上要带 C++ 实现、Android 上要带 Java 实现）——
// 为了存一个"上次选了哪个播放源"而增加安装包体积不划算
// （硬指标③要求 Windows <50MB）。
//
// 用数据目录下的一个 JSON 文件即可：
// ```text
// ① 零依赖 —— 不增加任何平台代码
// ② 所有平台行为一致 —— 不存在插件实现差异
// ③ 数据在应用数据目录里，跟其它状态放一起，便于用户备份/清理
// ```
//
// # 同步 API
//
// 启动时一次性读进内存，之后读写都是内存操作（写入异步落盘）。
// 调用方（UI）拿到的是同步接口 —— 这正是 localStorage 的用法，
// 原版代码里就是 `localStorage.getItem(...)` 直接用在渲染路径上。
//
// ⚠️ 但**必须**先 `await UiPrefs.load(dir)` 再用，否则读到空值。

import 'dart:convert';
import 'dart:io';

/// 纯前端偏好（键值对）
class UiPrefs {
  UiPrefs._();

  static Map<String, String> _data = {};
  static File? _file;
  static bool _dirty = false;

  /// 是否已加载
  static bool get isLoaded => _file != null;

  /// 测试专用：清空内存里的偏好（不碰磁盘文件）
  ///
  /// 为什么需要：`_data` 是 static，同一个 isolate 里多个测试文件会互相
  /// 看到对方写过的键；单测要的是"从空开始"的确定性。
  static void debugResetForTest([Map<String, String>? data]) {
    _data = <String, String>{...?data};
    _file = null;
    _dirty = false;
  }

  /// 从数据目录加载
  ///
  /// # 失败不抛 —— 偏好丢了不该让应用起不来
  ///
  /// 文件损坏 / 权限不足时降级成"空偏好"：
  /// 表现是"上次选的播放源没记住"，而不是白屏。
  static Future<void> load(String dataDir) async {
    final f = File('$dataDir${Platform.pathSeparator}ui-prefs.json');
    _file = f;
    try {
      if (await f.exists()) {
        final txt = await f.readAsString();
        final m = jsonDecode(txt);
        if (m is Map) {
          _data = m.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      }
    } catch (e) {
      // 损坏 → 用空偏好继续（不删文件，用户可能想自己看看）
      debugLog('偏好文件读取失败（降级为空）: $e');
      _data = {};
    }
  }

  /// 读一个键（不存在返回 null）
  static String? get(String key) => _data[key];

  /// 写一个键
  ///
  /// 立即改内存（UI 下一次读就能看到），落盘是异步的 ——
  /// 调用方不需要 await（与 localStorage 的同步语义一致）。
  static void set(String key, String value) {
    if (_data[key] == value) return;
    _data[key] = value;
    _dirty = true;
    _flushSoon();
  }

  /// 删一个键
  static void remove(String key) {
    if (!_data.containsKey(key)) return;
    _data.remove(key);
    _dirty = true;
    _flushSoon();
  }

  static Future<void>? _pending;

  /// 合并短时间内的多次写入
  ///
  /// 为什么：用户快速切几个播放源会触发多次写。
  /// 每次都落盘是浪费（且可能写坏 —— 两个异步写重叠）。
  static void _flushSoon() {
    if (_pending != null) return;
    _pending = Future.delayed(const Duration(milliseconds: 300), () async {
      _pending = null;
      await flush();
    });
  }

  /// 立刻落盘（退出前调一次，或测试里用）
  static Future<void> flush() async {
    if (!_dirty || _file == null) return;
    _dirty = false;
    try {
      await _file!.writeAsString(jsonEncode(_data));
    } catch (e) {
      debugLog('偏好落盘失败: $e');
      // 写失败不算致命 —— 内存里还是对的，本次会话不受影响
    }
  }

  // ── 播放源偏好（原版 `dsh.srcpref.<provider>:<id>`）──

  /// 读某作品记住的播放源 code
  static String sourcePref(String provider, String id) =>
      _data['dsh.srcpref.$provider:$id'] ?? '';

  /// 记住某作品的播放源 code
  static void setSourcePref(String provider, String id, String code) =>
      set('dsh.srcpref.$provider:$id', code);

  // ── 首页选中的源（原版 `dsh.homeSource`）──

  /// 存储键 —— **故意与原版同名**
  ///
  /// # 为什么必须是**独立的键**（原版注释专门解释了）
  ///
  /// > 它和播放偏好（`dsh.playprefs`）没关系。混在一起的话，
  /// > 「清空播放偏好」会顺带把首页选中的源也清掉 ——
  /// > 那是两件不相干的事。
  ///
  /// 所以**不要**把它塞进 `dsh.srcpref.*` 那个命名空间
  /// （那是"某作品用哪个播放线路"，与"首页看哪个内容源"完全是两回事）。
  static const homeSourceKey = 'dsh.homeSource';

  /// 首页当前选中的内容源 id（空串 = 没选过 / 已失效）
  static String get homeSource => _data[homeSourceKey] ?? '';

  /// 记住首页选中的内容源
  ///
  /// ⚠️ 传空串 = **清除**（与原版 `removeItem` 等价）。
  ///    不能直接 `set(key, '')` —— `set` 会把空串**存进去**
  ///    （而 `_data[key] ?? ''` 读出来也是空串，看起来一样，
  ///     但文件里会留一个 `"dsh.homeSource": ""` 的垃圾键）。
  static void setHomeSource(String id) {
    if (id.isEmpty) {
      remove(homeSourceKey);
    } else {
      set(homeSourceKey, id);
    }
  }

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ Owner 第 12 条：自定义直播源分组
  // ══════════════════════════════════════════════════════════════════

  /// 存储键（**故意不复用** dsh.srcpref.* 命名空间）
  ///
  /// # 为什么不塞进 dsh.srcpref.*
  /// ```text
  /// dsh.srcpref.<provider>:<id> 的语义是「**某作品**用哪个播放线路」，
  /// 与本条「**直播源**怎么分组」完全不相干 —— 同 [homeSourceKey] 的注释：
  /// 混在一起的话，「清空播放偏好」会顺带把分组也清掉。
  /// ```
  static const liveSourceGroupsKey = 'live_source_groups';

  /// 读全部直播源分组：分组名 → 源 id 列表
  ///
  /// # 返回值的形态（对外契约）
  /// ```text
  /// · 没存过 / 存的是垃圾 ⇒ 返回**空 Map**（不是 null）——
  ///   调用方只需判 isEmpty，不必再处理 null。
  /// · 值的顺序**保留**（用户建组的顺序 / 组内源的顺序都有意义）。
  /// · 一个源是否只能属于一个组？**本层不强制** —— 不做去重、不做互斥，
  ///   那是编辑 UI 的职责（数据层保持如实存取，便于将来放宽）。
  /// ```
  ///
  /// # ★ 向前兼容（Lead 明确要求）
  /// ```text
  /// 存的是 JSON **对象**（不是数组）⇒ 以后要加字段（组的颜色 / 排序权重）
  /// 时只需新增**键**：老版本读到不认识的键会**忽略**，
  /// 新版本读到老数据也能跑（缺的键用默认值）。
  /// ⚠️ 所以解析必须**逐键宽松**：任何一个键坏了只丢那个键，
  ///    **不**让整份数据作废（否则手改坏一个字符 ⇒ 用户分组全没了）。
  /// ```
  static Map<String, List<String>> liveSourceGroups() {
    final raw = _data[liveSourceGroupsKey];
    if (raw == null || raw.isEmpty) return <String, List<String>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, List<String>>{};
      final out = <String, List<String>>{};
      decoded.forEach((k, v) {
        // ⚠️ 逐键宽松：坏的那一项跳过，其余照收（见上面的向前兼容说明）
        if (k is! String || k.isEmpty) return;
        if (v is! List) return;
        out[k] = [
          for (final e in v)
            if (e is String && e.isNotEmpty) e,
        ];
      });
      return out;
    } catch (e) {
      debugLog('直播分组解析失败（按空处理，不炸）: $e');
      return <String, List<String>>{};
    }
  }

  /// 写全部直播源分组（整体覆盖）
  ///
  /// ⚠️ 传空 Map = **清除键**（与 [setHomeSource] 同一条纪律：不留垃圾键）。
  static void setLiveSourceGroups(Map<String, List<String>> groups) {
    if (groups.isEmpty) {
      remove(liveSourceGroupsKey);
      return;
    }
    set(liveSourceGroupsKey, jsonEncode(groups));
  }

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ 直播分组 v2：按**频道**而不是按源
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么必须换模型（Owner 原话）
  // ```text
  // > 我要的是自建分组可以选择直播源下的具体的直播的房间，而不是选择直播源
  // > 这是错误的
  // ```
  // v1（[liveSourceGroupsKey]）的成员是**源 id**，一个分组只能表达
  // 「这个源的全部频道」—— 而直播源动辄 20~48 个台，用户想挑的是其中几个。
  //
  // # 为什么是**新增一个键**而不是原地改格式
  // ```text
  // ① 用户机器上已经有 v1 数据（真实 ui-prefs.json 里就有）。
  //    原地改格式 ⇒ 老数据解析失败 ⇒ 用户分组**静默消失**。
  // ② 两个键可以**共存**：读的时候 v2 优先、v1 兜底（见
  //    `lib/ui/live_page.dart` 的 `resolveLiveGroupMembers`）。
  //    ⇒ 老分组照旧能用，用户在新界面里改一次就自然升级成 v2。
  // ③ 回退成本 = 删掉 v2 的键，v1 原样还在（不破坏性）。
  // ```

  /// 存储键：按**频道**分组的直播分组
  ///
  /// 值形如 `{"常看": [{"p":"<源 id>","c":"<频道 id>"}, …]}`
  /// ⚠️ 用占位符而不是真实台名做例子 —— 仓库有站名/台名门禁（t98），
  ///    注释里的举例也算命中。
  static const liveChannelGroupsKey = 'live_channel_groups';

  /// 读全部「按频道」分组：分组名 → 频道引用列表
  ///
  /// # 契约（与 [liveSourceGroups] 同一套纪律）
  /// ```text
  /// · 没存过 / 整份是垃圾 ⇒ **空 Map**（不是 null）
  /// · 逐键宽松：某个组坏了只丢那个组，不让整份作废
  /// · 逐项宽松：某个频道引用坏了只丢那项（手改坏一个字符不会清空分组）
  /// · 顺序保留（组的顺序 / 组内频道的顺序都有意义）
  /// ```
  static Map<String, List<LiveChannelRef>> liveChannelGroups() {
    final raw = _data[liveChannelGroupsKey];
    if (raw == null || raw.isEmpty) return <String, List<LiveChannelRef>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, List<LiveChannelRef>>{};
      final out = <String, List<LiveChannelRef>>{};
      decoded.forEach((k, v) {
        if (k is! String || k.isEmpty) return;
        if (v is! List) return;
        final members = <LiveChannelRef>[];
        for (final e in v) {
          final ref = LiveChannelRef.tryParse(e);
          if (ref != null) members.add(ref);
        }
        out[k] = members;
      });
      return out;
    } catch (e) {
      debugLog('直播频道分组解析失败（按空处理，不炸）: $e');
      return <String, List<LiveChannelRef>>{};
    }
  }

  /// 写全部「按频道」分组（整体覆盖）
  ///
  /// ⚠️ 传空 Map = **清除键**（同 [setLiveSourceGroups]：不留垃圾键）。
  static void setLiveChannelGroups(Map<String, List<LiveChannelRef>> groups) {
    if (groups.isEmpty) {
      remove(liveChannelGroupsKey);
      return;
    }
    set(
      liveChannelGroupsKey,
      jsonEncode({
        for (final e in groups.entries)
          e.key: [for (final r in e.value) r.toJson()],
      }),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  自建弹幕服务地址（T3 · dan-api 调研落地）
  // ══════════════════════════════════════════════════════════════════

  /// 存储键：自建弹幕服务基址
  ///
  /// # 为什么单独一个键（不复用弹弹play 那套）
  /// ```text
  /// 弹弹play 的凭证键（dsh.danmaku.appId / appSecret）语义是「给官方签名用」，
  /// 而这里是「换一个免凭证的后端地址」—— 两件事互不相干：
  /// 用户可能同时保留官方凭证、又临时切到自建服务。
  /// 混在一起 ⇒ 清其中一个会顺带清掉另一个。
  /// ```
  static const danmakuEndpointKey = 'dsh.danmaku.endpoint';

  /// 自建弹幕服务基址（空串 = 没配 ⇒ 走内置的官方/本机路径）
  static String get danmakuEndpoint => _data[danmakuEndpointKey] ?? '';

  /// 记住自建弹幕服务基址
  ///
  /// ⚠️ 传空串 = **清除键**（与 [setHomeSource] / [setLiveSourceGroups] 同一纪律：
  ///    不留垃圾键）。用户在设置里清空地址时必须能真的回到内置路径。
  static void setDanmakuEndpoint(String baseUrl) {
    if (baseUrl.trim().isEmpty) {
      remove(danmakuEndpointKey);
    } else {
      set(danmakuEndpointKey, baseUrl.trim());
    }
  }

  /// 存储键：布局骨架（Owner 第 14 条）
  ///
  /// # ★ 为什么放这里，**不**放进 ThemePack
  /// ```text
  /// 布局骨架 与 配色主题 是**正交**的两个维度：
  ///   配色 9 套（theme_pack.dart 管）    骨架 3 套（本键管）
  /// ⇒ 27 种组合。
  ///
  /// ⚠️ 若把骨架塞进 ThemePack，用户导入别人的配色主题时
  ///    **布局也会被一起改掉** —— 那不是他要的。
  ///    主题文件只该带「颜色」，不该带「控件摆在哪」。
  /// ```
  static const shellLayoutKey = 'shell.layout';

  /// 当前布局骨架 id（默认 `bottomBar` = 底栏式）
  ///
  /// ⚠️ 未知 id（老版本写入 / 手工改坏）⇒ 回落默认值，
  ///    不能让界面因为一个认不出的字符串就空白。
  static String get shellLayout => _data[shellLayoutKey] ?? 'bottomBar';

  /// 记住布局骨架（传空串 = 清除键，回到默认）
  static void setShellLayout(String layoutId) {
    if (layoutId.trim().isEmpty) {
      remove(shellLayoutKey);
    } else {
      set(shellLayoutKey, layoutId.trim());
    }
  }
  /// 存储键：自建弹幕服务的可选 token（放在路径前缀上，见 DanmakuEndpoint）
  static const danmakuTokenKey = 'dsh.danmaku.endpoint.token';

  /// 自建弹幕服务 token（空串 = 不带前缀）
  static String get danmakuToken => _data[danmakuTokenKey] ?? '';

  /// 记住 token（传空串 = 清除键）
  static void setDanmakuToken(String token) {
    if (token.trim().isEmpty) {
      remove(danmakuTokenKey);
    } else {
      set(danmakuTokenKey, token.trim());
    }
  }
}

/// 指向一个**具体直播频道**的引用（源 id + 频道 id）
///
/// # 为什么需要 `provider` 这一维
/// ```text
/// `LiveChannel.id` 只在**同一个源内**唯一：
///   实测本机两个直播源都有 id 形如 `1` / `2` 的频道
/// ⇒ 只存频道 id ⇒ 分组会命中**别的源**的同名频道（用户没选过的台）。
/// ⇒ 必须 (provider, channelId) 成对存。
/// ```
///
/// # 为什么不直接存 `LiveChannel` 对象
/// ```text
/// `LiveChannel` 还有 name / logo / group / now_playing —— 那些是**源给的
/// 实时数据**，会变（改名、换台标）。存进偏好里会立刻过期，
/// 而且用户换了源之后那份快照就成了假信息。
/// ⇒ 偏好只存**身份**（两个 id），名字等展示信息一律现取。
/// ```
///
/// ⚠️ 这个类**不依赖 Flutter**（本文件整体如此）⇒ 可直接单测。
class LiveChannelRef {
  const LiveChannelRef(this.provider, this.channelId);

  /// 源 id（`LiveGroup.provider`）
  final String provider;

  /// 频道 id（`LiveChannel.id`，**只在 [provider] 内唯一**）
  final String channelId;

  /// 序列化形态：`{"p": "...", "c": "..."}`
  ///
  /// ★ 用短键（p / c）而不是 provider / channelId：这个键会在用户的
  ///   ui-prefs.json 里出现很多次（一个组几十个频道），短键省一半体积。
  Map<String, String> toJson() => {'p': provider, 'c': channelId};

  /// 宽松解析：认不出来 ⇒ null（调用方**跳过这一项**，不让整份作废）
  static LiveChannelRef? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final p = raw['p'];
    final c = raw['c'];
    if (p is! String || p.isEmpty) return null;
    if (c is! String || c.isEmpty) return null;
    return LiveChannelRef(p, c);
  }

  /// 稳定字符串（用于去重 / 做 Widget key）
  String get key => '$provider\u0000$channelId';

  @override
  bool operator ==(Object other) =>
      other is LiveChannelRef &&
      other.provider == provider &&
      other.channelId == channelId;

  @override
  int get hashCode => Object.hash(provider, channelId);

  @override
  String toString() => '$provider/$channelId';
}

/// 轻量日志（这个文件不依赖 Flutter，所以用 print）
void debugLog(String msg) {
  // ignore: avoid_print
  print('[UI-PREFS] $msg');
}
