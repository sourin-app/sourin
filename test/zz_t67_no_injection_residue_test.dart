// ================================================================
//  注入残留门禁：lib/ 下不许有任何探针/注入文件
// ================================================================
//
// # 为什么要这条
// ```text
// 2026-10-17 我在做故障注入时，两次把临时文件写进 lib/：
//   lib/ui/widgets/zz_inject_probe_tmp.dart
//   lib/ui/widgets/zz_inject_tmp2.dart / zz_inject_tmp3.dart
// 有几次忘了删，导致：
//   · 另一位 teammate 跑门禁时多报了 2 处命中，以为产品有问题
//   · 全量测试会假红
// ```
//
// # 判据
// ```text
// 故障注入的临时文件必须写在 .probe/ 下（那里不入库、不进编译）；
// 绝对不能留在 lib/ —— 那是产品代码目录，多一个文件就是多一个污染源。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 明显是临时/注入文件的名字特征
const _patterns = <String>[
  'zz_inject',
  'zz_probe',
  'zz_tmp',
  '_tmp.dart',
  '_scratch.dart',
  '.bak.dart',
];

void main() {
  test('*** lib/ 下不许有注入/临时文件残留', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue);

    final hits = <String>[];
    for (final e in lib.listSync(recursive: true)) {
      if (e is! File) continue;
      final p = e.path.replaceAll(String.fromCharCode(92), '/');
      final base = p.split('/').last.toLowerCase();
      for (final pat in _patterns) {
        if (base.contains(pat)) {
          hits.add(p);
          break;
        }
      }
    }

    expect(hits, isEmpty,
        reason: 'lib/ 下发现注入/临时文件残留：' +
            String.fromCharCode(10) +
            hits.join(String.fromCharCode(10)) +
            String.fromCharCode(10) +
            '故障注入的文件请写在 .probe/ 下 —— lib/ 是产品目录。');
  });

  test('* 阳性对照：判定函数对明显的注入名必须报警', () {
    bool looksTemp(String name) {
      final b = name.toLowerCase();
      for (final pat in _patterns) {
        if (b.contains(pat)) return true;
      }
      return false;
    }

    expect(looksTemp('zz_inject_tmp.dart'), isTrue);
    expect(looksTemp('zz_probe_test.dart'), isTrue);
    expect(looksTemp('widget_x_tmp.dart'), isTrue);
    // 正常文件名不许误报
    expect(looksTemp('app_ink_well.dart'), isFalse);
    expect(looksTemp('settings_page.dart'), isFalse);
    expect(looksTemp('template.dart'), isFalse);
  });
}
