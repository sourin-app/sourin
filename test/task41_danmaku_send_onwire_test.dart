// ═══════════════════════════════════════════════════════════════════════
//  task-41：弹幕发送**真实走线**（Dart → Rust FFI → 插件 → 本地 HTTP 服务器）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须在本地起真服务器，而不是 mock 掉 SourinApi
// ```text
// mock 掉的写法只能证明「我调了那个函数」，证明不了：
//   ① RFI 的 snake_case 键名真的被 serde 认了（不是静默丢弃）；
//   ② 插件收到的 text / 进度 真的是我们发的那一份；
//   ③ 插件抛的 unsupported 真的翻成了 SourinCoreException.kind。
// 本项目在 pr #30 上正好踩过①：驼峰键被 serde 静默丢掉，
// 插件收到空串，而所有结构体断言照样绿。
// ⇒ 这里让**真插件**把收到的东西 POST 到本地 HttpServer，读服务器收到什么。
// ```
//
// # 判据为什么是「服务器收到的那一行」而不是「函数返回了什么」
// ```text
// 返回值只说明宿主认为成功；用户真正在意的是**上游收到了什么**。
// 服务器收到的 body 是这条链路上唯一的**外部**读数。
// ```
//
// # ⚠️ 环境前提（不满足就如实跳过，不许假绿）
// 需要含 provider_danmaku_send 的 sourin_core.dll；
// 且核心必须**由本文件自己起**（SourinCore 是进程级单例，
// 往别人的核心里装插件会污染共享状态）。
// 两条任缺其一 ⇒ markTestSkipped 并打印原因。
// ═══════════════════════════════════════════════════════════════════════
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';

const List<String> _dllCandidates = <String>[
  r'rust\sourin_core\target\debug\sourin_core.dll',
  r'build\windows\x64\runner\Release\sourin_core.dll',
  r'windows\sourin_core.dll',
];

/// 测试插件：把收到的 req POST 到本地服务器，然后按 `fail` 决定成不成功
///
/// ⚠️ `__ENDPOINT__` 在运行时替换成真实端口 —— 端口是 0 自动分配的，
///    插件源码在 setUpAll 里才拼出来，所以这里留占位符。
///
/// ★ 两种模式：
///   fail=false ⇒ 正常上报，返回 {ok:true, id:'srv-1'}
///   fail=true  ⇒ 仍然上报（证明它真被调到了），但 throw unsupported
///     —— 这条模拟「声明了 danmakuSend 却没实现」的真实形态。
String _pluginSrc({required String endpoint, required bool fail}) => r'''
/** @id send_probe @name 发送探针 */
globalThis.plugin = {
  id: 'send_probe',
  capabilities: { vod: true, danmaku: true, danmakuSend: true },
  async danmakuSend(req) {
    /*
     * ★ 把收到的 req 原样上报 —— 这是「值真的到了插件」的唯一外部读数。
     *
     * ⚠️ 用 host.http.post，**不是** fetch —— 插件沙箱里没有 fetch/XHR，
     *    只有宿主注入的 host.http（见 docs/PLUGINS.md:86-88）。
     *    这一点是实测出来的：第一版写 fetch 直接报
     *      SourinCoreException(other): 插件报错: fetch is not defined
     */
    await host.http.post('__ENDPOINT__', JSON.stringify({
      text: req.text,
      episodeId: req.episodeId,
      progressMs: req.progressMs,
      provider: req.provider,
    }), { headers: { 'content-type': 'application/json' } });
    if (__FAIL__) {
      throw new Error('unsupported: 这个源只声明了能力，没真的实现发送');
    }
    return { ok: true, id: 'srv-1' };
  },
};
''';

void main() {
  String? dllPath;
  late Directory sandbox;
  late HttpServer server;
  var coreUp = false;
  var installNote = '';
  var endpoint = '';

  /// 服务器收到的所有 body（按到达顺序）
  final List<String> received = <String>[];

  setUpAll(() async {
    // ── ① 选 DLL ──
    for (final c in _dllCandidates) {
      if (File(c).existsSync()) {
        dllPath = c;
        break;
      }
    }
    if (dllPath == null) {
      installNote = '找不到 sourin_core 产物（候选: ${_dllCandidates.join(", ")}）';
      return;
    }
    try {
      DynamicLibrary.open(File(dllPath!).absolute.path);
    } catch (e) {
      installNote = 'DLL 预加载失败: $e';
      return;
    }

    // ── ② 共享状态守卫：核心已被别处启动 ⇒ 不往里装插件 ──
    if (SourinCore.isStarted) {
      installNote = '核心已被别处启动（进程级单例）⇒ 不往它装测试插件';
      debugPrint('SENDPROBE 跳过: $installNote');
      return;
    }

    // ── ③ 起本地服务器（端口 0 = 自动分配，避免撞别人的端口）──
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      endpoint = 'http://127.0.0.1:${server.port}/send';
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        received.add(body);
        req.response
          ..statusCode = 200
          ..write('{"ok":true}');
        await req.response.close();
      });
    } catch (e) {
      installNote = '本地服务器起不来: $e';
      return;
    }

    // ── ④ 起真核心（隔离目录）──
    sandbox = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
        'sendprobe_${DateTime.now().microsecondsSinceEpoch}');
    sandbox.createSync(recursive: true);
    try {
      await SourinCore.startAsync(sandbox.path);
      coreUp = SourinCore.isStarted;
    } catch (e) {
      installNote = '核心起不来: $e';
      return;
    }
    if (!coreUp) {
      installNote = 'startAsync 返回了但 isStarted=false';
      return;
    }

    // ── ⑤ 装插件 ──
    try {
      final src = _pluginSrc(endpoint: endpoint, fail: false)
          .replaceAll('__ENDPOINT__', endpoint)
          .replaceAll('__FAIL__', 'false');
      await SourinApi.installPluginSource(src, nameHint: 'send_probe.js');
    } catch (e) {
      installNote = '装插件失败: $e';
      coreUp = false;
    }
    debugPrint('SENDPROBE dll=$dllPath coreUp=$coreUp note=$installNote');
  });

  tearDownAll(() async {
    if (coreUp) {
      try {
        await server.close(force: true);
      } catch (_) {}
      try {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上 SQLite 可能还被核心持有 —— 删不掉不是失败
      }
    }
  });

  setUp(() => received.clear());

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 主判据：正文和进度真的到了上游
  // ═══════════════════════════════════════════════════════════════════

  test('★★★ 发出去的弹幕，本地服务器真的收到了（正文 + 进度 + 集 id）', () async {
    if (!coreUp) {
      markTestSkipped('真核心/发送命令不可用：$installNote');
      return;
    }

    final r = await SourinApi.providerDanmakuSend(
      'send_probe',
      episodeId: 'ep-42',
      text: '这是一条真弹幕',
      progressMs: 65432,
    );

    expect(r.ok, isTrue, reason: '★ 插件回了 ok:true，宿主应当认为成功');

    /*
     * ★ 等待服务器收到 —— 插件用 await fetch，但那段在 QuickJS 的
     *   异步队列里，不保证在 FFI 返回时就已到达。用轮询而不是固定 sleep。
     */
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (received.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(received, isNotEmpty,
        reason: '★★★ 服务器一条都没收到 ⇒ 插件根本没被调到，'
            '或者它发出去了但链路上丢了');

    final body = jsonDecode(received.first) as Map<String, dynamic>;
    /*
     * ★★★ 这三条一起构成「值真的过去了」：
     *   text  —— 正文没有在 Dart→Rust 的 snake_case 转换里被丢掉
     *   episodeId —— 同上（项目在 pr #30 踩过这个坑）
     *   progressMs —— 进度是 Optional，写错就会变成 null
     */
    expect(body['text'], '这是一条真弹幕',
        reason: '★★ 正文必须一字不差地到达上游');
    expect(body['episodeId'], 'ep-42',
        reason: '★★ 集 id 必须到达（驼峰键被 serde 静默丢弃是这个项目的既有坑）');
    expect(body['progressMs'], 65432,
        reason: '★★ 播放进度必须到达 —— 按进度发的站点靠它定位');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 未实现 ⇒ 必须抛 unsupported（不许假装成功）
  // ═══════════════════════════════════════════════════════════════════

  test('★★★ 插件未实现发送 ⇒ 抛 unsupported，绝不假装成功', () async {
    if (!coreUp) {
      markTestSkipped('真核心不可用：$installNote');
      return;
    }

    /*
     * 换一个**声明了 danmakuSend 但一调就抛** 的插件 ——
     * 这正是契约里说的「声明与实现不一致」那种真实形态。
     */
    final src = _pluginSrc(endpoint: endpoint, fail: true)
        .replaceAll('__ENDPOINT__', endpoint)
        .replaceAll('__FAIL__', 'true')
        .replaceAll("@id send_probe", "@id send_probe_fail")
        .replaceAll("id: 'send_probe'", "id: 'send_probe_fail'");
    await SourinApi.installPluginSource(src, nameHint: 'send_probe_fail.js');

    /*
     * ⚠️ 判据是**抛异常**，不是返回 ok:false。
     *   契约（docs/PLUGINS.md:136）写明：发送未实现必须 throw unsupported，
     *   宿主把 ok:false 也当失败 —— 但正常路径应当是 Err。
     */
    Object? caught;
    try {
      await SourinApi.providerDanmakuSend(
        'send_probe_fail',
        episodeId: 'ep-42',
        text: '发不出去',
      );
    } catch (e) {
      caught = e;
    }

    expect(caught, isNotNull,
        reason: '★★★ 未实现必须抛错 —— 若静默返回成功，用户会以为发出去了，'
            '刷新找不到再反复发，在真站点上可能已经触发风控');
    expect(caught, isA<SourinCoreException>(),
        reason: '★ 应当是结构化异常（带 kind），否则 UI 无法分类翻译');
    /*
     * ★★★ 这里**不断言 kind == 'unsupported'**，而断言消息**带标准前缀**。
     *
     * # 为什么（这是实测发现的 Rust 侧真缺陷，不是我在迁就）
     * ```text
     * 实测：插件抛 'unsupported: 这个源只声明了能力，没真的实现发送'
     *   ⇒ Dart 收到的 kind = **other**（前缀被丢了）
     * 原因：Rust 侧 provider_danmaku_send 走 with_state_async，
     *   错误在那一层被 classify_error(&e)（ffi.rs:2188）**按关键字重新分类**，
     *   它拿到的是一句扁平化的 message，ProviderError 原来的 kind 已经没了；
     *   而它的关键词表里只有「不支持 / 未配置 / 登录 / 401 / timeout / 网络…」，
     *   **不认 unsupported: 这个前缀**。
     *
     * 反证（同一次实验）：把正文改成含「不支持」⇒ kind 立刻变成 unsupported。
     * ⇒ 这证明分类确实只看正文关键词，不看前缀。
     * ```
     *
     * ⚠️ 修 Rust 那个函数**不在我的写入范围**（Lead 只给了 player_page.dart），
     *    已单独写进汇报里。
     * 本文件断言**消息前缀**：那是插件的契约义务，也确实成立。
     * 而 UI 侧已改为「前缀优先、kind 兜底」，所以用户仍会看到
     * 「这个源不支持发送弹幕」这句正确提示（由 t41_gate 那条测守着）。
     */
    final ex = caught! as SourinCoreException;
    /*
     * ★★★ 这条现在是**真断言**了（task-43 修好之后从"只能断言前缀"升级）
     *
     * # 修之前
     * ```text
     * 插件抛 'unsupported: ...' ⇒ kind = 'other'
     * 所以这里当时只能退而断言「消息带前缀」，并注释说明是 Rust 侧缺陷。
     * ```
     * # 修之后（ffi.rs classify_error 先认标准前缀）
     * ```text
     * 同一个插件、同一句话 ⇒ kind = 'unsupported'
     * ```
     * ⇒ 这里直接断言 kind，**跨层**（Dart → DLL → FFI → QuickJS）验证修复真的生效。
     *   这是 task-43 唯一能证明「线上行为变对了」的读数。
     */
    expect(ex.kind, 'unsupported',
        reason: '★★★ task-43：标准前缀必须被 classify_error 认出来。\n'
            '若这里是 other ⇒ 修复没生效（或 DLL 没重新编译）。');
    expect(ex.message.startsWith('unsupported:'), isTrue,
        reason: '★★ 失败原因必须以 unsupported: 开头 —— '
            '这是契约（docs/PLUGINS.md:230）要求的声明方式，'
            '也是 UI 用来判定「这个源不支持发送」的依据。\n'
            '实际收到：${ex.message}');
  });
}