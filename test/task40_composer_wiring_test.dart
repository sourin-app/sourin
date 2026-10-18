// ═══════════════════════════════════════════════════════════════════════
//  task-40 判据 ④：从「编辑」入口能打开可视化编排器
// ═══════════════════════════════════════════════════════════════════════
//
// # 这里守的是**接线**，不是渲染
// Owner 原话「点击编辑还是老样子的配置」—— 意思是点「编辑」到不了编排器。
// 所以判据必须是「编辑声明式源 ⇒ 打开的是 SourceComposerDialog」，
// 而不是「SourceComposerDialog 能渲染」（那个由 task40_composer_visual_test 守）。
//
// # 为什么用源码契约断言而不是点真界面
// ```text
// `_editProvider` 是 SettingsPageState 的私有方法，触发它要真核心 + 真插件
// （走 FFI 的 get_provider_config）。单测里搭不出来，
// 而本仓既有做法就是「源码契约断言」守接线（见 t27_w5 / t135）。
// ⚠️ 因此本文件**只**证明「代码里有这条分支且指向对的东西」，
//    真正的点击验证放在真机截图（见 task40 的截图与交付报告）。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final src = _read('lib/ui/settings_page.dart');

  test('★★★ ④ 编辑入口对 declarative 走可视化编排（不是裸 JSON 弹窗）', () {
    expect(src, contains("if (p.kind == 'declarative')"),
        reason: '★★ 必须有这条分支 —— 没有它，声明式源编辑仍落到文本弹窗');
    expect(src, contains('_editDeclarativeViaComposer'),
        reason: '★★ 分支必须真的调用编排方法（有 if 没调用 = 假接线）');
    expect(src, contains('SourceComposerDialog('),
        reason: '★★ 最终必须打开编排器');
  });

  test('★★ ④ JS 插件路径**未被破坏**（仍走源码编辑器）', () {
    expect(src, contains("if (p.kind == 'js')"));
    expect(src, contains('await _editPlugin(info);'),
        reason: '★★ JS 插件必须仍走源码编辑器 —— 不许为了本条把老路拆掉');
    /*
     * ★ 顺序检查：js 分支必须在 declarative 分支**之前**，
     *   否则声明式分支先 return，js 就再也到不了源码编辑器。
     */
    final jsAt = src.indexOf("if (p.kind == 'js')");
    final declAt = src.indexOf("if (p.kind == 'declarative')");
    expect(jsAt, greaterThanOrEqualTo(0));
    expect(declAt, greaterThanOrEqualTo(0));
    expect(jsAt, lessThan(declAt),
        reason: '★★ js 分支必须先判 —— 顺序反了就等于把 JS 插件也送进编排器');
  });

  test('★★ ④ 编排器**带初值**打开（不是空白）', () {
    /*
     * ★★ 这正是改前那个真缺陷：provider_import_dialog.dart:644 调
     *    SourceComposerDialog 时**没传 initial** ⇒ 编排器空白，
     *    编辑已有源等于从零重填。
     */
    expect(src, contains('initial: initial'),
        reason: '★★ 必须把解析出来的初值传进去');
    expect(src, contains('composerDraftFromJson('),
        reason: '★★ 初值要从磁盘上的 JSON 还原');
  });

  test('★★ ④ 提交后**直接落盘**，不需要用户再点一次保存', () {
    expect(src, contains('SourinApi.importDeclarativeProvider'),
        reason: '★★ Owner 抱怨的「还得再点保存」必须消掉');
  });
}