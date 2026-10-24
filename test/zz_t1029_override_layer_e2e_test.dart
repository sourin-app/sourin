import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';

/// 第 06 项 P2：覆盖层 FFI 三条命令的**端到端**门禁
///
/// 走真实 `SourinCore.callAsync` → 真实 Rust 核心 → 真实文件系统，
/// 不 mock、不桩。核心未启动时 `setUpAll` 直接跳过并**明确报出**，
/// 不允许"没启动也算过"。
void main() {
  late Directory dataDir;
  // 核心是否真的起来了。CI 的顺序是「全量测试 → 构建发布版」，
  // 所以测试阶段 `sourin_core.dll` **还不存在**（build.yml 有注释记着这个坑）。
  // 那种环境下本文件无法验证 FFI 链路 ⇒ 明确 skip 并报出读数，
  // 而不是让 setUpAll 直接红（那不是缺陷，是缺件）。
  var coreReady = false;

  setUpAll(() async {
    dataDir = await Directory.systemTemp.createTemp('sourin_ovr_e2e_');
    try {
      final started = await SourinCore.startAsync(dataDir.path);
      coreReady = started['ok'] == true;
    } catch (_) {
      coreReady = false;
    }
    if (!coreReady) {
      // 不静默：把"为什么没跑"留在日志里
      // ignore: avoid_print
      print('OVERRIDE_E2E|core_ready=false ⇒ 本文件全部 skip（CI 测试阶段无 DLL）');
    }
  });

  tearDownAll(() async {
    try {
      await dataDir.delete(recursive: true);
    } catch (_) {}
  });

  const targetId = 'e2e_probe_src';

  test('未个性化时 get 返回 null（不是错误）', () async {
    if (!coreReady) {
      markTestSkipped('核心未启动（CI 测试阶段无 sourin_core.dll）；'
          '本地有 DLL 时仍真跑');
      return;
    }
    final r = await SourinCore.callAsync('get_override_layer', {'id': targetId});
    expect(r, isA<Map>(), reason: '必须返回 JSON 对象而不是错误');
    expect(r['layer'], isNull, reason: '没有覆盖层时应为 null');
  });

  test('保存后能读回，且文件落在 overrides 目录', () async {
    if (!coreReady) {
      markTestSkipped('核心未启动（CI 测试阶段无 sourin_core.dll）；'
          '本地有 DLL 时仍真跑');
      return;
    }
    final layer = {
      'target_id': targetId,
      'enabled': true,
      'methods': <String>[],
      'note': 'e2e',
      'mappings': [
        {'op': 'set', 'to': 'subtitle', 'value': '已个性化'},
      ],
      // L2 变换也要能通过 FFI 往返（P3）
      'transforms': [
        {'op': 'take_first', 'limit': 5},
        {'op': 'dedup_by', 'field': 'id'},
      ],
    };
    final saved = await SourinCore.callAsync('save_override_layer', {
      'layer': _encode(layer),
    });
    expect(saved, isA<Map>(), reason: '保存应返回对象');
    expect(saved['ok'], isTrue, reason: '保存必须成功');

    final path = saved['path'] as String;
    expect(path, contains('overrides'), reason: '只能写到 overrides 目录');
    expect(File(path).existsSync(), isTrue, reason: '文件必须真的落盘');

    // 读回
    final got = await SourinCore.callAsync('get_override_layer', {'id': targetId});
    expect(got['layer'], isNotNull, reason: '保存后必须能读回');
    expect(got['layer']['target_id'], targetId);
    expect(got['layer']['enabled'], isTrue);
    expect((got['layer']['mappings'] as List).length, 1);
    // L2 变换必须原样往返（不能被序列化丢掉）
    final tr = got['layer']['transforms'] as List;
    expect(tr.length, 2, reason: '两条 L2 变换必须完整往返');
    expect(tr[0]['op'], 'take_first');
    expect(tr[0]['limit'], 5);
    expect(tr[1]['op'], 'dedup_by');
    expect(tr[1]['field'], 'id');
  });

  test('删除后完全回到原行为，且删除是幂等的', () async {
    if (!coreReady) {
      markTestSkipped('核心未启动（CI 测试阶段无 sourin_core.dll）；'
          '本地有 DLL 时仍真跑');
      return;
    }
    final first = await SourinCore.callAsync('delete_override_layer', {'id': targetId});
    expect(first['ok'], isTrue);
    expect(first['existed'], isTrue, reason: '第一次删除应真的删掉');

    // 删完再读必须是 null
    final after = await SourinCore.callAsync('get_override_layer', {'id': targetId});
    expect(after['layer'], isNull, reason: '删除后必须回到未个性化状态');

    // 幂等：再删一次不算错误
    final second = await SourinCore.callAsync('delete_override_layer', {'id': targetId});
    expect(second['ok'], isTrue, reason: '重复删除不得报错');
    expect(second['existed'], isFalse, reason: '第二次应报 existed=false');
  });

  test('非法 layer JSON 被拒绝，不写坏文件', () async {
    if (!coreReady) {
      markTestSkipped('核心未启动（CI 测试阶段无 sourin_core.dll）；'
          '本地有 DLL 时仍真跑');
      return;
    }
    // ⚠️ 本仓 `callAsync` 的约定是**抛 SourinCoreException**，不是返回 {error}。
    //    所以要断言"抛了且消息对"，不能断言返回值里有 error 字段。
    Object? thrown;
    try {
      await SourinCore.callAsync('save_override_layer', {
        'layer': '{ 这不是合法 JSON',
      });
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull, reason: '非法 JSON 必须抛错而不是静默写入');
    expect('$thrown', contains('不合法'), reason: '错误消息要说明是 JSON 不合法');

    // 关键：拒绝后不得留下任何文件
    final after = await SourinCore.callAsync('get_override_layer', {'id': targetId});
    expect(after['layer'], isNull, reason: '拒绝保存后不得留下覆盖层');
  });

  test('缺 id 参数时明确报错', () async {
    if (!coreReady) {
      markTestSkipped('核心未启动（CI 测试阶段无 sourin_core.dll）；'
          '本地有 DLL 时仍真跑');
      return;
    }
    Object? thrown;
    try {
      await SourinCore.callAsync('get_override_layer', {});
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull, reason: '缺参数必须抛错，不能静默返回 null');
    expect('$thrown', contains('id'), reason: '错误消息要点名缺哪个参数');
  });
}

String _encode(Object o) {
  // 项目没引 dart:convert 到测试外的公共层，这里就地编码
  final buf = StringBuffer();
  void walk(Object? v) {
    if (v == null) {
      buf.write('null');
    } else if (v is String) {
      buf.write(_quote(v));
    } else if (v is num || v is bool) {
      buf.write(v.toString());
    } else if (v is Map) {
      buf.write('{');
      var first = true;
      v.forEach((k, val) {
        if (!first) buf.write(',');
        first = false;
        buf.write(_quote('$k'));
        buf.write(':');
        walk(val);
      });
      buf.write('}');
    } else if (v is List) {
      buf.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) buf.write(',');
        walk(v[i]);
      }
      buf.write(']');
    } else {
      buf.write(_quote('$v'));
    }
  }

  walk(o);
  return buf.toString();
}

String _quote(String s) {
  final b = StringBuffer('"');
  for (final c in s.codeUnits) {
    if (c == 0x22) {
      b.write(r'\"');
    } else if (c == 0x5C) {
      b.write(r'\\');
    } else if (c == 0x0A) {
      b.write(r'\n');
    } else if (c == 0x0D) {
      b.write(r'\r');
    } else if (c == 0x09) {
      b.write(r'\t');
    } else if (c < 0x20) {
      b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
    } else {
      b.writeCharCode(c);
    }
  }
  b.write('"');
  return b.toString();
}
