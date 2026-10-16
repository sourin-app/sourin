// ═══════════════════════════════════════════════════════════════════════
//  T5+T14 视觉自查台：三套「设计语言」主题各出一张图
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不用真实页面（沿用 `_theme_packs_shot_test.dart` 的既有做法）
//
// ```text
// ① 真实设置页/首页要 `await SourinCore.startAsync`（FFI），无核心时
//    永远停在转圈态 ⇒ 截出来一片黑，看不出主题好坏。
// ② 更重要的：把 `sourin_core.dll` 拷到 worktree 根会让**别人并行的
//    约 30 条 widget 测试**因「A Timer is still pending」变红
//    （`zz_settings_shots_test.dart` 的文件头专门警告过这件事）。
//    ⇒ 我不做这种影响他人并行工作的动作。
// ```
//
// ⇒ 改用**同一个自建展示页**，三套主题只换主题、页面一字不改。
//   展示页用的都是**真实生产组件**（AppDialogShell / SettingsBlock /
//   FilledButton / TextField / Switch / Slider / ListTile / Chip …），
//   不是手画方块 —— 所以"按钮圆角 0 还是 22""描边 1px 还是 2.5px"
//   这些**设计语言差异**在图上真的看得见。
//
// # 怎么跑
// ```text
// SOURIN_SHOT_DIR=<输出目录> flutter test test/zz_t14_theme_styles_shot_test.dart
// ```
// 输出：<输出目录>/t14_style_<id>.png
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme/theme_language.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/ui/widgets/settings_kit.dart';

import 'support/ui_shot.dart';

bool _noopBool(bool v) => true;

/// 三套「设计语言」主题的 id（顺序 = 汇报顺序）
const List<String> _styleIds = <String>[
  'builtin.glass',
  'builtin.neoBrutal',
  'builtin.minimal',
];

/// 展示页 —— 三套主题共用，**一字不改**
///
/// ⚠️ 刻意把「形状语言」最敏感的四样放在最显眼处：
///    按钮（圆角 + 内边距）、卡片（圆角 + 描边粗细）、输入框、分隔线。
Widget _showcase(AppPalette p) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 左：主内容区 ──
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶栏形态（真机上这里是液态玻璃标题栏）
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: p.secondary,
                  border: Border(
                    bottom: BorderSide(color: p.border, width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    Text('源影',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: p.foreground)),
                    const SizedBox(width: 24),
                    Text('首页   搜索   设置',
                        style: TextStyle(fontSize: 13, color: p.mutedForeground)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text('设计语言 · 门面',
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      color: p.foreground)),
              const SizedBox(height: 6),
              Text('同一套组件，四套维度不同：配色 / 圆角 / 描边 / 按钮几何',
                  style: TextStyle(fontSize: 13, color: p.mutedForeground)),
              const SizedBox(height: 20),

              // ── 按钮行（圆角 + 内边距差异最明显）──
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(onPressed: () {}, child: const Text('实心按钮')),
                  ElevatedButton(onPressed: () {}, child: const Text('浮起按钮')),
                  OutlinedButton(onPressed: () {}, child: const Text('描边按钮')),
                  TextButton(onPressed: () {}, child: const Text('文字按钮')),
                  const FilledButton(onPressed: null, child: Text('禁用')),
                ],
              ),
              const SizedBox(height: 20),

              // ── 真实设置区块（卡片圆角 + 描边 + 分隔线）──
              SettingsBlock(
                title: '外观',
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.palette_outlined, color: p.primary),
                    title: Text('主题', style: TextStyle(color: p.foreground)),
                    subtitle: Text('当前：设计语言主题',
                        style: TextStyle(color: p.mutedForeground)),
                    trailing: Icon(Icons.chevron_right, color: p.mutedForeground),
                  ),
                  Divider(color: p.border),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.play_circle_outline, color: p.primary),
                    title: Text('播放', style: TextStyle(color: p.foreground)),
                    subtitle: Text('硬件解码 / 倍速',
                        style: TextStyle(color: p.mutedForeground)),
                    trailing: const Switch(value: true, onChanged: _noopBool),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── 输入框 + 控件 ──
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: '内容源地址',
                        hintText: 'http://127.0.0.1:8787',
                      ),
                      style: TextStyle(color: p.foreground),
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 150,
                    child: Slider(value: 0.6, onChanged: (_) {}),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Chip / 标签 ──
              Wrap(
                spacing: 10,
                children: [
                  Chip(
                      label: Text('JS 插件',
                          style:
                              TextStyle(fontSize: 12, color: p.foreground))),
                  Chip(label: Text('已启用',
                      style: TextStyle(fontSize: 12, color: p.foreground))),
                  Chip(label: Text('v1.0.0',
                      style: TextStyle(fontSize: 12, color: p.foreground))),
                ],
              ),
              const SizedBox(height: 20),

              // ── 对话框外壳（全仓统一弹窗）──
              AppDialogShell(
                title: '添加插件',
                subtitle: '填一个插件链接，或直接粘贴 JS 源码 —— 会自动识别',
                onClose: () {},
                fill: false,
                actions: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(onPressed: () {}, child: const Text('取消')),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: () {}, child: const Text('安装')),
                  ],
                ),
                child: Text(
                  '这是一个弹窗的正文区域。\n'
                  '它的圆角、描边粗细、按钮内边距全部来自主题包。',
                  style: TextStyle(
                      fontSize: 13, height: 1.7, color: p.mutedForeground),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 28),
        // ── 右：色板（一眼看出配色差异）──
        SizedBox(
          width: 190,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('色板',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.foreground)),
              const SizedBox(height: 12),
              for (final e in <(String, Color)>[
                ('background', p.background),
                ('card', p.card),
                ('secondary', p.secondary),
                ('primary', p.primary),
                ('border', p.border),
                ('mutedForeground', p.mutedForeground),
                ('error', p.error),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 22,
                        decoration: BoxDecoration(
                          color: e.$2,
                          border: Border.all(color: p.border),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(e.$1,
                            style: TextStyle(
                                fontSize: 11, color: p.mutedForeground)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );

void main() {
  setUpAll(loadRealFonts);

  for (final id in _styleIds) {
    final pack = ThemePackStore.builtins.firstWhere((p) => p.id == id);
    testWidgets('设计语言主题 · ${pack.name}', (tester) async {
      await setShotViewport(tester, const Size(1440, 940));
      /*
       * ★ 这里显式套一层 `ThemeLanguage.apply`，而不是只调
       *   `AppTheme.themeForPack`。
       *
       * # 为什么（这不是"测试里偷偷补一脚"）
       *
       * 这两行**就是接线后 `theme_bridge.buildAppTheme` 的确切内容** ——
       * 补丁已经交给 Lead，等 dlg-source 让出 `theme_bridge.dart` 后由
       * Lead 逐字应用（我不会去动那个文件，它在别人手里）。
       *
       * 若这里只调 `themeForPack`，截出来的图**不含** borderWidth /
       * dividerThickness / buttonPadding 的效果 —— 那正是 Owner 要看的
       * 三套设计语言差异里最重要的三项（2.5px 硬边、直角、厚重按钮）。
       * 也就是说：图会"看起来还是同一套皮肤"，而代码其实是对的。
       * ⇒ 为了让验收图反映**接线后的真实观感**，这里必须套这一层。
       *   `themeForPack` 内部将会是 `ThemeLanguage.apply(buildAppTheme(...))`，
       *   于是这里就成了"apply 两次"—— 那是**逐值幂等**的
       *   （`zz_t14_theme_language_test.dart` 有一条用例专门钉它），
       *   所以接线前后截出来的图是同一张。
       */
      final td = ThemeLanguage.apply(
          AppTheme.themeForPack(pack.brightness, pack), pack);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: td,
        home: Scaffold(
          backgroundColor: pack.palette.background,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
            child: SingleChildScrollView(child: _showcase(pack.palette)),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await saveViewShot(tester, 't14_style_${pack.id.replaceAll('.', '_')}');
    });
  }
}
