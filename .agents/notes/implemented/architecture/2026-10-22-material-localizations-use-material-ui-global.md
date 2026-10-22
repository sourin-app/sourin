# Agent Note: Material 本地化改用 material_ui 自带的 GlobalMaterialLocalizations（真中文）

Status: implemented

> 同域：[2026-10-18-widgetsapp-migration-and-locale-crash.md](./2026-10-18-widgetsapp-migration-and-locale-crash.md)
> 那篇的 §② 决定「用 `_AnyLocaleMaterialDelegate` 兜底、恒解析成英文」被本篇替换。
> 那篇的 §①（`pageRouteBuilder`）、§③（保留 `material_ui` 依赖）、
> 「4131 个用例全绿而真机首屏崩」的教训**仍然成立**，未被动过。
> 那篇的 §② 正文留在原地不动（历史记录），以本篇为准。

## Problem

2026-10-18 移除 `MaterialApp` 后，`MaterialLocalizations.of(context)` 在真机首屏弹窗处
抛 `Null check operator used on a null value`。当时的修法是自建兜底代理
（`lib/shell.dart` 里的 `_AnyLocaleMaterialDelegate`）：

```dart
class _AnyLocaleMaterialDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  @override
  bool isSupported(Locale locale) => true;                    // 任何语言都收
  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      DefaultMaterialLocalizations.load(const Locale('en', 'US'));  // 一律英文
  @override
  bool shouldReload(_) => false;
}
```

它修掉了崩溃，代价是**中文用户听到的读屏文案是英文**。真正被读到的不是可见文字，
而是语义标签：`showDialog` → `DialogRoute` → `modalBarrierDismissLabel`。
中文环境里读屏念 "Dismiss"，这是缺陷，不是「看不见所以无所谓」。

PR #32 的 CodeRabbit 线程 2 指出这一点；本轮修它。

## Decision

`lib/shell.dart` 里删掉 `_AnyLocaleMaterialDelegate`（连同它 39 行旧注释），
改为一个**顶层公开常量**：

```dart
// lib/shell.dart 文件末尾
const List<LocalizationsDelegate<dynamic>> kAppLocalizationsDelegates =
    <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,      // ← material_ui 1.6.0 自带
  GlobalWidgetsLocalizations.delegate,       // ← flutter_localizations
  GlobalCupertinoLocalizations.delegate,     // ← flutter_localizations（flutter 侧类型）
];
```

`WidgetsApp` 的接线改成引用它（`lib/shell.dart:2188`）：

```dart
localizationsDelegates: kAppLocalizationsDelegates,
supportedLocales: [Locale("zh", "CN"), Locale("en", "US")],
```

### 为什么不整包塞 `GlobalMaterialLocalizations.delegates`

`material_ui` 也提供了一个现成三件套
（`global_material_localizations.dart:674`）：

```dart
static const List<LocalizationsDelegate<dynamic>> delegates = [
  GlobalCupertinoLocalizations.delegate,   // ← 来自 cupertino_ui，不是 flutter 侧
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
];
```

其中 Cupertino 代理来自 **`cupertino_ui` 包**（同文件 `:5`
`import 'package:cupertino_ui/cupertino_ui.dart' show GlobalCupertinoLocalizations;`），
它的 `CupertinoLocalizations` 与 **flutter 侧** `CupertinoLocalizations`
不是同一个类型。本仓第三方组件（`liquid_glass_widgets` 等）读的是 flutter 侧类型
⇒ 整包换会把本仓需要的那份顶掉。所以：Material 用 `material_ui` 的，
Widgets / Cupertino 用 `flutter_localizations` 的，手工拼三项。

这条不是靠注释守着，而是门禁里一条**可执行断言**：
`test/zz_t66_material_localizations_test.dart` 断言
`GlobalMaterialLocalizations.delegates` 里 type 为 flutter 侧 `CupertinoLocalizations`
的代理**必须为 0 个**（`isEmpty`）—— 哪天它不空了，那条断言会红，提示回头重读本笔记。

## 证据：旧决策的理由是错的，错在哪

旧笔记 §② 的最强理由是**类型同源**：

> ·`Global*` 来自 `flutter_localizations`，其类型是 flutter 侧的 `MaterialLocalizations`；
> 本仓已无 `package:flutter/material.dart`，混用会有类型冲突风险
> ·`Default*` 来自 `material_ui` 本身，与 `DialogRoute` 同源 ⇒ 类型必然一致
> · 代价：只有英文文案。但本仓弹窗文案全部是自己写的 …  Material 的默认文案基本用不到

**前半句对，后半句是漏看。** 对的部分：`flutter_localizations` 的
`GlobalMaterialLocalizations` 实现的确实是 flutter/material 侧的 `MaterialLocalizations`，
在本仓（已删掉 flutter/material）里用它**真的**会类型打架。
漏的部分：`material_ui` **自己也有一份** `GlobalMaterialLocalizations`，
实现的正是 material_ui 自己的 `MaterialLocalizations`。

证据（包内源码，全部读过）：

```text
material_ui-1.6.0/lib/src/global_material_localizations.dart
  :15   import 'material_localizations.dart';          ← 用 material_ui 自己的接口
  :72   abstract class GlobalMaterialLocalizations implements MaterialLocalizations {
  :650  static const LocalizationsDelegate<MaterialLocalizations> delegate =
            _MaterialLocalizationsDelegate();
  :701  bool isSupported(Locale locale) =>
            kMaterialSupportedLanguages.contains(locale.languageCode);

l10n/generated_material_localizations.dart
  :45298  String get modalBarrierDismissLabel => '关闭';   ← MaterialLocalizationZh
  :44977  class MaterialLocalizationZh extends GlobalMaterialLocalizations
  :46701  getMaterialTranslation() 按 languageCode switch；zh 分支里
          scriptCode(Hans/Hant) → countryCode(HK/TW → Hant 变体) → 其余落 MaterialLocalizationZh
          ⇒ Locale('zh','CN') 命中 '关闭'
  :46520/46601  kMaterialSupportedLanguages 含 'zh'

material_ui-1.6.0/lib/src/material_localizations.dart
  :1239  String get modalBarrierDismissLabel => 'Dismiss';  ← 英文默认（Default* 拿的是这个）
```

版本与来源：本仓 `pubspec.lock:368-376` 锁的是 **material_ui 1.6.0**（direct main）。
这份本地化代码不是 1.6.0 才有的 —— `material_ui` 的 `CHANGELOG.md` 在 **0.0.2**
就写了「Copies over Material localizations from flutter/flutter's
flutter_localizations package」。
⇒ **要害不是版本新，而是 2026-10-18 当时以为「`GlobalMaterialLocalizations` 只有
`flutter_localizations` 那一份」**，于是把一个本来存在的正解（material_ui 自己的那份）
当成了不可用项，退回英文兜底。这是一次**假设没过期、认知有缺口**的选型，
不是「当时对、后来上游变了」。

类型同源这一条现在**仍然成立，而且正是本方案的全部依据**：
`GlobalMaterialLocalizations` 实现的是 material_ui 的 `MaterialLocalizations`，
`DialogRoute`/`showDialog` 要的也是它 ⇒ 同源，不存在混排风险。

## Alternatives considered

- **自己实现一套中文 `MaterialLocalizations`**（旧笔记 §② 的备选，当时被否）——
  最强的理由：只实现用得到的 getter，不依赖上游文案。
  否决理由：`MaterialLocalizations` 是几十个 getter 的接口，且要维护日期/复数格式；
  上游已经有一份同类型、经过 Flutter 团队校对的中文实现，自己写等于重新造并持续对齐。
  旧笔记否它的理由（「投入产出极不平衡」）依然成立，而现在有了零成本的现成方案。

- **整包用 `GlobalMaterialLocalizations.delegates`** ——
  最强的理由：上游维护的三件套，顺序与组合都替你定好了，一行接完，最少自造。
  否决理由：其中 Cupertino 代理来自 `cupertino_ui`，类型与 flutter 侧不同，
  会顶掉本仓第三方组件需要的 flutter 侧 Cupertino 本地化（见上「为什么不整包塞」）。
  ★ 这条备选**没有被永久否掉**：若 `material_ui` 将来改用 flutter 侧 Cupertino，
  门禁里那条 `isEmpty` 断言会红，那时应回来重新评估。

- **保留 `_AnyLocaleMaterialDelegate`，只把 `load` 换中文，`isSupported` 仍恒 true** ——
  最强的理由：改动最小，不动 delegates 组合，只换文案来源。
  否决理由：`isSupported` 恒 true 是**语义谎报**（声明支持所有语言，实际只有中/英两种），
  而且把「哪些语言真的支持」这个事实藏进了自建类里，门禁只能靠 grep 类名验证。
  上游 `GlobalMaterialLocalizations` 的 `isSupported` 用的是真实语言表
  （`kMaterialSupportedLanguages`），并且 `load` 里有
  `assert(locale.toString() == localeName…)` 的自我保护 —— 用它等于把这份正确性交给上游。

- **门禁继续用 grep（断言源码里出现 `GlobalMaterialLocalizations`）** ——
  最强的理由：零依赖、不会因为 shell.dart 编译不过而红。
  否决理由：这正是 2026-10-18～10-22 假绿的形状。grep 抓不住「挂上去了但没生效」
  （例如把 Material 项换成只认 en 的 `DefaultMaterialLocalizations.delegate`，
  类名全都在，中文依然没有）。**树上的行为**才是要验的东西。

## Consequences

- **收益**
  · zh_CN 下 `MaterialLocalizations.of(context)` 非 null **且** `modalBarrierDismissLabel`
    是中文 `'关闭'`（读屏不再念英文 "Dismiss"）
  · 删掉自建兜底类 + 它的 39 行注释（`lib/shell.dart` 8688 → 8660 行），
    少一个「恒 true 的 isSupported」语义谎报
  · 门禁从 grep 升级为**行为级**：真挂 `Localizations(locale: zh_CN)` 读回文案，
    并有 en_US 阴性对照（证明中文不是硬编码巧合）+ 滤掉 Material 项的负向读数
    （必须抛，即 2026-10-18 崩溃的形状）
  · `modalBarrierDismissLabel == '关闭'` 是**版本锚**：上游改文案会有意识地红一次

- **代价 / 新的耦合**
  · `kAppLocalizationsDelegates` 成了 `lib/shell.dart` 的公开 API（门禁要 import 它）。
    ⇒ 门禁 `import 'package:sourin_spike/shell.dart'` 会拉进整个 App 外壳：
    `shell.dart` 或它 import 的任何文件编译不过，这条门禁就**编译失败**
    （已实测：`lib/ui/settings_page.dart:6621` 少一个 `ValueListenable` 的 import，
    整条门禁 `Failed to load … Compilation failed`）。
    这是「行为级门禁」的固有代价，换来的是「挂上但没生效」抓得住。
  · zh 文案进了 App：Material 的默认文案从英文变中文。本仓可见文案都是自己写的
    （`AppDialogShell` / `AppGlassDialog`），实际差别只在语义标签与 tooltip。
  · `flutter_localizations` 仍是**未在 pubspec 声明**的依赖
    （`dart analyze lib/shell.dart` 报 `:66 depend_on_referenced_packages`，info 级）。
    本轮没有扩大这个问题（改动前就在用它的 Widgets/Cupertino 代理），但也没修。

- **回头条件**（命中任一条，先读本笔记再动手）
  1. `material_ui` 升级后 `GlobalMaterialLocalizations` 不再
     `implements` material_ui 自己的 `MaterialLocalizations`
     （类型同源这一条是全部依据）；
  2. `GlobalMaterialLocalizations.delegates` 的 Cupertino 代理变成 **flutter 侧**类型
     ⇒ 「不能整包」的结论失效，门禁里那条 `isEmpty` 断言会红；
  3. zh 的 `modalBarrierDismissLabel` 不再是 `'关闭'` ⇒ 门禁的版本锚会红，
     去读新版 `generated_material_localizations.dart` 再**有意识**更新，
     不要为了让门禁变绿而改断言；
  4. 需要 Widgets/Cupertino 以外的语言能力（例如设备语言是 `zh_Hant`）时，
     确认 `getMaterialTranslation` 的 scriptCode/countryCode 分派是否满足需求。

## Testing

`test/zz_t66_material_localizations_test.dart`（行为级，7 条）：

```text
① zh_CN 真挂 kAppLocalizationsDelegates ⇒ of() 不抛 + label 是中文 + == '关闭'
② en_US 阴性对照 ⇒ 'Dismiss'（证明 locale 真的被尊重）
③ 滤掉 type==MaterialLocalizations 的代理再挂 ⇒ of() 必须抛（崩溃形状的负向读数）
④ type 锚：Material 代理恰好 1 个且是 material_ui 的 MaterialLocalizations
⑤ 回头探针：GlobalMaterialLocalizations.delegates 里 flutter 侧 Cupertino 代理必须 0 个
⑥ 接线：lib/shell.dart 的 `localizationsDelegates:` 真的是 kAppLocalizationsDelegates
   （常量存在但 App 没用 = 白改）
⑦ 判据自检：提取器不吃整文件（否则 ⑥ 假绿）
```

红注入读数（临时改 `lib/shell.dart`，改完还原并核对 sha256）：

```text
注入 A：kAppLocalizationsDelegates 去掉 Material 项
        ⇒ ① 红在「of() 抛异常」（当年的崩溃形状），③ 仍绿
注入 B：Material 项换回 DefaultMaterialLocalizations.delegate
        ⇒ ① 红在中文字符断言（label == 'Dismiss'）
注入 C：WidgetsApp 的 localizationsDelegates 改回字面量列表
        ⇒ ⑥ 红
```
