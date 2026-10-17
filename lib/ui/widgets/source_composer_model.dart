/// 声明式源的**可视化编排器** —— 用表单拼出 JSON，不用手写（Owner 第 9 条）
///
/// # Owner 原话（逐字）
/// ```text
/// > 这些分类,我不是太希望,我希望这些最好可以给一个可视化编排插件的一个功能,
/// > 你想想则呢么设计
/// ```
///
/// # 设计思路（先说清"为什么是这样"，再谈实现）
///
/// ## 一、为什么不发明一套新的插件格式
/// 本仓**已经有**一个"配置而非代码"的源格式 —— `DeclarativeSource`
/// （见 `provider_import_dialog.dart` 的 `kDeclarativeTemplate`）：
/// ```text
/// { id, name, base, headers, capabilities,
///   endpoints: { categories|list|detail|search: { path, params, map } } }
/// ```
/// 它本来就是**纯数据**、由 rust 侧通用执行器解释（`providers/declarative.rs`）。
/// ⇒ 可视化编排 = 给这份 JSON 做一个**结构化编辑器**，
///   **不新增格式、不新增运行时**。用户编出来的东西立刻能用，
///   而且与手写 JSON 的产物**逐字节同构**（可互相粘贴）。
///
/// ## 二、为什么不是"拖拽流程图"
/// 试过的取舍：流程图（节点 + 连线）看起来"更可视化"，但本场景的
/// **真实自由度只有两处**：
/// ```text
/// ① 每个端点要发什么请求（path + params 模板）
/// ② 响应里哪个字段映射到哪个语义（map）
/// ```
/// 其余（base / headers / capabilities）都是标量。
/// 硬做成流程图只会让用户在 4 个节点之间连线，**信息密度反而更低**、
/// 且无法表达「同一字段取两个备选路径」这种真实需求。
/// ⇒ 用**分步表单 + 实时 JSON 预览**：左编右看，改哪边都行。
///
/// ## 三、三步走（对应"一个源怎么接进来"的真实心智模型）
/// ```text
/// 第 1 步「站点」   base / headers / 名字   —— 你要连谁
/// 第 2 步「端点」   勾选需要哪几个端点     —— 你要它能干什么
/// 第 3 步「字段映射」每个端点挑字段        —— 数据怎么读
/// ```
/// 第 3 步是**真正的难点**（JSONPath 写错是接源失败的头号原因），
/// 所以它配一个「贴一段真实响应 → 自动列出可选字段」的辅助区。
///
/// ⚠️ 本文件只做**编排与预览**，不负责发起网络请求（那是 rust 侧的事）。
///    "拉取样例响应"由调用方注入（[onProbe]），便于测试与替换。
library;

import 'package:material_ui/material_ui.dart';
import '../../design/icons/app_icons.dart';


/// 端点种类 —— 与 `DeclarativeSource.endpoints` 的四个键一一对应
enum ComposerEndpoint {
  categories('categories', '分类', AppIcons.category_outlined),
  list('list', '列表', AppIcons.list_alt_outlined),
  detail('detail', '详情', AppIcons.movie_outlined),
  search('search', '搜索', AppIcons.search_outlined);

  const ComposerEndpoint(this.key, this.label, this.icon);

  /// JSON 里的键名 —— **必须**与 rust 侧一致
  final String key;
  final String label;
  final IconData icon;
}

/// 每个端点可映射的语义字段 —— 左是 JSON 键，右是给人看的说明
const Map<String, String> kComposerFieldLabels = {
  'items': '条目数组（必填）',
  'id': '唯一 id',
  'title': '标题',
  'cover': '封面图',
  'subtitle': '副标题 / 备注',
  'episodes': '剧集串',
  'categories': '分类列表',
};

/// 编排结果 —— 与手写 JSON 的产物**同构**
class ComposerDraft {
  ComposerDraft({
    this.id = '',
    this.name = '',
    this.base = '',
    this.headers = const <String, String>{},
    Map<ComposerEndpoint, ComposerEndpointDraft>? endpoints,
  }) : endpoints = endpoints ??
            <ComposerEndpoint, ComposerEndpointDraft>{
              for (final e in ComposerEndpoint.values) e: ComposerEndpointDraft(),
            };

  String id;
  String name;
  String base;
  Map<String, String> headers;
  final Map<ComposerEndpoint, ComposerEndpointDraft> endpoints;

  /// 已启用的端点（用户勾了「这个站支持它」）
  Iterable<ComposerEndpoint> get enabled =>
      endpoints.entries.where((e) => e.value.enabled).map((e) => e.key);

  /// 编出来的 JSON —— 与 `kDeclarativeTemplate` 的形状**逐字一致**
  ///
  /// ⚠️ 2026-10-17（CodeRabbit CR）：`id`/`name`/`base` 必须 **trim** 后再输出。
  ///   改前 `_canSubmit` 用 `trim()` **判断**非空、但 `toJson()` 输出的是
  ///   **原始值** ⇒ 用户输入 `" a "` 会生成带首尾空白的 JSON，
  ///   而 `base` 带空白会让 URL 拼接失败（`https://x.com /api`）。
  ///   ★ 「判据用 trim、产物不用」是典型的不一致 —— 判据和产物必须同源。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id.trim(),
      'name': name.trim(),
      'base': base.trim(),
      if (headers.isNotEmpty) 'headers': headers,
      'capabilities': <String, Object?>{
        for (final e in enabled) e.key: true,
      },
      'endpoints': <String, Object?>{
        for (final e in enabled) e.key: endpoints[e]!.toJson(),
      },
    };
  }
}

/// 单个端点的编排草稿
class ComposerEndpointDraft {
  ComposerEndpointDraft({
    this.enabled = false,
    this.path = '',
    Map<String, String>? params,
    Map<String, String>? map,
  })  : params = params ?? <String, String>{},
        map = map ?? <String, String>{};

  bool enabled;
  String path;
  final Map<String, String> params;
  final Map<String, String> map;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        if (params.isNotEmpty) 'params': params,
        if (map.isNotEmpty) 'map': map,
      };
}
