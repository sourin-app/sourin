import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';

/// `TvboxImportResult` 的解析门禁
///
/// # 为什么要单独测这一层
/// Rust 侧返回体里有 `liveImported`（**实际导入成功**的直播源），
/// 而 `lives` 是"配置里识别到的"。两者**不是一回事**：
///
/// ```text
/// lives        配置里有几个（可能因为没地址被跳过）
/// liveImported 真正注册成 m3u_live 源、重启后还在的个数
/// ```
///
/// UI 必须用后者说"已导入 N 个"，用前者会让人以为识别到就等于能用。
/// 这条链路（Rust 字段 → Dart 字段 → UI 文案）中间任何一环断了，
/// 用户看到的数字就是错的，而且**不会有任何报错**。
void main() {
  Map<String, dynamic> base() => {
        'totalSites': 3,
        'imported': [
          {'id': 'a', 'name': '源A', 'api': 'http://x/', 'categories': 2, 'total': 10},
        ],
        'skipped': [
          {'name': '源B', 'type': 3, 'stage': 'type', 'reason': '需要 Java'},
        ],
        'lives': [
          {'name': '直播1', 'url': 'http://x/1.m3u'},
          {'name': '直播2', 'url': ''},
        ],
        'liveImported': [
          {'id': 'm3ulive-1', 'name': '直播1', 'url': 'http://x/1.m3u'},
        ],
      };

  test('liveImportedCount 取实际导入数，不是 lives 的长度', () {
    final r = TvboxImportResult.fromJson(base());
    expect(r.lives.length, 2, reason: '配置里识别到 2 个直播源');
    expect(r.liveImportedCount, 1,
        reason: '★★ 实际只导入了 1 个（另一个没地址被跳过）—— '
            'UI 必须用这个数，用 lives.length 会说成 2');
  });

  test('缺 liveImported 字段时退化为 0（老核心兼容）', () {
    final j = base()..remove('liveImported');
    final r = TvboxImportResult.fromJson(j);
    expect(r.liveImportedCount, 0,
        reason: '老版本核心不返回该字段时不能崩，退化为 0');
    expect(r.lives.length, 2, reason: 'lives 仍应正常解析');
  });

  test('liveImported 不是数组时也不崩', () {
    final j = base()..['liveImported'] = 'oops';
    final r = TvboxImportResult.fromJson(j);
    expect(r.liveImportedCount, 0, reason: '类型异常时退化为 0，不进异常路径');
  });

  test('imported / skipped 仍按原样解析（回归）', () {
    final r = TvboxImportResult.fromJson(base());
    expect(r.totalSites, 3);
    expect(r.imported.length, 1);
    expect(r.imported.first.name, '源A');
    expect(r.skipped.length, 1);
    expect(r.skipped.first.reason, contains('Java'));
  });
}
