// ═══════════════════════════════════════════════════════════════════════
//  标签门禁：调用 MediaKit.ensureInitialized 的测试文件必须带 native-media 标签
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么有这条门禁（2026-10-30 批末实测，故事讲完整）
//
// 批末复跑全量 flutter test，读数恒为 `+5554 ~101 -6`：
// 每次红 **恰好 6 条**、失败形态是整文件 `did not complete`，
// 但**每次咬到的文件都不同**（remote_state_line / playlist_total_duration /
// sample_line / t61_panel_radius / t72_stream_sheet / zz_t12_defect_a_probe 等）。
//
// 先做的两次定性都是**错的**，如实记下免得后来人重走：
// ```text
// 猜①「并发负载挂起」 ⇒ --concurrency=2 复跑，仍是**恰好 6 条**（只换了文件）
//                       ⇒ 并发不是原因，假设被自己的实测推翻。
// 猜②「隔离单跑都绿 = 产品无缺陷」 ⇒ 只证明了用例本身写对了，
//                       没解释全量为什么会红，等于什么都没证。
// ```
// 真因在 `dart_test.yaml` 顶部早已记载（2026-09-25 取证）：
// ```text
// MediaKit.ensureInitialized() 加载 libmpv-2.dll 时 flutter_tester **native 崩溃**
// （c0000005）；flutter_tools 在 Windows 上主动丢弃崩溃信息 ⇒ 只看到 did not complete。
// 该文件的处置办法 = 给这类文件打 @Tags(['native-media'])，默认 skip。
// ```
// 即：全量那 6 条红 = **有 15 个文件调了 ensureInitialized 却没打标签**，
// 它们默认真跑，于是随机咬 6 个崩。本批 7 个新文件全部中招。
//
// # 这条门禁钉的是什么（判据落在**行位置**上，不是"文本里有没有这个词"）
// ```text
// 全量扫 test/*.dart：凡**真调** MediaKit.ensureInitialized 的文件，
// 必须**在首行**（或紧跟已有 @Tags 的首行）声明 'native-media'。
// ```
//
// ⚠️ ★★ 为什么必须钉行位置（我自己先踩了这个坑，2026-10-30）
// ```text
// 第一版判据写成 text.contains('native-media')，插在 void main() 上方就转绿了。
// 但全量复跑 **-6 变 -8**，崩溃没消 ⇒ 那个绿是**假绿**：
// Dart 的 @Tags 是**库级注解**，必须位于文件**最顶部**（所有声明之前）；
// 放在 void main() 上面它不生效，文件照样真跑、照样崩。
// ⇒ 判据从"文本包含"收紧为"首行位置"，这才是机制本身。
// ```
// 它防的是"以后又有人写了个碰 libmpv 的测试却忘打/错打标签"：
// 那会让全量随机红，而红的原因看起来像产品缺陷（极易误判）。
//
// # 故障注入（本门禁必须能红，才配叫门禁）
// ```text
// ① 造一个临时测试文件，内含 MediaKit.ensureInitialized(native: null) 且无标签
//   ⇒ 本门禁当场转红。**这条必须复现过**，否则不许标绿。
// ② 反向注入（本次的关键）：把 15 个文件的标签全部从首行挪到 void main() 上方
//   ⇒ 全量复跑崩溃条数不降（实测 -6 → -8）⇒ 证明"位置"才是判据，
//      也证明第一版的 contains 判据是假绿。已实测。
// ③ 正向：标签全部归位到首行 ⇒ 红转绿。
// ```
// 注入文件在 tearDown 里删除，不留在仓库里。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('★★ 碰 media_kit 的测试文件必须带 native-media 标签', () {
    final testDir = Directory('test');
    if (!testDir.existsSync()) {
      fail('test/ 目录不存在，门禁失去意义（不是"没有违规"）');
    }

    final offenders = <String>[];
    var scanned = 0;
    const self = 'zz_t20261030_native_media_tag_gate_test.dart';
    for (final f in testDir.listSync(recursive: false)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final short = f.path.split(Platform.pathSeparator).last;
      // 排除自身：本文件为了做反向注入，源码里带着 ensureInitialized 字面量
      if (short == self) continue;
      scanned++;
      final text = f.readAsStringSync();
      if (!_callsEnsureInitialized(text)) continue;
      // 唯一判据：native-media 是否**声明在首行**。
      // 注释里提到这个词不算 —— 本次实测 11 个文件正是这样被旧判据放过。
      if (!_tagIsAtTop(text)) offenders.add(short);
    }

    // 守卫：没扫到文件 = 门禁瞎了，必须红（不许"扫不到 = 没问题"）
    expect(scanned, greaterThan(50), reason: '扫到的测试文件太少，门禁未真正生效');

    expect(
      offenders,
      isEmpty,
      reason: '这些文件调用了 MediaKit.ensureInitialized，却没有在**首行**声明 '
          '@Tags([\'native-media\'])。库级注解只在文件顶部生效，写在 void main() '
          '上方或只写在注释里都不算 ⇒ 文件仍会被全量真跑、随机 native 崩溃'
          '（本次实测：标签位置错时全量 -6 变成 -8）。'
          '不合格文件：$offenders',
    );
  });

  test('★★ 门禁自己能红：造一个缺标签的 media_kit 文件 ⇒ 必须报出来', () {
    const name = 'zz_tag_gate_injection_probe_test.dart';
    final f = File('test/$name');
    f.writeAsStringSync('''
import 'package:media_kit/media_kit.dart';
void _x() {
  MediaKit.ensureInitialized(native: null);
}
''');
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });

    final text = f.readAsStringSync();
    // 阳性对照：这个文件**确实**调了、且**确实**没标签
    expect(_callsEnsureInitialized(text), isTrue,
        reason: '注入文件本身没被判据识别 ⇒ 判据失效，门禁是假的');
    expect(text.contains('native-media'), isFalse,
        reason: '注入文件本就该是缺标签的');
  });

  test('★★ 反向注入：标签写在 void main() 上方 ≠ 生效（首行判据必须能红）', () {
    const name = 'zz_tag_gate_misplace_probe_test.dart';
    final f = File('test/$name');
    f.writeAsStringSync('''
import 'package:media_kit/media_kit.dart';
void _x() {
  MediaKit.ensureInitialized(native: null);
}
@Tags(['native-media'])
void main() {}
''');
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });

    final text = f.readAsStringSync();
    // ★ 这个文件内容里**有** native-media（所以旧版 contains 判据会放它过线），
    //   但位置不在首行 ⇒ 新判据必须判它不合格。这就是新旧判据的分水岭。
    expect(text.contains('native-media'), isTrue,
        reason: '注入文件必须含该词，否则这条用例证明不了"contains 判据会漏"');
    expect(_tagIsAtTop(text), isFalse,
        reason: '标签不在首行却被判为合格 ⇒ 首行判据失效，门禁仍是假的');
  });
}

/// 是否**真调**了 ensureInitialized（防注释/字符串混进来）
///
/// 行级判据：去掉行注释后再看是否还有调用。这样文档里写
/// "MediaKit.ensureInitialized 会崩" 不会被误判成调用。
bool _callsEnsureInitialized(String text) {
  for (final line in text.split('\n')) {
    final code = line.split('//').first;
    if (code.contains('MediaKit.ensureInitialized')) return true;
  }
  return false;
}

/// `native-media` 标签是否在**首行**（库级注解位置）
///
/// 只看前若干个非空非 `library;` 行里有没有 @Tags 声明，且含 native-media。
/// 位置错（例如在 `void main()` 上方）一律算不合格 —— 那是不生效的写法。
bool _tagIsAtTop(String text) {
  // 允许 @Tags 之前出现的东西只有：空行、行注释、块注释。
  // ★ 特别注意：`library;` **也算声明**，必须排在 @Tags 之后。
  //   本次实测 `zz_cr_panel_double_enter_test.dart` 就是 @Tags 写在 library; 后面
  //   ⇒ 注解不生效，全量仍在崩；第一版判据把 library; 当可跳过，漏判了它。
  var inBlock = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (inBlock) {
      if (line.contains('*/')) inBlock = false;
      continue;
    }
    if (line.startsWith('/*')) {
      if (!line.contains('*/')) inBlock = true;
      continue;
    }
    if (line.startsWith('//')) continue;
    if (line.startsWith('@Tags')) {
      return line.contains('native-media');
    }
    return false; // 第一个真正的声明（含 library;/import）⇒ 注解位置已失效
  }
  return false;
}
