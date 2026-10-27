// ═══════════════════════════════════════════════════════════════════════
//  t1060：N8a 更名「源」+ N8b-4 五分类（源列表信息架构）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么
// ```text
// ① N8a：**用户可见的导航/区块/页签/页头标题**里不许出现「JS 插件」
//    （分类名与 kind chip **放行** —— Owner 自己在 N8b 原话里就把
//     「js插件」当分类名用；Lead 裁定的门禁范围就是这三类标题）
// ② N8b-4：五分类判据正确（含最易错的一条：聚合源与 csp 直连源
//    **kind 都是 "tvbox"**，必须靠 id==tvbox_agg 区分）
// ③ N8b-4：分组只返回**非空**类（画"（0 个源）"是噪声）
// ④ N8b-4：**折叠后组头必须还在**（否则「展开」按钮消失 = 单向开关）
// ⑤ N8b-4：hidden 子站不得出现在任何分类里（聚合只有一个入口）
// ```
//
// # 为什么判据放在**纯函数**上（而不是整页 pump）
// ```text
// `SettingsPage.build()` → `SourinApi.version()` → `DynamicLibrary.open(
//   'sourin_core.dll')`；`ffi.dart` 的 `_lib` 是 private static 且**没有注入口**
//   ⇒ flutter_test 里整棵子树会被换成 ErrorWidget（t76 文件头已记）。
// ⇒ 分类/分组逻辑抽成 @visibleForTesting 纯函数后，可以**直接断言行为**，
//   而"接线到底接没接"用源码锚点断言（两层合起来才是完整护栏）。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/settings_page.dart';

ProviderManifest p(String id, String kind, {bool hidden = false, bool live = false}) =>
    ProviderManifest(
      id: id,
      name: id,
      kind: kind,
      hidden: hidden,
      capabilities: Capabilities(live: live),
    );

void main() {
  final src = File('lib/ui/settings_page.dart').readAsStringSync();

  /// 去注释（只用于"不得出现"这类否定断言 —— 注释里解释实现是允许的）
  ///
  /// # ★ 必须同时剥掉**行注释**与**块注释**（实测踩到）
  /// ```text
  /// 第一版只 `startsWith('//')` ⇒ 漏掉块注释里的行：
  ///   `       * 机制描述可保留）不动。它引用的 \`_Block(title: 'JS 插件')\``
  /// 那一行**不以 `//` 开头**（它是 `/* ... */` 的中间行）⇒ 被判成代码
  /// ⇒ 本条假红，并"逼人"去删一段讲历史决策的合规注释。
  /// ⇒ 判据必须按**注释块状态机**剥，不能只看行首。
  /// ```
  String codeOnly(String s) {
    final out = <String>[];
    var inBlock = false;
    for (final line in s.split('\n')) {
      final t = line.trimLeft();
      if (inBlock) {
        if (t.contains('*/')) inBlock = false;
        continue;
      }
      if (t.startsWith('/*')) {
        // 同一行就闭合的块注释（`/* ... */`）不算进入块
        if (!t.contains('*/')) inBlock = true;
        continue;
      }
      if (t.startsWith('//')) continue;
      out.add(line);
    }
    return out.join('\n');
  }

  group('① N8a：用户可见标题里不许出现「JS 插件」', () {
    test('★★★ 导航入口行标题是「源」（不是「JS 插件」）', () {
      /*
       * 靶子：一级页那个 `SettingsEntryRow(title: 'JS 插件', ...)`。
       * 它是**导航**（用户照着找入口）⇒ 按 Lead 裁定必须在判禁范围内。
       *
       * ★ 反面：把 title 改回 'JS 插件' ⇒ 本条红。
       */
      expect(
        RegExp(r"SettingsEntryRow\(\s*icon: AppIcons\.extension_outlined,\s*[\s\S]{0,900}?title: '源',")
            .hasMatch(src),
        isTrue,
        reason: '★★★ 入口行标题必须是「源」（Owner 定名）；'
            '注入「改回 JS 插件」本条立刻红',
      );
      /*
       * ★★ 判据只扫**代码行**（注释除外）——
       *    N8a 口径明确「注释/文档里指实现机制的『JS 插件』可保留」，
       *    而这个文件里确实还有两处**注释**引用历史写法
       *    （`_Block(title: 'JS 插件')` 那段 102 行的原区块设计说明 +
       *      `_PluginTile` 字段注释）。
       *
       * ⚠️ 所以判据必须是"**代码里**不许有 `title: 'JS 插件'`"。
       *    写成"整文件 contains"会把那两处合规注释一起判红 ⇒ 假红，
       *    会逼人删掉讲历史决策的注释（那是信息损失，不是合规修复）。
       */
      expect(
        codeOnly(src).contains("title: 'JS 插件'"),
        isFalse,
        reason: '★★★ **代码**里任何 title 都不该再是「JS 插件」'
            '（导航/区块/页头三处都是用户可见标题；注释里的机制引用可留）',
      );
    });

    test('★★ 页签 / 二级页页头 / 区块标题都用「源」', () {
      expect(src.contains("plugins('源')"), isTrue,
          reason: '★ 二级页页签文案必须是「源」（导航用）');
      expect(src.contains("plugins('JS 插件')"), isFalse,
          reason: '★★ 页签不许回退（注入「改回 JS 插件」本条红）');
    });

    test('★★ 阳性对照：判据真的能抓到「JS 插件」标题（否则上面是假绿）', () {
      /*
       * 本文件前两条都是"不许出现"型断言 —— 天然容易恒真。
       * 这里喂一个**含违规标题的假源码**，断言判据确实能抓到。
       */
      const fake = "SettingsEntryRow(\n  title: 'JS 插件',\n)";
      expect(fake.contains("title: 'JS 插件'"), isTrue,
          reason: '★ 判据抓不到这种串 ⇒ 上面那条"零命中"毫无意义');
    });

    test('★ 分类名与 kind chip 放行（Owner 自己把它当分类名用）', () {
      /*
       * ⚠️ 与 Lead 裁定的门禁范围一致：只判导航/区块/页签标题。
       * `'js' => 'JS 插件'` 是 **kind chip**（分类名），放行。
       * 若把它一起判死，N8b-4 自己要的分类名就没法写了。
       */
      expect(src.contains("'js' => 'JS 插件'"), isTrue,
          reason: '★ kind chip 的分类名照旧（判禁范围不含它）');
    });
  });

  group('② N8b-4：五分类判据', () {
    test('★★★ 聚合源与 csp 直连源 kind 相同 ⇒ 必须靠 id 区分', () {
      /*
       * 这是本项**最容易写错**的一条：
       *   csp 导入子站     kind = "tvbox"（csp/provider.rs:126）
       *   tvbox 聚合源     kind = "tvbox"（tvbox_aggregate.rs:231）
       * 只按 kind 分组 ⇒ 两类糊成一组 —— 正是 Owner 说的"没区分开"。
       *
       * ★ 反面：把 `if (p.id == kTvboxAggregateId)` 那行删掉 ⇒ 本条红。
       */
      final agg = p('tvbox_agg', 'tvbox');
      final direct = p('csp-bili-x', 'tvbox');
      expect(sourceClassOf(agg), SourceClass.tvboxAggregate,
          reason: '★★★ 聚合入口归「TVBox 聚合源」；注入「删掉 id 判据」本条红');
      expect(sourceClassOf(direct), SourceClass.tvboxDirect,
          reason: '★★★ csp 直连源归「TVBox 源」（两者 kind 相同，只能靠 id 分）');
    });

    test('★★ 其余四类判据逐条', () {
      expect(sourceClassOf(p('a', 'js')), SourceClass.js);
      expect(sourceClassOf(p('b', 'declarative')), SourceClass.declarative);
      expect(sourceClassOf(p('c', 'http')), SourceClass.other,
          reason: '★ http 不在 Owner 点名的五类里 ⇒ 进「其他」（如实兜底）');
      expect(sourceClassOf(p('d', '')), SourceClass.other,
          reason: '★ 内置（kind 空）同理进「其他」');
      expect(sourceClassOf(p('e', 'm3u_live')), SourceClass.other,
          reason: '★ 直播 kind 也进「其他」—— 直播那一类由 capabilities.live 表达，'
              '不是第七个分类');
    });

    test('★★★ 分组只返回非空类（画"（0 个源）"是噪声）', () {
      final list = <ProviderManifest>[
        p('js1', 'js'),
        p('tv1', 'tvbox'),
        /*
         * ⚠️ id 必须**逐字**是 `tvbox_agg` —— 分类判据就是靠这个固定 id
         *    （kind 与 csp 直连源相同，不能靠 kind 分）。
         *    我第一版夹具写成 `p('agg','tvbox')` ⇒ 被判成 tvboxDirect，
         *    于是"三类非空"实际是两类 —— **假红**（测试的错，不是实现的错）。
         */
        p(kTvboxAggregateId, 'tvbox'),
      ];
      final g = groupSourcesByClass(list);
      expect(g.length, 3, reason: '★★★ 三类非空 ⇒ 恰好三组（空类不许出现）');
      expect(g.map((e) => e.$1).toList(),
          <SourceClass>[SourceClass.tvboxDirect, SourceClass.js, SourceClass.tvboxAggregate],
          reason: '★ 顺序 = Owner 点名的顺序（TVBox 源 → JS 插件 → 声明式 → 聚合源 → 其他）');
      // 三类之外（declarative / other）**一个都不许出现**
      expect(g.any((e) => e.$1 == SourceClass.declarative), isFalse,
          reason: '★★ 空类必须整组缺席（否则列表上会出现空标题）');
      expect(g.any((e) => e.$1 == SourceClass.other), isFalse);
      // 阴性对照：全空输入
      expect(groupSourcesByClass(const <ProviderManifest>[]), isEmpty);
    });

    test('★★★ hidden 子站不得出现在任何分类里（聚合只有一个入口）', () {
      /*
       * Lead 明确加的一条：被聚合器接管的 csp 子站（hidden:true）
       * **本来就不该单独出现在平铺列表里** —— 否则又是"N 个 hidden 子站平铺"，
       * 正是 Owner 抱怨的"没区分开"。
       *
       * ⚠️ 判据在**过滤之后**：真实数据里 16 个 csp 子站全 hidden
       *     ⇒ 它们一条都不该出现在任何类里。
       * ★ 反面：分组前不调 visibleProviders ⇒ 本条红。
       */
      final list = <ProviderManifest>[
        p('js1', 'js'),
        p('sub1', 'tvbox', hidden: true),
        p('sub2', 'tvbox', hidden: true),
        p(kTvboxAggregateId, 'tvbox'),
      ];
      final visible = visibleProviders(list);
      final g = groupSourcesByClass(visible);
      final ids = [for (final (_, items) in g) ...items.map((e) => e.id)];

      /*
       * ⚠️ 判据按**集合**写，不写死排列顺序 ——
       *    本条的靶子是"hidden 子站有没有混进来"，不是"类之间的先后"。
       *    写死顺序会让夹具一变（本夹具里**没有** tvboxDirect 条目，
       *    所以 enum 里靠前的 `js` 先出现）就假红，
       *    那是测试的错，不是实现的错（我第一版连着踩了两次）。
       * （类之间顺序另有专门一条断言：② 组的把 `g.map($1)` 逐条列出。）
       */
      expect(ids.toSet(), <String>{kTvboxAggregateId, 'js1'},
          reason: '★★★ 只剩「聚合入口 + JS 插件」两条；'
              'hidden 子站一个都不许出现（注入「去掉 hidden 过滤」本条红）');
      expect(ids.where((k) => k.startsWith('sub')).toList(), isEmpty,
          reason: '★★★ hidden 子站（sub1/sub2）必须一条都不在（聚合只有一个入口）');
      expect(ids.contains(kTvboxAggregateId), isTrue,
          reason: '★★ 聚合入口本身必须还在（否则用户找不到聚合源）');
      expect(ids.contains('sub1'), isFalse);
      expect(ids.contains('sub2'), isFalse);
    });
  });

  group('③ N8b-4：折叠后组头必须还在（单向开关是本项的真缺陷）', () {
    test('★★★ 分组输入是**折叠前的全集**，不是 visible', () {
      /*
       * 我第一版拿 `visible` 分组 ⇒ 折叠后 tvbox 类整个消失 ⇒
       * 组头（「展开」按钮）跟着消失 ⇒ **再也点不回来**。
       * 既有 `zz_t1048` 抓不到（它验的是两个纯函数 + 接线字符串）。
       *
       * ★ 反面：把 `groupSourcesByClass(list)` 改回 `groupSourcesByClass(visible)`
       *   ⇒ 本条红。
       */
      final code = codeOnly(src);
      expect(code.contains('groupSourcesByClass(list)'), isTrue,
          reason: '★★★ 分组必须基于折叠**之前**的全集 list；'
              '注入「改成 visible」⇒ 折叠后组头消失、开关单向 ⇒ 本条立刻红');
      expect(code.contains('groupSourcesByClass(visible)'), isFalse,
          reason: '★★ 不许拿折叠后的序列分组（那正是单向开关的成因）');
    });

    test('★★★ 折叠态下 TVBox 类**条目为空但类仍在**（组头可再点开）', () {
      /*
       * 这一条直接验**行为**（不是源码字符串）：
       *   分组输入 = 全集 ⇒ 折叠后「TVBox 源」这一类**仍然被返回**
       *   ⇒ 宿主照样能画组头（带「展开」）⇒ 能点回来。
       */
      final list = <ProviderManifest>[
        p('js1', 'js'),
        p('tv1', 'tvbox'),
        p('tv2', 'tvbox'),
      ];
      // 分组基于全集：折叠与否都返回 tvboxDirect 这一类
      final g = groupSourcesByClass(list);
      expect(g.map((e) => e.$1).toList(),
          <SourceClass>[SourceClass.tvboxDirect, SourceClass.js],
          reason: '★★★ 折叠态下该分类仍须存在（否则组头与「展开」一起消失）');
      // 而**该类的条目**按折叠态取：折叠 ⇒ 空（不画网格，但组头还在）
      final tvboxSection = g.firstWhere((e) => e.$1 == SourceClass.tvboxDirect).$2;
      expect(tvboxGroupOrder(tvboxSection, expanded: false), isEmpty,
          reason: '★ 折叠 ⇒ 本类条目为空（网格不画）');
      expect(tvboxGroupOrder(tvboxSection, expanded: true).length, 2,
          reason: '★ 展开 ⇒ 本类条目回来');
    });
  });

  group('④ 接线：宿主真的用了分组 + 组头', () {
    test('★★ 源码锚点：分组渲染 + 五类组头都在', () {
      final code = codeOnly(src);
      expect(code.contains('groupSourcesByClass(list)'), isTrue,
          reason: '★ 分组必须真接线到列表渲染');
      /*
       * ⚠️ 2026-10-27（R2-#2，tvbox-ui）：锚点从**字面量**改成**容忍换行/缩进的正则**。
       *
       * 改前的字面量是 `'SourceClassHeader(label: cls.label'`。
       * R2-#2 给「TVBox 聚合源」那类补了 `onConfigure` 入口 ⇒ 这个调用变成多行：
       * ```text
       *   SourceClassHeader(
       *     label: cls.label,
       *     count: sectionItems.length,
       *     onConfigure: cls == SourceClass.tvboxAggregate ? … : null,
       *   )
       * ```
       * ⇒ 字面量不再连续匹配，本条**假红**（判据本身没退化）。
       *
       * ★ 判据**一个字没放松**：仍然要求"四类组头真的被调用、且 label 来自 cls.label"，
       *   只容忍参数之间的空白/换行（版式变化，不是行为变化）。
       *   反面：把 SourceClassHeader 删掉、或把 label 写成常量 ⇒ 本条照样红。
       */
      expect(RegExp(r'SourceClassHeader\(\s*label: cls\.label').hasMatch(code), isTrue,
          reason: '★ 非 tvboxDirect 的四类要有组头（否则分类只分不显）');
      expect(RegExp(r'cls == SourceClass\.tvboxDirect').hasMatch(code), isTrue,
          reason: '★ 「TVBox 源」沿用既有可折叠组头（不另造第二个）');
      expect(code.contains('TvboxGroupHeader('), isTrue,
          reason: '★ 既有折叠组头必须保留（Lead 裁定：不许顺手重构）');
    });

    test('★★ 既有两 tab 结构没被推翻', () {
      /*
       * Lead 裁定：保留既有 `_PluginsTab{plugins, live}` 两 tab 结构，
       * 五分类是在**列表内部**再分组（一次大改无法归因）。
       */
      expect(RegExp(r"enum _PluginsTab\s*\{").hasMatch(src), isTrue,
          reason: '★ 两 tab 结构必须保留');
      expect(src.contains("live('直播源')"), isTrue,
          reason: '★ 直播源 tab 不动');
    });
  });
}