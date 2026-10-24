//! JS 插件运行时 —— 把「外置 JS 文件」变成可用的 `MediaProvider`
//!
//! # 为什么做这个
//!
//! 原先 srcl / srca 是**编译进程序**的 Rust 代码，用户看不到也改不了。
//! 现在把它们搬到外置 JS 文件，好处：
//!   · 用户能打开文件看「这个源是怎么写的」
//!   · 改一行不用重新编译
//!   · 别人能发布自己的插件（GitHub 导入）
//!
//! # 契约
//!
//! 详见 `research/插件API契约设计.md`。要点：
//!   · 脚本头部注释声明元信息（`@id` / `@name` / `@version`）
//!   · 脚本给 `globalThis.plugin` 赋一个对象，方法名对应 `MediaProvider` 的方法
//!   · 宿主注入 `host.http` / `host.store` / `host.crypto` / `host.log`
//!
//! # 实测得出的三条硬规则
//!
//! 1. **等 JS Promise 必须用 `async_with!` 宏** ——
//!    `ctx.with()` 不能返回 future（rquickjs 源码注释写明），
//!    而 `ctx.async_with()` 要手动 `Pin<Box<...>>`。宏是最好用的封装。
//!
//! 2. **熔断按「墙钟时间」而不是 tick 次数** ——
//!    第一版写「tick > 300 万次就中断」，实测**跑了 168 秒**才触发。
//!    tick 回调不是每条 VM 指令都调。改看时间后精确按预算终止。
//!
//! 3. **每次调用新建 Runtime** —— 实测建一个只要 **0.16 毫秒**，
//!    相对网络请求可忽略，换来最好的隔离性（插件状态不跨调用泄漏）。

use crate::model::*;
use crate::provider::*;
use async_trait::async_trait;
use rquickjs::function::Async;
use rquickjs::{async_with, AsyncContext, AsyncRuntime, Function, Object, Promise};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

/// 插件执行预算（毫秒）—— 防止死循环卡死应用
///
/// 实测：按 tick 计数的方式要 168 秒才触发，**必须按时间**。
/// 取 10 秒：正常插件调用（含网络）远小于此，死循环也能及时掐掉。
const SCRIPT_BUDGET_MS: u64 = 10_000;

/// 插件 HTTP 默认超时
const HTTP_TIMEOUT_SECS: u64 = 15;

// ─────────────────────────── 元信息 ───────────────────────────

/// 从脚本头部注释解析出的元信息
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct PluginMeta {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub homepage: String,
    /// ★ 源类型（头部注释 `@type`）—— 插件作者声明的**源形态**
    ///
    /// 取值契约（插件仓按此写）：
    /// ```text
    /// video-site    单站视频源（站点自己的接口）
    /// aggregator    聚合源（一个插件里挂多份上游 / TVBox 订阅）
    /// iptv          直播源（IPTV / m3u / txt）
    /// emby          Emby 服务器
    /// other         其它
    /// ```
    ///
    /// ⚠️ **Rust 字段名是 `kind` 而不是 `type`**（`type` 是关键字），
    ///    但**序列化名必须是 `type`** —— Dart 侧 `PluginEntry.fromJson`
    ///    读的就是 `type`。`#[serde(rename)]` 让两边对得上。
    ///
    /// ⚠️ 空串 = 源码里**没写** `@type`（老插件全这样，实测本机 32 个 `.js`
    ///    无一命中）—— 界面据此**不显示**类型，而不是猜一个。
    #[serde(default, rename = "type")]
    pub kind: String,
    /// ★ 上次源更新时间（头部注释 `@updated`，ISO8601 带时区）
    ///
    /// 语义：插件作者**最后一次真实验证上游源**的时间，
    /// 形如 `2026-10-23T09:10:00+08:00`。
    ///
    /// ⚠️ 只是"作者说的时间"，**不是宿主保证的真实性**。
    ///    运行时真值优先：`plugins/.data/<id>.json` 的 `sourceStatus`
    ///    里有 `updatedAt` 时，列表用的是那个（见 [read_source_status]）。
    ///
    /// ⚠️ 空串 = 没写（老插件），界面不显示。
    #[serde(default)]
    pub updated: String,
}

/// 解析脚本头部的 `@key value` 元信息
///
/// ⚠️ **必须全局扫描而不是按行首前缀匹配**。
/// 实测：真实写法常把多个 tag 放同一行 ——
/// `/** @name 某电视台站 @version 1.0.0 @author dsh @id srcl */`
/// 按行首匹配**一个都匹配不到**。
///
/// 值取到「下一个 `@` / 换行 / 注释结束符」为止。
///
/// # ★ 两套定位规则（2026-10-23 起，为 `@type` / `@updated` 而加）
///
/// 老字段（id/name/version/author/description/homepage）继续用**裸查找**
/// `find("@key")` —— 它们在真实插件里已经跑了几十轮，改成严格规则
/// 属于无谓的回归风险（本仓规矩：能不动就不动）。
///
/// 新字段（`@type` / `@updated`）用 [find_tag] 的**边界版**，因为：
/// ```text
/// "JSDoc 里 @typedef / @type {Object} 非常常见"
/// 裸 find("@type") 会命中 @typedef 并返回 "def {Object}" 这种垃圾
///   ⇒ 卡片上会显示「def {Object}」，比不显示更糟
/// ```
/// 边界版要求 `@type` 后面紧跟空白 / `:` / 注释结束，见 [find_tag]。
pub fn parse_meta(src: &str) -> PluginMeta {
    // 只看开头 2KB（元信息约定在文件头部）
    let head: String = src.chars().take(2048).collect();

    // 老字段：裸查找（行为与加新字段前**逐字相同**）
    let get = |key: &str| -> String { tag_value(&head, key, false) };

    PluginMeta {
        id: get("id"),
        name: get("name"),
        version: get("version"),
        author: get("author"),
        description: get("description"),
        homepage: get("homepage"),
        // ★ 新字段：边界查找 + 多候选 + 值净化（见 pick_source_type / pick_updated）
        kind: pick_source_type(&head),
        updated: pick_updated(&head),
    }
}

/// 在头部注释里定位 `@key`，返回它的**字节偏移**
///
/// `boundary == false` —— 裸查找（老字段用，保持原行为）。
///
/// `boundary == true` —— `@key` 后面必须紧跟「值的开始」，
/// 否则继续往后找下一个 `@key`。合法后继字符：
/// ```text
/// 空白（空格 / Tab / CR / LF）   `@type video-site` / `@updated 2026-...`
/// ':'                            `@type: video-site`（不强制，但认）
/// '/'                            `@type */`（空值 + 注释结束）
/// 字符串末尾                     `@type`（空值）
/// ```
/// ⚠️ 关键的一条：**`@typedef` / `@updatedAt` 这类"同前缀的长 tag"必须被拒**
///    （后继是字母 ⇒ 不是我们要的 tag）⇒ 继续找下一个。
///    `@upstream` 之类**不同前缀**天然不会命中 `@type`，测试里一并钉住。
fn find_tag(head: &str, key: &str, boundary: bool) -> Option<usize> {
    find_tag_from(head, key, boundary, 0)
}

/// [find_tag] 的可续扫版本（`from` = 上次命中之后的位置，给收集全部候选用）
fn find_tag_from(head: &str, key: &str, boundary: bool, from: usize) -> Option<usize> {
    let tag = format!("@{key}");
    if from >= head.len() {
        return None;
    }
    if !boundary {
        return head[from..].find(&tag).map(|rel| from + rel);
    }
    let mut from = from;
    while let Some(rel) = head[from..].find(&tag) {
        let pos = from + rel;
        let ok = match head[pos + tag.len()..].chars().next() {
            None => true,
            Some(c) => c.is_whitespace() || c == ':' || c == '/',
        };
        if ok {
            return Some(pos);
        }
        // 命中了一个「同前缀但更长」的 tag（@typedef 等）—— 跳过它继续找
        from = pos + tag.len();
    }
    None
}

/// 收集 `@key` 的**全部**候选值（按出现顺序，边界规则同 [find_tag]）
///
/// # 为什么新字段要"多候选"而不是"取第一个"
///
/// JSDoc 里 `@type {Object}` 是**合法且常见**的写法，它会通过边界检查
/// （`@type` 后面是空格），但它**不是**我们要的源类型。若只取第一个命中，
/// 一个同时写了 `@type {Object}` 和 `@type video-site` 的文件就会解析失败。
///
/// ⇒ 逐候选过净化（[clean_source_type] / [clean_updated]），
///   **取第一个净化后非空的** —— 垃圾候选天然被跳过，真候选照样命中。
fn tag_values(head: &str, key: &str) -> Vec<String> {
    let tag = format!("@{key}");
    let mut out = Vec::new();
    let mut from = 0usize;
    while let Some(pos) = find_tag_from(head, key, true, from) {
        out.push(value_after(head, pos, &tag, true));
        from = pos + tag.len();
    }
    out
}

/// 取 `@key` 的值（到下一个 `@` / 换行 / `*/` 为止，两端 trim）
///
/// ⚠️ 终止符里**没有** `:` / `+` / `-` —— 所以
///    `@updated 2026-10-23T09:10:00+08:00` 的时区部分**完整保留**。
///    （只按 `@` 切是安全的：ISO8601 里不含 `@`；而下一个 tag 一定以 `@` 开头。）
fn tag_value(head: &str, key: &str, boundary: bool) -> String {
    let Some(pos) = find_tag(head, key, boundary) else {
        return String::new();
    };
    value_after(head, pos, &format!("@{key}"), boundary)
}

/// 从 `pos`（`@key` 的起始位置）开始取值的公共实现
fn value_after(head: &str, pos: usize, tag: &str, boundary: bool) -> String {
    let rest = &head[pos + tag.len()..];
    let end = [rest.find('@'), rest.find('\n'), rest.find("*/")]
        .into_iter()
        .flatten()
        .min()
        .unwrap_or(rest.len());
    let raw = rest[..end].trim();
    // `@type: video-site` 这种带冒号的写法（boundary 模式下才可能走到）
    let raw = if boundary {
        raw.trim_start_matches(':').trim()
    } else {
        raw
    };
    raw.to_string()
}

/// ★ `@type` 的值：全部候选中取**第一个净化后非空的**
fn pick_source_type(head: &str) -> String {
    tag_values(head, "type")
        .iter()
        .map(|v| clean_source_type(v))
        .find(|v| !v.is_empty())
        .unwrap_or_default()
}

/// ★ `@updated` 的值：全部候选中取**第一个看着像日期**的
fn pick_updated(head: &str) -> String {
    tag_values(head, "updated")
        .iter()
        .map(|v| clean_updated(v))
        .find(|v| !v.is_empty())
        .unwrap_or_default()
}

/// 净化 `@type` 的值：只接受「一个 token」（字母/数字/`-`/`_`）
///
/// # 为什么必须净化（不是洁癖）
///
/// 就算过了 [find_tag] 的边界检查，仍有两种会漏进来的垃圾：
/// ```text
/// ① JSDoc 的 `@type {Object}`  ← 后继是空格，边界检查**放行**
///    ⇒ 值是 "{Object}" ⇒ 卡片上显示「{Object}」⇒ 用户看不懂
/// ② 作者手滑 `@type video site` ⇒ 值是 "video site"
/// ```
/// 契约里的取值都是**单个 slug**（`video-site` / `aggregator` / `iptv` /
/// `emby` / `other`）。所以只放行 slug 字符集，其余一律当"没写"。
/// 超长（> 32）同样丢弃 —— 那是解析错位，不是真的类型名。
fn clean_source_type(raw: &str) -> String {
    let t = raw.trim();
    if t.is_empty() || t.len() > 32 {
        return String::new();
    }
    if !t
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return String::new();
    }
    t.to_string()
}

/// 净化 `@updated` 的值：必须**看起来像日期**，否则当"没写"
///
/// 只做一条极轻的检查：`YYYY-...`（前 4 位数字 + `-`）。
/// ```text
/// "2026-10-23T09:10:00+08:00"  ✓ 原样返回（一个字节都不改）
/// "2026-10-23"                 ✓ 只有日期也认
/// "{Object}" / "待验证"         ✗ 丢弃（界面不显示垃圾）
/// ```
/// ⚠️ 不在 Rust 侧重排格式 —— 格式化是界面的事（Dart 侧按本地时区显示）。
///    这里只保证"塞给界面的东西至少是个日期"。
fn clean_updated(raw: &str) -> String {
    let t = raw.trim();
    let b = t.as_bytes();
    if b.len() >= 5 && b[..4].iter().all(|c| c.is_ascii_digit()) && b[4] == b'-' {
        t.to_string()
    } else {
        String::new()
    }
}

/// 运行时源状态（从 `plugins/.data/<id>.json` 的 `sourceStatus` 键里读出来）
///
/// # 数据形态（★ 插件仓正在按此写，宿主只读不写）
///
/// `host.store.set('sourceStatus', JSON.stringify({...}))` ——
/// ⚠️ store 的 value 只能是**字符串**（见 `store.set` 的绑定签名
/// `move |key: String, value: String|`），所以这里要**二次 JSON.parse**。
///
/// ```json
/// {"sources":[
///   {"id":"migu","type":"video-site","updatedAt":"2026-10-23T09:10:00+08:00","state":"ok"},
///   {"id":"demo-iptv","type":"iptv",      "updatedAt":"2026-10-20T11:00:00+08:00","state":"ok"}
/// ]}
/// ```
/// `type` / `updatedAt` / `state` 都是**可选**的（老插件只有 id/url 也可能）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PluginSourceStatus {
    /// 上游源类型：取**第一个**非空的 `type`（各源的 type 通常一致）
    pub kind: String,
    /// 上游源**最新**的 `updatedAt`（挑最大，而不是取第一个）
    pub updated: String,
}

/// 读插件的运行时源状态；**任何失败都降级为 `Default`，绝不 panic**
///
/// # 降级契约（重要）
/// ```text
/// 文件不存在 / 读不动 / 不是合法 JSON / sourceStatus 缺失
/// sourceStatus 不是字符串也不是对象 / sources 不是数组 / 元素不是对象
/// updatedAt 不是合法 RFC3339 / type 不是 slug
///     ⇒ 对应字段留空，由调用方回退到头注释的 @type / @updated
/// ```
/// 设计原则：**列表页不该因为某个插件的私有存储写坏了就整页崩掉**。
/// 一个坏文件只让那一张卡片少显示一行，不连坐。
pub fn read_source_status(data_dir: &std::path::Path, plugin_id: &str) -> PluginSourceStatus {
    let mut out = PluginSourceStatus::default();
    // 1) 整个 store 映射（坏文件 → 空映射，不 panic）
    let map = store_load(data_dir, plugin_id);

    // 2) 取 sourceStatus —— 契约是「JSON 字符串」，但对「已经是对象」
    //    的写法也宽容（author 手写 .data 文件时可能直接写对象）
    let status = match map.get("sourceStatus") {
        Some(serde_json::Value::String(s)) => match serde_json::from_str(s) {
            Ok(v) => v,
            Err(_) => return out, // 字符串里不是合法 JSON ⇒ 降级
        },
        Some(v @ serde_json::Value::Object(_)) => v.clone(),
        _ => return out,
    };

    // 3) 遍历 sources，挑 type（第一个）/ updatedAt（最大）
    let Some(sources) = status.get("sources").and_then(|v| v.as_array()) else {
        return out;
    };
    let mut newest: Option<(chrono::DateTime<chrono::FixedOffset>, String)> = None;
    for s in sources {
        if let Some(t) = s.get("type").and_then(|v| v.as_str()) {
            let t = clean_source_type(t);
            if !t.is_empty() && out.kind.is_empty() {
                out.kind = t;
            }
        }
        // `updatedAt` 是契约定名；`updated_at` 只是顺手兼容（下划线风格）
        let raw = s
            .get("updatedAt")
            .or_else(|| s.get("updated_at"))
            .and_then(|v| v.as_str())
            .map(|v| v.trim())
            .unwrap_or("");
        // ⚠️ 运行时值**必须**能解析成真时间才收（界面上要按本地时区重排），
        //    解析不了就当没有 —— 回退头注释，而不是把垃圾塞进界面
        let Ok(t) = chrono::DateTime::parse_from_rfc3339(raw) else {
            continue;
        };
        if newest.as_ref().map(|(best, _)| t > *best).unwrap_or(true) {
            newest = Some((t, raw.to_string()));
        }
    }
    if let Some((_, raw)) = newest {
        out.updated = raw;
    }
    out
}

/// ★ 把「头注释」与「运行时状态」合成卡片要显示的那两个值
///
/// 返回 `(kind, updated)`，任一可能为空串（=界面不显示）。
///
/// # 优先级（2026-10-23 Lead 批准的口径，**故意两边不一样**）
///
/// ```text
/// kind    ：头注释 @type 优先 ── 插件级声明更准
///           （aggregator 这类插件里每个源可能各有 type，
///            卡片上要显示的是「这个插件是什么」，不是某个源是什么）
///           头注释没写 → 用运行时的 sources[].type（有总比没有强）
///
/// updated ：运行时 updatedAt 优先 ── 那才是「真的验证过上游」的证据
///           运行时没有/非法 → 回落头注释 @updated（作者自报）
/// ```
/// 这个函数是**纯函数**（不碰磁盘），所以能直接单测，
/// 而 `commands_provider.rs` 的接线只剩两行。
pub fn resolve_source_display(
    meta: &PluginMeta,
    runtime: &PluginSourceStatus,
) -> (String, String) {
    let kind = if !meta.kind.is_empty() {
        meta.kind.clone()
    } else {
        runtime.kind.clone()
    };
    // 两边都已各自净化过（slug / 日期形状），这里只做取值
    let updated = if !runtime.updated.is_empty() {
        runtime.updated.clone()
    } else {
        meta.updated.clone()
    };
    (kind, updated)
}


/// 从插件源码里提取**上游接口地址**（只服务界面显示，不参与插件运行）
///
/// # 为什么需要它（Owner 缺陷 5）
///
/// > 你既然已经支持了 tvbox，那么就应该把所有的 tvbox 插件都还原成原本的
/// > 链接，而不是现在转换后的插件
///
/// ★ 事实是**链接从来没丢过** —— TVBox 转换器把原始接口逐字写进了生成的
///   `.js` 文件里（模板见 `tvbox.rs`），只是**界面从来没显示过**。
///   实测本机 28 个插件：22 个 `tvbox-convert` 的头部注释与正文
///   `const API` **逐字节相同**，6 个 `dsh` 里 2 个有 `const API`。
///
/// # 为什么只认头部注释的「上游接口」
///
/// ```text
/// 头部注释：` * 上游接口（苹果CMS v10）：http://tyyszy.com/api.php/provide/vod`
///   ⇒ 转换器专门写给人看的**来源说明**，22 个转换插件全有 ⇒ 认
///
/// 正文常量：`const API = 'https://api.example-v.com'`
///   ⇒ 这是**接口地址**，不是来源 ⇒ ✗ 不认（2026-10-09 修掉的 bug）
/// ```
///
/// ⚠️ 曾经也认正文那条，结果手写插件的「接口地址」被当成了「安装来源」，
///    UI 据此把它判成「按链接安装的插件」⇒ 编辑框预填接口地址、
///    保存时当成链接去重新安装 ⇒ **覆盖坏用户的本地插件**。细节见函数体里的注释。
///
/// ★ 手写插件返回空串是**正确**的：它的来源就是用户自己写的，没有"来源链接"。
///   真正按链接安装的来源存在 `plugins/.meta/<id>.json` 的 `source_url` 里。
///
/// # ⚠️ 为什么不改 `parse_meta` 而是单开一个函数
///
/// `parse_meta` 的语义是「解析 `@key value` 形式的元信息」，它的结果进
/// `PluginMeta` 并参与插件注册。`上游接口` **不是** `@key`，塞进
/// `parse_meta` 会让「元信息解析」多一条隐式规则，将来改 tag 扫描逻辑时
/// 容易连坐。这里只读源码、只返回字符串，**零副作用**。
///
/// ⚠️ 只认 `http://` / `https://` 开头 —— 否则像
///    `const API = '/api.php/provide/vod'`（相对路径）这种会被当成链接显示，
///    用户复制出来是个**不能用的东西**。
pub fn upstream_of(src: &str) -> String {
    // ① 头部注释（只看开头 2KB，与 `parse_meta` 同一个约定）
    let head: String = src.chars().take(2048).collect();
    if let Some(i) = head.find("上游接口") {
        let rest = &head[i..];
        // 全角「：」是转换器写的；半角「:」兼容手写插件
        let start = match rest.find('：') {
            Some(p) => Some(p + '：'.len_utf8()),
            None => rest.find(':').map(|p| p + 1),
        };
        if let Some(p) = start {
            // 取到行尾，并容忍「行尾就是注释结束符 */」的写法
            let line = rest[p..].lines().next().unwrap_or("");
            let url = line.trim().trim_end_matches("*/").trim();
            if url.starts_with("http://") || url.starts_with("https://") {
                return url.to_string();
            }
        }
    }

    /*
     * ⚠️⚠️ 这里**故意**没有「正文 `const API` 回退」—— 那是 2026-10-09 修掉的 bug。
     *
     * 原来还有一条：找不到头部注释时，去正文找 `const API = 'https://…'` 当上游。
     * 但那个常量是**接口地址**，不是**安装来源**，两者根本不是一回事：
     * ```text
     * srcv.js 正文第 91 行  const API = 'https://api.example-v.com'
     *   ⇒ upstream = "https://api.example-v.com"
     *   ⇒ 编辑对话框判成「链接型」⇒ 预填这个地址、类型锁死
     *   ⇒ 用户点保存会去拉 api.example-v.com 当插件装 ⇒ **本地插件被覆盖坏**
     * ```
     * 手写插件（srcv 就是）根本没有"安装来源"这个概念 ——
     * 它的来源是用户自己写的。宁可为空，也不能编一个。
     *
     * ★ 真正的安装来源在 `plugins/.meta/<id>.json` 的 `source_url`
     *   （见 `install_plugin` / `list_plugin_sources`），与这里无关。
     */

    String::new()
}

// ─────────────────────────── 熔断 ───────────────────────────

/// 生成一个「按墙钟时间」判断的中断处理器
///
/// 返回 `true` 时 QuickJS 会中断当前执行。
///
/// ⚠️ 必须是 `Send` —— 开了 rquickjs 的 `parallel` feature 后
/// `InterruptHandler` 要求 `Send`。当前实现只捕获一个 `Instant`，天然满足。
fn make_interrupt(deadline_ms: u64) -> impl FnMut() -> bool + Send + 'static {
    let start = std::time::Instant::now();
    move || start.elapsed().as_millis() as u64 > deadline_ms
}

// ─────────────────────────── 命名风格转换 ───────────────────────────
//
// ★ 契约承诺「插件写 camelCase，宿主自动转 snake_case」，这里就是那一层。
//
// 为什么不让 Rust 侧直接 `#[serde(rename_all = "camelCase")]`：
// 那些模型结构体**同时用于前后端通信**（Tauri 命令的返回值），
// 改 serde 命名会**一并改掉给前端的线上格式**，把已有界面全打挂。
// 所以转换只发生在「插件边界」这一层。

/// `categoryId` → `category_id`
fn camel_to_snake(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 4);
    for c in s.chars() {
        if c.is_ascii_uppercase() {
            out.push('_');
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

/// `category_id` → `categoryId`
fn snake_to_camel(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut up = false;
    for c in s.chars() {
        if c == '_' {
            up = true;
        } else if up {
            out.push(c.to_ascii_uppercase());
            up = false;
        } else {
            out.push(c);
        }
    }
    out
}

/// 把插件返回的 JSON 转成 Rust 侧结构能吃的形态
///
/// 做两件事：
/// 1. **键名 camelCase → snake_case**（递归，含嵌套对象与数组元素）
/// 2. **`headers` 从对象转成键值对数组**
///    Rust 侧是 `Vec<(String, String)>`，而插件按契约写
///    `{ Referer: 'x' }` 这种对象 —— serde 会报
///    `invalid type: map, expected a sequence`
fn js_value_to_rust(v: serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (k, val) in map {
                let key = camel_to_snake(&k);
                // headers 特例：对象 → [[k, v], ...]
                let val = if key == "headers" {
                    match val {
                        serde_json::Value::Object(h) => serde_json::Value::Array(
                            h.into_iter()
                                .map(|(hk, hv)| {
                                    serde_json::Value::Array(vec![
                                        serde_json::Value::String(hk),
                                        hv,
                                    ])
                                })
                                .collect(),
                        ),
                        other => js_value_to_rust(other),
                    }
                } else {
                    js_value_to_rust(val)
                };
                out.insert(key, val);
            }
            serde_json::Value::Object(out)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.into_iter().map(js_value_to_rust).collect())
        }
        other => other,
    }
}

/// 把 Rust 侧的值转成插件习惯的形态（反向）
///
/// 用在「宿主传给插件的参数」方向，如 `PlayRequest` → `resolve(id, req)`。
/// 插件作者写 `req.episodeId` 比 `req.episode_id` 自然。
fn rust_value_to_js(v: serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(map) => {
            let mut out = serde_json::Map::new();
            for (k, val) in map {
                out.insert(snake_to_camel(&k), rust_value_to_js(val));
            }
            serde_json::Value::Object(out)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.into_iter().map(rust_value_to_js).collect())
        }
        other => other,
    }
}

// ─────────────────────────── 插件 Provider ───────────────────────────

/// 一个由 JS 文件驱动的 Provider
///
/// `Debug` 是必需的（测试里 `unwrap_err()` 要求 `T: Debug`）。
/// 手动实现而不用 derive：**源码可能很长**，
/// derive 会把整个脚本打进日志，排查时反而看不清。
pub struct JsPluginProvider {
    manifest: ProviderManifest,
    /// 插件源码（每次调用新建 Runtime 时重新求值）
    source: String,
    /// 站点代理（插件通过 host.http 发的请求走它）
    proxy: Option<Arc<crate::proxy::ProxyStore>>,
    /// 插件私有数据目录（`host.store` 落盘位置）
    ///
    /// 由加载方（`load_plugins_hydrated`）注入 —— 模块本身不知道
    /// 应用数据目录在哪，这是有意的（便于测试时用临时目录）。
    data_dir: Option<std::path::PathBuf>,
    /// ★ 域名池（插件给候选、宿主选路）
    ///
    /// `RefCell` 是因为 `call_js` 收 `&self`（它被 `MediaProvider` 的
    /// 一堆 `&self` 方法调用），而选路要改状态。单线程内使用，无跨线程争用。
    ///
    /// 没有声明 `hosts` 的插件这里恒为 `None` ⇒ 行为与加这个字段前**完全一致**。
    pool: Arc<std::sync::Mutex<Option<crate::hostpool::HostPool>>>,
    /// Where pool state is persisted (same dir as persist.rs).
    pool_dir: Option<std::path::PathBuf>,
}

impl std::fmt::Debug for JsPluginProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("JsPluginProvider")
            .field("id", &self.manifest.id)
            .field("name", &self.manifest.name)
            .field("source_bytes", &self.source.len())
            .finish()
    }
}

impl JsPluginProvider {
    /// ★ 剥掉 `"{provider}:"` 前缀，得到插件自己的 native id
    ///
    /// 宿主给插件返回的条目**加了前缀**（见 `prefix_media_ids`），
    /// 前端把带前缀的 id 传回来时（`detail` / `resolve` / `sources` /
    /// `episodes`），必须还原成插件认识的那个 id。
    ///
    /// ⚠️ **漏掉这一步的后果**（实测踩到）：
    /// 插件收到 `srcl:c899032a...` 却拿它当 pid 去请求，接口返回空，
    /// 于是详情页标题显示成一串 guid、剧集列表为空 ——
    /// 但**不报错**，看起来像「这个视频本来就没信息」，极难排查。
    ///
    /// 只剥自己那一份前缀：`srcl:xxx` → `xxx`；
    /// 其它形态（无前缀、别的 provider 前缀）原样返回。
    fn strip_prefix(&self, id: &str) -> String {
        let prefix = format!("{}:", self.manifest.id);
        id.strip_prefix(&prefix).unwrap_or(id).to_string()
    }

    /// 从脚本源码构建
    ///
    /// 会先解析元信息并校验 —— **不执行脚本**就能判断它是不是合法插件。
    ///
    /// ⚠️ 返回 `std::result::Result` 而不是 crate 的 `Result<T>` 别名 ——
    /// 加载阶段的错误是「文件格式问题」（字符串），不是运行时的
    /// `ProviderError`。用字符串让调用方（扫描目录）能直接把
    /// 「哪个文件、为什么失败」展示给用户。
    ///
    /// ⚠️ **能力位此时还拿不到** —— 插件把 `capabilities` 写在
    /// `globalThis.plugin` 里，要执行脚本才知道。
    /// 所以能力位默认全 false，由 `hydrate_capabilities()` 在注册前补齐。
    /// （**踩过**：默认给了 `vod: true` 而 `live/search` 留在 false，
    /// 导致直播页与搜索完全看不到这个源 —— registry 是按
    /// `manifest().capabilities.live` 过滤的。）
    /// resolve 的**第一个参数**该传什么（抽出来是为了可单测）
    ///
    /// # ★★★ 为什么要有这个函数（Owner 报的 bug）
    ///
    /// > 播放第二集,实际还是第一集,这是bug
    ///
    /// tvbox 转换插件的 detail() 里剧集 id **就是剧集地址**
    /// （`154.js:369  id: e.url`），而它的 resolve(id) 只认第一个参数、
    /// **完全忽略 req**（`154.js:392`，见 resolve 里的长注释）。
    /// 宿主原来传 id.native（条目 id，如 "150758"）⇒ 插件去查详情、
    /// 取 eps[0] ⇒ 无论点第几集都返回第一集。
    ///
    /// ⇒ **episode_id 明确是 http(s) URL 时，用它当第一个参数。**
    ///
    /// # ⚠️ 判据必须精确（不许无条件替换）
    ///
    /// 别的插件用 episode_id 表达**别的东西** —— 最典型的是 srca，
    /// 它拿它当 section_id（纯数字 51463）。一律替换会把某动画站打坏。
    /// ⇒ 只有 `starts_http` 为真才替换；否则**原样**返回条目 id
    ///   （= 改动前行为，逐字相同）。
    fn resolve_first_arg(&self, id: &MediaId, req: &PlayRequest) -> String {
        match req.episode_id.as_deref() {
            Some(ep) if crate::tvbox::starts_http(ep) => ep.to_string(),
            _ => self.strip_prefix(&id.native),
        }
    }
    pub fn from_source(source: &str) -> std::result::Result<Self, String> {
        let meta = parse_meta(source);
        if meta.id.is_empty() {
            return Err("插件缺少 @id（头部注释里必须有，如 `@id srcl`）".into());
        }
        if meta.name.is_empty() {
            return Err(format!("插件 {} 缺少 @name", meta.id));
        }

        let manifest = ProviderManifest {
            id: meta.id.clone(),
            name: meta.name.clone(),
            version: if meta.version.is_empty() {
                "1.0.0".into()
            } else {
                meta.version.clone()
            },
            kind: "js".into(),
            description: if meta.description.is_empty() {
                None
            } else {
                Some(meta.description.clone())
            },
            icon: None,
            id_prefixes: vec![format!("{}:", meta.id)],
            /*
             * 能力位此时**只能是保守值**。
             *
             * 插件把 capabilities 写在 `globalThis.plugin` 里，
             * 不执行脚本读不到。若在这里写死 `vod: true`，
             * 而 registry 是按 `manifest().capabilities.live` 过滤的
             * （见 `live_all` / `search_all`），
             * 结果就是**直播页与搜索页完全看不到这个源**（实测踩到）。
             *
             * 所以全部默认 false，注册前用 `hydrate_capabilities()` 补齐。
             */
            capabilities: Capabilities::default(),
            /*
             * 配置项同样要**执行脚本才拿得到**（插件写在 `globalThis.plugin.config`），
             * 由 `hydrate_capabilities()` 一并填充。
             */
            cover_headers: Vec::new(),
            config: Vec::new(),
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            // 启用状态由 `list_providers` 在出口处统一填（Provider 不关心）
            enabled: None,
        };

        Ok(Self {
            manifest,
            source: source.to_string(),
            proxy: None,
            data_dir: None,
            pool: Arc::new(std::sync::Mutex::new(None)),
            pool_dir: None,
        })
    }

    /// 注入插件私有数据目录（`host.store` 的落盘位置）
    pub fn with_data_dir(mut self, dir: std::path::PathBuf) -> Self {
        self.data_dir = Some(dir);
        self
    }

    /// task-37: inject pool persistence dir.
    pub fn with_pool_dir(mut self, dir: std::path::PathBuf) -> Self {
        self.pool_dir = Some(dir);
        self
    }

    /// task-37: apply persisted pool state onto this plugin.
    ///
    /// The pool is rebuilt from plugin declarations during hydrate, but
    /// "which host is broken" is memory across restarts. Without restoring it,
    /// persisting would be pointless.
    ///
    /// Only restores hosts that still exist (sync_hosts prunes), so removing a
    /// host from the plugin does not leave stale state accumulating.
    pub fn apply_saved_pool(&mut self, saved: Option<&crate::hostpool::HostPool>) {
        let Some(saved) = saved else { return };
        let mut guard = self.pool.lock().unwrap_or_else(|e| e.into_inner());
        let Some(live) = guard.as_mut() else { return };
        let hosts = live.hosts.clone();
        live.sync_hosts(hosts);
        for (h, st) in &saved.states {
            if live.hosts.iter().any(|x| x == h) {
                live.states.insert(h.clone(), st.clone());
            }
        }
        if let Some(cur) = &saved.current {
            if live.hosts.iter().any(|x| x == cur) {
                live.current = Some(cur.clone());
            }
        }
    }

    /// task-37: write current pool state to disk (throttled to 1 per 5s).
    ///
    /// record_outcome runs after EVERY host.http request; a detail page can
    /// fire dozens. Unthrottled that is dozens of disk writes.
    fn maybe_save_pool(&self) {
        use std::sync::atomic::{AtomicU64, Ordering};
        static LAST: AtomicU64 = AtomicU64::new(0);
        let Some(dir) = &self.pool_dir else { return };
        let now = now_unix().max(0) as u64;
        let prev = LAST.load(Ordering::Relaxed);
        if now.saturating_sub(prev) < 5 {
            return;
        }
        LAST.store(now, Ordering::Relaxed);
        self.save_pool_now(dir);
    }

    /// task-37: write immediately, no throttling (for shutdown/tests).
    pub fn save_pool_now(&self, dir: &std::path::Path) {
        // Single write path: route through save_hook so tests that cover
        // save_hook also cover this. Two paths previously diverged and a
        // fault-injected bug slipped past the test.
        save_hook(&Some(dir.to_path_buf()), &self.manifest.id, &self.pool, true);
    }

    /// 把插件声明的 `config` 装进 manifest
    ///
    /// # ⚠️ 为什么不能直接 `serde_json::from_value`
    ///
    /// `call_js` 的出口会对**所有**对象键做 `camel_to_snake` 转换。
    /// 那对能力位（`loginRequired` → `login_required`）是对的，
    /// 但对**用户配置的键名是灾难**：
    ///
    /// ```text
    /// 插件声明  key: 'proxyUrl'
    /// 到达这里  变成  proxy_url
    /// 插件再读  host.config.get('proxyUrl')  → 永远读不到！
    /// ```
    ///
    /// 而且这个转换**对非 ASCII 键会写坏**（项目已知：
    /// `camel_to_snake('UP主')` → `_u_p主`，不可逆）。
    ///
    /// 所以配置项的 `key` 必须在**插件源码里原样保留**。
    /// 做法：不用转换后的值，而是重新从插件源码里读一遍？
    /// —— 那太脆弱。
    ///
    /// **采用的办法**：让插件把 key 也写成 ASCII snake_case 就
    /// 不会被转换（`camel_to_snake` 对已经是 snake 的串是幂等的）。
    /// 同时在契约文档里写明这个约束，并在加载时**检测**
    /// 「声明里出现了被转换过的键」并给出明确警告。
    ///
    /// 见 `research/插件API契约设计.md` 的「配置键命名」一节。
    fn hydrate_config(&mut self, cfg: &serde_json::Value) {
        let Some(arr) = cfg.as_array() else {
            if !cfg.is_null() {
                log::warn!(
                    "插件 {} 的 config 不是数组，已忽略",
                    self.manifest.id
                );
            }
            return;
        };

        let mut fields: Vec<crate::model::ConfigField> = Vec::new();
        let mut warnings: Vec<String> = Vec::new();

        for item in arr {
            match serde_json::from_value::<crate::model::ConfigField>(item.clone()) {
                Ok(mut f) => {
                    /*
                     * 检测「键被 camel_to_snake 改过」的迹象。
                     *
                     * 判据：key 里含 `_` 但其前后是小写字母+数字
                     * （即形如 `proxy_url`），而插件源码里写的多半是
                     * `proxyUrl`。我们无法 100% 确定，所以只**提示**
                     * 而不改 —— 因为 snake_case 本身是允许的写法。
                     */
                    if f.key.contains('_') && f.key.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') {
                        warnings.push(format!(
                            "配置项「{}」的 key 是 `{}`。\
                             ⚠️ 若你源码里写的是驼峰（如 `proxyUrl`），\
                             它已被宿主转成蛇形 —— 请把源码里的 key 也改成蛇形，\
                             否则 `host.config.get('proxyUrl')` 读不到。",
                            f.label, f.key
                        ));
                    }

                    f.sanitize(&mut warnings);
                    // 去掉重复 key（后者覆盖前者，但只保留一个）
                    if fields.iter().any(|x| x.key == f.key) {
                        warnings.push(format!("配置项 key「{}」重复，已忽略后一个", f.key));
                        continue;
                    }
                    fields.push(f);
                }
                Err(e) => warnings.push(format!("配置项解析失败（已跳过）: {e}")),
            }
        }

        if !fields.is_empty() {
            log::info!(
                "插件 {} 声明了 {} 项配置",
                self.manifest.id,
                fields.len()
            );
        }
        for w in &warnings {
            log::warn!("插件 {} 的配置声明有问题：{w}", self.manifest.id);
        }

        self.manifest.config = fields;
    }

    /// ★ 执行插件脚本，把它的 `capabilities` 读进 manifest
    ///
    /// **必须在注册进 Registry 之前调用** —— `live_all()` / `search_all()`
    /// 都按 `manifest().capabilities.*` 过滤，能力位不对的话
    /// 直播页与搜索页会看不到这个源。
    ///
    /// 失败时不报错（保持保守默认值）：能列出分类但仍声明不了能力，
    /// 总比整个插件加载失败好。
    pub async fn hydrate_capabilities(&mut self) {
        /*
         * ★ 一次调用同时取 capabilities / config / coverHeaders
         *
         * 为什么要合并：`call_js` 每次都要建一个 QuickJS 运行时并执行
         * 整个插件脚本（实测有几百毫秒）。分成多次调用等于白跑几遍。
         */
        let json = match self
            .call_js(
                "({ capabilities: plugin.capabilities ?? {}, \
                   config: plugin.config ?? [], \
                   coverHeaders: plugin.coverHeaders ?? null, \
                   hosts: plugin.hosts ?? null })",
            )
            .await
        {
            Ok(j) => j,
            Err(e) => {
                log::warn!("插件 {} 能力位读取失败（按默认值）: {}", self.manifest.id, e.message);
                return;
            }
        };

        let Ok(v) = serde_json::from_str::<serde_json::Value>(&json) else {
            return;
        };

        // ── 抓封面需要的请求头 ──
        //
        // ⚠️ 读的键名是 **snake_case** 的 `cover_headers` ——
        // `call_js` 出口已统一做过 camelCase → snake_case（与能力位同一原因）。
        //
        // ⚠️ 另外：`js_value_to_rust` 只对**名为 `headers`** 的键做
        // 「对象 → 键值对数组」特例，`coverHeaders` **不走那个特例**。
        // 所以插件必须直接写成数组：`coverHeaders: [['Referer','https://…']]`
        if let Some(h) = v.get("cover_headers") {
            match serde_json::from_value::<Vec<(String, String)>>(h.clone()) {
                Ok(list) if !list.is_empty() => {
                    log::info!(
                        "插件 {} 声明了 {} 个封面请求头",
                        self.manifest.id,
                        list.len()
                    );
                    self.manifest.cover_headers = list;
                }
                Ok(_) => {}
                Err(e) => log::warn!(
                    "插件 {} 的 coverHeaders 格式不对（应为 [[名, 值], ...]）：{e}",
                    self.manifest.id
                ),
            }
        }

        // ── ★ 域名池（task-37）──
        //
        // 插件声明 hosts: ['https://a.example.com', ...]。
        // 只有数组形式才认；不声明 / 空数组 ⇒ 不建池，
        // 行为与加这个能力前完全一致。
        if let Some(h) = v.get("hosts") {
            match serde_json::from_value::<Vec<String>>(h.clone()) {
                Ok(list) if !list.is_empty() => {
                    let pool = crate::hostpool::HostPool::from_hosts(list);
                    if pool.hosts.len() == 1 {
                        log::info!(
                            "插件 {}：hosts 只有一项，无处可切（仍会记失败）",
                            self.manifest.id
                        );
                    }
                    log::info!(
                        "插件 {}：声明了 {} 个域名候选",
                        self.manifest.id,
                        pool.hosts.len()
                    );
                    *self.pool.lock().unwrap_or_else(|e| e.into_inner()) = Some(pool);
                }
                Ok(_) => {}
                Err(e) => log::warn!(
                    "插件 {}：hosts 格式不对（应为字符串数组）：{e}",
                    self.manifest.id
                ),
            }
        }

        // ── 配置项（先做，因为它与 capabilities 独立）──
        if let Some(cfg) = v.get("config") {
            self.hydrate_config(cfg);
        }

        let Some(caps) = v.get("capabilities") else {
            return;
        };

        let flag = |key: &str| caps.get(key).and_then(|b| b.as_bool()).unwrap_or(false);

        /*
         * ★★ 提前把"这个源是否支持登录"取出来（2026-09-25，task-38）
         *
         * # 为什么不能等到下面再读
         *
         * 下面有 `let c = &mut self.manifest.capabilities;` —— 那是个
         * **可变借用**。而"运行时探测 canAutoLogin"要调 `self.call_js(...)`
         * （`&self` 不可变借用）。两者**不能共存**：
         * ```text
         * error[E0502]: cannot borrow `*self` as immutable
         *              because it is also borrowed as mutable
         * ```
         * ⇒ 所以在可变借用**之前**把需要的两个布尔值取出来（它们就是 `bool`，Copy）。
         */
        let supports_login = flag("login_required") || flag("login_supported");

        /*
         * ⚠️ 这里读的键名是 **snake_case**，不是插件源码里写的 camelCase。
         *
         * 因为 `call_js` 出口已经统一做过 camelCase → snake_case 转换
         * （见 `js_value_to_rust`）。插件写 `loginRequired`，
         * 到这里已经变成 `login_required`。
         *
         * **实测踩过**：第一版按 `loginRequired` 读，永远读到 false，
         * 于是 srca 的 `loginRequired: true` 完全没生效 ——
         * 表现是「界面上不显示登录入口」「会话状态是 not_required」，
         * 用户根本没法登录这个源。
         */
        /*
         * ★★★ 运行时探测 `canAutoLogin`（2026-09-25，task-38）
         *
         * ⚠️ **必须在 `let c = &mut self.manifest.capabilities;` 之前做** ——
         *    `c` 是可变借用，而探测要 `self.call_js(..)`（不可变借用），
         *    同一作用域里共存会 `error[E0502]`。
         *    所以先把探测结果存进 `probed_auto_login`，再进借用区。
         *
         * 详见下面（写回处）那段长注释：为什么需要运行时兜底。
         */
        let declared_auto_login = flag("can_auto_login");
        let mut probed_auto_login = false;

        /*
         * ⚠️ 先把声明值取到**局部变量**里再探测 ——
         *    `c` 是 `&mut self.manifest.capabilities`（可变借用），
         *    而探测要 `self.call_js(...)`（不可变借用），两者不能共存。
         *    读成 bool（Copy）之后这个借用就不再需要了；
         *    探测完再写回 `c`。
         */
        if !declared_auto_login {
            /*
             * ★ 只在**可能有关**时才探测：必须支持登录。
             *
             * 不设这个门的话，25 个没有登录能力的插件（api/ffj/iptv/…）
             * 每次加载都要白跑一次 JS 求值 —— 纯浪费。
             */
            if supports_login {
                match self
                    .call_js("(plugin.canAutoLogin ? plugin.canAutoLogin() : false)")
                    .await
                {
                    Ok(v) if v == "true" => {
                        probed_auto_login = true;
                        log::info!(
                            "插件 {} 未声明 canAutoLogin，但**运行时探测为真** —— \
                             按其实现为准（声明可能只是没跟上）",
                            self.manifest.id
                        );
                    }
                    Ok(_) => { /* 探测为假：方法不存在 / 返回 false —— 正常 */ }
                    Err(e) => {
                        /*
                         * ★ 纪律 ③：探测失败要留痕。
                         *
                         * 不记的话，将来"某个插件探测失败"就是**静默的假 false** ——
                         * 用户又回到"看到验证码却说不出为什么"。
                         */
                        log::warn!(
                            "插件 {} 的 canAutoLogin 探测失败，按 false 处理: {}",
                            self.manifest.id,
                            e.message
                        );
                    }
                }
            }
        }


        let c = &mut self.manifest.capabilities;
        c.vod = flag("vod");
        c.live = flag("live");
        c.epg = flag("epg");
        c.search = flag("search");
        c.login_required = flag("login_required");
        c.multi_source = flag("multi_source");
        c.server_side_history = flag("server_side_history");
        c.favorites = flag("favorites");
        c.timeshift = flag("timeshift");
        c.danmaku = flag("danmaku");

        /*
         * ★★ 发送弹幕（task-T2，2026-10-16）
         *
         * ⚠️ 与上面每一项同一个坑：本函数是**逐字段**读的，往
         *    `Capabilities` 加字段**不会**自动生效 —— 必须在这里显式赋值。
         *    忘了写的话表现是「插件声明了 danmakuSend: true，
         *    界面上却不出现发送入口」，且**不报错**。
         *
         * ⚠️ 默认 false（老插件没有这个能力）。
         *    与 `danmaku` **刻意分开**：能取弹幕的站点远多于能发弹幕的，
         *    合成一个位宿主就无法如实告诉用户「这个源只能看不能发」。
         */
        c.danmaku_send = flag("danmaku_send");

        /*
         * ★★ 登录三项（2026-09-20 新增）—— **必须在这里逐个赋，不能只加字段**
         *
         * 这个函数是**逐字段**读的（不是整体 `serde::from_value`），
         * 所以往 `Capabilities` 结构体加字段**不会**自动生效 ——
         * 实测踩到：加了 `login_supported` 但插件侧一直是 false，
         * 表现是「某视频站 声明了 loginSupported: true，登录入口却不出现」。
         *
         * ⚠️ 键名同理是 snake_case（`call_js` 已做过 camelCase 转换）。
         */
        c.login_supported = flag("login_supported");
        c.login_hint = caps
            .get("login_hint")
            .and_then(|h| h.as_str())
            .map(|s| s.to_string());
        /*
         * ⚠️ `login_needs_username` 的**默认值是 true**（不是 false）——
         *    老插件没声明这一项时要保持原有行为（显示账号框）。
         *    用 `flag()`（默认 false）会把所有源的账号框都隐藏掉。
         */
        c.login_needs_username = caps
            .get("login_needs_username")
            .and_then(|b| b.as_bool())
            .unwrap_or(true);

        /*
         * ★ 扫码登录（2026-09-21）
         *
         * 与上面三项同一个坑：这个函数是**逐字段**读的，
         * 加了结构体字段**不会**自动生效，必须在这里显式赋值。
         * 忘了写的话表现是「插件声明了 loginQrSupported: true，
         * 登录弹窗却没有扫码页签」—— 且不报任何错。
         *
         * ⚠️ 默认 false（老插件没有这个能力）。
         */
        c.login_qr_supported = flag("login_qr_supported");

        /*
         * ★★★ 能用保存的凭据自动重登（2026-09-25，task-38）
         *
         * # 两层来源：「声明」或「运行时探测」（**取或**）
         *
         * ```text
         * ① 声明     插件写 `capabilities.canAutoLogin: true`
         *            → 零开销（这里就是读它）
         * ② 运行时探测 直接问插件 `canAutoLogin()` 方法
         *            → 兜底，见下面「为什么必须有兜底」
         * ```
         *
         * # ★★★ 为什么必须有运行时兜底（实测发现的关键问题）
         *
         * 声明**不一定送得到用户手里**。实测：
         * ```text
         * repo    rust/sourin_core/plugins/srca.js     17882 B  声明在
         * deployed %APPDATA%\...\plugins\srca.js       17457 B  声明**不在**
         * ```
         * 根因：`srca.js`（和 `srcl.js`）**从来不由程序投放** ——
         * `state.rs` 只有 `seed_demo_plugin` / `seed_iptv_plugin` 两个，
         * 而那里自己的注释就写着：
         * > 但**没有** `iptv.js` —— 因为 `srcl.js` / `srca.js` 都是**人工放进去**的
         *
         * ⇒ 所以「等插件声明」= **等一次永远不会发生的插件更新**
         *   （插件是人工投放的，没有升级通道）
         * ⇒ 只靠声明，用户**永远**看不到「正在自动重新登录」，
         *   Owner 报的那句「还提示 验证码」原封不动。
         *
         * ★ 但**运行时方法**在用户那份插件里**是存在的**
         *   （`srca.js` L309 `async canAutoLogin()`）——
         *   直接问它就能立刻拿到正确答案。
         *
         * # 语义：声明是"缓存"，实现是"真相"
         *
         * ```text
         * 声明 = 实现的镜像（可能过期/缺失）
         * 实现 = 真相
         * ⇒ 两者都在时以**实现**为准；声明只是"省一次调用"的优化
         * ```
         * 所以这里是 `声明 || 探测`：已声明的插件**零额外开销**（短路）。
         *
         * # ⚠️ 三条纪律（Lead 明确要求）
         *
         * ```text
         * ① 探测**必须容错**：抛异常 / 方法不存在 / 超时 → 一律当 **false**
         *    （不能当 true —— 否则显示"正在自动重新登录"然后失败，
         *      比原来那句通用文案**更糟**：从"误导"变成"撒谎"）
         * ② 探测**只在这里做一次**（插件加载时），**不进 `session_state`**
         *    ⇒ 读会话状态的路径零额外开销（那是高频路径）
         * ③ 探测失败要**可观测**（log::warn）——
         *    否则"某个插件探测失败"会变成**静默的假 false**，回到今天的问题
         * ```
         */
        /*
         * ★ 声明 或 探测（取或）—— 探测已在**借用 `c` 之前**做完，
         *   结果放在 `probed_auto_login` 里（见上面那段长注释）。
         */
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★ 实测开销（2026-09-25 实测，n=15，**部署版真实插件**）
         * ══════════════════════════════════════════════════════════════
         *
         * 见 `tests/zz_t38_perf.rs`（可复现）。中位数：
         * ```text
         * 基线（不触发探测）        中位数 = 1.461 ms
         * 带探测（缺声明 → 走探测） 中位数 = 3.453 ms
         * ★ 探测净开销              中位数 ≈ **2 ms / 插件**
         * ```
         *
         * # 为什么这个代价可以接受
         *
         * ```text
         * ① 它发生在**插件加载时**（本函数由 `load_plugins_hydrated` 调用，
         *    每个插件**一次**）—— 不是每次请求
         * ② 它被**门控**限制：只有 `login_required || login_supported`
         *    的插件才会走探测（见上面的 if）
         * ```
         * ⇒ 总代价 = **「有登录能力的插件数」× 2 ms**，
         *    **不是** × 全部插件数（门控正是为此）。
         *    实测本机 27 个插件里只有 2 个有登录能力（srca / srcv）
         *    ⇒ 约 **4 ms 一次性**，一次进程生命周期只付一次。
         *
         * ⚠️ **绝不能**把这段探测搬到 `can_auto_login()` 或 `session_state()` ——
         *    那两个在**读会话状态**时被反复调用（设置页每次刷新都调），
         *    2 ms/次 就完全不可接受了。
         *    本文件里 `plugin.canAutoLogin` 的求值**只允许出现在本函数里**，
         *    `test/probe_cost_documented_test.dart` 有断言守着这一点。
         */
        c.can_auto_login = declared_auto_login || probed_auto_login;

        log::info!(
            "插件 {} 能力位: vod={} live={} epg={} search={} timeshift={} \
             login={} qr={} autoLogin={}",
            self.manifest.id,
            c.vod,
            c.live,
            c.epg,
            c.search,
            c.timeshift,
            c.login_required,
            c.login_qr_supported,
            c.can_auto_login
        );
    }

    pub fn with_proxy(mut self, proxy: Arc<crate::proxy::ProxyStore>) -> Self {
        self.proxy = Some(proxy);
        self
    }

    /// ★ 核心：在 JS 里执行一次插件方法
    ///
    /// `expr` 是求值表达式，形如 `plugin.home()`。
    /// 返回 JS 侧 JSON.stringify 后的字符串。
    ///
    /// # ⚠️ 传进来的表达式**必须整体加括号**（如果含三元运算符）
    ///
    /// `call_js` 内部会把它拼进 `await <expr>`。而 JS 里
    /// **`await` 比三元运算符 `?:` 结合更紧**，于是：
    ///
    /// ```js
    /// await plugin.rank ? plugin.rank("1",1) : fallback
    /// // 被解析成：
    /// (await plugin.rank) ? plugin.rank("1",1) : fallback
    /// //            ↑ await 的是**函数对象**（真值）
    /// //              于是返回一个**未 await 的 Promise**
    /// ```
    ///
    /// 而 `JSON.stringify(Promise)` 得到 `{}` —— 报错会是
    /// `missing field 'items' at line 1 column 2`（`{}` 的第 2 列），
    /// **完全看不出是优先级问题**（实测踩过）。
    ///
    /// 正解：`(plugin.rank ? plugin.rank(...) : fallback)`
    async fn call_js(&self, expr: &str) -> Result<String> {
        let rt = AsyncRuntime::new()
            .map_err(|e| ProviderError::new(ErrorKind::Other, format!("创建 JS 运行时失败: {e}")))?;

        // ★ 熔断：按墙钟时间（tick 计数方式实测要 168 秒才触发）
        rt.set_interrupt_handler(Some(Box::new(make_interrupt(SCRIPT_BUDGET_MS))))
            .await;

        let ctx = AsyncContext::full(&rt)
            .await
            .map_err(|e| ProviderError::new(ErrorKind::Other, format!("创建 JS 上下文失败: {e}")))?;

        // 注入 host API
        let proxy = self.proxy.clone();
        let plugin_id = self.manifest.id.clone();
        // 未注入时退回「当前目录下的 .plugin-data」（测试场景）；
        // 正常运行时由 `with_data_dir` 指定应用数据目录
        let data_dir = self
            .data_dir
            .clone()
            .unwrap_or_else(|| std::path::PathBuf::from(".plugin-data"));

        /*
         * ★ `host.base()` —— 当前该用的域名（2026-10-17，task-37）
         *
         * # 为什么要有它
         *
         * 插件声明 `hosts: [...]` 之后，**必须**通过这个函数拿域名拼 URL。
         * 否则宿主不知道「这一次请求打的是哪个域名」，
         * 也就无法在失败时把账记到正确的域名头上 —— 池子形同虚设。
         *
         * # 没声明 hosts 时
         *
         * 返回空串。插件不该依赖它非空：老插件照旧写死自己的域名，
         * 行为与加这个能力前**完全一致**。
         */
        let base_now: String = {
            let mut guard = self.pool.lock().unwrap_or_else(|e| e.into_inner());
            match guard.as_mut() {
                Some(p) => {
                    let now = now_unix().max(0) as u64;
                    p.revive_cooled(now);
                    p.pick(now).unwrap_or_default()
                }
                None => String::new(),
            }
        };

        let pool_ref = self.pool.clone();
        let save_dir = std::sync::Arc::new(self.pool_dir.clone());
        let pid = self.manifest.id.clone();
        let base_for_http = base_now.clone();
        ctx.with(move |ctx| {
            let g = ctx.globals();

            /*
             * ⚠️ 不要在这里 `g.set("host", ...)` 注入任何东西。
             *
             * 下面的 shim 会 `globalThis.host = { ... }` **整体覆盖**，
             * 先设的一律丢失。我就是这么丢过 base() 的（实测：
             * 插件调 host.base() 报 "not a function"）。
             * 新增 host 方法请加到**下面那个字面量**里。
             */

            // host.http
            let http = Object::new(ctx.clone())?;
            let px = proxy.clone();
            let pool_get = pool_ref.clone();
            let save_dir_get = save_dir.clone();
            let pid_get = pid.clone();
            let base_get = base_for_http.clone();
            http.set(
                "get",
                Function::new(
                    ctx.clone(),
                    Async(move |url: String, headers: Option<Object>| {
                        let px = px.clone();
                        // ★ 必须在 async 块**之前**把 Object 转成 owned 的 HashMap ——
                        //   `Object<'js>` 借用上下文，跨 await 会报 lifetime 错误
                        let h = headers.map(|o| object_to_headers(&o)).unwrap_or_default();
                        let pool = pool_get.clone();
                        let used = base_get.clone();
                        let save_dir = save_dir_get.clone();
                        let pid = pid_get.clone();
                        async move {
                            let out = do_http(&px, &pid, "GET", &url, &h, None).await;
                            if record_outcome(&pool, &used, &out) {
                                save_hook(save_dir.as_ref(), &pid, &pool, false);
                            }
                            out
                        }
                    }),
                )?,
            )?;
            let px2 = proxy.clone();
            let pool_post = pool_ref.clone();
            let save_dir_post = save_dir.clone();
            let pid_post = pid.clone();
            let base_post = base_for_http.clone();
            http.set(
                "post",
                Function::new(
                    ctx.clone(),
                    Async(move |url: String, body: Option<String>, headers: Option<Object>| {
                        let px = px2.clone();
                        let h = headers.map(|o| object_to_headers(&o)).unwrap_or_default();
                        let pool = pool_post.clone();
                        let used = base_post.clone();
                        let save_dir = save_dir_post.clone();
                        let pid = pid_post.clone();
                        async move {
                            let out = do_http(&px, &pid, "POST", &url, &h, body).await;
                            if record_outcome(&pool, &used, &out) {
                                save_hook(save_dir.as_ref(), &pid, &pool, false);
                            }
                            out
                        }
                    }),
                )?,
            )?;

            /*
             * ★★ `host.http.raw` —— 带**响应头**的请求（2026-09-20 新增）
             *
             * # 为什么需要（扫码登录的前提）
             *
             * `get`/`post` 只返回响应体。而 某视频站 扫码登录成功时，
             * 凭据是通过 **`Set-Cookie` 响应头**下发的 —— 不在 body 里。
             * 没有这个 API，插件就拿不到登录态。
             *
             * # 返回结构
             * ```js
             * const r = await host.http.raw('GET', url, { headers })
             * // r = { status: 200, body: '…', setCookie: ['SESSDATA=…; Path=/', …] }
             * ```
             *
             * ⚠️ `setCookie` 是**数组**：Cookie 的 `Expires` 里含逗号，
             *    拼成一个串再切分会有歧义（见 `HttpFull` 的说明）。
             *
             * ⚠️ 新增 API 而不是改 `get`/`post` ——
             *    那 26 个现有插件都按「返回字符串」写的，
             *    改返回值会**全部坏掉**。
             */
            let px3 = proxy.clone();
            let pid_raw = pid.clone();
            http.set(
                "raw",
                Function::new(
                    ctx.clone(),
                    Async(move |method: String, url: String, headers: Option<Object>| {
                        let px = px3.clone();
                        let pid = pid_raw.clone();
                        let h = headers.map(|o| object_to_headers(&o)).unwrap_or_default();
                        async move {
                            let r = do_http_full(&px, &pid, &method, &url, &h, None).await;
                            /*
                             * 手搓 JSON —— 与其它出口一致（都用 serde_json::json!），
                             * 避免手写转义出错。
                             */
                            serde_json::json!({
                                "status": r.status,
                                "body": r.body,
                                "setCookie": r.set_cookie,
                            })
                            .to_string()
                        }
                    }),
                )?,
            )?;
            g.set("host_http", http)?;

            /*
             * host.store —— 插件私有存储（按插件 id 隔离）
             *
             * 用途：存 token、cookie、缓存。每个插件一个文件
             * （`plugins/.data/<id>.json`），互相看不见。
             *
             * ★ 同步实现（不是 Async）：
             *   本地文件读写是微秒级的，套一层 Promise 只会让插件
             *   写起来更啰嗦（每个 get 都要 await）。宿主侧一次性
             *   读进内存，之后就是内存查表。
             *
             * ⚠️ 这里**不走系统钥匙串**：插件的 token 是插件自己的凭据，
             *   与应用级凭据（如 srca 的登录态）分开存放，
             *   避免插件互相读到对方的敏感值。
             */
            let store = Object::new(ctx.clone())?;
            let data_dir = data_dir.clone();
            let pid_for_store = plugin_id.clone();

            let dir_get = data_dir.clone();
            let pid_get = pid_for_store.clone();
            store.set(
                "get",
                Function::new(ctx.clone(), move |key: String| -> Option<String> {
                    store_read(&dir_get, &pid_get, &key)
                })?,
            )?;

            let dir_set = data_dir.clone();
            let pid_set = pid_for_store.clone();
            store.set(
                "set",
                Function::new(ctx.clone(), move |key: String, value: String| {
                    let _ = store_write(&dir_set, &pid_set, &key, Some(value));
                })?,
            )?;

            let dir_del = data_dir.clone();
            let pid_del = pid_for_store.clone();
            store.set(
                "remove",
                Function::new(ctx.clone(), move |key: String| {
                    let _ = store_write(&dir_del, &pid_del, &key, None);
                })?,
            )?;
            g.set("host_store", store)?;

            /*
             * ★ host.extract —— 通用提取器（task-41）
             *
             * # 为什么宿主只提供「执行」而不是「站点解析器」
             * 见文件上方 extract_regex / extract_json_path 的说明。
             * 一句话：站点知识留在插件，宿主不认识任何具体站点。
             *
             * # 两个方法都是纯函数，不碰网络/磁盘
             *   extract.regex(text, pattern)     -> string[]（语法错则抛）
             *   extract.json(text, path)         -> JSON 文本 或 'null'
             *
             * ⚠️ json 返回**字符串**而不是对象，与 host.config.get 一致：
             *    QuickJS 跨边界传对象不如传字符串稳，插件自己 JSON.parse。
             */
            let extract_obj = Object::new(ctx.clone())?;
            extract_obj.set(
                "regex",
                Function::new(ctx.clone(), move |text: String, pattern: String| -> std::result::Result<
                    Vec<String>,
                    rquickjs::Error,
                > {
                    // 语法错误要变成 JS 异常，不能静默返回空数组
                    extract_regex(&text, &pattern).map_err(|e| {
                        rquickjs::Error::new_from_js_message("string", "ExtractError", &e)
                    })
                })?,
            )?;
            extract_obj.set(
                "json",
                Function::new(ctx.clone(), move |text: String, path: String| -> String {
                    let doc = match serde_json::from_str::<serde_json::Value>(&text) {
                        Ok(v) => v,
                        Err(e) => return format!("__EXTRACT_ERR__JSON 解析失败: {e}"),
                    };
                    match extract_json_path(&doc, &path) {
                        Ok(Some(v)) => serde_json::to_string(&v).unwrap_or_else(|_| "null".into()),
                        Ok(None) => "null".into(),
                        Err(e) => format!("__EXTRACT_ERR__{e}"),
                    }
                })?,
            )?;
            g.set("host_extract", extract_obj)?;

            /*
             * ★ host.playback.probe —— 探测播放地址（task-41 第 2 步）
             *
             * 返回 **JSON 文本**（与 host.config.get 一致：跨 QuickJS 边界
             * 传字符串比传对象稳），插件自己 JSON.parse：
             *
             *   const r = JSON.parse(await host.playback.probe(url))
             *   // r = { verdict, kind, contentType, message, retryable }
             *
             * # verdict 的四种取值（**互不混淆**）
             *   playable        —— 可以尝试播放
             *   dash_unsupported—— DASH 格式，本播放器**未实现**（不是内容坏了）
             *   drm             —— 受 DRM 保护，**架构上不可能播**
             *   unreachable     —— 网络/HTTP 失败，**可以重试**
             */
            let playback = Object::new(ctx.clone())?;
            {
                let proxy_probe = proxy.clone();
                let pid_probe = pid.clone();
                playback.set(
                    "probe",
                    Function::new(
                        ctx.clone(),
                        Async(move |url: String| {
                            let px = proxy_probe.clone();
                            let pid = pid_probe.clone();
                            async move {
                                // ProbeReport 自己负责序列化（含 statusCode / redirected / finalUrl）
                                probe_url(&px, &pid, &url).await.to_json()
                            }
                        }),
                    )?,
                )?;
            }
            g.set("host_playback", playback)?;


            /*
             * ★ host.config —— 插件读取**用户在界面上配置的值**
             *
             * 这是「1080P / 代理 / 登录都做在插件里」的最后一环：
             * 插件声明 config（宿主渲染界面）→ 用户填 → 插件用这里读。
             *
             * # 为什么读的时候要**现查磁盘**
             *
             * `call_js` 每次都会新建 QuickJS 运行时并重跑插件脚本，
             * 所以每次调用都重新读一遍是**正确且必要**的 ——
             * 否则用户在界面上改了配置，插件要等下次重启才看到。
             *
             * # 与 host.store 的区别
             *
             * · `host.store.get(k)`  → 返回**字符串**（插件自己序列化）
             * · `host.config.get(k)` → 返回**原生类型**（布尔/数字/字符串），
             *   因为配置是界面控件直接写进去的
             */
            let cfg_dir = data_dir.clone();
            let cfg_pid = plugin_id.clone();
            let config = Object::new(ctx.clone())?;
            {
                // 每次 clone —— 闭包要 `move`，共用一个变量会被第一个闭包吃掉
                let d = cfg_dir.clone();
                let p = cfg_pid.clone();
                config.set(
                    "get",
                    Function::new(ctx.clone(), move |key: String| -> rquickjs::Result<String> {
                        /*
                         * 返回 **JSON 文本**而不是 JS 值。
                         *
                         * 原因：rquickjs 的 `Function` 返回值要能转成 Rust 类型，
                         * 而配置值类型不定（bool/number/string）。统一走
                         * JSON 字符串最省事，插件侧由 `host.config.parse()`
                         * 或直接按需转型。
                         *
                         * ⚠️ 但这样插件写起来别扭，所以下面还提供了
                         * `getBool` / `getNumber` / `getString` 三个便捷方法。
                         */
                        Ok(match config_read(&d, &p, &key) {
                            Some(v) => serde_json::to_string(&v).unwrap_or_else(|_| "null".into()),
                            None => "null".into(),
                        })
                    })?,
                )?;
            }
            // 便捷读取：省得插件每次 JSON.parse
            {
                let d = cfg_dir.clone();
                let p = cfg_pid.clone();
                config.set(
                    "getBool",
                    Function::new(ctx.clone(), move |key: String, def: bool| {
                        config_read(&d, &p, &key)
                            .and_then(|v| v.as_bool())
                            .unwrap_or(def)
                    })?,
                )?;
            }
            {
                let d = cfg_dir.clone();
                let p = cfg_pid.clone();
                config.set(
                    "getNumber",
                    Function::new(ctx.clone(), move |key: String, def: f64| {
                        config_read(&d, &p, &key)
                            .and_then(|v| v.as_f64())
                            .unwrap_or(def)
                    })?,
                )?;
            }
            {
                let d = cfg_dir.clone();
                let p = cfg_pid.clone();
                config.set(
                    "getString",
                    Function::new(ctx.clone(), move |key: String, def: String| {
                        config_read(&d, &p, &key)
                            .and_then(|v| v.as_str().map(String::from))
                            .unwrap_or(def)
                    })?,
                )?;
            }
            {
                // 一次拿全部（插件想问"用户到底配了什么"时用）
                let d = cfg_dir.clone();
                let p = cfg_pid.clone();
                config.set(
                    "all",
                    Function::new(ctx.clone(), move || -> rquickjs::Result<String> {
                        let map = store_load(&d, &p);
                        let mut out = serde_json::Map::new();
                        for (k, v) in map {
                            if let Some(real) = k.strip_prefix(CONFIG_PREFIX) {
                                out.insert(real.to_string(), v);
                            }
                        }
                        Ok(serde_json::to_string(&out).unwrap_or_else(|_| "{}".into()))
                    })?,
                )?;
            }
            g.set("host_config", config)?;

            // host.log
            let log = Object::new(ctx.clone())?;
            let pid = plugin_id.clone();
            for level in ["debug", "info", "warn", "error"] {
                let pid2 = pid.clone();
                let lv = level.to_string();
                log.set(
                    level,
                    Function::new(ctx.clone(), move |msg: String| {
                        match lv.as_str() {
                            "error" => log::error!("[plugin:{pid2}] {msg}"),
                            "warn" => log::warn!("[plugin:{pid2}] {msg}"),
                            "debug" => log::debug!("[plugin:{pid2}] {msg}"),
                            _ => log::info!("[plugin:{pid2}] {msg}"),
                        }
                    })?,
                )?;
            }
            g.set("host_log", log)?;

            /*
             * 组装成契约里的 `host` 对象
             *
             * ⚠️ 这里**必须把 options 透传下去**。
             * 第一版写的是 `get: (u, o) => host_http.get(u)` ——
             * 把第二个参数（headers）**丢掉了**，
             * 于是插件的 `Referer` 从来没发出去过（某电视台接口要它）。
             * 这种 bug 不报错、只是偶尔拿到错误页，极难查。
             */
            // task-37: expose the picked host as a global the shim can close over
            let _ = g.set("host_base_value", base_for_http.clone());

            ctx.eval::<(), _>(
                r#"
                globalThis.host = {
                  /*
                   * task-37: which host to use for multi-domain pools.
                   *
                   * Defined here (not on the pre-shim host_obj) because this
                   * literal OVERWRITES globalThis.host wholesale -- anything set
                   * earlier is lost. That was a real bug: base() was injected at
                   * 1060 but wiped here, so plugins got "not a function".
                   */
                  base: () => host_base_value,
                  http: {
                    get: (url, options) => host_http.get(url, (options && options.headers) || null),
                    post: (url, body, options) => host_http.post(
                      url,
                      typeof body === 'string' ? body : JSON.stringify(body ?? null),
                      (options && options.headers) || null,
                    ),
                    /*
                     * ★★ 带**响应头**的请求（2026-09-20 新增，为扫码登录）
                     *
                     * 返回 **JSON 文本**（与 host.config.get 一致的做法：
                     * QuickJS 里跨边界传对象不如传字符串稳），插件要
                     * 自己 JSON.parse：
                     *
                     *   const r = JSON.parse(await host.http.raw('GET', url, { headers }))
                     *   // r = { status, body, setCookie: [...] }
                     *
                     * ⚠️ `setCookie` 是数组 —— Cookie 的 Expires 里含逗号，
                     *    拼成一个串再切分会有歧义。
                     */
                    raw: (method, url, options) => host_http.raw(
                      method,
                      url,
                      (options && options.headers) || null,
                    ),
                  },
                  log: host_log,
                  /*
                   * task-41: 通用提取器（不含任何站点知识）
                   *
                   *   host.extract.regex(text, pattern)  -> string[]
                   *   host.extract.json(text, path)      -> JSON 文本或 'null'
                   */
                  extract: host_extract,

                  /*
                   * task-41 第 2 步：探测播放地址
                   *
                   *   const r = JSON.parse(await host.playback.probe(url))
                   *   // r = { verdict, kind, contentType, message, retryable }
                   *
                   * verdict 四种取值互不混淆：
                   *   playable / dash_unsupported / drm / unreachable
                   */
                  playback: host_playback,
                  store: host_store,
                  /*
                   * ★ 用户配置（插件声明 → 宿主渲染界面 → 用户填 → 这里读）
                   *
                   * `get(k)` 返回 **JSON 文本或 'null'**（因为值类型不定），
                   * 所以优先用下面三个便捷方法，它们已经处理好默认值：
                   *
                   *   host.config.getBool('proxy', false)
                   *   host.config.getNumber('quality', 720)
                   *   host.config.getString('proxyUrl', '')
                   */
                  config: {
                    get: (k) => host_config.get(k),
                    getBool: (k, d) => host_config.getBool(k, d),
                    getNumber: (k, d) => host_config.getNumber(k, d),
                    getString: (k, d) => host_config.getString(k, d),
                    all: () => host_config.all(),
                  },
                  util: {
                    urlEncode: (s) => encodeURIComponent(String(s)),
                    urlDecode: (s) => decodeURIComponent(String(s)),
                    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
                  },
                };
                "#,
            )?;
            Ok::<_, rquickjs::Error>(())
        })
        .await
        .map_err(|e| ProviderError::new(ErrorKind::Other, format!("注入 host API 失败: {e}")))?;

        // 执行插件脚本 + 调用目标方法
        let source = self.source.clone();
        let expr = expr.to_string();
        let out = async_with!(ctx => |ctx| {
            /*
             * 1) 加载插件本体
             *
             * ⚠️ **必须在单独的一步里做，且失败要能与其他错误区分开**。
             *
             * 实测踩到（编辑插件保存时）：语法错误（如括号不配对）
             * 会让 `eval` 抛 QuickJS 自身的异常 —— 而下游的错误分类
             * 把「QuickJS 异常」一律当成**中断超时**，
             * 于是用户看到「保存失败：插件执行超时（超过 10000 ms）」，
             * 完全看不出是**语法写错了**。
             *
             * 所以这里先求值一次；失败就直接返回 `SyntaxError`，
             * 不进下面的 Promise 流程。
             */
            match ctx.eval::<(), _>(source.as_str()) {
                Ok(()) => {}
                Err(_) => {
                    // 取回真实错误消息（rquickjs 的 Error 不带消息）
                    let msg = ctx
                        .catch()
                        .as_exception()
                        .and_then(|e| e.message())
                        .unwrap_or_else(|| "语法错误".to_string());
                    return Err(rquickjs::Error::new_from_js_message(
                        "SyntaxError",
                        "plugin",
                        msg,
                    ));
                }
            }

            /*
             * 2) 调方法并等 Promise
             *
             * ★ 关键：在 **JS 侧**把异常转成带标记的返回值，
             * 而不是让异常穿透到 Rust。
             *
             * 为什么：rquickjs 把 JS 抛的错统一变成 `Error::Exception`，
             * **消息体丢失**（实测只拿到字符串 "Exception"）——
             * 那样 `map_js_error()` 完全没法按前缀分类，
             * 用户也看不到「插件到底为什么失败」。
             *
             * 这里 catch 住真实消息再带出来。
             */
            let code = format!(
                r#"(async () => {{
                    try {{
                        const r = await {expr};
                        return JSON.stringify({{ ok: true, data: r ?? null }});
                    }} catch (e) {{
                        const msg = (e && e.message) ? e.message : String(e);
                        return JSON.stringify({{ ok: false, error: msg }});
                    }}
                }})()"#
            );
            let p: Promise = ctx.eval(code.as_str())?;
            p.into_future::<String>().await
        })
        .await;

        let raw = match out {
            Ok(s) => s,
            Err(e) => {
                /*
                 * 走到这里有三类原因，**必须分开报**（实测都踩过）：
                 *
                 * 1. **语法错误** —— 脚本求值就失败了（括号不配对等）。
                 *    我们上面主动包成了 `SyntaxError`，`{e}` 里带真实消息。
                 *    ⚠️ 不区分的话会被误报成「执行超时」，
                 *    用户去查超时原因，永远查不到（其实是写错了）。
                 *
                 * 2. **执行超时** —— QuickJS 被中断处理器掐断，
                 *    抛的是 `Exception generated by QuickJS`，
                 *    消息里**没有** "interrupted" 字样，
                 *    第一版按 `contains("interrupted")` 判断导致误报。
                 *
                 * 3. **其他加载失败** —— 如 host API 注入失败。
                 *
                 * 判据顺序很重要：先看语法错误的前缀，再看 `is_exception()`。
                 */
                let msg = format!("{e}");

                return Err(if msg.contains("SyntaxError") {
                    /*
                     * 从 rquickjs 的包装里取出**真正的 JS 报错**。
                     *
                     * 原始消息形如：
                     * ```
                     * Error converting from js 'SyntaxError' into type 'plugin':
                     * Unexpected token 'const'
                     * ```
                     * 冒号**之后**那段才是用户要看的。
                     * 前面那段是 rquickjs 的内部细节，对用户毫无意义
                     * （而且会让人以为是插件的什么 "plugin" 类型出了问题）。
                     */
                    let detail = msg
                        .rsplit_once(':')
                        .map(|(_, rest)| rest.trim())
                        .filter(|s| !s.is_empty())
                        .unwrap_or(msg.as_str());
                    ProviderError::new(
                        ErrorKind::Parse,
                        format!("语法错误，未保存：{detail}"),
                    )
                } else if e.is_exception() {
                    ProviderError::new(
                        ErrorKind::Other,
                        format!("插件执行超时（超过 {SCRIPT_BUDGET_MS} ms 被强制终止）"),
                    )
                } else {
                    ProviderError::new(ErrorKind::Other, format!("插件加载失败: {msg}"))
                });
            }
        };

        // 拆开 JS 侧包的 { ok, data } / { ok, error }
        let wrapped: serde_json::Value = serde_json::from_str(&raw)
            .map_err(|e| ProviderError::parse(format!("插件返回值无法解析: {e}")))?;

        if wrapped.get("ok").and_then(|b| b.as_bool()) != Some(true) {
            let msg = wrapped
                .get("error")
                .and_then(|s| s.as_str())
                .unwrap_or("插件未返回错误信息");
            return Err(map_js_error(msg));
        }

        let data = wrapped
            .get("data")
            .cloned()
            .unwrap_or(serde_json::Value::Null);

        // ★ 命名风格 + headers 形态转换（见模块顶部说明）
        let mut rust = js_value_to_rust(data);

        // ★ 给插件返回的条目补上 provider 前缀
        //
        // 契约承诺「插件只写自己的 id，宿主自动加前缀」——
        // 插件作者不该关心 `MediaId` 是 `"srcl:xxx"` 这种形态。
        self.prefix_media_ids(&mut rust);

        serde_json::to_string(&rust)
            .map_err(|e| ProviderError::parse(format!("转换返回值失败: {e}")))
    }

    /// 递归给 `id` 字段补上 `"{provider}:"` 前缀
    ///
    /// 只处理**形如媒体条目**的对象（含 `id` 且同时有 `title`），
    /// 避免误伤 `Section.id` / `PlaySource.code` 这类普通标识 ——
    /// 它们只是字符串，不是 `MediaId`。
    ///
    /// 已经带前缀的不重复加（插件可能自己拼了，或数据来自往返）。
    fn prefix_media_ids(&self, v: &mut serde_json::Value) {
        let prefix = format!("{}:", self.manifest.id);

        match v {
            serde_json::Value::Object(map) => {
                /*
                 * ★ 只给**媒体条目**加前缀，不能误伤剧集（实测踩到）
                 *
                 * `MediaItem` 的特征是「有 `id`，且有 `title`/`cover`」。
                 * 但 `Episode` 也长这样 —— `{id, title, order}` ——
                 * 于是剧集 id 被加了前缀变成 `srca:51463`，
                 * 前端把它放进 `PlayRequest.episode_id` 传回来，
                 * 插件拿它当数字 id 用 → 服务端报
                 * `bind uri "section_id": parsing "srca:51463": invalid syntax`
                 * （Owner 实测报的错）。
                 *
                 * 判据：`Episode` **一定带 `order`**（契约里是必填），
                 * 而 `MediaItem` 没有这个字段。所以见到 `order` 就跳过。
                 *
                 * 另一条判据：`PlaySource` 有 `code`/`count`，
                 * `Section` 有 `source` —— 都不该加前缀，也一并排除。
                 */
                let is_episode = map.contains_key("order");
                let is_source = map.contains_key("code") && map.contains_key("count");
                let is_section = map.contains_key("source");

                let looks_like_item = !is_episode
                    && !is_source
                    && !is_section
                    && map.contains_key("id")
                    && (map.contains_key("title") || map.contains_key("cover"));

                if looks_like_item {
                    if let Some(serde_json::Value::String(id)) = map.get_mut("id") {
                        /*
                         * ★★ 判据必须是「有没有**本插件的**前缀」，而不是「含不含冒号」
                         *
                         * # 这是一个真 bug（Owner 报「某视频站的这些点开，显示没有路由」）
                         *
                         * 原实现是 `if !id.contains(':')` —— 本意是"已带前缀的不重复加"，
                         * 但**冒号不等于前缀**：
                         *
                         * ```text
                         * 插件返回 id = "av:BV1u9ew6yEEP"      ← 外部视频站插件的内部命名空间
                         * contains(':') == true
                         *   → 判定"已有前缀"，跳过
                         *   → 前端拿到 "av:BV1u9ew6yEEP"
                         *   → splitKey 切第一个冒号 → provider = "av"
                         *   → 后端 route("av") 找不到 → 「无法路由: av:BV1u9ew6yEEP」
                         * ```
                         *
                         * 对照：某电视台插件返回 `1f6ed843…`（不含冒号）→ 正常加上 `srcl:`
                         * 前缀 → 一直正常。**所以只有 外部视频站坏，而且坏得很隐蔽。**
                         *
                         * # 为什么"含冒号"这个判据根本不成立
                         *
                         * 插件的 id **允许含冒号**（契约里只要求非空字符串）。
                         * 用"含冒号"去猜"有没有加过前缀"，等于要求插件作者
                         * **永远不要在 id 里用冒号** —— 而这条约束从来没写进契约，
                         * 插件作者也不可能知道。
                         *
                         * 正解：直接比对**本插件的前缀**。这也是幂等的 ——
                         * 无论调多少次都不会重复加。
                         */
                        if !id.starts_with(&prefix) {
                            *id = format!("{prefix}{id}");
                        }
                    }
                }

                for (_, child) in map.iter_mut() {
                    self.prefix_media_ids(child);
                }
            }
            serde_json::Value::Array(arr) => {
                for child in arr.iter_mut() {
                    self.prefix_media_ids(child);
                }
            }
            _ => {}
        }
    }
}

/// 把 JS 异常映射成 `ProviderError`
///
/// 插件按契约用前缀声明错误类型（见 `docs/PLUGINS.md`）：
/// `unauthorized:` / `not_found:` / `unsupported:` / `network:` / `parse:`
///
/// # ★★★ 为什么「前缀优先」，而不是按顺序 if-else 混着判
///
/// # 实测踩到的真 bug（2026-10-17）
///
/// 改前是「裸关键词与前缀混在一条 if-else 链里」，且顺序是：
/// ```text
/// unauthorized / 401  →  not_found / 404  →  unsupported  →  network / timeout
/// ```
/// 看起来没问题，但**前缀与消息正文会互相抢**：
/// ```text
/// 插件抛：parse: 返回不是合法 JSON — <html><title>404 Not Found</title>
///                     ↑ 正文里带 404
/// ⇒ 先命中的是 `404` 那一支 ⇒ 判成 NotFound（**错的，应该是 Parse**）
/// ```
/// 而这恰恰是 `parse:` 最典型的触发场景：**上游返回 404/风控 HTML 页**，
/// 插件 `JSON.parse` 失败 ⇒ 抛 `parse:` 并把响应片段带进消息。
/// 同类还有：登录页返回 401、限流文案里带 timeout 等。
///
/// ⇒ 结论：**显式前缀是权威声明，必须先判**；裸关键词（401/404/timeout）
///    只是给「没按契约写前缀的老插件」兜底的启发式，**只能在后**。
///
/// ⚠️ 别把这条改成「把 404 删掉」—— 老插件确实会裸抛 `HTTP 404`，
///    删了它们的错误种类就全退化成 Other。
fn map_js_error(msg: &str) -> ProviderError {
    let lower = msg.to_lowercase();
    /*
     * 容忍前缀被「包裹」的写法：前导空白、反引号、引号。
     *
     * 典型来源是插件作者在错误消息里**引用**前缀，或从模板字符串拼出来
     * 时把定界符一起带进了消息。真实等价消息本身不该有这些字符，
     * 所以只 trim **前导标点**、不改消息本体。
     *
     * ⚠️ 只剥前导、且只剥标点 —— 不剥数字/字母，
     *    否则 `404: xxx` 这种前缀形态会被自己吃掉。
     */
    let t = lower.trim_start_matches(|c: char| {
        c.is_whitespace() || c == '`' || c == '"' || c == '\''
    });

    /*
     * ── ① 显式前缀（权威）────────────────────────────────────
     *
     * ⚠️ `unauthorized` 这一支**故意返回固定文案**（不带 msg）——
     *    与改前逐字一致：登录失败时插件常把 token 片段带进消息，
     *    原样透出可能泄露凭据，也不便用户阅读。
     */
    if t.starts_with("unauthorized:") || t.starts_with("401:") {
        return ProviderError::unauthorized("需要登录或登录已失效");
    }
    if t.starts_with("not_found:") || t.starts_with("404:") {
        return ProviderError::new(ErrorKind::NotFound, msg.to_string());
    }
    if t.starts_with("unsupported:") {
        return ProviderError::unsupported(msg.to_string());
    }
    if t.starts_with("network:") {
        return ProviderError::network(msg.to_string());
    }
    /*
     * ★★★ 本支是本次修的缺口（task：map_js_error 漏了 parse）
     *
     * 改前没有这一支 ⇒ `parse: xxx` 落到最后的 else，变成
     * `Other` + 多一层 `插件报错: ` 包装：
     * ```text
     * 用户看到：「插件报错: parse: 找不到该条目…」
     * 前端按 ErrorKind 分支的逻辑（如「上游改版」提示）全部失效
     * ```
     * ⚠️ 消息**原样透出、不加任何包装**：前缀本身就是给用户看的语义，
     *    再包一层只会让排错更难（本仓「错误必须原文透出」的纪律）。
     */
    if t.starts_with("parse:") {
        return ProviderError::parse(msg.to_string());
    }

    /*
     * ── ② 裸关键词兜底（老插件没写前缀时的启发式）──────────────
     *
     * ⚠️ 必须在前缀之后 —— 否则正文里的 `404` / `401` / `timeout`
     *    会抢走带前缀消息的判定（见函数头的实测 bug）。
     */
    if lower.contains("unauthorized") || lower.contains("401") {
        ProviderError::unauthorized("需要登录或登录已失效")
    } else if lower.contains("not_found") || lower.contains("404") {
        ProviderError::new(ErrorKind::NotFound, msg.to_string())
    } else if lower.contains("unsupported") {
        ProviderError::unsupported(msg.to_string())
    } else if lower.contains("network") || lower.contains("timeout") {
        ProviderError::network(msg.to_string())
    } else {
        /*
         * ★★★ 不再加 `插件报错: ` 前缀（Owner 第 7 条，2026-10-17）
         *
         * # Owner 原话
         * ```text
         * > 像图2 那种报错的信息,就不要加上溯影自己的信息了,
         * > 就只显示插件的报错信息就足够了
         * ```
         *
         * # 改前用户看到
         * ```text
         * SourinCoreException(other): 插件报错: 该内容需要大会员
         * ```
         * 前缀「插件报错:」是**宿主自己加的**，对用户无信息量 ——
         * 用户只想知道「为什么不能播」，不需要知道「这是插件报的」。
         *
         * # 改后
         * ```text
         * 该内容需要大会员
         * ```
         * ⚠️ 消息**原样透出**。这也与本文件上方 `parse:` 那一支的纪律一致
         *    （那里早就写着「消息原样透出、不加任何包装」）。
         */
        ProviderError::new(ErrorKind::Other, msg.to_string())
    }
}

/// raw-deflate 回退（仅在 `r.text()` 解码失败时调用）
///
/// # 它解决什么
/// ```text
/// 某些站返回 `Content-Encoding: deflate`，但是 **raw-deflate**（无 zlib 头），
/// 而 reqwest 的 `deflate` 特性按 **zlib** 格式解
/// ⇒ `r.text().await` 报 `error decoding response body`
/// ⇒ 插件拿不到任何数据。
/// ```
///
/// # 为什么要重发一次请求
/// ```text
/// `r.text()` 会**消耗** response（`take self`），失败后拿不到原始字节
/// ⇒ 只能重发。这个回退只在"正常解压失败"时才走，
///   正常站**一次都不会**重发 ⇒ 零回归风险。
/// ```
///
/// # 返回值
/// ```text
/// Some(文本) ⇒ 回退成功（已按原状态码包好前缀）
/// None       ⇒ 回退也不行（调用方保留原错误）
/// ```
async fn try_raw_deflate_fallback(
    proxy: &Option<Arc<crate::proxy::ProxyStore>>,
    provider: &str,
    method: &str,
    url: &str,
    headers: &HashMap<String, String>,
    body: Option<&str>,
    status: &reqwest::StatusCode,
) -> Option<String> {
    /*
     * ★★★ 2026-10-21（CodeRabbit PR#32 ①）：不能再从零新建 client
     *
     * # 旧实现漏了什么（用户可见后果）
     * ```text
     * 旧：let raw_client = reqwest::Client::builder().no_gzip()… .build()
     *     ⇒ 这个 client **没有** 任何代理配置
     *
     *   1. 用户给这个源配了自定义代理（ProxyStore::client_for 配的）
     *      ⇒ 回退请求走**直连**
     *      ⇒ 轻则回退失败（那台站必须靠代理才通）
     *      ⇒ 重则**暴露用户真实出口 IP** —— 站点看到的不是代理地址
     *   2. 丢掉了 `user_agent`
     *      ⇒ 按 UA 分流的站点把回退请求当爬虫
     *   3. 丢掉了 `client_for` 的绕过列表（bypass）
     * ```
     *
     * # 修法：同一个 `build_client`，只换「自动解压」这一个开关
     * ```text
     * `proxy.rs::client_for_ex(provider, None, AutoDecompress::Off)`
     *   ⇒ 代理/认证/绕过列表/UA/timeout **全部一致**
     *   ⇒ 唯一差别是三个 no_gzip/no_deflate/no_brotli
     * ```
     *
     * # 为什么**不能**直接复用调用方传进来的 `client`
     * ```text
     * 那个 client 是自动解压的 ⇒ `r.bytes()` 重踩同一个解压坑
     * ⇒ 回退形同虚设（这正是 2026-10-18 二次实测那段注释写的事）
     * ```
     *
     * # 无代理时也不能裸建
     * ```text
     * `default_client()` 有统一的 timeout + UA；
     * 旧代码里的裸 builder 连 UA 都没有。
     * ⇒ 无代理路径改为「default_client 的配置 + 关自动解压」。
     * ```
     */
    let raw_client = match proxy {
        Some(px) => px
            .client_for_ex(provider, None, crate::proxy::AutoDecompress::Off)
            // 代理配置坏了也不该把回退整个吞掉：退回"无代理但关解压"的客户端，
            // 至少行为与修复前一致（旧代码本来就没代理），不会更差。
            .unwrap_or_else(|_| raw_decompress_off_client()),
        None => raw_decompress_off_client(),
    };
    let req = if method == "POST" {
        raw_client.post(url)
    } else {
        raw_client.get(url)
    };
    let mut req = req;
    for (k, v) in headers {
        // ★ 不发 Accept-Encoding：让服务端按它自己的意愿给（有的站强制压缩）
        if k.eq_ignore_ascii_case("accept-encoding") {
            continue;
        }
        req = req.header(k, v);
    }
    if let Some(b) = body {
        req = req.body(b.to_string());
    }
    let r = req.send().await.ok()?;
    // ★ 只对 deflate 响应做回退；别的编码交给上层报错
    let enc = r
        .headers()
        .get(reqwest::header::CONTENT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !enc.contains("deflate") {
        return None;
    }
    let bytes = r.bytes().await.ok()?;
    /*
     * ★★★ 依次尝试三种格式（2026-10-18 二次修复）
     *
     * # 为什么不是只试 raw-deflate
     * ```text
     * 本站实测：声明 `Content-Encoding: deflate`，内容确实是 raw-deflate。
     * 但「声明 deflate、内容却是 zlib 或 gzip」在 HTTP 世界里**真实存在**
     * （某些反代的压缩配置与响应头不同步）。
     *
     * 只试 raw-deflate 的话，那种站会**静默失败**：
     *   解不开 ⇒ return None ⇒ 保留原错误 ⇒ 用户看不到数据，日志也只是原错误。
     * ⇒ 成本极低（三次尝试都在内存里），收益是把"名不副实"也覆盖掉。
     * ```
     *
     * # 顺序有讲究
     * ```text
     * raw-deflate 在前：本站实测就是它（最常见的情况优先，少走一次尝试）
     * zlib        其次：deflate 的标准封装（带 2 字节头）
     * gzip        最后：名不副实的兜底
     * ```
     *
     * ★ 三种都失败 ⇒ 返回 None，**保留调用方的原始错误**（不编造新错误）。
     */
    use std::io::Read as _;
    let mut out = String::new();
    let ok = flate2::read::DeflateDecoder::new(&bytes[..])
        .read_to_string(&mut out)
        .is_ok()
        || {
            out.clear();
            flate2::read::ZlibDecoder::new(&bytes[..])
                .read_to_string(&mut out)
                .is_ok()
        }
        || {
            out.clear();
            flate2::read::GzDecoder::new(&bytes[..])
                .read_to_string(&mut out)
                .is_ok()
        };
    if !ok {
        return None;
    }
    if status.is_success() {
        Some(out)
    } else {
        Some(format!(
            "__ERR__HTTP {status}: {}",
            out.chars().take(200).collect::<String>()
        ))
    }
}

/// 仅供集成测试调用 `do_http` 的转发出口（`do_http` 本身是私有的）
///
/// # 为什么需要它
/// ```text
/// `do_http` 是模块私有 —— 这**是对的**（插件只能通过 `host.http` 走到它）。
/// 但 CodeRabbit PR#32 ② 的判据必须是「服务端 accept 了几次」，
/// 那需要一个**从外部**驱动一次真 HTTP 往返的入口。
///
/// 替代方案都更差：
///   · 把 `do_http` 改成 `pub` ⇒ 扩大公开面，为测试改产品 API
///   · 走完整插件链路（起 QuickJS + 装插件）⇒ 慢、且与 HTTP 层无关
/// ⇒ 一个 `#[doc(hidden)]` 的薄转发，公开面最小。
/// ```
#[doc(hidden)]
pub async fn do_http_for_test(
    proxy: &Option<Arc<crate::proxy::ProxyStore>>,
    provider: &str,
    method: &str,
    url: &str,
    headers: &HashMap<String, String>,
    body: Option<String>,
) -> String {
    do_http(proxy, provider, method, url, headers, body).await
}

/// `r.text()` 的失败**是不是真的解压/解码失败**（决定要不要回退重发）
///
/// # ★★★ 为什么不能用 `e.is_decode()` —— 实测推翻了 CodeRabbit 的建议
///
/// ```text
/// CodeRabbit PR#32 ② 的修法：「只在 e.is_decode() 时进入回退」。
/// 实测（2026-10-21，本机真 TcpListener 四种场景）：
///
///   场景                               is_decode  is_timeout
///   ────────────────────────────────────────────────────────
///   A 读 body 超时（头已到，body 没来）   **true**    true
///   B 连接中途断开（Content-Length 不够） **true**    false
///   C 完整 raw-deflate（真解压失败）      **true**    false
///   D raw-deflate 被截断（解压中途失败）  **true**    false
///
/// ⇒ 四种**全部** is_decode = true
/// ⇒ 照 CR 的原话改，A/B 照样回退重发 ⇒ **修不掉**。
/// ```
///
/// # 那靠什么区分
///
/// ```text
/// reqwest 把真实原因藏在 `source()` 链的第 2 层：
///
///   A  ... → "operation timed out"
///   B  ... → "error reading a body from connection"
///   C  ... → "deflate decompression error"     ← 只有这个该回退
///   D  ... → "deflate decompression error"     ← 同上
///
/// ⇒ 判据：**source 链里出现解压失败的标志文本**才回退。
/// ```
///
/// # 为什么不判「不是超时/不是连接错误」而是要「是解压错误」
///
/// ```text
/// 白名单比黑名单安全：将来 reqwest 新增一类 body 错误（如 HTTP/3 流中断），
/// 黑名单会漏掉它 ⇒ 又变成"未知错误也重发"。
/// 白名单下未知错误一律不回退 ⇒ 最坏是少一次回退（退回原错误），
/// 而不是多一次重发（用户可见事故）。
/// ```
fn is_real_decompress_failure(e: &reqwest::Error) -> bool {
    /*
     * ① 先排除超时：即使 source 链里恰好也有解压字样，
     *    超时说明**请求已经到达服务端**，重发就是执行两次。
     */
    if e.is_timeout() {
        return false;
    }

    /*
     * ② 走 source 链，找解压失败的标志。
     *
     * flate2 / reqwest 的原文是 "deflate decompression error"
     * （也可能带 gzip/brotli 字样）。这里只认「decompress」这个根。
     */
    use std::error::Error as _;
    let mut src: Option<&(dyn std::error::Error + 'static)> = e.source();
    while let Some(s) = src {
        let msg = s.to_string();
        let lower = msg.to_ascii_lowercase();
        if lower.contains("decompress")
            || lower.contains("deflate")
            || lower.contains("gzip")
            || lower.contains("brotli")
            || lower.contains("zlib")
        {
            return true;
        }
        src = s.source();
    }

    false
}

/// 插件 HTTP 请求（走站点代理配置）
///
/// 返回**响应文本**，失败返回 `__ERR__<原因>` 前缀串。
/// ⚠️ 为什么不用 `Result`（让 JS 侧 throw）：
/// rquickjs 抛出的异常在 Rust 侧只剩 `Error::Exception`（消息丢失），
/// 所以错误信息走返回值这条通道，由插件的 `getJson` 判断前缀再抛。
async fn do_http(
    proxy: &Option<Arc<crate::proxy::ProxyStore>>,
    provider: &str,
    method: &str,
    url: &str,
    headers: &HashMap<String, String>,
    body: Option<String>,
) -> String {
    /*
     * ★★★ 2026-10-17（Owner 实测报障）：`client_for` 的 provider 参数
     * 原来硬编码成字面量 `"plugin"`，导致**用户给某个源配的代理永远读不到**。
     *
     * # 为什么这是真缺陷（不是理论问题）
     * ```text
     * UI 侧：proxy_panel.dart 用 widget.providerId（真实插件 id）存配置
     *        → SourinApi.setProxyConfig(id, cfg) → Rust 按 id 存进 ProxyStore
     * 插件侧：client_for("plugin") 查的是 "plugin" 这个 key
     *        → 查不到 ⇒ 返回 ProxyConfig::default() ⇒ mode=Direct ⇒ 强制直连
     * ⇒ 用户配了代理 = 白配；用户配了直连 = 恰好蒙对
     * ```
     *
     * 实测依据（Owner 原话「某动画站（代号 S0）是不能挂梯子，必须直接访问，不然就是会 403」）：
     *   同一 URL，直连 200 / 走代理 403。
     *   而本机开着 HTTP_PROXY=127.0.0.1:7890，
     *   若某源被误配成跟随系统，用户看到的就是 403 —— 但 UI 上他明明配过直连。
     *
     * ⇒ 必须把真实 provider id 传进来，让「按源配置」真的生效。
     */
    let client = match proxy {
        Some(px) => px
            .client_for(provider, None)
            .unwrap_or_else(|_| default_client()),
        None => default_client(),
    };

    let mut req = if method == "POST" {
        client.post(url)
    } else {
        client.get(url)
    };

    /*
     * ★ POST 且调用方没指定 Content-Type 时，默认 `application/json`
     *
     * 实测踩过：reqwest 的 `.body(String)` 默认发 `text/plain`，
     * 而几乎所有 JSON 接口（某动画站、苹果 CMS 系）都要求
     * `application/json` —— 服务端会报
     * `Username is a required field` 这种**看起来像参数没传**的错误，
     * 实际是 body 根本没被解析。这类问题极难从报错里看出来。
     *
     * 调用方显式给了 Content-Type 就尊重它（有站点要 form-urlencoded）。
     */
    let has_ct = headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("content-type"));
    if method == "POST" && !has_ct {
        req = req.header("Content-Type", "application/json");
    }
    for (k, v) in headers {
        req = req.header(k, v);
    }
    /*
     * ★ 2026-10-18：`body` 用 `as_deref()` 而不是 move。
     *
     * 原来写 `if let Some(b) = body { req = req.body(b); }` ——
     * 那会**部分移动** `body` ⇒ 下面 raw-deflate 回退里
     * `body.as_deref()` 变成「借用已移动的值」⇒ E0382 编译不过。
     *
     * 改成 `as_deref()`（只借不拿）+ `to_string()`（克隆一份给 reqwest）
     * ⇒ body 保持可用，回退还发一次同样的请求体。
     * 代价：多一次 String 克隆 —— 请求体本来就不大（插件侧 JSON），可接受。
     */
    if let Some(b) = body.as_deref() {
        req = req.body(b.to_string());
    }

    match req.send().await {
        Ok(r) => {
            let status = r.status();
            /*
             * ★★★ 2026-10-18（E2E 验证发现）：**raw-deflate 回退**
             *
             * # 真实缺陷
             * ```text
             * 某些站的弹幕接口返回 `Content-Encoding: deflate`，
             * 但它是 **raw-deflate**（无 zlib 头），
             * 而 reqwest 的 `deflate` 特性按 **zlib** 格式解
             * ⇒ `r.text().await` 报 `error decoding response body`
             * ⇒ 插件拿不到任何数据，整个弹幕功能失效。
             * ```
             *
             * # 实测证据
             * ```text
             * 同一接口两个不同 id 都是这样（不是偶发）：
             *   前 2 字节 ecfd / bcfd ⇒ zlib 解压 False，raw 解压 True
             * ⇒ 这是**该接口的固定行为**，不是数据傏坏
             * ```
             *
             * # 为什么是「回退」而不是「直接关掉自动解压」
             * ```text
             * 关掉自动解压 ⇒ 影响**所有插件**（gzip/brotli/deflate 全要插件自己处理）
             * 而回退只在"正常解压失败"时才走第二次
             * ⇒ 正常站一个字节都不受影响（零回归风险）
             * ```
             *
             * # ⚠️ 只在 `r.text()` 失败时才重发，不预先读 body
             * ```text
             * `r.text()` 会消耗 response（take self）
             * ⇒ 必须先 `r.bytes()` 拿到原始字节，再自己解压
             * ⇒ 所以本实现是：正常路径照旧 `text()`，
             *   失败后重发一次并用 bytes() + 手动 raw-inflate
             * ```
             */
            match r.text().await {
                Ok(t) => {
                    if status.is_success() {
                        t
                    } else {
                        // 把 HTTP 状态带出去，插件可据此判断 401/404 并抛对应的前缀错误
                        format!("__ERR__HTTP {status}: {}", t.chars().take(200).collect::<String>())
                    }
                }
                Err(e) => {
                    /*
                     * ★★★ 2026-10-21（CodeRabbit PR#32 ②）：**只在真解压失败时回退**
                     *
                     * ```text
                     * 改前：Err(e) 分支不区分错误类型 ⇒ 一律重发
                     * ⇒ 读 body 超时 / 连接断开也会重发
                     * ⇒ 那个 POST **已经到达服务端**，重发就是执行两次
                     *   （发弹幕 ⇒ 屏幕上出现两条）
                     * ⇒ GET 还会多等一次 HTTP_TIMEOUT_SECS ⇒ 失败延迟最长 30s
                     * ```
                     *
                     * 判据见 [`is_real_decompress_failure`] ——
                     * **不能用 `e.is_decode()`**，实测四种失败全是 true。
                     */
                    if !is_real_decompress_failure(&e) {
                        return format!("__ERR__读取响应失败: {e}");
                    }

                    // ★ 回退：重发一次，自己拿原始字节并按 raw-deflate 解
                    match try_raw_deflate_fallback(
                        proxy, provider, method, url, headers, body.as_deref(), &status,
                    )
                    .await
                    {
                        Some(t) => t,
                        None => format!("__ERR__读取响应失败: {e}"),
                    }
                }
            }
        }
        Err(e) => format!("__ERR__请求失败: {e}"),
    }
}

/// 把一次 HTTP 结果记到域名池里（task-37）
///
/// # 为什么在 `do_http` 外面记
///
/// `do_http` 是个纯函数（拿不到池），而「这一次打的是哪个域名」
/// 只有调用方知道（它刚才从 `host.base()` 拿的）。
///
/// # 失败判据
///
/// 只认 `do_http` 自己的失败语言：以 `__ERR__` 开头。
/// 不按内容猜（比如「没有 JSON」就当失败）—— 那会把
/// 正常的空列表误判成网络故障，反而把好域名记坏。
///
/// # 没用池时完全不动
///
/// `used` 为空（插件没声明 `hosts`）或池为 `None` ⇒ 直接返回。
/// task-37: persist pool state after a change.
///
/// Throttled to once per 5s (see `maybe_save_pool`). Errors are logged, never
/// propagated: a failed disk write must not break a plugin HTTP call.
fn save_hook(
    dir: &Option<std::path::PathBuf>,
    plugin_id: &str,
    pool: &Arc<std::sync::Mutex<Option<crate::hostpool::HostPool>>>,
    force: bool,
) {
    use std::sync::atomic::{AtomicU64, Ordering};
    static LAST: AtomicU64 = AtomicU64::new(0);
    let Some(dir) = dir else { return };
    let now = now_unix().max(0) as u64;
    let prev = LAST.load(Ordering::Relaxed);
    if !force && now.saturating_sub(prev) < 5 {
        return;
    }
    LAST.store(now, Ordering::Relaxed);

    // Read-modify-write: other plugins own their own entries.
    let mut all = crate::hostpool::load(dir);
    let guard = pool.lock().unwrap_or_else(|e| e.into_inner());
    let Some(p) = guard.as_ref() else { return };
    all.pools.insert(plugin_id.to_string(), p.clone());
    drop(guard);

    if let Err(e) = crate::hostpool::save(dir, &all) {
        log::warn!("host pool save failed: {e}");
    }
}

fn record_outcome(
    pool: &Arc<std::sync::Mutex<Option<crate::hostpool::HostPool>>>,
    used: &str,
    body: &str,
) -> bool {
    if used.is_empty() {
        return false;
    }
    let mut guard = pool.lock().unwrap_or_else(|e| e.into_inner());
    let Some(p) = guard.as_mut() else {
        return false;
    };
    if !p.hosts.iter().any(|h| h == used) {
        return false;
    }
    if body.starts_with("__ERR__") {
        let now = now_unix().max(0) as u64;
        let cooled = p.record_failure(used, now);
        if cooled {
            log::warn!(
                "域名池：{used} 连续失败 {} 次，进入冷却",
                crate::hostpool::COOLDOWN_AFTER_FAILURES
            );
        }
    } else {
        p.record_success(used);
    }
    true
}

/// HTTP 响应（**含响应头**）—— 给 `host.http.raw` 用
///
/// # 为什么需要它（2026-09-20，为扫码登录加）
///
/// [`do_http`] 只返回响应体，**响应头被丢掉**。
/// 而 某视频站 扫码登录成功时，凭据是通过 **`Set-Cookie` 响应头**下发的：
/// ```text
/// POST/GET passport.example-v.com/x/passport-login/web/qrcode/poll
///   ← Set-Cookie: SESSDATA=…; bili_jct=…; DedeUserID=…
/// ```
/// 那些值**不在 body 里** —— 所以光有 `do_http` 读不到登录态。
///
/// ⚠️ `set_cookie` 必须是**数组**，不能拼成一个字符串 ——
///    Cookie 的 `Expires` 属性里含逗号（`Expires=Wed, 21 Oct…`），
///    拼接后再按逗号切分会产生歧义。reqwest 的 `get_all` 已经帮我们
///    按正确的边界切好了。
pub struct HttpFull {
    pub status: u16,
    pub body: String,
    /// 每一条 `Set-Cookie`（原样，未解析）
    pub set_cookie: Vec<String>,
}

/// 与 [`do_http`] 相同，但**保留响应头**
pub async fn do_http_full(
    proxy: &Option<Arc<crate::proxy::ProxyStore>>,
    provider: &str,
    method: &str,
    url: &str,
    headers: &HashMap<String, String>,
    body: Option<String>,
) -> HttpFull {
    let client = match proxy {
        Some(px) => px
            .client_for(provider, None)
            .unwrap_or_else(|_| default_client()),
        None => default_client(),
    };

    let mut req = if method.eq_ignore_ascii_case("POST") {
        client.post(url)
    } else {
        client.get(url)
    };

    let has_ct = headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("content-type"));
    if method.eq_ignore_ascii_case("POST") && !has_ct {
        req = req.header("Content-Type", "application/json");
    }
    for (k, v) in headers {
        req = req.header(k, v);
    }
    if let Some(b) = body {
        req = req.body(b);
    }

    match req.send().await {
        Ok(r) => {
            let status = r.status().as_u16();
            /*
             * ⚠️ 必须在 `.text()` **之前**取头 —— `text()` 会消费响应。
             */
            let set_cookie: Vec<String> = r
                .headers()
                .get_all(reqwest::header::SET_COOKIE)
                .iter()
                .filter_map(|v| v.to_str().ok())
                .map(|s| s.to_string())
                .collect();
            let body = r.text().await.unwrap_or_default();
            HttpFull {
                status,
                body,
                set_cookie,
            }
        }
        Err(e) => HttpFull {
            status: 0,
            body: format!("__ERR__请求失败: {e}"),
            set_cookie: Vec::new(),
        },
    }
}

/// 把 `null` / `"null"` 解析成 `None`，其余解析成 `Some(Session)`
fn parse_optional_session(json: &str, what: &str) -> Result<Option<Session>> {
    if json == "null" || json.is_empty() {
        return Ok(None);
    }
    serde_json::from_str::<Session>(json)
        .map(Some)
        .map_err(|e| ProviderError::parse(format!("{what}() 返回格式不符: {e}")))
}

/// 插件私有存储的读写（`plugins/.data/<id>.json`）
///
/// 一个插件一个文件，键值都是字符串 —— 插件自己决定怎么序列化。
/// 读失败/文件损坏一律当「没有这个键」（不报错）：插件存储是**尽力而为**的，
/// 不该因为它坏了就整个插件用不了。
fn store_path(dir: &std::path::Path, plugin_id: &str) -> std::path::PathBuf {
    dir.join(format!("{plugin_id}.json"))
}

/// 读插件数据文件（**故意不取 `STORE_LOCK`**）
///
/// ⚠️ 不取锁是**有意的**，不是漏了：
/// ```text
/// ① store_write / config_write 会先调它再写回 —— 若这里也取锁，
///    就是同一把**非可重入** Mutex 的自我死锁（整个数据层永久挂住）。
/// ② 读侧的正确性由 store_write_atomic 的"临时文件 + rename"保证：
///    rename 原子 ⇒ 读到的要么旧、要么新，不会是半截。
/// ③ 读是高频路径（每次 call_js 都可能读 config）——
///    加锁会让所有插件的读串行化，纯亏。
/// ```
/// ⚠️ 坏文件 / 空文件一律兜底成**空 map**。调用方据此得到"没有凭据" ——
///    方向是**安全**的（宁可让用户重新登录，也不要拿半截数据去发请求）。
fn store_load(dir: &std::path::Path, plugin_id: &str) -> serde_json::Map<String, serde_json::Value> {
    let p = store_path(dir, plugin_id);
    std::fs::read_to_string(&p)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

// ═══════════════════════════════════════════════════════════════════
//  ★ 通用提取器（2026-10-17，task-41）
// ═══════════════════════════════════════════════════════════════════
//
// # 为什么是「通用提取」而不是「内置站点解析器」
//
// 原设想是宿主内置若干具体站点的解析器。但这与仓库三条硬约束冲突：
//
//  ① test/t98_no_site_names_test.dart —— 仓库任何可发布文本不许出现具体站名
//     （扫描 .dart / .rs / .js / .md / .yaml / .json / .toml / .sh）
//  ② Owner 口径：具体视频网站由**用户本地插件**提供，不进仓库
//  ③ task-37 的分工：插件给数据，宿主给算法，宿主不认识任何具体域名
//
// ⇒ 在 src/ 里写某个站点的接口地址，会**直接让 t98 门禁变红**。
//   也就是说：自己的门禁会挡住自己的实现 —— 这是设计正确的信号，不是障碍。
//
// # 所以这里只提供**不含任何站点知识**的通用能力
//
//   站点知识（正则、JSON 路径、签名算法、接口地址）全部留在插件里；
//   宿主只提供「按规则从文本里取值」这个**执行**能力。
//
// ⚠️ 这两个都是**纯函数**：不碰网络、不碰磁盘、不碰全局状态。
//    纯函数的边界最好测，见文件底部的单测。

/// 按正则从文本里提取匹配（task-41）
///
/// # 返回
///
///  Ok(vec)  —— 所有匹配的第 1 个捕获组（无捕获组时取整个匹配）
///  Err(msg) —— 正则本身语法错误
///
/// # 为什么「无捕获组取整个匹配」
///
/// 插件写 `regex(html, '<title>(.*?)</title>')` 时自然期望拿到标题；
/// 而写 `regex(html, 'vid=\\w+')` 时没有捕获组，
/// 这时「取整个匹配」才符合直觉。两种情况都覆盖，插件不用记两套规则。
///
/// # 为什么错误要返回 Err 而不是空数组
///
///   正则写错 ⇒ 静默返回 [] ⇒ 插件以为「页面上没有」⇒ 报「解析失败」⇒
///   用户和开发者都不知道其实是**正则语法错了**。
///   ⇒ 必须把「语法错误」和「没匹配到」分开。
fn extract_regex(text: &str, pattern: &str) -> std::result::Result<Vec<String>, String> {
    let re = regex::Regex::new(pattern).map_err(|e| format!("正则语法错误: {e}"))?;

    // 有捕获组 ⇒ 取第 1 组；没有 ⇒ 取整个匹配
    let use_group = re.captures_len() > 1;

    let mut out = Vec::new();
    for caps in re.captures_iter(text) {
        let got = if use_group {
            caps.get(1).map(|m| m.as_str())
        } else {
            caps.get(0).map(|m| m.as_str())
        };
        if let Some(s) = got {
            out.push(s.to_string());
        }
    }
    Ok(out)
}

/// 按路径从 JSON 取值（task-41）
///
/// # 路径语法（刻意做得极简）
///
///  a.b.c        对象嵌套
///  a.b[0]       数组下标
///  a[0].b[2].c  混用
///  (空)         空路径 ⇒ 返回整个文档
///
/// # 为什么不用 json pointer（RFC 6901）
///
/// json pointer 的写法是 "/a/b/0"，对**写插件的普通用户**不直观；
/// 而且它把「键名里含斜杠」搞得很麻烦（要转义成 ~1）。
/// 这里用点号+方括号，与 JS 里 `obj.a.b[0]` 的读法一致，插件作者不用学新语法。
///
/// # 返回
///
///  Ok(Some(json)) —— 取到了
///  Ok(None)       —— 路径不存在（**不是错误**，是「没有」）
///  Err(msg)       —— 路径语法错误
///
/// ⚠️ 「路径不存在」返回 None 而不是 Err：
///    解析页面时「某个字段没有」是**常态**（页面结构会变），
///    插件需要能用 `?? 默认值` 处理，不该每次都抛异常。
fn extract_json_path(
    doc: &serde_json::Value,
    path: &str,
) -> std::result::Result<Option<serde_json::Value>, String> {
    let path = path.trim();
    if path.is_empty() {
        return Ok(Some(doc.clone()));
    }

    let mut cur = doc.clone();

    // 把 a.b[0].c 切成 ["a", "b", "[0]", "c"]
    let mut tokens: Vec<String> = Vec::new();
    let mut buf = String::new();
    for ch in path.chars() {
        match ch {
            '.' => {
                if !buf.is_empty() {
                    tokens.push(std::mem::take(&mut buf));
                }
            }
            '[' => {
                if !buf.is_empty() {
                    tokens.push(std::mem::take(&mut buf));
                }
                buf.push('[');
            }
            ']' => {
                buf.push(']');
                tokens.push(std::mem::take(&mut buf));
            }
            _ => buf.push(ch),
        }
    }
    if !buf.is_empty() {
        tokens.push(buf);
    }

    for tok in tokens {
        if tok.starts_with('[') && tok.ends_with(']') {
            let inner = &tok[1..tok.len() - 1];
            let idx: usize = inner
                .parse()
                .map_err(|_| format!("数组下标不是数字: [{inner}]"))?;
            match cur {
                serde_json::Value::Array(ref arr) => match arr.get(idx) {
                    Some(v) => cur = v.clone(),
                    None => return Ok(None),
                },
                _ => return Ok(None),
            }
        } else {
            match cur {
                serde_json::Value::Object(ref map) => match map.get(&tok) {
                    Some(v) => cur = v.clone(),
                    None => return Ok(None),
                },
                _ => return Ok(None),
            }
        }
    }

    Ok(Some(cur))
}

// ═══════════════════════════════════════════════════════════════════
//  ★ 播放地址探测（2026-10-17，task-41 第 2 步）
// ═══════════════════════════════════════════════════════════════════
//
// # 这一层要回答什么
//
//   ① 这个地址**能不能放**（HTTP 可达？状态码？）
//   ② 它是**什么流**（HLS / DASH / MP4 / 纯音频 / 根本不是流）
//   ③ 有没有 **DRM 保护**（命中就如实报，不假装能放）
//   ④ 跳转过没有（302 链路的最终地址）
//
// # 为什么必须看响应头而不是猜后缀
//
// 本项目踩过真实坑（见 model.rs 的 StreamKind 注释）：
//   某个源的 MP4 直链被伪装成 .mp3 后缀，
//   按后缀判成 AudioOnly ⇒ 播不了；按「无扩展名当 HLS」⇒ 无限转圈。
//   ⇒ **URL 后缀根本不可靠**，只有 Content-Type 可信。
//
// # 关于 DASH
//
//   StreamKind::Dash 只是「认得出」，**不是「能播」**。
//   streamproxy 里没有 mpd 改写逻辑。
//   ⇒ 识别为 DASH 时必须如实报「未实现」，不能：
//     · 报「播放失败」（用户以为是网络问题，反复重试）
//     · 映射成 Mp4（放不出来还查不出原因）

/// 探测结论 —— 给插件/UI 用的**结构化**结果
///
/// 与「返回一个错误字符串」的区别：
/// 插件要能按类别做不同处理（换线路 / 提示用户 / 标记不可播），
/// 所以必须结构化，不能只有一句人话。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProbeVerdict {
    /// 可以尝试播放
    Playable {
        kind: crate::model::StreamKind,
        content_type: String,
    },
    /// ★ 识别为 DASH —— 宿主**尚未实现**播放（不是内容坏了）
    DashUnsupported { content_type: String },
    /// ★ 内容受 DRM 保护 —— **架构上不可能播**，不是暂不支持
    DrmProtected { reason: String },
    /// ★ 响应不是媒体流（例如拿到一个 HTML 页面）
    ///
    /// 与 `Unreachable` 的区别：地址**能访问**，只是内容不是流。
    /// 常见于「防盗链拦截返回错误页」「登录页跳转」「API 返回 JSON 错误」。
    NotAStream { content_type: String },
    /// HTTP 层失败（连不上 / 4xx / 5xx）
    Unreachable { detail: String },
}

impl ProbeVerdict {
    /// 给用户看的一句话（UI 直接用）
    ///
    /// ⚠️ 这几句话必须**互不混淆**：
    ///   DRM     ⇒ 换了播放器也放不了
    ///   DASH    ⇒ 本播放器还没做，以后可能做
    ///   不是流  ⇒ 地址错了 / 被拦截了，不是播放器的问题
    ///   不可达  ⇒ 网络/链接问题，可以重试
    /// 混成一句「播放失败」，用户无法判断该不该重试。
    pub fn user_message(&self) -> String {
        match self {
            ProbeVerdict::Playable { .. } => "可以播放".to_string(),
            ProbeVerdict::DashUnsupported { .. } => {
                "该内容为 DASH 格式，本播放器暂不支持".to_string()
            }
            ProbeVerdict::DrmProtected { .. } => {
                "该内容受 DRM 保护，本播放器无法播放".to_string()
            }
            ProbeVerdict::NotAStream { content_type } => {
                format!("该地址返回的不是视频流（Content-Type: {content_type}）")
            }
            ProbeVerdict::Unreachable { detail } => format!("无法访问该地址: {detail}"),
        }
    }

    /// 是否值得让用户重试（区分「暂时性」与「永久性」）
    pub fn retryable(&self) -> bool {
        match self {
            ProbeVerdict::Playable { .. } => false,
            ProbeVerdict::DashUnsupported { .. } => false, // 未实现，重试无用
            ProbeVerdict::DrmProtected { .. } => false,    // 架构限制，重试无用
            ProbeVerdict::NotAStream { .. } => false,      // 内容不对，重试无用
            ProbeVerdict::Unreachable { .. } => true,      // 网络问题，可重试
        }
    }

    /// 稳定的机器可读标签（给插件做判断用，**不要用 Debug 格式**）
    ///
    /// # 为什么要单独一个方法
    ///
    /// 第一版用 `format!("{kind:?}")` 把 Debug 输出当标签传给 JS，
    /// 那是**脆的**：改个枚举名/加个变体，插件里的字符串比较就静默失效。
    /// ⇒ 对外契约必须是显式的、稳定的字面量。
    pub fn verdict_tag(&self) -> &'static str {
        match self {
            ProbeVerdict::Playable { .. } => "playable",
            ProbeVerdict::DashUnsupported { .. } => "dash_unsupported",
            ProbeVerdict::DrmProtected { .. } => "drm",
            ProbeVerdict::NotAStream { .. } => "not_a_stream",
            ProbeVerdict::Unreachable { .. } => "unreachable",
        }
    }
}

/// 探测的完整结果（含 HTTP 元信息）
///
/// 与 `ProbeVerdict` 分开：verdict 是**结论**，这里是**证据**。
/// 插件调试时需要看到 statusCode / 最终 URL，否则「为什么判成这样」无从查起。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProbeReport {
    pub verdict: ProbeVerdict,
    /// HTTP 状态码（0 = 请求没发出去）
    pub status_code: u16,
    /// 原始 Content-Type（空串 = 响应没带）
    pub content_type: String,
    /// 是否发生过跳转（302 / 301 等）
    pub redirected: bool,
    /// 跳转后的最终地址（未跳转时等于入参）
    pub final_url: String,
}

impl ProbeReport {
    /// 序列化成给 JS 的 JSON 文本
    pub fn to_json(&self) -> String {
        let kind = match &self.verdict {
            ProbeVerdict::Playable { kind, .. } => format!("{kind:?}"),
            ProbeVerdict::DashUnsupported { .. } => "Dash".to_string(),
            _ => String::new(),
        };
        serde_json::json!({
            "verdict": self.verdict.verdict_tag(),
            "kind": kind,
            "contentType": self.content_type,
            "statusCode": self.status_code,
            "redirected": self.redirected,
            "finalUrl": self.final_url,
            "message": self.verdict.user_message(),
            "retryable": self.verdict.retryable(),
        })
        .to_string()
    }
}

/// 从 HTTP 响应头 + 响应体前缀判断这条流是什么、能不能放（**纯函数**）
///
/// # 参数
///
///  · status       —— HTTP 状态码（0 表示请求根本没发出去）
///  · content_type —— 响应头里的 Content-Type（可能为空串）
///  · head         —— 响应体的**前缀**（用于嗅探 m3u8/mpd 里的 DRM 标记）
///  · url          —— 原始地址（仅在响应头缺失时作兜底推断）
///
/// # 为什么是纯函数
///
/// 判定逻辑是本层**唯一有分支复杂度**的地方，
/// 做成纯函数 ⇒ 可用构造数据穷举所有组合，不需要起网络。
/// 真正发 HTTP 的部分在 `probe_url` 里，只负责搬运字节。
fn classify_stream(status: u16, content_type: &str, head: &str, url: &str) -> ProbeVerdict {
    use crate::model::StreamKind;

    // ① HTTP 层失败优先报（连不上就无所谓格式）
    if status == 0 {
        return ProbeVerdict::Unreachable {
            detail: "请求未能发出".to_string(),
        };
    }
    if !(200..400).contains(&status) {
        return ProbeVerdict::Unreachable {
            detail: format!("HTTP {status}"),
        };
    }

    // ② ★ DRM 嗅探要**先于**格式判定
    //
    // 理由：一条 HLS 若带 SAMPLE-AES 加密，它的 Content-Type 仍是
    // application/vnd.apple.mpegurl —— 格式是 HLS，但它**放不了**。
    // 若先判格式并返回 Playable，用户会看到「可以播放」然后黑屏。
    if let Some(reason) = detect_drm(head) {
        return ProbeVerdict::DrmProtected { reason };
    }

    // ③ 格式判定：响应头优先，URL 兜底
    //
    // ⚠️ 关键：`text/html` 必须判「不是流」，不能退回按 URL 猜。
    //   因为「URL 是 .mp4 但返回一个 HTML 错误页」是**真实且常见**的情况
    //   （防盗链拦截 / 登录页跳转 / 404 页面）。
    //   若这时还按 URL 猜成 Mp4，插件会以为拿到了能播的地址，
    //   然后播放器黑屏 —— 而那是最难查的一类问题。
    let ct = content_type.trim();
    if !ct.is_empty() {
        match StreamKind::from_content_type(ct) {
            Some(StreamKind::Dash) => {
                return ProbeVerdict::DashUnsupported {
                    content_type: ct.to_string(),
                };
            }
            Some(k) => {
                return ProbeVerdict::Playable {
                    kind: k,
                    content_type: ct.to_string(),
                };
            }
            None => {
                // 响应头存在但**不认识**（text/html / application/json / …）
                // ⇒ 明确是「不是流」，不猜。
                return ProbeVerdict::NotAStream {
                    content_type: ct.to_string(),
                };
            }
        }
    }

    // ④ 响应头缺失 ⇒ 退回按 URL 猜（最小假设，见 StreamKind::from_url）
    let kind = StreamKind::from_url(url);
    if kind == StreamKind::Dash {
        return ProbeVerdict::DashUnsupported {
            content_type: String::new(),
        };
    }

    ProbeVerdict::Playable {
        kind,
        content_type: String::new(),
    }
}

/// 从清单文本里嗅探 DRM 标记，命中则返回人类可读的原因
///
/// # 为什么读清单文本而不是只看响应头
///
/// DRM 信息**不在响应头里** —— 它藏在清单内部：
///
/// ```text
/// HLS:  #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://..."
///       #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES
/// DASH: <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed">
///       ↑ 这个 UUID 是 Widevine 的固定 scheme id
/// ```
///
/// 所以必须把清单开头读回来做字符串匹配。
///
/// # 为什么 AES-128 **不算** DRM
///
/// AES-128 是普通 HLS 加密，密钥就是一个普通 HTTP 地址
/// （URI="key.bin"），**libmpv 自己能解** —— 本仓 streamproxy 就在改
/// 写这类 playlist（见 streamproxy.rs 的 #EXT-X-KEY 处理）。
/// 把它当 DRM 会让一大批**本来能播**的内容被误判为不可播。
///
/// ⇒ 只认 SAMPLE-AES（需要 CDM）与 Widevine/PlayReady/ClearKey 的 scheme id。
fn detect_drm(text: &str) -> Option<String> {
    let lower = text.to_lowercase();

    // ── HLS ──────────────────────────────────────────────
    //
    // SAMPLE-AES / SAMPLE-AES-CTR 是 Apple 的 DRM 形态，需要 FairPlay CDM。
    // ⚠️ 必须排除 AES-128 —— 那个能解。
    if lower.contains("method=sample-aes") {
        return Some("HLS 使用 SAMPLE-AES 加密（需要 FairPlay CDM）".to_string());
    }

    // ── DASH ─────────────────────────────────────────────
    //
    // 这几个 schemeIdUri 是业界固定的 DRM 系统标识：
    //   edef8ba9-79d6-4ace-a3c8-27dcd51d21ed  ⇒ Widevine
    //   9a04f079-9840-4286-ab92-e65be0885f95  ⇒ PlayReady
    //   e2719d58-a985-b3c9-781a-b030af78d30e  ⇒ ClearKey
    if lower.contains("edef8ba9-79d6-4ace-a3c8-27dcd51d21ed") {
        return Some("DASH 使用 Widevine 加密".to_string());
    }
    if lower.contains("9a04f079-9840-4286-ab92-e65be0885f95") {
        return Some("DASH 使用 PlayReady 加密".to_string());
    }
    if lower.contains("e2719d58-a985-b3c9-781a-b030af78d30e") {
        return Some("DASH 使用 ClearKey 加密".to_string());
    }

    None
}

/// 只读响应体前缀的字节上限
///
/// m3u8/mpd 的 DRM 标记都在开头几十行内；
/// 视频直链可能上百 MB，**绝不能全读**。
const PROBE_HEAD_BYTES: usize = 16 * 1024;

/// 探测一个播放地址（**带网络**的那一层）
///
/// # 为什么用 GET + 只读前缀，而不是 HEAD
///
///   ① 很多 CDN/源不支持 HEAD（返回 405），会误判为「不可达」
///   ② DRM 标记藏在**响应体里的清单文本**中，HEAD 拿不到
/// ⇒ 必须 GET 且读回一段 body 才能嗅探 DRM。
///
/// # 关于跳转
///
/// reqwest 默认跟随跳转，`resp.url()` 就是**最终**地址。
/// 这里把 `final_url != url` 记为跳转过 —— 插件可据此判断
/// 「是不是被重定向到了登录页」（那种情况通常拿到 text/html）。
pub async fn probe_url(
    proxy: &Option<Arc<crate::proxy::ProxyStore>>,
    provider: &str,
    url: &str,
) -> ProbeReport {
    let client = match proxy {
        Some(px) => px
            .client_for(provider, None)
            .unwrap_or_else(|_| default_client()),
        None => default_client(),
    };

    let resp = match client.get(url).send().await {
        Ok(r) => r,
        Err(e) => {
            return ProbeReport {
                verdict: ProbeVerdict::Unreachable {
                    detail: format!("请求失败: {e}"),
                },
                status_code: 0,
                content_type: String::new(),
                redirected: false,
                final_url: url.to_string(),
            };
        }
    };

    let status_code = resp.status().as_u16();
    let final_url = resp.url().to_string();
    let redirected = final_url != url;

    // ⚠️ 必须在读 body 之前取头 —— 与 do_http_full 里的注释同理
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    // 只读前缀：仅当看起来是清单时才读（清单小且含 DRM 标记）。
    // 视频直链不读 —— 可能是 GB 级，而 DRM 标记不会出现在直链里。
    let head = {
        let lower = content_type.to_lowercase();
        let is_manifest = lower.contains("mpegurl") || lower.contains("dash");
        if is_manifest {
            match resp.bytes().await {
                Ok(b) => {
                    let n = b.len().min(PROBE_HEAD_BYTES);
                    String::from_utf8_lossy(&b[..n]).to_string()
                }
                Err(_) => String::new(),
            }
        } else {
            String::new()
        }
    };

    ProbeReport {
        verdict: classify_stream(status_code, &content_type, &head, url),
        status_code,
        content_type,
        redirected,
        final_url,
    }
}

fn store_read(dir: &std::path::Path, plugin_id: &str, key: &str) -> Option<String> {
    store_load(dir, plugin_id)
        .get(key)
        .and_then(|v| v.as_str())
        .map(String::from)
}

/// 插件数据文件的**进程内写锁**（2026-09-25，task-38）
///
/// # 为什么需要（真存在的数据丢失窗口）
///
/// `store_write` / `config_write` 都是 **读-改-写**：
/// ```text
/// ① 读整个 JSON 进内存
/// ② 改一个键
/// ③ 把**整个** JSON 写回
/// ```
/// 而 `store`（`session` / `credentials`）与 `config`（`cfg:*`）
/// **共用同一个文件**（见下面 `CONFIG_PREFIX` 的说明）。
///
/// 于是两个调用交错时（都是 async 任务，`call_js` 每次新建运行时）
/// 会出现**丢失更新**：
/// ```text
/// 任务 A（写 session）        任务 B（写 credentials）
/// ─────────────────────      ─────────────────────
/// ① 读 {session: 旧}
///                            ① 读 {session: 旧, credentials: 旧}
/// ② 改 session
///                            ② 改 credentials
/// ③ 写 {session: 新}   ← 丢了 credentials
///                            ③ 写 {session: 旧!, credentials: 新}
///                                   ↑ ↑ 把 A 刚写的 session 覆盖回**旧值**
/// ```
/// 表现：**刚登录完 token 又变回旧的**（用户看到"登录了但马上又失效"）。
///
/// # 为什么是全局一把锁而不是按插件分
///
/// ```text
/// ① 同一个插件的数据才可能撞（不同插件是不同文件）——
///    但按插件分锁要一张 HashMap<PathBuf, Mutex>，而**地图本身也要锁**，
///    复杂度上去了，收益只是"不同插件能并行写"。
/// ② 写盘本身是微秒级（几十 KB 的 JSON），串行化完全无感。
/// ③ 这个文件的并发度本来就极低（用户点登录/改配置才写）。
/// ⇒ 全局一把：简单、不会错。**真出现性能问题再按插件分。**
/// ```
///
/// ⚠️ 这只是**进程内**锁。同一个数据目录被**两个进程**打开时（理论上
///    不该发生，但用户可能双击两次）仍会互相覆盖 —— 那需要文件锁，
///    超出本任务范围。这里只消掉**同一进程内**的交错。
static STORE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 插件数据文件的**进程内写锁**（2026-09-25，task-38）
///
/// # 为什么需要（真存在的数据丢失窗口）
///
/// `store_write` / `config_write` 都是 **读-改-写**：
/// ```text
/// ① 读整个 JSON 进内存
/// ② 改一个键
/// ③ 把**整个** JSON 写回
/// ```
/// 而 `store`（`session` / `credentials`）与 `config`（`cfg:*`）
/// **共用同一个文件**（见下面 `CONFIG_PREFIX` 的说明）。
///
/// 两个调用交错时会**丢失更新**：
/// ```text
/// 任务 A（写 session）        任务 B（写 credentials）
/// ─────────────────────      ─────────────────────
/// ① 读 {session: 旧}
///                            ① 读 {session: 旧, credentials: 旧}
/// ② 改 session
///                            ② 改 credentials
/// ③ 写 {session: 新}
///                            ③ 写 {session: 旧, credentials: 新}
///                                   ↑ 把 A 刚写的**新 session 覆盖回旧值**
/// ```
/// 表现：**刚登录完 token 又变回旧的** → 用户看到"登录了但马上又失效"。
///
/// # 为什么是全局一把锁
///
/// 写盘是微秒级（几十 KB JSON），而写操作本身极低频
/// （用户点登录 / 改配置才发生）⇒ 串行化完全无感。
/// 按插件分锁要维护 `HashMap<PathBuf, Mutex>`，而**那张表自己也要锁**，
/// 复杂度换来的只是"不同插件能并行写"—— 不值。
fn store_guard() -> std::sync::MutexGuard<'static, ()> {
    /*
     * ⚠️ `lock()` 返回 `Err` 只发生在**前一个持锁者 panic** 时（中毒）。
     *    那种情况下数据文件可能写了一半 —— 但我们**不该因此让插件彻底不能用**：
     *    继续执行（`unwrap_or_else(|e| e.into_inner())`）比"整个插件数据层瘫痪"好。
     *    这里不 unwrap：宁可拿到中毒的锁也要让用户能继续操作。
     */
    STORE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// **原子**写插件数据文件（先写临时文件再 rename）
///
/// # 为什么要原子替换（不只是"好看"）
///
/// `std::fs::write` 是**截断后写** —— 执行期间另一个**不取锁**的读操作
/// （`store_read` / `resolved_config`）会读到**写了一半的 JSON**，
/// `serde_json::from_str` 失败 → `store_load` 兜底成**空 map**。
///
/// 后果很隐蔽：
/// ```text
/// 读到的 {credentials: …} 变成 {} → can_auto_login() 返回 false
///                                → UI 说「可能需要验证码，请手动完成」
/// ```
/// 也就是**本轮用户报的那个现象**，成因却是"读到半截文件"。
///
/// `rename` 在同一文件系统内是**原子**的 ⇒ 读侧要么看到旧内容、
/// 要么看到新内容，**永远不会看到半截**。
///
/// ⚠️ 临时文件用 `.json.tmp` 扩展名 —— **不是** `.js`，
///    所以 `load_plugins` 扫 `*.js` 时不会把它当插件（否则会报一堆坏插件）。
fn store_write_atomic(path: &std::path::Path, body: &str) -> std::result::Result<(), String> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, body).map_err(|e| format!("写入临时文件失败: {e}"))?;
    /*
     * ⚠️ Windows 的 `rename` 在**目标已存在**时会失败（不像 POSIX 会覆盖）——
     *    所以先删目标。删与改名之间有极小窗口（目标短暂不存在），
     *    读侧那时拿到"文件不存在" → 同样兜底成空 map。
     *    这比"读到半截 JSON"好：**不存在**是明确的，半截是**欺骗性**的。
     */
    let _ = std::fs::remove_file(path);
    std::fs::rename(&tmp, path).map_err(|e| format!("替换数据文件失败: {e}"))
}

fn store_write(
    dir: &std::path::Path,
    plugin_id: &str,
    key: &str,
    value: Option<String>,
) -> std::result::Result<(), String> {
    // ★ 读-改-写**全程持锁**（否则并发写互相覆盖，见 STORE_LOCK）
    let _g = store_guard();
    let mut map = store_load(dir, plugin_id);
    match value {
        Some(v) => {
            map.insert(key.to_string(), serde_json::Value::String(v));
        }
        None => {
            map.remove(key);
        }
    }
    std::fs::create_dir_all(dir).map_err(|e| format!("创建插件数据目录失败: {e}"))?;
    let body = serde_json::to_string_pretty(&map).map_err(|e| e.to_string())?;
    // ★ 原子替换（免得读侧拿到半截 JSON，见 store_write_atomic）
    store_write_atomic(&store_path(dir, plugin_id), &body)
        .map_err(|e| format!("写入插件数据失败: {e}"))
}

// ─────────────────────── 插件配置的读写 ───────────────────────

/*
 * 配置与 `host.store` **共用同一个数据文件**，但值的 JSON 类型不同：
 *
 *   · `host.store`  —— 值一律是**字符串**（插件自己序列化）
 *   · `host.config` —— 值是**原生 JSON**（布尔 / 数字 / 字符串），
 *                      因为界面控件要按类型渲染与回写
 *
 * 为什么共用文件：一个插件的数据集中在一处，备份/排查/清理都简单。
 * 键名加 `cfg:` 前缀避免与 store 的键撞车。
 */
const CONFIG_PREFIX: &str = "cfg:";

/// 读一个配置值（返回原生 JSON）
fn config_read(
    dir: &std::path::Path,
    plugin_id: &str,
    key: &str,
) -> Option<serde_json::Value> {
    store_load(dir, plugin_id)
        .get(&format!("{CONFIG_PREFIX}{key}"))
        .cloned()
}

/// 写一个配置值
fn config_write(
    dir: &std::path::Path,
    plugin_id: &str,
    key: &str,
    value: serde_json::Value,
) -> std::result::Result<(), String> {
    // ★ 与 store_write **共用同一把锁** —— 它们写的是**同一个文件**
    let _g = store_guard();
    let mut map = store_load(dir, plugin_id);
    map.insert(format!("{CONFIG_PREFIX}{key}"), value);
    std::fs::create_dir_all(dir).map_err(|e| format!("创建插件数据目录失败: {e}"))?;
    let body = serde_json::to_string_pretty(&map).map_err(|e| e.to_string())?;
    store_write_atomic(&store_path(dir, plugin_id), &body)
        .map_err(|e| format!("写入插件数据失败: {e}"))
}

/// 读出某插件的**全部**配置（已填默认值）
///
/// 这是给界面用的：用户没改过的项也要显示默认值，
/// 否则界面上是一堆空控件，用户不知道本来是什么。
pub fn resolved_config(
    dir: &std::path::Path,
    fields: &[crate::model::ConfigField],
    plugin_id: &str,
) -> serde_json::Map<String, serde_json::Value> {
    let mut out = serde_json::Map::new();
    for f in fields {
        let v = config_read(dir, plugin_id, &f.key).unwrap_or_else(|| f.effective_default());
        out.insert(f.key.clone(), v);
    }
    out
}

/// 写多个配置值（只接受**已声明**的键 —— 防止插件/前端塞垃圾）
///
/// 返回真正被写入的键数。
pub fn config_write_many(
    dir: &std::path::Path,
    fields: &[crate::model::ConfigField],
    plugin_id: &str,
    values: &serde_json::Map<String, serde_json::Value>,
) -> std::result::Result<usize, String> {
    let mut n = 0;
    for (k, v) in values {
        let Some(field) = fields.iter().find(|f| &f.key == k) else {
            // ⚠️ 未声明的键**直接忽略**而不是报错：
            // 插件升级后删掉某个配置项时，旧值不该让写入整体失败
            log::debug!("插件 {plugin_id} 收到未声明的配置键 {k}，已忽略");
            continue;
        };
        if !config_value_ok(field, v) {
            return Err(format!("配置项「{}」的值类型不对", field.label));
        }
        config_write(dir, plugin_id, k, v.clone())?;
        n += 1;
    }
    Ok(n)
}

/// 值是否符合该控件的类型
///
/// **必须在写盘前校验** —— 否则界面传个字符串给 `switch`，
/// 插件读到的就不是布尔，会出现"开关打开了但没生效"这种难查的问题。
fn config_value_ok(field: &crate::model::ConfigField, v: &serde_json::Value) -> bool {
    match field.kind.as_str() {
        "switch" => v.is_boolean(),
        "number" => {
            if !v.is_number() {
                return false;
            }
            let n = v.as_f64().unwrap_or(0.0);
            field.min.map(|m| n >= m).unwrap_or(true) && field.max.map(|m| n <= m).unwrap_or(true)
        }
        "select" => v
            .as_str()
            .map(|s| field.options.iter().any(|o| o.value == s))
            .unwrap_or(false),
        "text" | "password" => v.is_string(),
        // `info` 不接收值
        _ => false,
    }
}


/// 把 JS 对象转成请求头表（字符串值，非字符串跳过）
fn object_to_headers(o: &Object) -> HashMap<String, String> {
    let mut m = HashMap::new();
    for entry in o.props::<String, rquickjs::Value>() {
        if let Ok((k, v)) = entry {
            if let Some(s) = v.as_string().and_then(|s| s.to_string().ok()) {
                m.insert(k, s);
            }
        }
    }
    m
}

fn default_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/143.0.0.0")
        .build()
        .expect("build http client")
}

/// `default_client()` 的 raw 版：**同样的 timeout + UA，只关掉自动解压**
///
/// 供「没有 ProxyStore」的路径（例如离线测试 / 未挂代理的场景）在
/// raw-deflate 回退时使用。旧代码在这里裸建 builder，连 UA 都没有。
fn raw_decompress_off_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/143.0.0.0")
        .no_gzip()
        .no_deflate()
        .no_brotli()
        .build()
        .expect("build raw http client")
}

// ─────────────────────────── MediaProvider 实现 ───────────────────────────

#[async_trait]
impl MediaProvider for JsPluginProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    /// 首页分区 —— 调插件的 `plugin.home()`
    async fn home(&self) -> Result<Vec<Section>> {
        let json = self.call_js("plugin.home()").await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("home() 返回格式不符: {e}")))
    }

    /// 分类列表
    ///
    /// ★ `categories` 在这个生态里有**两种合法形态**，两种都要认：
    ///   · **方法** —— `async categories() { ... }`（内置 `srcl.js` 这样写）
    ///   · **数据数组** —— `categories: [ { id, name }, ... ]`
    ///     （`tools/tvbox-convert.mjs` 生成的插件这样写 —— 分类是
    ///      转换时探测到的固定清单，苹果CMS 的分类很少变）
    ///
    /// # 症状（Owner 报的「tvbox源的确实没做完」里剩下的那一处）
    /// ```text
    /// get_categories("360")  =>  {"error":"插件报错: not a function"}
    /// => 浏览页顶部的分类切换栏是空的（列表本身照常显示）
    /// ```
    /// 实测：22 个转换来的 TVBox 源**全部**报这一条；而内置 `srcl`
    /// （`categories` 是方法）在同一台宿主上取到 8 个真分类 => 链是好的。
    /// 取证：`.probe/t359_vod_final.py`（`RESULT pass=14 fail=0`）。
    ///
    /// # 为什么用三元而不是 try/catch
    /// 与 `rank()` / `epg()` 同一条纪律（见本文件 L2213 的长注释）：
    /// **先判形态再取值**，让「方法存在但内部报错」原样透出，
    /// 不被「捕获所有错误都返回空数组」吞掉。
    ///
    /// ⚠️ 这**不是**我们这次改写引入的回归：旧宿主
    ///    `src-tauri/src/plugins/mod.rs:1562` 是同一行 `plugin.categories()`。
    async fn categories(&self) -> Result<Vec<Category>> {
        let json = self
            .call_js(
                "(typeof plugin.categories === 'function' ? plugin.categories() : (plugin.categories || []))",
            )
            .await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("categories() 返回格式不符: {e}")))
    }

    /// 分类内容
    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>> {
        let expr = format!(
            "plugin.list({})",
            serde_json::json!({
                "categoryId": req.category_id,
                "page": req.page,
            })
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("list() 返回格式不符: {e}")))
    }

    /// 搜索
    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>> {
        let expr = format!(
            "plugin.search({}, {})",
            serde_json::to_string(keyword).unwrap_or_else(|_| "\"\"".into()),
            page
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("search() 返回格式不符: {e}")))
    }

    /// ★ 榜单内容（首页 `SectionSource::Rank` 区块用）
    ///
    /// ⚠️ **漏掉这个方法会静默出错**（实测踩到）：
    /// 某动画站的 `home()` 声明了两个 `SectionSource::Rank` 区块
    /// （「TV番组榜」「剧场番组榜」），插件里也实现了 `rank()`，
    /// 但宿主没桥接 → 走 trait 默认实现 → 返回
    /// `Unsupported("该源不支持榜单")` → **首页那两个区块永远空白**，
    /// 而插件作者完全不知道为什么自己写的 rank 没被调用。
    async fn rank(&self, rank_id: &str, page: u32) -> Result<Page<MediaItem>> {
        let expr = format!(
            "(plugin.rank ? plugin.rank({}, {}) : Promise.reject(new Error('unsupported: 该源不支持榜单')))",
            serde_json::to_string(rank_id).unwrap_or_else(|_| "\"\"".into()),
            page
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("rank() 返回格式不符: {e}")))
    }

    /// 详情
    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let expr = format!(
            "plugin.detail({})",
            serde_json::to_string(&self.strip_prefix(&id.native))
                .unwrap_or_else(|_| "\"\"".into())
        );
        let json = self.call_js(&expr).await?;
        let mut d: MediaDetail = serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("detail() 返回格式不符: {e}")))?;

        /*
         * ★ 把返回的 id 归一化成带前缀的形态。
         *
         * 插件不知道前缀的存在（契约里它只写自己的 id），
         * 所以它回传的 `id` 可能是**裸的**（没有冒号）——
         * 而 `MediaId` 的反序列化要求 `provider:native` 形态，
         * 裸 id 会直接报「非法 MediaId」。
         *
         * 这里统一重建：provider 用本插件的 id，native 用剥掉前缀后的值。
         */
        let raw = d.id.as_key();
        let native = self.strip_prefix(&raw);
        d.id = MediaId::new(&self.manifest.id, native);
        Ok(d)
    }

    /// ★ 按播放源取剧集
    ///
    /// ⚠️ 漏桥接的后果（与 `rank` 同类）：trait 默认实现会去调 `detail()`，
    /// 而插件可能**只为某个特定源实现了 `episodes()`**（如 srca 的
    /// `/videos/{id}/sections?player_code=`）—— 用 detail 的结果代替，
    /// 用户切换线路后会看到**上一个线路的剧集**。
    async fn episodes(&self, id: &MediaId, source_code: &str) -> Result<Vec<Episode>> {
        let native =
            serde_json::to_string(&self.strip_prefix(&id.native)).unwrap_or_else(|_| "\"\"".into());
        let expr = format!(
            "(plugin.episodes ? plugin.episodes({native}, {}) : plugin.detail({native}).then(d => d.episodes))",
            serde_json::to_string(source_code).unwrap_or_else(|_| "\"\"".into()),
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("episodes() 返回格式不符: {e}")))
    }

    /// 列出可用播放源
    ///
    /// 默认实现从 `detail()` 取（大多数插件只需这样），
    /// 但插件若实现了 `sources()` 就用它的 —— 有些站点要单独请求。
    async fn sources(&self, id: &MediaId) -> Result<Vec<PlaySource>> {
        let native =
            serde_json::to_string(&self.strip_prefix(&id.native)).unwrap_or_else(|_| "\"\"".into());
        let expr = format!(
            "(plugin.sources ? plugin.sources({native}) : plugin.detail({native}).then(d => d.sources))"
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("sources() 返回格式不符: {e}")))
    }

    /// 取流
    ///
    /// `req` 是 Rust 侧的 `PlayRequest`（字段是 snake_case），
    /// 要转成 camelCase 再给插件 —— 契约里插件写的是
    /// `req.episodeId` 而不是 `req.episode_id`。
    ///
    /// # ⚠️ 必须剥掉 `episode_id` 上的 provider 前缀（实测踩到）
    ///
    /// `detail()` 返回的 `episodes[].id` 会经 `prefix_media_ids` 被加上
    /// `"{provider}:"` 前缀（那是给**媒体条目**用的，避免跨源撞 id）。
    /// 但 `Episode.id` 在 Rust 侧是**普通字符串**，前端把它原样放进
    /// `PlayRequest.episode_id` 传回来时，插件收到的是 `srca:51463`。
    ///
    /// 后果（Owner 实测报的错）：
    /// ```text
    /// bind uri "section_id": parsing "srca:51463": invalid syntax
    /// ```
    /// 某动画站的取流接口拿它当数字 id 用，直接 400。
    ///
    /// 所以这里要把前缀剥掉再给插件。
    async fn resolve(&self, id: &MediaId, req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        let mut req_js = rust_value_to_js(
            serde_json::to_value(req).unwrap_or(serde_json::Value::Object(Default::default())),
        );

        // 剥掉 episode_id 上的前缀（剧集 id 是插件自己的数字/字符串 id）
        if let Some(serde_json::Value::String(ep)) = req_js.get_mut("episodeId") {
            *ep = self.strip_prefix(ep);
        }

        /*
         * ★★★ 第一个参数：tvbox 转换插件要的是**剧集地址**，不是条目 id
         *
         * # Owner 报的 bug
         * > 播放第二集,实际还是第一集,这是bug
         *
         * # 根因（逐行核对过）
         *
         * tvbox 转换插件的 detail() 里，剧集的 id **就是剧集地址**
         * （154.js:369  id: e.url,  // 直接存 URL），而它的 resolve(id)
         * **只认第一个参数、完全忽略第二个 req**：
         * ```text
         * 154.js:392  async resolve(id) {
         * 154.js:415    let url = String(id)
         * 154.js:417    if (!/^https?:\/\//i.test(url)) {
         * 154.js:419      const j = await getJson(...ids=${url})   // ← 拿它当**条目 id**
         * 154.js:425      url = eps[0].url                          // ★★★ 永远第一集
         * 154.js:426    }
         * ```
         * 宿主原来把 id.native（条目 id，如 "150758"）当第一个参数传下去，
         * 于是插件每次都在第 419 行去查详情、在第 425 行取 eps[0]
         * ⇒ **无论点第几集都返回第一集**，与 Owner 的描述完全吻合。
         *
         * # 为什么改成"看 episode_id 是不是 URL"而不是别的判据
         *
         * 宿主**不能**改用户数据目录里的插件文件（那是用户数据），
         * 所以只能在这一层做适配。而 PlayRequest.episode_id 在
         * tvbox 转换插件里**就是剧集地址**（上面那行 id: e.url），
         * 所以：**它是 http(s) URL 时，就用它当第一个参数**。
         *
         * # ⚠️ 判据必须**精确**：只有明确是 http(s) URL 才替换
         *
         * 别的插件用 episode_id 表达**别的东西** ——
         * 最典型的是 srca：它拿 episode_id 当 section_id
         * （见上面那段前缀坑，插件要的是纯数字 51463）。
         * 若不加判断地一律替换，某动画站那条路会被打坏。
         * ⇒ 用 starts_http（与 tvbox.rs 同一份语义：大小写不敏感、
         *   必须是完整 http:// / https:// 前缀），
         *   不是 URL 就**原样**传条目 id（= 改前行为，逐字相同）。
         *
         * # 反向控制（必须逐字不变）
         *
         * episode_id 为 None / 空串 / "150758" / "srca:51463"
         * 时，走的都是 else 分支 ⇒ 第一个参数仍是 strip_prefix(id.native)
         * ⇒ 与改动前**完全一致**，不影响从播放历史/追更直接续播的路径。
         */
        let first_arg = self.resolve_first_arg(id, req);

        let expr = format!(
            "plugin.resolve({}, {})",
            serde_json::to_string(&first_arg).unwrap_or_else(|_| "\"\"".into()),
            serde_json::to_string(&req_js).unwrap_or_else(|_| "{}".into())
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("resolve() 返回格式不符: {e}")))
    }

    // ── 登录（可选能力）──
    //
    // ⚠️ 每个方法都要先判断插件**是否实现了它**。
    //    不判断的话，一个不需要登录的插件（如某电视台）被问到
    //    `session()` 时会抛 `plugin.session is not a function` ——
    //    而宿主在启动时会普遍地问一遍，于是**每次启动都刷一堆错误日志**，
    //    真正的问题反而被淹没。

    async fn login(&self, cred: Credentials) -> Result<Session> {
        let expr = format!(
            "plugin.login({}, {})",
            serde_json::to_string(&cred.username).unwrap_or_else(|_| "\"\"".into()),
            serde_json::to_string(&cred.password).unwrap_or_else(|_| "\"\"".into())
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("login() 返回格式不符: {e}")))
    }

    async fn logout(&self) -> Result<()> {
        // 没实现就当作「已经登出」，不是错误
        self.call_js("(plugin.logout ? plugin.logout() : null)")
            .await?;
        Ok(())
    }

    async fn session(&self) -> Result<Option<Session>> {
        let json = self
            .call_js("(plugin.session ? plugin.session() : null)")
            .await?;
        parse_optional_session(&json, "session")
    }

    async fn refresh_session(&self) -> Result<Option<Session>> {
        let json = self
            .call_js("(plugin.refreshSession ? plugin.refreshSession() : null)")
            .await?;
        parse_optional_session(&json, "refreshSession")
    }

    async fn can_auto_login(&self) -> bool {
        matches!(
            self.call_js("(plugin.canAutoLogin ? plugin.canAutoLogin() : false)")
                .await
                .as_deref(),
            Ok("true")
        )
    }

    /// ★ 用已保存的凭据自动重新登录
    ///
    /// Owner 报「登录失效，像这种没有验证码的，应该自动重登」——
    /// 宿主在「token 过期且续期失败」时会走这里。
    async fn auto_login(&self) -> Result<Option<Session>> {
        let json = self
            .call_js("(plugin.autoLogin ? plugin.autoLogin() : null)")
            .await?;
        parse_optional_session(&json, "autoLogin")
    }

    /// 彻底忘记凭据（插件版存在插件私有存储里）
    async fn forget_credentials(&self) -> Result<()> {
        self.call_js("(plugin.forgetCredentials ? plugin.forgetCredentials() : null)")
            .await?;
        Ok(())
    }

    // ── 扫码登录（2026-09-21）───────────────────────────────────
    //
    // 契约见 `provider.rs` 的 `QrLoginStart` 说明。
    // 宿主只做两件事：① 调插件拿 url 与状态 ② 把 url 画成二维码。

    /// ★ 申请登录二维码
    ///
    /// ⚠️ 插件**没有**实现 `qrLoginStart` 时返回 `unsupported`，
    ///    而不是空值 —— 宿主据此决定登录弹窗里显不显示「扫码」页签。
    ///    这与 `has_method("qrLoginStart")` 是两条互补的判据：
    ///    `has_method` 用于**渲染前**判断要不要显示入口，
    ///    这里用于**真的调用时**给出明确错误。
    async fn qr_login_start(&self) -> Result<crate::provider::QrLoginStart> {
        let json = self
            .call_js("(plugin.qrLoginStart ? plugin.qrLoginStart() : null)")
            .await?;
        if json == "null" {
            return Err(ProviderError::unsupported("该插件不支持扫码登录"));
        }
        let mut start: crate::provider::QrLoginStart = serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("qrLoginStart() 返回格式不符: {e}")))?;

        /*
         * ★★★ 二维码由**宿主**渲染（不是插件）
         *
         * QuickJS 里没有 canvas / DOM，插件画不出二维码。
         * 而宿主已经有 `qrcode` 依赖（局域网遥控的二维码就在用同一套）。
         *
         * ⚠️ 渲染失败**不能**让整个扫码流程失败 —— 界面仍可把 url
         *    当文本显示（虽然不好扫，但用户至少能看到出了什么事）。
         *    所以这里是 `unwrap_or_default()` 而不是 `?`。
         */
        /*
         * ★ 上游给了**图片地址**时，绝不能再拿 url 去画二维码。
         *
         * 腾讯 ptqrshow 这类接口：url 就是「那张 PNG 的地址」，
         * 把它编码成二维码 = 让用户扫一个图片链接，扫完什么都不会发生。
         * 这种时候清空 svg，交给界面直接显示图片
         * （provider_login_panel.dart 里的 imageUrl 分支）。
         */
        start.finalize_qr_rendering();
        Ok(start)
    }

    /// ★ 轮询扫码状态
    async fn qr_login_poll(&self, key: &str) -> Result<crate::provider::QrLoginPoll> {
        let expr = format!(
            "(plugin.qrLoginPoll ? plugin.qrLoginPoll({}) : null)",
            serde_json::to_string(key).unwrap_or_else(|_| "\"\"".into())
        );
        let json = self.call_js(&expr).await?;
        if json == "null" {
            return Err(ProviderError::unsupported("该插件不支持扫码登录"));
        }
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("qrLoginPoll() 返回格式不符: {e}")))
    }

    /// 该插件是否实现了某个方法（供宿主分派可选能力）
    ///
    /// 用 `typeof` 判断而不是「调用后看有没有报错」——
    /// 后者分不清「没实现」与「实现了但出错」。
    async fn has_method(&self, name: &str) -> bool {
        // 名字来自宿主代码（不是用户输入），但仍做一次白名单校验，
        // 避免将来有人把外部字符串传进来导致注入
        if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return false;
        }
        matches!(
            self.call_js(&format!("typeof plugin.{name} === 'function'"))
                .await
                .as_deref(),
            Ok("true")
        )
    }

    // ── 直播与节目单 ──
    //
    // ⚠️ 这几个**必须实现**，不能靠 trait 默认值。
    //    默认值是 `Unsupported`，而 `Registry::live_all()` 会
    //    吞掉错误直接跳过 —— 表现是「插件明明声明了 live: true，
    //    直播页却完全看不到它」（实测踩到，很难查）。

    async fn live_channels(&self) -> Result<Vec<LiveChannel>> {
        let json = self.call_js("plugin.liveChannels()").await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("liveChannels() 返回格式不符: {e}")))
    }

    async fn live_stream(&self, channel_id: &str) -> Result<Vec<StreamCandidate>> {
        let expr = format!(
            "plugin.liveStream({})",
            serde_json::to_string(channel_id).unwrap_or_else(|_| "\"\"".into())
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("liveStream() 返回格式不符: {e}")))
    }

    async fn epg(&self, channel_id: &str, day: Option<&str>) -> Result<Vec<EpgEntry>> {
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 可选方法要优雅降级（2026-09-25 修的真 bug）
         * ══════════════════════════════════════════════════════════════
         *
         * # 症状
         * ```text
         * 用户切台时每次都刷一条：
         *   [LIVE] 该频道暂无节目单: SourinCoreException(other): 插件报错: not a function
         * ```
         * 复现（`.probe/t42_epg_repro.py`，真实 FFI）：
         * ```text
         * get_epg("iptv", …)  ⇒ {"error":"插件报错: not a function"}   ★ 失败
         * get_epg("srcl", …)  ⇒ [{"title":"…","start":…}]              ★ 阳性对照通过
         * ```
         *
         * # 根因：**能力位声明 false，但桥接层无条件调用**
         * ```text
         * `plugins/iptv.js` 声明 `capabilities: { …, epg: false }`，
         * ★ 且**根本没有** `epg` 方法（公共源没有 EPG 数据）。
         * 而本函数无条件拼 `plugin.epg(...)` 去执行 ⇒ 调用不存在的方法
         * ⇒ JS 抛 `TypeError: plugin.epg is not a function`。
         * ```
         *
         * # 为什么必须在这里（桥接层）降级
         * ```text
         * 本文件 L3336 早就写明了原则：
         *   「插件**没实现**的可选方法要优雅降级，不能报「is not a function」」
         * —— `session()` / `logout()` / `rank()` 都照做了，
         * ★ 只有 `epg()`（和 `timeshift()`）漏了。
         * ⇒ 与管理「哪些方法可选」的知识放在**同一层**，最不容易再漏。
         * ```
         *
         * # 为什么用三元表达式而不是 try/catch
         * ```text
         * `rank()` 用的就是 `plugin.rank ? … : Promise.reject(unsupported…)`
         * —— **先判存在再调用**。照抄它能保证：
         *   ① 方法**不存在** ⇒ 明确报 `unsupported`（语义准确）
         *   ② 方法**存在但内部报错** ⇒ 错误**原样透出**（不被误吞）
         * ★ 若改成"捕获所有错误都返回空数组"，
         *   那会把插件真正的 bug 也吞掉（用户看到"没有节目单"而不是报错）
         *   ⇒ 那是**更坏的**选择。
         * ```
         *
         * ⚠️ 与 `rank()` 的差别：`rank` 的"没实现"是**真错误**
         *    （首页区块会永远空白，L1907 记录过），所以它 `reject`。
         *    而 EPG **本来就是可选**的（没有节目单是正常状态）⇒
         *    这里返回**空数组**更贴合语义 ——
         *    Flutter 侧那句注释就是 `// 失败就空`，
         *    调用方本来也把"取不到"当成"暂无节目单"。
         */
        let expr = match day {
            Some(d) => format!(
                "(plugin.epg ? plugin.epg({}, {}) : [])",
                serde_json::to_string(channel_id).unwrap_or_else(|_| "\"\"".into()),
                serde_json::to_string(d).unwrap_or_else(|_| "null".into())
            ),
            None => format!(
                "(plugin.epg ? plugin.epg({}) : [])",
                serde_json::to_string(channel_id).unwrap_or_else(|_| "\"\"".into())
            ),
        };
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("epg() 返回格式不符: {e}")))
    }

    async fn timeshift(
        &self,
        channel_id: &str,
        start: i64,
        end: i64,
    ) -> Result<StreamCandidate> {
        /*
         * ★★ 与 `epg()` **同一个形态**的漏洞（2026-09-25 一并修）
         *
         * # 复现（我实测，`.probe/t42_epg_repro.py`）
         * ```text
         * get_timeshift("iptv", …)  ⇒ ★ **空响应**（不是报错，也不是流）
         * get_timeshift("srcl", …)  ⇒ {"url":"https://…index.m3u8","kind":"hls",…}
         * ```
         * ★ iptv.js 同样声明 `timeshift` 未实现（只声明了 `live: true`）
         * ⇒ 无条件调用 ⇒ `plugin.timeshift is not a function`。
         *
         * ⚠️ 与 `epg` 的**关键差别**：这里**不能**用"返回空值"降级 ——
         *    `timeshift` 的返回类型是 `StreamCandidate`（**非 Option**），
         *    没有"空流"这种合法值。
         * ⇒ 必须报**明确的不支持错误**（`unsupported`），
         *    让调用方能区分"这个源不支持时移"与"时移失败了"。
         *    ★ 与 `rank()` 的处理方式一致（它也是"没实现 ⇒ unsupported"）。
         */
        let expr = format!(
            "(plugin.timeshift ? plugin.timeshift({}, {}, {}) \
             : Promise.reject(new Error('unsupported: 该源不支持时移回看')))",
            serde_json::to_string(channel_id).unwrap_or_else(|_| "\"\"".into()),
            start,
            end
        );
        let json = self.call_js(&expr).await?;
        serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("timeshift() 返回格式不符: {e}")))
    }

    // ── 弹幕（task-T2，2026-10-16）────────────────────────────────
    //
    // # ★ 为什么必须桥接（漏掉的后果与 rank/episodes/sources 同类）
    //
    // `Capabilities.danmaku` 早就在界面上显示「弹幕」标签，
    // 但宿主**没有任何地方拿它去调插件** —— 插件作者想实现也无从下手。
    // 这类 bug **不报错、只是没内容**，最难发现（见本文件 L2036 的长注释）。
    //
    // ⚠️ 判形态用**三元式**而不是 try/catch —— 与 `rank()` / `epg()` 同纪律：
    //    先判方法在不在，让「方法存在但内部报错」原样透出，
    //    不被「捕获所有错误都当成不支持」吞掉。

    /// 取某一集的弹幕列表 —— 调插件的 `plugin.danmakuList(req)`
    async fn danmaku_list(&self, req: DanmakuRequest) -> Result<DanmakuBundle> {
        /*
         * ★ 剥掉 `{provider}:` 前缀再给插件 —— 与 `resolve()` / `detail()` 同纪律。
         *   `episodes[].id` 会被 `prefix_media_ids()` 加上前缀，插件收到
         *   `srca:51463` 会拿去当数字 id 用 → 上游 400（实测记录见本文件 L2119）。
         */
        let mut req = req;
        req.provider = self.manifest.id.clone();
        req.media_id = self.strip_prefix(&req.media_id);
        req.episode_id = self.strip_prefix(&req.episode_id);
        let req_js = rust_value_to_js(
            serde_json::to_value(&req).unwrap_or(serde_json::Value::Object(Default::default())),
        );
        let expr = format!(
            "(plugin.danmakuList ? plugin.danmakuList({}) : Promise.reject(new Error('unsupported: 该源不支持弹幕')))",
            serde_json::to_string(&req_js).unwrap_or_else(|_| "{}".into())
        );
        let json = self.call_js(&expr).await?;
        let mut bundle: DanmakuBundle = serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("danmakuList() 返回格式不符: {e}")))?;

        /*
         * ★★★ 给缺 cid 的弹幕补位 —— **没有这一步，插件弹幕会静默全丢**
         *
         * 宿主 `lib/core/danmaku.dart` 的 `DanmakuComment.fromJson` 在
         * `cid == null` 时**直接 return null（整条丢弃）**，且不抛异常。
         * 实测（`.probe/plugin-work/danmaku_wire_crosscheck_test.dart`）：
         * 3 条只有 {p, m} 的 wire 喂进去 ⇒ 3 条**全部**被丢弃。
         *
         * ⇒ 不补的话，表现是「弹幕加载成功但一条都没有」，
         *   用户与插件作者都**无从排查**。补位规则见 `fill_missing_cids`。
         */
        let filled = bundle.fill_missing_cids();
        if filled > 0 {
            log::debug!(
                "插件 {} 的 danmakuList 有 {} 条未带 cid，已按「下标+1」补位（宿主 fromJson 在 cid 缺失时会整条丢弃）",
                self.manifest.id,
                filled
            );
        }
        Ok(bundle)
    }

    /// 发送一条弹幕 —— 调插件的 `plugin.danmakuSend(req)`
    async fn danmaku_send(&self, req: DanmakuSendRequest) -> Result<DanmakuSendResult> {
        // 同样剥前缀（见 danmaku_list 里的说明）
        let mut req = req;
        req.provider = self.manifest.id.clone();
        req.episode_id = self.strip_prefix(&req.episode_id);
        let req_js = rust_value_to_js(
            serde_json::to_value(&req).unwrap_or(serde_json::Value::Object(Default::default())),
        );
        let expr = format!(
            "(plugin.danmakuSend ? plugin.danmakuSend({}) : Promise.reject(new Error('unsupported: 该源不支持发送弹幕')))",
            serde_json::to_string(&req_js).unwrap_or_else(|_| "{}".into())
        );
        let json = self.call_js(&expr).await?;
        let r: DanmakuSendResult = serde_json::from_str(&json)
            .map_err(|e| ProviderError::parse(format!("danmakuSend() 返回格式不符: {e}")))?;

        /*
         * ★★ 纪律兜底：`ok: false` **不是**合法结果
         *
         * 契约要求「未实现 / 被上游拒绝 ⇒ 抛 unsupported:/unauthorized:」。
         * 但插件作者可能写成 `return { ok: false }` —— 若宿主把它当
         * 「软失败」放过去，调用方就会以为**发送成功了**：
         * ```text
         * 用户以为发出去了 → 刷新找不到 → 反复发 →
         * 在真站点上可能**已经触发风控封禁**
         * ```
         * ⇒ 在这里就把它转成明确的 Unsupported，让 UI 能如实告知。
         *   宁可报错，也不给一个「看起来成功」的返回值。
         */
        if !r.ok {
            return Err(ProviderError::unsupported(
                "插件返回 ok=false —— 发送未成功。按契约应抛 unsupported:/unauthorized: 而不是返回 false（宿主不能把它当成软失败）",
            ));
        }
        Ok(r)
    }

}

// ─────────────────────────── 扫描插件目录 ───────────────────────────

/// 扫描目录下所有 `.js` 插件（**只做静态解析，不执行脚本**）
///
/// 返回 `(成功加载的插件, 失败原因列表)` —— **隔离失败**：
/// 一个坏插件不该影响其它插件可用。
///
/// ⚠️ 能力位还没补齐（要执行脚本才知道），
/// 调用方注册前必须逐个 `hydrate_capabilities()`。
pub fn load_plugins(dir: &std::path::Path) -> (Vec<JsPluginProvider>, Vec<(String, String)>) {
    let mut ok = Vec::new();
    let mut bad = Vec::new();

    let Ok(entries) = std::fs::read_dir(dir) else {
        return (ok, bad);
    };

    for e in entries.flatten() {
        let path = e.path();
        if path.extension().and_then(|s| s.to_str()) != Some("js") {
            continue;
        }
        let fname = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("?")
            .to_string();

        match std::fs::read_to_string(&path) {
            Ok(src) => match JsPluginProvider::from_source(&src) {
                Ok(p) => ok.push(p),
                Err(e) => bad.push((fname, e)),
            },
            Err(e) => bad.push((fname, format!("读取失败: {e}"))),
        }
    }

    (ok, bad)
}

/// 扫描 + 补齐能力位（**注册进 Registry 前用这个**）
///
/// 相比 `load_plugins` 多一步：执行脚本读 `capabilities`。
/// 少了这一步，插件在直播页/搜索页会完全不可见。
pub async fn load_plugins_hydrated(
    dir: &std::path::Path,
    proxy: Option<Arc<crate::proxy::ProxyStore>>,
) -> (Vec<JsPluginProvider>, Vec<(String, String)>) {
    let (plugins, bad) = load_plugins(dir);
    let mut out = Vec::with_capacity(plugins.len());
    // task-37: pool state lives next to third-party-providers.json
    let saved_pools = crate::hostpool::load(dir);
    // 插件私有数据放 `plugins/.data/`
    let data_dir = dir.join(".data");

    for mut p in plugins {
        if let Some(px) = proxy.clone() {
            p = p.with_proxy(px);
        }
        p = p.with_data_dir(data_dir.clone());
        p.hydrate_capabilities().await;
        // task-37: restore failure counts / current selection from disk.
        // hydrate rebuilt the pool from declarations; this re-attaches memory.
        p = p.with_pool_dir(dir.to_path_buf());
        p.apply_saved_pool(saved_pools.pools.get(&p.manifest().id));
        out.push(p);
    }

    (out, bad)
}

/// 校验插件源码能否加载（**真的执行一次**，但不调用任何方法）
///
/// 用途：编辑插件后保存前先验证 —— 语法错误（括号不配对、少个逗号）
/// 只有真正求值才能发现，光看 `@id` 是拦不住的。
///
/// 不会执行插件的方法（`home`/`resolve` 等），所以**不产生网络请求**，
/// 也不会因为插件逻辑本身有问题而误判为「语法错误」。
pub async fn validate_source(source: &str) -> std::result::Result<(), String> {
    let p = JsPluginProvider::from_source(source)?;

    // 只求值脚本本体 + 确认 plugin 对象存在，不调任何业务方法
    match p.call_js("(typeof plugin === 'object' && plugin !== null)").await {
        Ok(_) => Ok(()),
        Err(e) => Err(e.message),
    }
}

// ─────────────────────── 在线安装（GitHub → CDN）───────────────────────

/// 把用户粘贴的地址解析成**真正可下载的直链**
///
/// # 为什么要做这层
///
/// 用户复制的是 GitHub **页面**地址（`github.com/user/repo`），
/// 而 `raw.githubusercontent.com` 在国内**直连不通**（实测 12 秒超时）。
/// 实测可用的 CDN：
///
/// | 来源 | 实测（直连，不挂代理）|
/// |---|---|
/// | `cdn.jsdelivr.net` | ✅ 200，1.1 秒 ← 默认走这个 |
/// | `fastly.jsdelivr.net` | ✅ 200，1.5 秒 |
/// | `gcore.jsdelivr.net` | ✅ 200，2.7 秒 |
/// | `raw.githubusercontent.com` | ❌ 12 秒超时 |
///
/// 所以**默认走 jsDelivr**，用户不需要懂 raw 与 CDN 的区别，
/// 也不需要为此配代理。
///
/// # 支持的输入形态
///
/// | 用户粘贴 | 解析为 |
/// |---|---|
/// | `https://github.com/u/r` | `https://cdn.jsdelivr.net/gh/u/r@main/index.js` |
/// | `https://github.com/u/r/blob/main/src/x.js` | `.../gh/u/r@main/src/x.js` |
/// | `u/r` | 同上（补全）|
/// | 任意 `http(s)` 直链 | 原样返回 |
pub fn resolve_plugin_url(input: &str) -> std::result::Result<String, String> {
    let s = input.trim();
    if s.is_empty() {
        return Err("请填写插件地址".into());
    }

    if let Some(rest) = s
        .strip_prefix("https://github.com/")
        .or_else(|| s.strip_prefix("http://github.com/"))
    {
        return github_to_cdn(rest);
    }

    // 已经是直链（jsDelivr / raw / 自建服务器）→ 原样用
    if s.starts_with("http://") || s.starts_with("https://") {
        return Ok(s.to_string());
    }

    // `owner/repo` 简写
    if s.matches('/').count() == 1 && !s.contains(' ') {
        return github_to_cdn(s);
    }

    Err("无法识别的地址。支持：GitHub 仓库地址、owner/repo，或任意 http(s) 直链".into())
}

/// `owner/repo` 或 `owner/repo/blob/branch/path` → jsDelivr CDN 地址
fn github_to_cdn(rest: &str) -> std::result::Result<String, String> {
    let rest = rest.trim_end_matches('/');
    let parts: Vec<&str> = rest.split('/').filter(|s| !s.is_empty()).collect();
    if parts.len() < 2 {
        return Err("GitHub 地址至少要包含 owner/repo".into());
    }
    let (owner, repo) = (parts[0], parts[1]);

    // 形如 owner/repo/blob/<branch>/<path...>
    if parts.len() >= 5 && (parts[2] == "blob" || parts[2] == "raw") {
        let branch = parts[3];
        let path = parts[4..].join("/");
        return Ok(format!(
            "https://cdn.jsdelivr.net/gh/{owner}/{repo}@{branch}/{path}"
        ));
    }

    // 仓库根 → 默认入口文件 index.js。
    // 分支名固定试 main；下载失败会自动退到 master（见 fetch_plugin_source）——
    // GitHub 已改默认分支名，让用户记得自己用哪个是不现实的。
    Ok(format!(
        "https://cdn.jsdelivr.net/gh/{owner}/{repo}@main/index.js"
    ))
}

/// 下载插件源码（CDN 失败时自动退到另一分支名与 raw）
///
/// 返回 `(源码, 实际使用的地址)` —— 地址要回传给用户，
/// 否则出问题（如「装的还是旧版」）没法排查。
pub async fn fetch_plugin_source(
    proxy: Option<&Arc<crate::proxy::ProxyStore>>,
    url: &str,
) -> std::result::Result<(String, String), String> {
    /*
     * ⚠️ 这里**故意**保留字面量 key（与 do_http / do_http_full / probe_url 不同）。
     *
     * 理由：本函数是「安装插件时下载它的源码」—— 此刻**插件还不存在**，
     * 没有任何 provider id 可用。用户能给的是「下载插件用哪个代理」这种
     * 全局设置，所以用固定 key 是语义正确的，不是漏改。
     */
    let client = match proxy {
        Some(px) => px
            .client_for("plugin", None)
            .unwrap_or_else(|_| default_client()),
        None => default_client(),
    };

    /* 候选地址，按「最可能成功」排序
     *
     * 1. 解析出来的（默认 jsDelivr）
     * 2. 换另一个分支名 —— 仓库默认分支是 main 还是 master，用户不会记得
     * 3. raw（国内通常不通，但用户配了代理就能用）
     */
    let mut candidates = vec![url.to_string()];
    if url.contains("cdn.jsdelivr.net/gh/") {
        if url.contains("@main/") {
            candidates.push(url.replace("@main/", "@master/"));
        } else if url.contains("@master/") {
            candidates.push(url.replace("@master/", "@main/"));
        }
        candidates.push(
            url.replace("https://cdn.jsdelivr.net/gh/", "https://raw.githubusercontent.com/")
                .replace('@', "/"),
        );
    }

    let mut tried = Vec::new();
    for c in candidates {
        tried.push(c.clone());
        match client.get(&c).send().await {
            Ok(r) if r.status().is_success() => match r.text().await {
                Ok(t) => {
                    // ★ 校验拿到的确实是插件，而不是 CDN 返回的 HTML 错误页
                    //   （jsDelivr 对不存在的路径会返回 HTML，直接写盘会得到一个坏插件）
                    if !t.contains("@id") {
                        continue;
                    }
                    return Ok((t, c));
                }
                Err(_) => continue,
            },
            _ => continue,
        }
    }

    Err(format!(
        "下载失败，已尝试 {} 个地址：\n{}\n\n\
         可能原因：地址写错、仓库里没有 index.js、或网络受限。\n\
         若网络受限，可在「网络代理」里给插件下载配置代理。",
        tried.len(),
        tried.join("\n")
    ))
}

// ═══════════════════════════════════════════════════════════════════════
//  插件「安装来源 / 版本历史 / 回滚」（task-23，2026-09-25）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这一块
//
// 用户拍板：
// > 通过链接检测更新,可以进行回滚
// > 插件市场暂时不做  github raw 暂时不做
//
// 「通过链接检测更新」的技术前提是**得知道当初是哪个链接装的** ——
// 而实测发现：`install_plugin` 一直**返回** `resolvedUrl`，
// 却**从不落盘** → 装完之后就再也找不到"去哪查新版"。
// 所以这一块的第一件事是把来源记住。
//
// # 磁盘布局（**全是 sidecar，绝不改插件本体**）
//
// ```text
// <dataDir>/plugins/
//   ├── 154.js                     ← 插件本体（用户能直接看/改，不动它）
//   ├── .data/154.json             ← 插件私有配置（已有，绝不能碰）
//   ├── .meta/154.json             ← ★ 本模块：安装来源
//   └── .versions/                 ← ★ 本模块：历史版本
//         ├── 154@1.0.0.js
//         └── 154@2.0.0.js
// ```
//
// ⚠️ 为什么用 `.meta/` 而不是把来源写进 `.js` 的头部注释：
// ```text
// ① 插件本体是**用户的文件**（用户能"打开看、自己改"）——
//    我们往里塞字段，用户改完保存就会丢掉，或产生 diff 噪音
// ② `.js` 的头部注释是**插件作者**的地盘（@id/@name/@version），
//    宿主往里写东西等于篡改作者的产物
// ③ 分离之后：删掉 .meta 只是"忘了来源"，插件照样能用（优雅降级）
// ```
//
// ⚠️ 目录名以 `.` 开头是有意的：`load_plugins` 只扫 `*.js`，
//    点目录天然不会被打扰；用户也不容易误删。

/// 插件安装来源（`plugins/.meta/<id>.json`）
///
/// # 字段与理由
///
/// ```text
/// source_url    当初安装用的**最终解析地址**（install_plugin 的 resolvedUrl）
///               ⚠️ 存 resolvedUrl 而不是用户输入的原始链接：
///                  原始链接可能是"插件市场页"，而真正能 GET 到 JS 的是解析后的地址。
///                  检测更新时直接 GET 这个，不用再解析一次（也避免解析规则变化）。
///
/// installed_version  安装/更新时插件声明的 @version
///                    用于"远端版本 vs 本地版本"的比较基准
///
/// installed_at  Unix 秒。给界面显示"什么时候装的"
/// file          装成了哪个文件名（`154.js`）—— 回滚要写回这个文件
/// ```
///
/// ⚠️ 没有 `sha256` 字段：实测 `sha2` 不在依赖树里，加它要动 `Cargo.toml`。
///    "内容没变就别覆盖"这个需求的**实质**是"比对内容"，
///    而**直接逐字节比对**比 hash 更准（无碰撞可能）且零依赖 ——
///    见 `same_content()`。
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct PluginSourceMeta {
    /// 安装来源链接（`None` = 没有来源，例如用户手动丢进目录的）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    #[serde(default)]
    pub installed_version: String,
    /// Unix 秒
    #[serde(default)]
    pub installed_at: i64,
    /// 装成的文件名（`154.js`）
    #[serde(default)]
    pub file: String,
}

/// `plugins/.meta/` 目录
pub fn plugin_meta_dir(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join(".meta")
}

/// `plugins/.versions/` 目录
pub fn plugin_versions_dir(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join(".versions")
}

/// `<dir>/.meta/<id>.json` 的路径
///
/// ⚠️ `id` 直接进文件名 → 必须过滤字符集，否则 `../../x` 能写到插件目录外。
///    与 `save_plugin()` 用**同一套**规则（那里已经踩过一次，见其注释）。
fn plugin_source_meta_path(dir: &std::path::Path, id: &str) -> Option<std::path::PathBuf> {
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        || id.is_empty()
    {
        return None;
    }
    Some(plugin_meta_dir(dir).join(format!("{id}.json")))
}

/// 当前 Unix 秒（读 meta 时用来兜底 `installed_at == 0` 的老数据）
fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 读安装来源
///
/// # ★ 老数据必须优雅处理（本机 26 个插件全都没有 meta）
///
/// ```text
/// 文件不存在      → Ok(None)      ← 不是错误！"没有来源"是完全正常的状态
/// JSON 坏了       → Ok(None) + 警告日志（不能因为一个坏文件就让设置页打不开）
/// id 非法         → Ok(None)
/// ```
/// ⚠️ 一律**不返回 Err**：调用方（设置页）要能无条件列出全部插件，
///    某个插件缺 meta 只是"查不了更新"，不该让整个列表失败。
pub fn read_plugin_meta(dir: &std::path::Path, id: &str) -> Option<PluginSourceMeta> {
    let path = plugin_source_meta_path(dir, id)?;
    let raw = std::fs::read_to_string(&path).ok()?;
    match serde_json::from_str::<PluginSourceMeta>(&raw) {
        Ok(m) => Some(m),
        Err(e) => {
            // ★ 坏文件只记日志、不算错 —— 见上面的说明
            log::warn!("插件 meta 解析失败（忽略，当作没有来源）: {path:?}: {e}");
            None
        }
    }
}

/// 写安装来源（自动建目录）
pub fn write_plugin_meta(
    dir: &std::path::Path,
    id: &str,
    meta: &PluginSourceMeta,
) -> std::result::Result<(), String> {
    let path = plugin_source_meta_path(dir, id)
        .ok_or_else(|| format!("插件 @id 含非法字符（只允许字母/数字/-/_）: {id}"))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建 .meta 目录失败: {e}"))?;
    }
    let body = serde_json::to_string_pretty(meta).map_err(|e| format!("序列化失败: {e}"))?;
    std::fs::write(&path, body).map_err(|e| format!("写入 {path:?} 失败: {e}"))
}

/// 「内容没变」判定 —— **直接逐字节比对**（不引入 hash 依赖）
///
/// # 为什么不用 sha256（这是有意的技术选择，不是省事）
///
/// 需求的实质是"内容没变就别覆盖"。两条路：
/// ```text
/// ① 存 sha256 再比指纹 —— 理论上有碰撞（虽然极小），且**要加依赖**
///    （实测 `sha2` 不在依赖树里，加它要改 Cargo.toml）
/// ② 直接比内容         —— **精确**（无碰撞概念），零依赖
/// ```
/// 这里选 ②：下载回来的源码本来就在内存里，本地文件也就几十 KB，
/// 直接 `==` 比读一遍文件再算哈希**更快**（少一趟哈希计算）。
pub fn same_content(a: &str, b: &str) -> bool {
    /*
     * ⚠️ 行尾差异要归一化：远端仓库可能是 CRLF，本地写盘后是原样字节。
     *    不归一化的话，"内容其实一样"会被判成"有更新"，
     *    然后白白覆盖一次、还多存一个历史档 —— 用户看到的是
     *    "版本号没变却提示更新了"。所以按行比较、忽略 \r。
     */
    let norm = |s: &str| -> Vec<String> {
        s.lines().map(|l| l.trim_end_matches('\r').to_string()).collect()
    };
    norm(a) == norm(b)
}

/// 语义化版本比较：`a` 是否**比** `b` 新
///
/// # ★ 为什么不能直接比字符串（这是本模块最容易写错的地方）
///
/// ```text
/// "1.10.0" > "1.9.0"  字符串比较 → false  ★ 错！（"1" < "9"）
/// "1.10.0" > "1.9.0"  按数字段比 → true   ✓
/// "1.2.3"  > "1.2.10" 字符串比较 → true   ★ 错！
/// "1.2.3"  > "1.2.10" 按数字段比 → false  ✓
/// ```
/// 版本号是**数字段序列**，必须逐段转数字比。这是经典陷阱
///（用户装的插件里 `1.10.0` 和 `1.9.0` 同时存在时就会踩到）。
///
/// # 规则（够用且不会误判）
///
/// ```text
/// · 按 `.` 切段，每段取**开头的数字**（"3-beta" → 3）
/// · 逐段比数字；段数不同时缺的段按 0 算（"1.2" == "1.2.0"）
/// · 段里有非数字前缀（"v1.2"）也能解析出来（取第一段数字）
/// · 无法解析的段按 0（宁可判"没有新版"，也不要误报更新）
/// ```
///
/// ⚠️ 不处理 `-alpha`/`+build` 这类**预发布**语义（`1.0.0-beta < 1.0.0`）——
///    插件生态里没人用；真遇到时按"数字段相等"处理，即**不提示更新**（保守）。
pub fn version_is_newer(remote: &str, local: &str) -> bool {
    fn segment(s: &str) -> u64 {
        let digits: String = s
            .trim_start_matches(|c: char| !c.is_ascii_digit())
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        digits.parse::<u64>().unwrap_or(0)
    }
    let r: Vec<u64> = remote.split('.').map(segment).collect();
    let l: Vec<u64> = local.split('.').map(segment).collect();
    let n = r.len().max(l.len());
    for i in 0..n {
        // 缺的段按 0：这样 "1.2" 与 "1.2.0" 相等（不会假报更新）
        let a = *r.get(i).unwrap_or(&0);
        let b = *l.get(i).unwrap_or(&0);
        if a != b {
            return a > b;
        }
    }
    false
}

/// `.versions` 每个插件**保留几档**历史
///
/// # 为什么是 5（判断说明，不是随手定的数）
///
/// ```text
/// 用户的诉求是「可以回滚」—— 实际场景是"升级后发现不好用，退回去"，
/// 也就是**回一档**占 95%。留 5 档的余量是为了：
///   ① 连续两次踩坑（升了 A 不好 → 回滚 → 又装了 B 不好 → 再回滚）
///   ② 用户可能想看看"三个版本前是什么样"
///
/// 磁盘：单个插件约 10~60KB → 5 档 ≈ 最多 300KB/插件。
///       26 个插件最坏 26 × 300KB ≈ 7.8MB —— 可接受。
///       留 20 档就是 31MB，只是为了极罕见的场景，不值得。
/// ```
pub const MAX_PLUGIN_VERSIONS: usize = 5;

/// 把**当前**插件内容归档为一档历史
///
/// 返回归档文件路径（失败返回 Err —— 调用方决定是否让整个更新失败）。
///
/// ⚠️ 文件名用 `<id>@<version>.js`：
/// ```text
/// · 带 version 让用户/我们一眼看出这是哪一版（比时间戳可读得多）
/// · 同版本重复归档会**覆盖**同一个文件 —— 这是有意的：
///   同版本内容不同只可能是"作者改了内容没改版本号"，
///   留两份同名版本反而让"回滚到 vX"变成歧义
/// ```
pub fn archive_plugin_version(
    dir: &std::path::Path,
    id: &str,
    version: &str,
    source: &str,
) -> std::result::Result<std::path::PathBuf, String> {
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        || id.is_empty()
    {
        return Err(format!("插件 @id 含非法字符: {id}"));
    }
    // 版本号进文件名 → 同样要过滤（版本号是插件作者写的，不可信）
    let v: String = version
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_')
        .collect();
    let v = if v.is_empty() { "unknown".to_string() } else { v };

    let vdir = plugin_versions_dir(dir);
    std::fs::create_dir_all(&vdir).map_err(|e| format!("创建 .versions 失败: {e}"))?;
    let path = vdir.join(format!("{id}@{v}.js"));
    std::fs::write(&path, source).map_err(|e| format!("归档历史版本失败: {e}"))?;
    Ok(path)
}

/// 列出某个插件的全部历史档（**新→旧**排序）
///
/// 返回 `(version, 文件路径)`。
///
/// ⚠️ 排序按 `version_is_newer` 而不是文件名字符串 ——
///    否则 `1.10.0` 会排在 `1.9.0` 前面（同一条版本比较陷阱）。
///    解析不出文件名格式的（用户手动放进来的）按 "0" 处理、排最后。
pub fn list_plugin_versions(
    dir: &std::path::Path,
    id: &str,
) -> Vec<(String, std::path::PathBuf)> {
    let vdir = plugin_versions_dir(dir);
    let Ok(rd) = std::fs::read_dir(&vdir) else {
        return Vec::new(); // 目录不存在 = 没有历史（正常，不是错误）
    };
    let prefix = format!("{id}@");
    let mut out: Vec<(String, std::path::PathBuf)> = Vec::new();
    for e in rd.flatten() {
        let path = e.path();
        if path.extension().and_then(|s| s.to_str()) != Some("js") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let Some(rest) = stem.strip_prefix(&prefix) else {
            continue; // 不是这个插件的
        };
        out.push((rest.to_string(), path));
    }
    // 新 → 旧
    out.sort_by(|a, b| {
        if version_is_newer(&a.0, &b.0) {
            std::cmp::Ordering::Less
        } else if version_is_newer(&b.0, &a.0) {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    });
    out
}

/// 清理 `.versions`，每个插件只留最近 [`MAX_PLUGIN_VERSIONS`] 档
///
/// 返回被删掉的文件数。
///
/// # 为什么每次归档后都调（而不是定时任务）
///
/// ```text
/// ① 归档是**低频**操作（用户点"更新"才发生）→ 顺便清理零成本
/// ② 定时任务要额外状态（上次清理时间），还可能被用户关掉
/// ③ 每次归档后立刻清理 → **.versions 永远有界**，
///    不存在"涨到几个 GB 才发现"的窗口
/// ```
///
/// ⚠️ 删的是**最旧**的档（`list_plugin_versions` 已是新→旧）。
pub fn prune_plugin_versions(dir: &std::path::Path, id: &str) -> usize {
    let all = list_plugin_versions(dir, id);
    if all.len() <= MAX_PLUGIN_VERSIONS {
        return 0;
    }
    let mut removed = 0;
    for (v, path) in all.into_iter().skip(MAX_PLUGIN_VERSIONS) {
        match std::fs::remove_file(&path) {
            Ok(_) => {
                removed += 1;
                log::info!("清理旧版本档 {id}@{v}");
            }
            Err(e) => log::warn!("清理 {path:?} 失败: {e}"),
        }
    }
    removed
}

/// 写入插件文件（文件名由 id 派生，避免覆盖别人的插件）
pub fn save_plugin(
    dir: &std::path::Path,
    id: &str,
    source: &str,
) -> std::result::Result<(String, u64), String> {
    if id.is_empty() {
        return Err("插件缺少 @id".to_string());
    }
    // ★ 防目录穿越：id 会进文件名，必须限制字符集
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(format!("插件 @id 含非法字符（只允许字母/数字/-/_）: {id}"));
    }

    std::fs::create_dir_all(dir).map_err(|e| format!("创建插件目录失败: {e}"))?;
    let file = format!("{id}.js");
    std::fs::write(dir.join(&file), source).map_err(|e| format!("写入失败: {e}"))?;

    Ok((file, source.len() as u64))
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// ★ 元信息解析：多个 tag 在同一行也要能解析
    ///
    /// 实测踩过：按「行首前缀」匹配时**一个都匹配不到**，
    /// 因为真实写法常是 `/** @name 某电视台站 @version 1.0.0 @id srcl */`。
    #[test]
    fn parses_meta_on_single_line() {
        let src = "/** @name 某电视台站 @version 1.0.0 @author dsh @id srcl */\ncode";
        let m = parse_meta(src);
        assert_eq!(m.id, "srcl");
        assert_eq!(m.name, "某电视台站");
        assert_eq!(m.version, "1.0.0");
        assert_eq!(m.author, "dsh");
    }

    // ═══════════════════════════════════════════════════════════════
    //  task-5：上游接口地址提取（缺陷 5）
    // ═══════════════════════════════════════════════════════════════

    /// ★★ 转换器生成的插件：头部注释里的上游接口要能提出来
    ///
    /// 这是缺陷 5 的主路径 —— 本机 22 个 `tvbox-convert` 插件**全部**
    /// 靠这条拿到链接（实测 22/22 命中）。
    #[test]
    fn upstream_from_head_comment() {
        // 真实文件 `tyyszy.js` 的头部（逐字抄，只截了相关几行）
        let src = "/**\n * 影视天涯 —— 由 TVBox 源自动转换\n *\n * @id tyyszy\n * @author tvbox-convert\n *\n * 上游接口（苹果CMS v10）：http://tyyszy.com/api.php/provide/vod\n *\n * ⚠️ 这是**自动生成**的插件。\n */\nconst API = \"http://tyyszy.com/api.php/provide/vod\";";
        assert_eq!(upstream_of(src), "http://tyyszy.com/api.php/provide/vod");
    }

    /// ★★★ 手写插件**不能**拿正文 `const API` 当来源（2026-10-09 修掉的 bug）
    ///
    /// Owner 报的症状（截图）：源码装的 `srcv` 插件，点「编辑」显示成了
    /// 「链接安装」并预填 `https://api.example-v.com` —— 那是**接口地址**。
    ///
    /// # 原实现与危害
    /// ```text
    /// 原来这条回退是"预期行为"，还配了单测（本测试的旧版本）。
    /// 但 upstream 被 UI 用来判「这个插件是不是按链接装的」（plugin_edit_dialog.dart:197）
    /// ⇒ 误判成链接型 ⇒ 编辑框预填接口地址 + 类型锁死
    /// ⇒ 点保存走 install_plugin(那个地址) ⇒ **把本地插件覆盖坏**。
    /// ```
    ///
    /// ⇒ 现在只认头部注释的「上游接口」；正文常量一律不认，返回空串。
    ///   `srcv` 属于"用户自己写的源码"，本来就没有安装来源。
    #[test]
    fn upstream_ignores_body_const_api() {
        // ① 头部只有元信息、正文有 const API ⇒ 必须为空（这正是 srcv 的形状）
        let bili = "/** @id srcv @name 外部视频源 @author dsh */\nconst API = 'https://api.example-v.com';";
        assert_eq!(upstream_of(bili), "", "接口地址不能被当成安装来源");
        // ② 三种引号都不认（整条回退都删了，不是只改一种）
        assert_eq!(upstream_of("const API = \"https://a.example.com\""), "");
        assert_eq!(upstream_of("const API = `https://b.example.com`"), "");
        // ③ 但头部有「上游接口」时照常认 —— 转换器插件的主路径不受影响
        let conv = "/**\n * 影视天涯\n * 上游接口（苹果CMS v10）：http://tyyszy.com/api.php/provide/vod\n */\nconst API = \"http://tyyszy.com/api.php/provide/vod\";";
        assert_eq!(upstream_of(conv), "http://tyyszy.com/api.php/provide/vod");
    }

    /// ★★ 宁可为空也不能给错 —— 界面会把它当"上游链接"展示并可复制
    ///
    /// 三类的拒绝理由：
    /// ```text
    /// ① 相对路径    用户复制出来是个不能用的东西
    /// ② 非 http 协议 file:// / javascript: 之类不该出现在"上游"位置
    /// ③ 没有链接     本机 4 个内置源（srcl/srca/iptv/tvbox-live）就是这种
    /// ```
    #[test]
    fn upstream_is_empty_rather_than_wrong() {
        // ① 相对路径
        assert_eq!(upstream_of("const API = '/api.php/provide/vod'"), "");
        // ② 非 http(s)
        assert_eq!(upstream_of("const API = 'ftp://x.example.com'"), "");
        // ③ 完全没有
        assert_eq!(upstream_of("globalThis.plugin = { id: 'srcl' };"), "");
        // ④ 头部那行是相对路径时，**不再**去看正文 —— 正文那条已删（会误判成来源）
        let src = "/** 上游接口（苹果CMS v10）：/api.php/provide/vod */\nconst API = 'https://real.example.com';";
        assert_eq!(upstream_of(src), "", "相对路径照旧不认，且不回头扫正文");
    }

    /// ★ 拼接式 `const API = base + "/x"` 也不能被扫出来（这条回退整个删了）
    ///
    /// 原来专门有个"只认第一个引号"的逻辑来防它 —— 现在不需要了，
    /// 因为正文常量一律不看。保留断言是为了锁住"不会哪天又加回来"。
    #[test]
    fn upstream_ignores_concatenated_const_api() {
        let src = "const API = base + \"/api.php/provide/vod\";";
        assert_eq!(upstream_of(src), "");
    }

    // ═══════════════════════════════════════════════════════════════
    //  task-23：版本比较 / 元数据 / 历史档 / 老数据兼容
    // ═══════════════════════════════════════════════════════════════

    /// ★★ 版本比较必须按**数字段**比，不能按字符串
    ///
    /// 这是本任务最容易写错的地方 —— 验收明确要求这两条：
    /// ```text
    /// 1.10.0 > 1.9.0   字符串比较会得 false（"1" < "9"）★ 错
    /// 1.2.3 > 1.2.10   字符串比较会得 true              ★ 错
    /// ```
    #[test]
    fn version_compare_is_numeric() {
        assert!(
            version_is_newer("1.10.0", "1.9.0"),
            "1.10.0 应比 1.9.0 新（字符串比较会判错）"
        );
        assert!(
            !version_is_newer("1.2.3", "1.2.10"),
            "1.2.3 不应比 1.2.10 新（字符串比较会判错）"
        );
        // 常规
        assert!(version_is_newer("2.0.0", "1.9.9"));
        assert!(version_is_newer("1.0.1", "1.0.0"));
        assert!(!version_is_newer("1.0.0", "1.0.0"), "相等不算更新");
        assert!(!version_is_newer("1.0.0", "1.0.1"), "更旧不算更新");
        // 段数不同：缺的段按 0（"1.2" == "1.2.0"，不假报更新）
        assert!(!version_is_newer("1.2", "1.2.0"));
        assert!(!version_is_newer("1.2.0", "1.2"));
        assert!(version_is_newer("1.2.1", "1.2"));
        // 容错：前缀非数字 / 段里有非数字后缀
        assert!(version_is_newer("v1.3.0", "v1.2.0"), "带 v 前缀也要能比");
        assert!(version_is_newer("1.3.0-beta", "1.2.0"), "带后缀要取到数字");
        // 极端：完全解析不出来的按 0 → 保守（不报更新）
        assert!(!version_is_newer("abc", "def"));
        assert!(!version_is_newer("", "1.0.0"));
    }

    /// 「内容没变」判定：忽略行尾差异，但不忽略真实差异
    #[test]
    fn same_content_normalizes_line_endings() {
        assert!(same_content("a\nb\n", "a\nb\n"));
        assert!(same_content("a\r\nb\r\n", "a\nb\n"), "CRLF / LF 视为同一内容");
        assert!(!same_content("a\nb\n", "a\nc\n"));
        assert!(!same_content("a\n", "a\nb\n"), "多一行就是不同");
    }

    /// 元数据 sidecar 往返 + **老数据（没有 meta）不报错**
    #[test]
    fn meta_roundtrip_and_missing_is_ok() {
        let dir = std::env::temp_dir().join(format!("sourin_meta_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // ★ 老数据：本机 26 个插件全都没有 meta → 必须返回 None，不是 Err
        assert!(
            read_plugin_meta(&dir, "nonexistent").is_none(),
            "没有 meta 是**正常状态**（手动放入的插件），不能报错"
        );

        let m = PluginSourceMeta {
            source_url: Some("https://example.com/x.js".into()),
            installed_version: "1.2.3".into(),
            installed_at: 1234567,
            file: "x.js".into(),
        };
        write_plugin_meta(&dir, "x", &m).unwrap();
        let got = read_plugin_meta(&dir, "x").expect("应能读回");
        assert_eq!(got.source_url.as_deref(), Some("https://example.com/x.js"));
        assert_eq!(got.installed_version, "1.2.3");
        assert_eq!(got.installed_at, 1234567);

        // ★ 坏 JSON 也不能让调用方失败（设置页要能列出全部插件）
        std::fs::write(plugin_meta_dir(&dir).join("bad.json"), "{ not json").unwrap();
        assert!(read_plugin_meta(&dir, "bad").is_none(), "坏 meta 当作没有来源");

        // ★ id 含非法字符 → 不能写出目录外（防目录穿越）
        let evil = PluginSourceMeta::default();
        assert!(write_plugin_meta(&dir, "../escape", &evil).is_err());
        assert!(read_plugin_meta(&dir, "../escape").is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }


    /// ★ host.base() 必须真的可用（task-37）
    ///
    /// # 这条钉的是一个真 bug
    ///
    /// 主机先 `g.set("host", host_obj)` 注入了 base()，
    /// 但紧接着的 shim 又 `globalThis.host = { http, log, store, ... }`
    /// **整体重写**了 host —— base() 被冲掉。
    /// 插件调 `host.base()` 会拿到 undefined，拼出 `undefined/api/list`。

    // ═══════════════════════════════════════════════════════════════
    //  通用提取器（task-41）
    // ═══════════════════════════════════════════════════════════════


    // ═══════════════════════════════════════════════════════════════
    //  播放地址探测（task-41 第 2 步）
    // ═══════════════════════════════════════════════════════════════

    #[test]
    fn classify_hls_from_content_type() {
        let v = classify_stream(200, "application/vnd.apple.mpegurl", "", "https://x.com/a");
        match v {
            ProbeVerdict::Playable { kind, .. } => {
                assert_eq!(kind, crate::model::StreamKind::Hls);
            }
            other => panic!("应是 Hls，实际: {other:?}"),
        }
    }

    #[test]
    fn classify_mp4_from_content_type() {
        let v = classify_stream(200, "video/mp4", "", "https://x.com/a");
        assert!(matches!(
            v,
            ProbeVerdict::Playable {
                kind: crate::model::StreamKind::Mp4,
                ..
            }
        ));
    }

    #[test]
    fn classify_audio_from_content_type() {
        let v = classify_stream(200, "audio/mpeg", "", "https://x.com/a");
        assert!(matches!(
            v,
            ProbeVerdict::Playable {
                kind: crate::model::StreamKind::AudioOnly,
                ..
            }
        ));
    }

    /// ★ DASH 必须如实报「未实现」，不能报 Playable 也不能报 Unreachable
    #[test]
    fn dash_is_reported_as_unsupported_not_playable() {
        let v = classify_stream(200, "application/dash+xml", "", "https://x.com/a.mpd");
        assert!(
            matches!(v, ProbeVerdict::DashUnsupported { .. }),
            "DASH 应报 DashUnsupported（不是 Playable），实际: {v:?}"
        );
        assert!(!v.retryable(), "DASH 是未实现，重试无用");
        assert!(
            v.user_message().contains("DASH"),
            "文案要说明是 DASH 格式，实际: {}",
            v.user_message()
        );
    }

    /// ★ 伪装后缀：.mp3 后缀但 video/mp4 ⇒ 必须按 Mp4（不能信后缀）
    #[test]
    fn disguised_extension_defers_to_content_type() {
        let v = classify_stream(200, "video/mp4", "", "https://x.com/abc.mp3");
        assert!(matches!(
            v,
            ProbeVerdict::Playable {
                kind: crate::model::StreamKind::Mp4,
                ..
            }
        ));
    }

    /// 响应头缺失 ⇒ 退回按 URL 判断
    #[test]
    fn empty_content_type_falls_back_to_url() {
        let v = classify_stream(200, "", "", "https://x.com/a.m3u8?t=1");
        assert!(matches!(
            v,
            ProbeVerdict::Playable {
                kind: crate::model::StreamKind::Hls,
                ..
            }
        ));
    }

    #[test]
    fn http_error_is_unreachable_and_retryable() {
        let v = classify_stream(404, "video/mp4", "", "https://x.com/a");
        assert!(matches!(v, ProbeVerdict::Unreachable { .. }));
        assert!(v.retryable(), "HTTP 失败应可重试");
    }

    #[test]
    fn status_zero_is_unreachable() {
        let v = classify_stream(0, "", "", "https://x.com/a");
        assert!(matches!(v, ProbeVerdict::Unreachable { .. }));
    }

    /// ★★ 关键：SAMPLE-AES 的 HLS 格式正确但放不了 ⇒ 必须报 DRM
    #[test]
    fn hls_with_sample_aes_is_drm_not_playable() {
        let manifest = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\"\n";
        let v = classify_stream(200, "application/vnd.apple.mpegurl", manifest, "https://x.com/a.m3u8");
        assert!(
            matches!(v, ProbeVerdict::DrmProtected { .. }),
            "SAMPLE-AES 应报 DrmProtected，实际: {v:?}"
        );
        assert!(!v.retryable(), "DRM 是架构限制，重试无用");
    }

    /// ★★ 反例：AES-128 是普通加密，libmpv 能解 ⇒ **不算 DRM**
    ///
    /// 若把它当 DRM，一大批本来能播的内容会被误判为不可播。
    #[test]
    fn hls_with_aes128_is_playable_not_drm() {
        let manifest = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n";
        let v = classify_stream(200, "application/vnd.apple.mpegurl", manifest, "https://x.com/a.m3u8");
        assert!(
            matches!(v, ProbeVerdict::Playable { .. }),
            "AES-128 能解，不该判 DRM，实际: {v:?}"
        );
    }

    #[test]
    fn dash_widevine_is_drm() {
        let mpd = r#"<ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/>"#;
        let v = classify_stream(200, "application/dash+xml", mpd, "https://x.com/a.mpd");
        assert!(
            matches!(v, ProbeVerdict::DrmProtected { .. }),
            "Widevine 应报 DrmProtected（优先于 DashUnsupported），实际: {v:?}"
        );
    }

    #[test]
    fn dash_playready_is_drm() {
        let mpd = r#"<ContentProtection schemeIdUri="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95"/>"#;
        let v = classify_stream(200, "application/dash+xml", mpd, "https://x.com/a.mpd");
        assert!(matches!(v, ProbeVerdict::DrmProtected { .. }));
    }

    /// DRM 文案不能与 DASH 文案混淆
    #[test]
    fn drm_and_dash_messages_are_distinct() {
        let drm = ProbeVerdict::DrmProtected {
            reason: "x".into(),
        };
        let dash = ProbeVerdict::DashUnsupported {
            content_type: "x".into(),
        };
        assert_ne!(drm.user_message(), dash.user_message());
        assert!(!drm.retryable(), "DRM 重试无用");
        assert!(!dash.retryable(), "DASH 重试无用");
    }


    /// ★★ text/html 必须判「不是流」，不能退回按 URL 猜
    ///
    /// 真实场景：防盗链拦截返回错误页 / 跳转到登录页。
    /// 若这时按 URL 猜成 Mp4，插件以为拿到能播地址，播放器黑屏 —— 最难查的一类。
    #[test]
    fn html_response_is_not_a_stream_even_if_url_looks_like_mp4() {
        let v = classify_stream(200, "text/html; charset=utf-8", "", "https://x.com/a.mp4");
        assert!(
            matches!(v, ProbeVerdict::NotAStream { .. }),
            "text/html 应报 NotAStream（不是按 URL 猜成 Mp4），实际: {v:?}"
        );
        assert!(!v.retryable(), "内容不对，重试无用");
    }

    #[test]
    fn json_response_is_not_a_stream() {
        let v = classify_stream(200, "application/json", "", "https://x.com/a.m3u8");
        assert!(matches!(v, ProbeVerdict::NotAStream { .. }), "实际: {v:?}");
    }

    /// 五种 verdict 的标签必须互不相同（插件靠它做分支）
    #[test]
    fn verdict_tags_are_distinct() {
        let all = [
            ProbeVerdict::Playable {
                kind: crate::model::StreamKind::Mp4,
                content_type: String::new(),
            },
            ProbeVerdict::DashUnsupported {
                content_type: String::new(),
            },
            ProbeVerdict::DrmProtected {
                reason: String::new(),
            },
            ProbeVerdict::NotAStream {
                content_type: String::new(),
            },
            ProbeVerdict::Unreachable {
                detail: String::new(),
            },
        ];
        let mut tags: Vec<&str> = all.iter().map(|v| v.verdict_tag()).collect();
        tags.sort_unstable();
        tags.dedup();
        assert_eq!(tags.len(), 5, "五个标签必须互不相同，实际: {tags:?}");
    }

    /// 五种 verdict 的文案必须互不相同（用户要能区分该不该重试）
    #[test]
    fn verdict_messages_are_distinct() {
        let msgs = [
            ProbeVerdict::Playable {
                kind: crate::model::StreamKind::Mp4,
                content_type: String::new(),
            }
            .user_message(),
            ProbeVerdict::DashUnsupported {
                content_type: String::new(),
            }
            .user_message(),
            ProbeVerdict::DrmProtected {
                reason: String::new(),
            }
            .user_message(),
            ProbeVerdict::NotAStream {
                content_type: "text/html".into(),
            }
            .user_message(),
            ProbeVerdict::Unreachable {
                detail: "timeout".into(),
            }
            .user_message(),
        ];
        let mut s: Vec<String> = msgs.to_vec();
        s.sort();
        s.dedup();
        assert_eq!(s.len(), 5, "五条文案必须互不相同，实际: {msgs:?}");
    }

    /// ★ host.playback.probe 契约：从 JS 侧真调用
    #[tokio::test]
    async fn host_playback_probe_is_callable_from_plugin() {
        // 指向必然不可达的地址（.invalid 是 RFC 2606 保留 TLD）
        let src = r#"
/** @id probedemo @name probe test */
globalThis.plugin = {
  capabilities: { vod: true },
  probe: () => host.playback.probe("http://bad.invalid/x.m3u8"),
};
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        p.hydrate_capabilities().await;

        let got = p.call_js("plugin.probe()").await.unwrap();
        assert!(
            got.contains("unreachable"),
            "不可达地址应返回 verdict=unreachable，实际: {got}"
        );
        // 结构化字段必须在
        assert!(got.contains("statusCode"), "应带 statusCode，实际: {got}");
        assert!(got.contains("finalUrl"), "应带 finalUrl，实际: {got}");
        assert!(got.contains("retryable"), "应带 retryable，实际: {got}");
    }

    #[test]
    fn extract_regex_returns_first_capture_group() {
        let got = extract_regex("<title>Hello</title>", r"<title>(.*?)</title>").unwrap();
        assert_eq!(got, vec!["Hello"]);
    }

    #[test]
    fn extract_regex_without_group_returns_whole_match() {
        // 没有捕获组 ⇒ 取整个匹配（否则插件拿不到东西）
        let got = extract_regex("a vid=abc b vid=def", r"vid=\w+").unwrap();
        assert_eq!(got, vec!["vid=abc", "vid=def"]);
    }

    #[test]
    fn extract_regex_returns_all_matches() {
        let got = extract_regex("x1 x2 x3", r"x(\d)").unwrap();
        assert_eq!(got, vec!["1", "2", "3"]);
    }

    #[test]
    fn extract_regex_no_match_is_empty_not_error() {
        let got = extract_regex("hello", r"(zzz)").unwrap();
        assert!(got.is_empty(), "没匹配到应返回空数组，不是错误");
    }

    #[test]
    fn extract_regex_bad_pattern_is_error_not_empty() {
        // ★ 关键区分：语法错误必须报错，不能静默返回空
        let err = extract_regex("hello", r"(unclosed").unwrap_err();
        assert!(
            err.contains("正则语法错误"),
            "语法错误必须报错（否则插件以为是页面上没有）: {err}"
        );
    }

    #[test]
    fn extract_json_path_object_nesting() {
        let doc: serde_json::Value = serde_json::json!({"a": {"b": {"c": 42}}});
        let got = extract_json_path(&doc, "a.b.c").unwrap().unwrap();
        assert_eq!(got, serde_json::json!(42));
    }

    #[test]
    fn extract_json_path_array_index() {
        let doc: serde_json::Value = serde_json::json!({"list": [{"id": "x"}, {"id": "y"}]});
        let got = extract_json_path(&doc, "list[1].id").unwrap().unwrap();
        assert_eq!(got, serde_json::json!("y"));
    }

    #[test]
    fn extract_json_path_missing_returns_none_not_error() {
        let doc: serde_json::Value = serde_json::json!({"a": {"b": 1}});
        assert!(extract_json_path(&doc, "a.zzz").unwrap().is_none());
        assert!(extract_json_path(&doc, "nope.deep").unwrap().is_none());
        // 类型不对也用 None（不是错误）
        assert!(extract_json_path(&doc, "a.b[0]").unwrap().is_none());
    }

    #[test]
    fn extract_json_path_empty_returns_whole_doc() {
        let doc: serde_json::Value = serde_json::json!({"a": 1});
        let got = extract_json_path(&doc, "").unwrap().unwrap();
        assert_eq!(got, doc);
    }

    #[test]
    fn extract_json_path_bad_index_is_error() {
        let doc: serde_json::Value = serde_json::json!({"a": [1]});
        let err = extract_json_path(&doc, "a[zz]").unwrap_err();
        assert!(err.contains("数组下标不是数字"), "got: {err}");
    }

    #[test]
    fn extract_json_path_out_of_range_returns_none() {
        let doc: serde_json::Value = serde_json::json!({"a": [1, 2]});
        assert!(extract_json_path(&doc, "a[9]").unwrap().is_none());
    }


    /// ★ host.extract 契约：从 JS 侧**真调用**（task-41）
    ///
    /// # 为什么必须是真调用而不是单测
    /// 后端单测已经覆盖了 `extract_regex` / `extract_json_path` 这两个纯函数。
    /// 但那只证明「算法对」，**不证明「插件真的能调到」**。
    /// 而「接线了但没通电」是本项目反复踩的坑（save_hook 空写、base() 被 shim 覆盖）。
    /// ⇒ 这条测试走完整链路：插件 JS → QuickJS → Rust 函数 → 返回值。
    #[tokio::test]
    async fn host_extract_regex_is_callable_from_plugin() {
        let src = r#"
/** @id extdemo @name extract test */
globalThis.plugin = {
  capabilities: { vod: true },
  probe: () => host.extract.regex('<title>Hello</title>', '<title>(.*?)</title>'),
};
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        p.hydrate_capabilities().await;

        // call_js 会把返回值当 JSON 序列化，字符串会多一层引号
        let got = p.call_js("JSON.stringify(plugin.probe())").await.unwrap();
        assert!(
            got.contains("Hello"),
            "host.extract.regex must reach Rust, got: {got}"
        );
    }

    #[tokio::test]
    async fn host_extract_json_is_callable_from_plugin() {
        let src = r#"
/** @id extdemo2 @name extract json */
globalThis.plugin = {
  capabilities: { vod: true },
  probe: () => host.extract.json('{"a":{"b":[1,2,3]}}', 'a.b[1]'),
};
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        p.hydrate_capabilities().await;

        // call_js 把返回的字符串当 JSON 序列化 ⇒ 会多一层引号，先剥掉
        let got = p.call_js("plugin.probe()").await.unwrap();
        let got = got.trim().trim_matches('"');
        assert_eq!(got, "2", "host.extract.json must reach Rust");
    }

    #[tokio::test]
    async fn host_extract_json_missing_path_returns_null_text() {
        let src = r#"
/** @id extdemo3 @name extract json missing */
globalThis.plugin = {
  capabilities: { vod: true },
  probe: () => host.extract.json('{"a":1}', 'a.zzz'),
};
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        p.hydrate_capabilities().await;

        let got = p.call_js("plugin.probe()").await.unwrap();
        let got = got.trim().trim_matches('"');
        assert_eq!(
            got, "null",
            "缺失路径应返回 'null' 文本，好让插件用 ?? 兜住"
        );
    }

    #[tokio::test]
    async fn host_extract_regex_bad_pattern_throws_to_js() {
        // ★ 关键：语法错误必须让 JS 侧收到异常，不能静默返回空
        let src = r#"
/** @id extdemo4 @name extract bad */
globalThis.plugin = {
  capabilities: { vod: true },
  probe: () => {
    try {
      host.extract.regex('x', '(unclosed');
      return 'NO_THROW';
    } catch (e) {
      return 'THREW';
    }
  },
};
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        p.hydrate_capabilities().await;

        let got = p.call_js("plugin.probe()").await.unwrap();
        assert_eq!(
            got.trim_matches('"'),
            "THREW",
            "正则语法错误必须抛到 JS（静默返回空会让插件误判为'页面没有'）"
        );
    }

    #[tokio::test]
    async fn host_base_is_callable_from_plugin() {
        let src = r#"
/** @id basedemo @name base test */
globalThis.plugin = {
  capabilities: { vod: true },
  hosts: ['https://a.example.com', 'https://b.example.com'],
  probe: () => host.base(),
};
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        p.hydrate_capabilities().await;

        let got = p.call_js("plugin.probe()").await.unwrap();
        let got = got.trim_matches('"');
        assert_eq!(
            got, "https://a.example.com",
            "host.base() must return the picked host; empty/undefined means the shim overwrote it"
        );
    }
    /// 历史档：归档 → 列出（新→旧）→ 超过上限自动清理
    #[test]
    fn versions_archive_list_and_prune() {
        let dir = std::env::temp_dir().join(format!("sourin_ver_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // 没有历史 → 空列表（不是错误）
        assert!(list_plugin_versions(&dir, "p").is_empty());

        // ★ 归档 7 档（超过 MAX=5）验证清理
        for v in ["1.0.0", "1.1.0", "1.2.0", "1.9.0", "1.10.0", "1.11.0", "2.0.0"] {
            archive_plugin_version(&dir, "p", v, &format!("// {v}")).unwrap();
        }
        let all = list_plugin_versions(&dir, "p");
        assert_eq!(all.len(), 7, "清理前应有 7 档");

        // ★ 排序必须是**版本序**而不是文件名字符串序：
        //   1.10.0 要排在 1.9.0 **前面**（字符串序会反过来）
        let vs: Vec<&str> = all.iter().map(|(v, _)| v.as_str()).collect();
        assert_eq!(
            vs,
            vec!["2.0.0", "1.11.0", "1.10.0", "1.9.0", "1.2.0", "1.1.0", "1.0.0"],
            "历史档必须按版本号新→旧（不能按文件名字符串）"
        );

        // 清理：只留最近 5 档
        let removed = prune_plugin_versions(&dir, "p");
        assert_eq!(removed, 2, "7 档留 5 → 应删 2");
        let after: Vec<String> = list_plugin_versions(&dir, "p")
            .into_iter()
            .map(|(v, _)| v)
            .collect();
        assert_eq!(after, vec!["2.0.0", "1.11.0", "1.10.0", "1.9.0", "1.2.0"]);
        assert_eq!(MAX_PLUGIN_VERSIONS, 5);
        // 再清一次不动（幂等）
        assert_eq!(prune_plugin_versions(&dir, "p"), 0);

        // 别的插件的档不能被误删/误列
        archive_plugin_version(&dir, "q", "9.9.9", "// q").unwrap();
        assert_eq!(list_plugin_versions(&dir, "q").len(), 1);
        assert_eq!(list_plugin_versions(&dir, "p").len(), 5);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 归档的版本号含非法字符要过滤（版本号来自插件作者，不可信）
    #[test]
    fn archive_sanitizes_version_in_filename() {
        let dir = std::env::temp_dir().join(format!("sourin_san_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let p = archive_plugin_version(&dir, "p", "../../evil/1.0", "// x").unwrap();
        // 必须还在 .versions/ 里（没穿出去）
        assert!(
            p.starts_with(plugin_versions_dir(&dir)),
            "版本号里的路径分隔符必须被过滤掉：{p:?}"
        );
        // 非法 id 直接拒绝
        assert!(archive_plugin_version(&dir, "../x", "1.0", "// x").is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 多行写法同样支持
    #[test]
    fn parses_meta_multi_line() {
        let src = "/**\n * @id demo\n * @name 示例源\n * @description 这是一个示例\n */\n";
        let m = parse_meta(src);
        assert_eq!(m.id, "demo");
        assert_eq!(m.name, "示例源");
        assert_eq!(m.description, "这是一个示例");
    }

    /// 缺 @id 必须报错（没有唯一标识就无法注册）
    #[test]
    fn rejects_plugin_without_id() {
        let err = JsPluginProvider::from_source("/** @name 无 id */").unwrap_err();
        assert!(err.contains("@id"), "错误信息应指出缺 @id，实际: {err}");
    }

    /// 缺 @name 也要报错（界面上无法展示）
    #[test]
    fn rejects_plugin_without_name() {
        let err = JsPluginProvider::from_source("/** @id x */").unwrap_err();
        assert!(err.contains("@name"), "实际: {err}");
    }

    /// 正常插件应能构建，且元信息落到 manifest
    #[test]
    fn builds_provider_from_valid_source() {
        let src = "/** @id srcl @name 某电视台站 @version 2.0.0 */\n";
        let p = JsPluginProvider::from_source(src).unwrap();
        let m = p.manifest();
        assert_eq!(m.id, "srcl");
        assert_eq!(m.name, "某电视台站");
        assert_eq!(m.version, "2.0.0");
        assert_eq!(m.kind, "js");
        // id 前缀要带上，避免与其它源撞 id
        assert_eq!(m.id_prefixes, vec!["srcl:".to_string()]);
    }

    /// 缺版本号时给默认值（不阻断加载）
    #[test]
    fn defaults_version_when_missing() {
        let p = JsPluginProvider::from_source("/** @id x @name X */").unwrap();
        assert_eq!(p.manifest().version, "1.0.0");
    }

    /// 错误映射：插件抛的前缀要转成对应的 ErrorKind
    #[test]
    fn maps_prefixed_js_errors() {
        assert_eq!(
            map_js_error("unauthorized: token 过期").kind,
            ErrorKind::Unauthorized
        );
        assert_eq!(map_js_error("not_found: 没有这个视频").kind, ErrorKind::NotFound);
        assert_eq!(map_js_error("unsupported: 不支持搜索").kind, ErrorKind::Unsupported);
        assert_eq!(map_js_error("network: 站点无响应").kind, ErrorKind::Network);
        assert_eq!(map_js_error("parse: 返回不是合法 JSON").kind, ErrorKind::Parse);
    }

    /// ★★★ `parse:` 必须映射成 `ErrorKind::Parse`，且消息**不加包装**
    ///
    /// # 修的是什么
    ///
    /// `map_js_error` 漏了 `parse:` 这一支 —— 而契约（`docs/PLUGINS.md`）
    /// 与 `ProviderError::parse` 都早就有了。后果：
    /// ```text
    /// 插件抛 parse: xxx  ⇒  落到最后的 else
    /// ⇒ kind = Other（前端按类型分支的逻辑全部失效）
    /// ⇒ 消息变成「插件报错: parse: xxx」（多一层无意义包装）
    /// ```
    ///
    /// ⚠️ 这条测试**必须**同时钉住两件事（kind + 消息），只钉 kind 不够：
    ///    包装那层是用户**直接看到**的东西（本仓「错误必须原文透出」纪律）。
    #[test]
    fn parse_prefix_maps_to_parse_kind_without_wrapping() {
        let msg = "parse: 找不到该条目（上游搜索结果已变化）";
        let e = map_js_error(msg);

        assert_eq!(
            e.kind,
            ErrorKind::Parse,
            "★ parse: 必须映射成 ErrorKind::Parse（改前落到 Other），实际 {:?}",
            e.kind
        );
        assert_eq!(
            e.message,
            msg,
            "★ 消息必须**原样透出**：多一层「插件报错: 」会让用户看不懂，实际: {}",
            e.message
        );
        assert!(
            !e.message.contains("插件报错"),
            "★ 绝不能带「插件报错: 」前缀（那是 Other 分支的包装），实际: {}",
            e.message
        );
        // 前缀本身要保留 —— 它是给用户看的语义，不是内部标记
        assert!(
            e.message.starts_with("parse:"),
            "原文要完整保留（排错靠它），实际: {}",
            e.message
        );
    }

    /// ★★★ Other 分支也必须原样透出，不许加「插件报错:」前缀（Owner 第 7 条）
    ///
    /// # Owner 原话
    /// ```text
    /// > 像图2 那种报错的信息,就不要加上溯影自己的信息了,
    /// > 就只显示插件的报错信息就足够了
    /// ```
    ///
    /// # 改前用户看到
    /// ```text
    /// SourinCoreException(other): 插件报错: 该内容需要大会员
    /// ```
    /// 「插件报错:」是宿主加的包装，对用户零信息量。
    ///
    /// # 为什么单独立一条（上面已有 parse: 那一条）
    /// ```text
    /// 上面那条只覆盖 `parse:` 前缀分支；
    /// 而**绝大多数**插件错误走的是最后的 else（Other 分支）——
    /// 正是这一支在加前缀。不测这一支等于没测。
    /// ```
    #[test]
    fn other_kind_does_not_wrap_message_with_host_prefix() {
        // 典型：源站会员限制（图 2 的实际文案）
        let msg = "该内容需要大会员";
        let e = map_js_error(msg);

        assert_eq!(e.kind, ErrorKind::Other, "无前缀关键词 ⇒ Other 分支");
        assert_eq!(
            e.message, msg,
            "★ 消息必须原样透出，实际: {}",
            e.message
        );
        assert!(
            !e.message.contains("插件报错"),
            "★★★ 绝不能带「插件报错:」前缀（Owner 第 7 条），实际: {}",
            e.message
        );
    }

    /// ★★ 反面：带前缀时**必须能被本测试抓到**（证明上一条不是恒真）
    ///
    /// 这条不调用生产代码，而是**复现改前的形态**并断言它违反判据 ——
    /// 若有人把 `format!("插件报错: {msg}")` 加回去，上一条会红；
    /// 本条的用处是证明「那种形态确实违反判据」，避免有人以为判据写错了。
    #[test]
    fn wrapped_form_would_violate_the_rule() {
        let msg = "该内容需要大会员";
        let old_form = format!("插件报错: {msg}"); // ← 改前的形态
        assert!(
            old_form.contains("插件报错"),
            "改前形态确实带前缀 ⇒ 说明上一条断言能抓到回归"
        );
        // 且它不等于原文 —— 证明两者是可区分的，不是同一个串
        assert_ne!(old_form, msg);
    }
    ///
    /// # 这是实测出来的真 bug（不是我推测的）
    ///
    /// 改前 `404` 那一支排在前面，于是：
    /// ```text
    /// 插件抛：parse: 返回不是合法 JSON — <html><title>404 Not Found</title>
    /// ⇒ 先命中 `404` ⇒ 判成 NotFound（**错的**）
    /// ```
    /// 而这正是 `parse:` 最典型的触发场景 —— **上游返回 404 / 风控 HTML 页**，
    /// 插件 `JSON.parse` 失败，把响应片段带进消息。
    ///
    /// ⇒ 契约：**显式前缀是权威声明，必须先判**；
    ///    裸关键词只是给老插件兜底的启发式，只能在后。
    #[test]
    fn explicit_prefix_beats_bare_code_in_body() {
        // 真实形态：parse: + 正文里带 404（上游返回了 Not Found 的 HTML 页）
        let real = "parse: 返回不是合法 JSON — <html><head><title>404 Not Found</title></head>";
        assert_eq!(
            map_js_error(real).kind,
            ErrorKind::Parse,
            "★ 正文里的 404 不许抢走 parse: 的判定（前缀优先），实际: {}",
            map_js_error(real).message
        );

        // 同类：正文带 401 / timeout 也不能抢
        assert_eq!(
            map_js_error("parse: 上游返回了 401 登录页而不是 JSON").kind,
            ErrorKind::Parse
        );
        assert_eq!(
            map_js_error("parse: 响应超时片段 timeout after 5s").kind,
            ErrorKind::Parse
        );
        // 反向：network: 消息里带 404 也不许被判成 NotFound
        assert_eq!(
            map_js_error("network: 站点返回 404").kind,
            ErrorKind::Network,
            "★ 前缀仍优先于正文里的裸编码"
        );
        // 反向：unsupported: 里带 unauthorized 字样同理
        assert_eq!(
            map_js_error("unsupported: 本接口需要 unauthorized 处理，未实现").kind,
            ErrorKind::Unsupported
        );
    }

    /// ★ 老插件兼容：**没写前缀**时裸关键词仍要能分类（不许为了修 parse 把它们弄坏）
    ///
    /// ⚠️ 这条是「撤销验证」的另一半：如果我把 401/404/timeout 那几支删掉，
    ///    前缀那一侧照样绿，但**这四条会红** —— 两边的门禁都要在。
    #[test]
    fn bare_keywords_still_classified_for_legacy_plugins() {
        assert_eq!(map_js_error("HTTP 401 Unauthorized").kind, ErrorKind::Unauthorized);
        assert_eq!(map_js_error("HTTP 404").kind, ErrorKind::NotFound);
        assert_eq!(map_js_error("request timeout").kind, ErrorKind::Network);
        // 什么都没命中 ⇒ Other
        let o = map_js_error("something odd");
        assert_eq!(o.kind, ErrorKind::Other);
        /*
         * ★★★ 这条断言的方向**被 Owner 第 7 条反转了**（2026-10-18）
         *
         * # 改前钉的是
         * ```text
         * o.message.contains("插件报错")  ← 要求**保留**包装
         * 理由：「Other 分支保留包装（与 parse: 分支的区别就在这里）」
         * ```
         *
         * # Owner 原话
         * ```text
         * > 像图2 那种报错的信息,就不要加上溯影自己的信息了,
         * > 就只显示插件的报错信息就足够了
         * ```
         * ⇒ 「与 parse: 分支的区别」这个设计意图**本身被否了**：
         *   两个分支现在**都要**原样透出，区别只剩 kind。
         *
         * ⚠️ 这不是「为了让测试变绿而放宽断言」—— 是行为**有意改变**，
         *    断言改成钉**新行为**，且新断言在旧行为下会红（已用故障注入验证：
         *    把 format!("插件报错: {msg}") 加回去 ⇒ 本条与
         *    other_kind_does_not_wrap_message_with_host_prefix 同时红）。
         */
        assert!(
            !o.message.contains("插件报错"),
            "★★★ Other 分支也必须原样透出（Owner 第 7 条），实际: {}",
            o.message
        );
        assert_eq!(o.message, "something odd", "原文必须完整保留");
    }

    /// ★ 前缀判定的健壮性：反引号 / 首尾空白 / 大小写都要认
    #[test]
    fn parse_prefix_tolerates_quotes_and_case() {
        assert_eq!(map_js_error("PARSE: 上游改版").kind, ErrorKind::Parse);
        assert_eq!(map_js_error("  parse: 前导空白").kind, ErrorKind::Parse);
        assert_eq!(map_js_error("`parse: 反引号包裹`").kind, ErrorKind::Parse);
    }

    /// ★ 端到端：插件真的抛 `parse:` ⇒ 宿主收到的 ErrorKind 是 Parse
    ///
    /// ⚠️ 上面几条直接测 `map_js_error`（纯函数）。这条走**真 JS 引擎**，
    ///    证明「插件 throw → JS 侧 catch 带出消息 → map_js_error」整条链是通的
    ///    （中间那段 `{ok:false, error:msg}` 的打包/拆包也是 bug 高发区）。
    #[tokio::test]
    async fn plugin_thrown_parse_prefix_reaches_parse_kind() {
        let src = r#"/** @id pfx @name 前缀测试源 */
globalThis.plugin = {
  async home() {
    // 真实形态：上游返回了 404 的 HTML 页 ⇒ JSON.parse 失败 ⇒ 抛 parse:
    throw new Error('parse: 返回不是合法 JSON — <html><title>404 Not Found</title>');
  },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let err = p.home().await.unwrap_err();
        assert_eq!(
            err.kind,
            ErrorKind::Parse,
            "★ 插件抛 parse: ⇒ 必须判成 Parse（正文里的 404 不许抢），实际: {:?} / {}",
            err.kind,
            err.message
        );
        assert!(
            !err.message.contains("插件报错"),
            "★ 不许有「插件报错: 」包装，实际: {}",
            err.message
        );
    }


    // ─────────── ★ 端到端：插件真的能跑 ───────────

    /// ★★ 最核心的一条：插件能返回结构化数据，宿主能解析
    ///
    /// 这条测试覆盖「JS 求值 → JSON.stringify → Rust 反序列化」全链路。
    /// 不需要网络（插件里不调 http）。
    #[tokio::test]
    async fn plugin_returns_sections_without_network() {
        let src = r#"
/** @id t1 @name 测试源 */
globalThis.plugin = {
  async home() {
    return [
      { id: 'a', title: '区块A', source: { type: 'category', categoryId: '1' } },
      { id: 'b', title: '区块B', source: { type: 'rank', rankId: '9' } },
    ];
  },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let sections = p.home().await.expect("home() 应成功");

        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].title, "区块A");
        // SectionSource 是带 tag 的枚举，确认解析到了正确的变体
        match &sections[0].source {
            SectionSource::Category { category_id } => assert_eq!(category_id, "1"),
            other => panic!("第一个区块应是 Category，实际 {other:?}"),
        }
        match &sections[1].source {
            SectionSource::Rank { rank_id } => assert_eq!(rank_id, "9"),
            other => panic!("第二个区块应是 Rank，实际 {other:?}"),
        }
    }

    /// 插件返回列表页时，字段要能正确映射到 `Page<MediaItem>`
    #[tokio::test]
    async fn plugin_returns_paged_items() {
        let src = r#"
/** @id t2 @name 测试源 */
globalThis.plugin = {
  async list(req) {
    return {
      items: [
        { id: 'v1', title: '影片一', cover: 'https://x/1.jpg', kind: 'movie' },
        { id: 'v2', title: '影片二' },
      ],
      page: req.page,
      total: 42,
    };
  },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let page = p
            .list(ListRequest {
                category_id: "cat1".into(),
                page: 3,
                filters: Default::default(),
            })
            .await
            .expect("list() 应成功");

        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].title, "影片一");
        assert_eq!(page.page, 3, "插件应收到并回传请求里的页码");
        assert_eq!(page.total, Some(42));
    }

    /// ★ 熔断必须生效：插件写死循环要能被终止，且**不能等太久**
    ///
    /// 实测教训：按 tick 计数的方式跑了 **168 秒**才触发，
    /// 一个坏插件能卡死应用近 3 分钟。改成按墙钟时间后精确终止。
    /// 这条测试锁死「必须按时间」这个结论。
    #[tokio::test]
    async fn infinite_loop_is_interrupted_quickly() {
        let src = r#"
/** @id bad @name 坏插件 */
globalThis.plugin = {
  async home() {
    while (true) {}   // 故意死循环
  },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();

        let t0 = std::time::Instant::now();
        let r = p.home().await;
        let ms = t0.elapsed().as_millis();

        assert!(r.is_err(), "死循环必须报错而不是永远挂着");
        assert!(
            ms < 20_000,
            "中断耗时 {ms} ms，太慢了（预算 {SCRIPT_BUDGET_MS} ms）—— \
             检查中断处理器是不是改回按 tick 计数了"
        );
        // 错误信息要让用户看得懂
        let msg = format!("{}", r.unwrap_err());
        assert!(msg.contains("超时"), "错误信息应说明是超时，实际: {msg}");
    }

    /// 插件抛异常时，错误要能被映射成合适的 ErrorKind
    #[tokio::test]
    async fn plugin_exception_maps_to_error_kind() {
        let src = r#"
/** @id t3 @name 测试源 */
globalThis.plugin = {
  async home() { throw new Error('unauthorized: 登录已失效'); },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let err = p.home().await.unwrap_err();
        assert_eq!(err.kind, ErrorKind::Unauthorized);
    }

    /// ★ 插件真的能发 HTTP 并解析响应
    ///
    /// 打真实站点（某电视台栏目接口，公开无需鉴权）。
    /// 这条通过 = 「插件自己发请求 → 解析 → 返回结构化数据」全链路可用，
    /// 也就是 srcl 能被搬成插件的前提。
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn plugin_can_fetch_and_parse_real_http() {
        let src = r#"
/** @id net @name 联网测试 */
const API = 'https://api.example-l.cn/lanmu/columnSearch?&fl=&p=1&n=3&serviceId=tv-l1';
globalThis.plugin = {
  async home() {
    const raw = await host.http.get(API);
    const j = JSON.parse(raw);
    return j.response.docs.map(d => ({
      id: 'col-' + d.column_id,
      title: d.column_name,
      source: { type: 'category', categoryId: d.column_id },
    }));
  },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let sections = p.home().await.expect("联网取栏目应成功");

        assert!(!sections.is_empty(), "应至少拿到一个栏目");
        // 某电视台「新闻联播」是稳定存在的栏目
        let titles: Vec<&str> = sections.iter().map(|s| s.title.as_str()).collect();
        assert!(
            titles.iter().any(|t| t.contains("新闻联播")),
            "应包含新闻联播，实际: {titles:?}"
        );
    }

    /// ★★ POST 必须带 `Content-Type: application/json`
    ///
    /// 实测踩过（srca 登录）：reqwest 的 `.body(String)` 默认发
    /// `text/plain`，服务端解析不了 JSON body，报的却是
    /// `Username is a required field` —— **看起来像参数没传**，
    /// 实际是 body 根本没被解析。这类问题极难从报错里看出来。
    ///
    /// 这条测试打一个回显请求头的服务，确认 Content-Type 正确。
    #[tokio::test]
    #[ignore = "需要网络"]
    async fn post_sends_json_content_type() {
        // httpbin 的回显接口会返回我们发过去的头
        let out = do_http(
            &None,
            "test",
            "POST",
            "https://httpbin.org/post",
            &HashMap::new(),
            Some(r#"{"a":1}"#.to_string()),
        )
        .await;

        if out.starts_with("__ERR__") {
            // 网络不可达时跳过（不让环境问题把测试判成失败）
            eprintln!("跳过：httpbin 不可达 — {}", &out[..out.len().min(80)]);
            return;
        }
        assert!(
            out.to_lowercase().contains("application/json"),
            "POST 应带 application/json，实际响应: {}",
            &out[..out.len().min(300)]
        );
    }

    /// ★ 插件私有存储：读写与删除
    #[test]
    fn plugin_store_roundtrip() {
        let dir = std::env::temp_dir().join(format!("dsh-pl-store-{}", std::process::id()));

        // 未写过 → None
        assert!(store_read(&dir, "p1", "token").is_none());

        store_write(&dir, "p1", "token", Some("abc".into())).unwrap();
        assert_eq!(store_read(&dir, "p1", "token").as_deref(), Some("abc"));

        // ★ 插件之间必须隔离（p2 读不到 p1 的值）
        assert!(
            store_read(&dir, "p2", "token").is_none(),
            "不同插件的存储必须隔离"
        );

        // 多键共存
        store_write(&dir, "p1", "other", Some("x".into())).unwrap();
        assert_eq!(store_read(&dir, "p1", "token").as_deref(), Some("abc"));
        assert_eq!(store_read(&dir, "p1", "other").as_deref(), Some("x"));

        // 删除只删指定键
        store_write(&dir, "p1", "token", None).unwrap();
        assert!(store_read(&dir, "p1", "token").is_none());
        assert_eq!(store_read(&dir, "p1", "other").as_deref(), Some("x"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 存储文件损坏时应当作「空」而不是让插件崩掉
    #[test]
    fn plugin_store_survives_corrupt_file() {
        let dir = std::env::temp_dir().join(format!("dsh-pl-corrupt-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(store_path(&dir, "p1"), "{ 这不是 JSON").unwrap();

        // 读到 None 而不是 panic
        assert!(store_read(&dir, "p1", "k").is_none());
        // 而且还能正常写入（覆盖掉坏文件）
        store_write(&dir, "p1", "k", Some("v".into())).unwrap();
        assert_eq!(store_read(&dir, "p1", "k").as_deref(), Some("v"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★★ 插件的每个可选方法都必须**真的被桥接**
    ///
    /// 实测踩过两次同类问题：
    ///   · `rank()` —— srca 首页声明了「TV番组榜」区块、插件也实现了
    ///     `rank()`，但宿主漏桥接 → 走 trait 默认实现 →
    ///     首页那两个区块**永远空白**，插件作者完全不知道为什么
    ///   · `episodes()` / `sources()` —— 同理
    ///
    /// 这类 bug **不报错、只是没内容**，最难发现。
    /// 这条测试用一个「实现了全部可选方法」的插件逐个调一遍。
    #[tokio::test]
    async fn all_optional_methods_are_bridged() {
        let src = r#"
/** @id full @name 全方法插件 */
globalThis.plugin = {
  id: 'full',
  capabilities: { vod: true, live: true, epg: true, timeshift: true, search: true },
  async home() { return []; },
  async categories() { return []; },
  async list() { return { items: [], page: 1 }; },
  async rank(rankId, page) {
    return { items: [{ id: 'r1', title: '榜单项' }], page: page, total: 1 };
  },
  async search() { return { items: [], page: 1 }; },
  async detail(id) {
    return { id: id, title: '详情', sources: [{ code: 's1', title: '线路一', count: 2 }], episodes: [] };
  },
  async episodes(id, code) {
    return [{ id: 'e1', title: '第1集', order: 1 }, { id: 'e2', title: '第2集', order: 2 }];
  },
  async sources(id) {
    return [{ code: 's1', title: '线路一', count: 2 }];
  },
  async resolve(id, req) { return [{ url: 'https://x/a.m3u8', quality: '原画', kind: 'hls' }]; },
  async liveChannels() { return [{ id: 'c1', name: '频道一' }]; },
  async liveStream(cid) { return [{ url: 'https://x/l.m3u8', kind: 'hls' }]; },
  async epg(cid) { return [{ title: '节目', start: 1, end: 2, duration: 1, replayable: true }]; },
  async timeshift(cid, s, e) { return { url: 'https://x/t.m3u8', kind: 'hls' }; },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let id = MediaId::new("full", "v1");

        // rank —— 曾经漏桥接的那个
        let r = p.rank("1", 1).await.expect("rank 必须被桥接");
        assert_eq!(r.items.len(), 1);
        assert_eq!(r.items[0].title, "榜单项");

        // episodes —— 曾经漏桥接
        let eps = p.episodes(&id, "s1").await.expect("episodes 必须被桥接");
        assert_eq!(eps.len(), 2, "应拿到插件返回的 2 集，而不是 detail 的空列表");

        // sources
        let srcs = p.sources(&id).await.expect("sources 必须被桥接");
        assert_eq!(srcs.len(), 1);
        assert_eq!(srcs[0].title, "线路一");

        // live / epg / timeshift
        let chans = p.live_channels().await.expect("liveChannels 必须被桥接");
        assert_eq!(chans.len(), 1);
        let live = p.live_stream("c1").await.expect("liveStream 必须被桥接");
        assert_eq!(live.len(), 1);
        let epg = p.epg("c1", None).await.expect("epg 必须被桥接");
        assert_eq!(epg.len(), 1);
        let ts = p
            .timeshift("c1", 1, 2)
            .await
            .expect("timeshift 必须被桥接");
        assert!(ts.url.contains("t.m3u8"));
    }

    /// ★★★ `epg` / `timeshift` 未实现时必须优雅降级（2026-09-25 修的真 bug）
    ///
    /// # 为什么单独一条（`missing_optional_methods_degrade_gracefully` 没覆盖到）
    /// ```text
    /// 那条测的是 session/logout/rank 等；而 `epg`/`timeshift` **漏了**。
    /// ★ 上面 `bridges_live_epg_timeshift`（L3397）用的是**实现了 epg 的插件**
    ///   ⇒ 「声明 false 且不实现」这条路径**从来没有被测过**
    ///   ⇒ 所以 bug 上线了（真机切台每次刷 `插件报错: not a function`）。
    /// ```
    ///
    /// # 真实复现（`.probe/t42_epg_repro.py`，走真实 FFI）
    /// ```text
    /// get_epg("iptv", …)  ⇒ {"error":"插件报错: not a function"}   ← 修前
    /// get_epg("srcl", …)  ⇒ [{"title":…}]                          ← 阳性对照
    /// ```
    ///
    /// # 两者的**不同**降级方式（不是笔误，是刻意区分）
    /// ```text
    /// · `epg()`      → `Ok(vec![])`      —— EPG **本来就是可选的**
    ///                   （"没有节目单"是正常状态，不是错误）
    /// · `timeshift()`→ `Err(unsupported)` —— 返回类型 `StreamCandidate`
    ///                   **没有"空流"这种合法值** ⇒ 必须让调用方区分
    ///                   "这个源不支持时移" 与 "时移失败了"
    /// ```
    #[tokio::test]
    async fn unimplemented_epg_and_timeshift_degrade_gracefully() {
        let src = r#"
/** @id nolive @name 没有 EPG 的插件 */
globalThis.plugin = {
  id: 'nolive',
  // ★ 声明 false 且**不实现** —— 正是 iptv.js 的形态
  capabilities: { vod: true, live: true, epg: false },
  async liveChannels() { return [{ id: 'c1', name: '频道一' }]; },
  async liveStream() { return [{ url: 'https://x/a.m3u8', kind: 'hls' }]; },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();

        /*
         * ① EPG：必须返回**空列表**，不是错误
         *
         * ⚠️ 修前这里会拿到 `Err("插件报错: not a function")`
         *    ⇒ 每次切台都刷一条错误日志（真机实测）。
         */
        let epg = p
            .epg("c1", None)
            .await
            .expect("★ 没实现 epg ⇒ 返回空列表，**不是** Err（否则用户每次切台都看到报错）");
        assert!(epg.is_empty(), "没实现 epg ⇒ 空列表，实际 {} 条", epg.len());

        /*
         * ② timeshift：必须返回**明确的 unsupported**，也不是「not a function」
         *
         * ★ 为什么要区分 `kind`：
         *   调用方据此决定"隐藏时移按钮"（不支持）还是"提示重试"（失败）。
         *   若报成 `Other`，UI 会当成"出错了" ⇒ 给用户一个无意义的报错。
         */
        let err = p
            .timeshift("c1", 0, 100)
            .await
            .expect_err("没实现 timeshift ⇒ 必须报错（没有「空流」这种合法值）");
        assert_eq!(
            err.kind,
            ErrorKind::Unsupported,
            "★ 必须是 Unsupported（让调用方能区分「不支持」与「失败」），实际: {:?} / {}",
            err.kind,
            err.message
        );
        assert!(
            !err.message.contains("not a function"),
            "★ 绝不能是「not a function」—— 那是宿主没做守卫的锅，不该让用户看到: {}",
            err.message
        );
    }

    /// 插件**没实现**的可选方法要优雅降级，不能报「is not a function」
    ///
    /// 宿主在启动与聚合时会普遍地问一遍（如 `session()`），
    /// 一个不需要登录的插件被问到不该刷错误日志。
    #[tokio::test]
    async fn missing_optional_methods_degrade_gracefully() {
        let src = r#"
/** @id mini @name 最小插件 */
globalThis.plugin = {
  id: 'mini',
  capabilities: { vod: true },
  async resolve() { return [{ url: 'https://x/a.mp4', kind: 'mp4' }]; },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let id = MediaId::new("mini", "v1");

        // 这些都不该 panic / 报 "is not a function"
        assert!(p.session().await.unwrap().is_none(), "没实现 session → None");
        assert!(p.logout().await.is_ok(), "没实现 logout → Ok");
        assert!(
            p.refresh_session().await.unwrap().is_none(),
            "没实现 refreshSession → None"
        );
        assert!(!p.can_auto_login().await, "没实现 canAutoLogin → false");
        assert!(
            p.rank("1", 1).await.is_err(),
            "没实现 rank → 报「不支持」而不是崩"
        );

        // episodes/sources 没实现时退回 detail（trait 的语义）
        // —— mini 也没实现 detail，所以这里应报错而不是 panic
        assert!(p.episodes(&id, "s1").await.is_err());
    }

    /// ★★ 自动重登链路必须完整（Owner 报「没有验证码的应该自动重登」）
    ///
    /// `Registry::ensure_session()` 的链路是：
    /// ```
    /// login_required? → session_needs_refresh? → refresh_session()
    ///   → 失败 → can_auto_login() → auto_login()
    /// ```
    /// 任何一环没桥接，自动重登都不会发生 —— 而**不会报错**，
    /// 只是用户每次 token 过期都要手动重登。
    #[tokio::test]
    async fn auto_login_chain_is_bridged() {
        let src = r#"
/** @id auto @name 自动重登测试 */
globalThis.plugin = {
  id: 'auto',
  capabilities: { vod: true, loginRequired: true },
  async session() { return null; },
  async refreshSession() { return null; },   // 续期失败
  async canAutoLogin() { return true; },     // ★ 有凭据，能重登
  async autoLogin() {
    return { token: 'Bearer new-token', displayName: 'tester' };
  },
  async resolve() { return []; },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();

        // 1) 这几个方法都要被识别为「已实现」
        assert!(p.has_method("session").await);
        assert!(p.has_method("refreshSession").await);
        assert!(p.has_method("canAutoLogin").await);
        assert!(p.has_method("autoLogin").await);
        assert!(
            !p.has_method("forgetCredentials").await,
            "没实现的方法不该报 true"
        );

        // 2) 续期返回 None（插件表示「不支持续期」）
        assert!(p.refresh_session().await.unwrap().is_none());

        // 3) ★ 关键：canAutoLogin 必须为 true，否则宿主不会去 autoLogin
        assert!(
            p.can_auto_login().await,
            "canAutoLogin 必须被桥接 —— 否则自动重登永远不会发生"
        );

        // 4) ★ 关键：autoLogin 必须能拿到新会话
        let s = p
            .auto_login()
            .await
            .expect("autoLogin 必须被桥接")
            .expect("应返回会话");
        assert_eq!(s.token, "Bearer new-token");
        assert_eq!(s.display_name.as_deref(), Some("tester"));
    }

    /// ★★ 语法错误必须报「语法错误」，不能报「执行超时」
    ///
    /// 实测踩到（编辑插件保存时）：语法错误（括号不配对）会让 `eval` 抛
    /// QuickJS 自身异常，而错误分类把「QuickJS 异常」一律当成**中断超时** →
    /// 用户看到「插件执行超时（超过 10000 ms）」，跑去查超时原因，
    /// **永远查不到**（其实是写错了）。
    ///
    /// 这条测试锁死「两种错误必须分开报」。
    #[tokio::test]
    async fn syntax_error_is_not_reported_as_timeout() {
        // 故意写坏：括号不配对
        let src = r#"
/** @id broken @name 坏插件 */
globalThis.plugin = {
  async resolve() { return []; },
(((
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let err = p.resolve(&MediaId::new("broken", "x"), &PlayRequest::default()).await;
        let e = err.unwrap_err();
        let msg = e.message.clone();

        assert!(
            msg.contains("语法错误"),
            "语法错误必须如实说明，实际: {msg}"
        );
        assert!(
            !msg.contains("超时"),
            "语法错误**不能**被误报成超时（那会让用户查错方向），实际: {msg}"
        );
    }

    /// 对照：真正的死循环**必须**报超时（不能被当成语法错误）
    #[tokio::test]
    async fn real_infinite_loop_reports_timeout() {
        let src = r#"
/** @id loop2 @name 死循环 */
globalThis.plugin = {
  async home() { while (true) {} },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let e = p.home().await.unwrap_err();
        assert!(
            e.message.contains("超时"),
            "死循环必须报超时，实际: {}",
            e.message
        );
    }

    /// ★ 随程序发布的 demo.js 必须是**合法且真的能加载**的
    ///
    /// demo 是用户照着写插件的模板 —— 它自己要是坏的，用户会被误导。
    #[test]
    fn shipped_demo_is_loadable() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("plugins/demo.js");
        let src = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("读不到 {}: {e}", path.display()));

        let p = JsPluginProvider::from_source(&src)
            .unwrap_or_else(|e| panic!("demo.js 不是合法插件: {e}"));

        assert_eq!(p.manifest().id, "demo");
        assert!(!p.manifest().name.is_empty());
    }
    // ─────────── task-37：域名池───────────

    /// ★ 插件声明的 hosts 真的能落到池里（全链路）
    ///
    /// # 这条在防什么
    ///
    /// 「hydrate 了但忘了存」是本仓反复出现的缺陷类（声明了但没人消费）。
    /// 不测这条，「hosts 能读到」就只是一个假设。
    #[tokio::test]
    async fn hydrates_hosts_into_pool() {
        let src = r#"
/// @id pooldemo @name 域名池测试
globalThis.plugin = {
  capabilities: { vod: true },
  hosts: [
    'https://a.example.com',
    'https://b.example.com',
    'https://a.example.com',
  ],
};
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        // 沉默默认：没声明前不建池
        assert!(p.pool.lock().unwrap().is_none(), "未 hydrate 前不该有池");

        p.hydrate_capabilities().await;

        let g = p.pool.lock().unwrap();
        let pool = g.as_ref().expect("声明了 hosts 就必须建池");
        assert_eq!(
            pool.hosts,
            vec!["https://a.example.com", "https://b.example.com"],
            "重复项应被去重，顺序保持插件声明的优先级"
        );
    }

    /// 没声明 hosts 的插件 ⇒ 池为 None（行为与加能力前一致）
    #[tokio::test]
    async fn no_hosts_means_no_pool() {
        let src = r#"
/// @id nopooldemo @name 无池
globalThis.plugin = { capabilities: { vod: true } };
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        p.hydrate_capabilities().await;
        assert!(
            p.pool.lock().unwrap().is_none(),
            "没声明 hosts 就不建池 —— 老插件行为不变"
        );
    }

    /// task-37: save_pool_now must actually write the pool into the file.
    ///
    /// This guards a real bug I hit: save_hook first loaded the file and wrote
    /// it straight back without inserting the in-memory pool -> the file stayed
    /// empty and "persistence" silently did nothing.
    #[tokio::test]
    async fn save_pool_now_writes_state_to_disk() {
        let dir = std::env::temp_dir().join(format!("pool-save-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let src = r#"
/** @id savedemo @name save test */
globalThis.plugin = {
  capabilities: { vod: true },
  hosts: ['https://a.example.com', 'https://b.example.com'],
};
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        p.hydrate_capabilities().await;
        p = p.with_pool_dir(dir.clone());

        // record a failure so there is something meaningful to persist
        {
            let mut g = p.pool.lock().unwrap();
            let pool = g.as_mut().unwrap();
            pool.record_failure("https://b.example.com", 0);
        }
        p.save_pool_now(&dir);

        let all = crate::hostpool::load(&dir);
        let saved = all.pools.get("savedemo").expect("savedemo must be persisted");
        assert_eq!(saved.hosts.len(), 2);
        assert_eq!(
            saved.states["https://b.example.com"].failures,
            1,
            "failure count must reach disk, not just memory"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  直播插件取流/缓存辅助函数的门禁（**自建最简夹具，不依赖仓库里的具体网站插件**）
    // ═══════════════════════════════════════════════════════════════════
    //
    // ★ 架构口径（Owner 逐字）：客户端只提供**视频播放能力**，
    //   具体的视频网站由用户的本地插件提供，不进仓库。
    //   ⇒ 仓库里**没有**任何具体网站的插件文件。
    //   但"直播取流地址组装 / 缓存结构校验"这两类**通用**逻辑的回归
    //   门禁仍然有价值，所以这里用一份**自建的最简夹具**（函数名与
    //   真实插件一致：`pickHls` / `cacheValid`）来钉住它们 ——
    //   夹具**只在测试里**，不进 `plugins/` 目录、不打真实站点。

    /// 自建最简直播夹具：`pickHls`（取流地址组装）+ `cacheValid`（缓存结构校验）
    ///
    /// # 为什么这两个是被单独拎出来测的
    ///
    /// `liveStream()` 需要 `host.http`（由宿主注入真实 proxy），
    /// 单测里 stub 不掉 —— 真网络又会让 CI 依赖外网可用性
    /// （本仓不接受"时绿时红"的门禁）。
    ///
    /// 而 `pickHls(data)` 是**纯函数**：输入接口返回体、输出地址。
    /// 真实返回体里会**翻车**的每一处分支，都能用 fixture 精确复现：
    /// ```text
    /// ① host + base_url + extra 三段拼接（漏 extra = 签名没了 = 403）
    /// ② hevc 必须被过滤（选了会黑屏）
    /// ③ 只有 http_hls 才要（http_stream/flv 不要）
    /// ④ 未开播 / 无 HLS 线路 = 返回 null（调用方据此报 not_found）
    /// ```
    /// ★ 契约「函数名 = 全局」是 `ctx.eval(source)` 在**全局作用域**求值
    ///   决定的（顶层 `function` 变成全局）—— 与插件调用同一套，不是特制接缝。
    ///
    /// ⚠️ 夹具里的站点域名一律用 `example`（中性），不含任何具体网站名。
    const LIVE_FIXTURE_SRC: &str = r#"
/** @id live-fixture @name 直播夹具 @version 1.0.0 */
function cacheValid(c) {
  if (!c || !c.at || !Array.isArray(c.rooms) || !c.rooms.length) return false
  return c.rooms.slice(0, 3).every((x) => x && x.id && x.name)
}

function pickHls(data) {
  const streams = (data && data.playurl_info && data.playurl_info.playurl
    && data.playurl_info.playurl.stream) || []

  const hls = streams.find((s) => s.protocol_name === 'http_hls')
  if (!hls || !Array.isArray(hls.format)) return null

  const avcItems = []
  for (const f of hls.format) {
    for (const c of f.codec || []) {
      if (c.codec_name !== 'avc') continue
      const ui = (c.url_info || [])[0]
      if (!ui || !ui.host || !c.base_url) continue
      const qn = Array.isArray(c.accept_qn) && c.accept_qn.length
        ? Math.max.apply(null, c.accept_qn)
        : (c.current_qn || 0)
      avcItems.push({ url: ui.host + c.base_url + (ui.extra || ''), qn })
    }
  }
  if (!avcItems.length) return null

  avcItems.sort((a, b) => b.qn - a.qn)
  return avcItems[0]
}

globalThis.plugin = {
  id: 'live-fixture',
  capabilities: { live: true },
  async home() { return [] },
};
"#;

    /// 读自建直播夹具的源码
    fn live_fixture_src() -> &'static str {
        LIVE_FIXTURE_SRC
    }

    /// 喂 fixture 调夹具里的纯函数 `pickHls`
    fn pick_hls(p: &JsPluginProvider, fixture: serde_json::Value) -> String {
        let expr = format!("pickHls({})", fixture);
        // `call_js` 是 async；这里用 block_on 跑（测试里没有 runtime）
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(p.call_js(&expr))
            .unwrap_or_else(|e| panic!("pickHls 调用失败: {}", e.message))
    }

    /// ★★ 自建夹具必须**合法、能加载、能力位正确**
    ///
    /// # 为什么这条门禁是**必要的**（不是形式）
    /// ```text
    /// 插件由 `from_source()` 现场求值。若它语法错 / 缺 @id /
    /// capabilities.live 没打开：
    ///   · `Registry::live_all()` 按 `capabilities.live` 过滤
    ///     = 直播页**完全看不到这个源**，且**没有任何报错**
    /// ```
    /// ⚠️ 断言读的是**用户可见的结果**（manifest 的能力位），
    ///    而不是"某个函数被调用了"。
    #[tokio::test]
    async fn live_fixture_is_loadable_with_live_capability() {
        let src = live_fixture_src();
        let mut p = JsPluginProvider::from_source(src)
            .unwrap_or_else(|e| panic!("夹具不是合法插件: {e}"));

        /*
         * ★ 能力位必须**执行脚本**才拿得到（`from_source` 之后仍是
         *   `Capabilities::default()` 全 false）。
         *   完整背景见 `hydrate_capabilities` 的说明。
         */
        p.hydrate_capabilities().await;

        let m = p.manifest();
        assert_eq!(m.id, "live-fixture");
        assert!(
            m.capabilities.live,
            "★ live 必须为 true，否则直播页看不到这个源（且无报错）"
        );
    }

    /// ★★★ 真门禁：地址 = host + base_url + extra（**三段缺一不可**）
    ///
    /// 撤销验证（把 `+ (ui.extra || '')` 去掉）= 本测试**必须变红**：
    /// 返回的 url 会缺 `expires=…&sign=…` = 真机 403。
    #[test]
    fn live_pickhls_joins_host_baseurl_extra() {
        let p = JsPluginProvider::from_source(live_fixture_src()).unwrap();
        let fixture = serde_json::json!({
            "playurl_info": { "playurl": { "stream": [
                { "protocol_name": "http_hls", "format": [
                    { "format_name": "ts", "codec": [
                        { "codec_name": "avc",
                          "current_qn": 10000,
                          "accept_qn": [10000, 250],
                          "base_url": "/live-bvc/x.m3u8?",
                          "url_info": [{ "host": "https://h.example", "extra": "expires=1&sign=ab" }] }
                    ] }
                ] }
            ] } }
        });
        let got = pick_hls(&p, fixture);

        // 解析回 JSON 看结构（比断言整串稳）
        let v: serde_json::Value = serde_json::from_str(&got).expect("必须是 JSON");
        assert_eq!(
            v["url"].as_str().unwrap(),
            "https://h.example/live-bvc/x.m3u8?expires=1&sign=ab",
            "★ 必须是三段拼接 —— 少了 extra 就没有签名，真机 403"
        );
        assert_eq!(v["qn"].as_u64().unwrap(), 10000, "应取 accept_qn 里最高档");
    }

    /// ★★★ 真门禁：**必须过滤掉 hevc**（选了会黑屏，不是画质差）
    ///
    /// 撤销验证（把 `if (c.codec_name !== 'avc') continue;` 去掉）= 变红：
    /// 下面的 fixture 里 hevc 项排在前面，会被选中 = 真机黑屏。
    #[test]
    fn live_pickhls_rejects_hevc() {
        let p = JsPluginProvider::from_source(live_fixture_src()).unwrap();
        let fixture = serde_json::json!({
            "playurl_info": { "playurl": { "stream": [
                { "protocol_name": "http_hls", "format": [
                    { "format_name": "ts", "codec": [
                        // hevc 排在前、且清晰度更高 —— 若不过滤必胜出
                        { "codec_name": "hevc", "current_qn": 20000, "accept_qn": [20000],
                          "base_url": "/hevc.m3u8?", "url_info": [{ "host": "https://h", "extra": "e=1" }] },
                        { "codec_name": "avc", "current_qn": 10000, "accept_qn": [10000],
                          "base_url": "/avc.m3u8?", "url_info": [{ "host": "https://h", "extra": "e=2" }] }
                    ] }
                ] }
            ] } }
        });
        let got = pick_hls(&p, fixture);
        let v: serde_json::Value = serde_json::from_str(&got).unwrap();
        assert!(
            v["url"].as_str().unwrap().contains("/avc.m3u8"),
            "★ 必须挑 avc —— 选 hevc 会黑屏（有声音有进度没画面）。实际: {}",
            v["url"]
        );
    }

    /// ★ 真门禁：**只要 http_hls** —— 不要 http_stream（flv）
    ///
    /// 撤销验证（`find(s => s.protocol_name === 'http_hls')` 改成取 `[0]`）= 变红。
    #[test]
    fn live_pickhls_prefers_http_hls() {
        let p = JsPluginProvider::from_source(live_fixture_src()).unwrap();
        let fixture = serde_json::json!({
            "playurl_info": { "playurl": { "stream": [
                { "protocol_name": "http_stream", "format": [
                    { "format_name": "flv", "codec": [
                        { "codec_name": "avc", "current_qn": 10000, "accept_qn": [10000],
                          "base_url": "/x.flv?", "url_info": [{ "host": "https://h", "extra": "e=1" }] }
                    ] }
                ] },
                { "protocol_name": "http_hls", "format": [
                    { "format_name": "ts", "codec": [
                        { "codec_name": "avc", "current_qn": 10000, "accept_qn": [10000],
                          "base_url": "/x.m3u8?", "url_info": [{ "host": "https://h", "extra": "e=2" }] }
                    ] }
                ] }
            ] } }
        });
        let got = pick_hls(&p, fixture);
        let v: serde_json::Value = serde_json::from_str(&got).unwrap();
        assert!(
            v["url"].as_str().unwrap().ends_with("x.m3u8?e=2"),
            "★ 必须走 http_hls（flv 是未验证过的路径）。实际: {}",
            v["url"]
        );
    }

    /// ★ 真门禁：**没有 HLS 线路 = null**（调用方据此报 not_found）
    ///
    /// 阴性对照 —— 上面三条都测"有 HLS 时怎样"，这条测"没有时怎样"。
    /// 撤销验证（`if (!hls) return null` 改成返回一个占位地址）= 变红。
    #[test]
    fn live_pickhls_returns_null_without_hls() {
        let p = JsPluginProvider::from_source(live_fixture_src()).unwrap();

        // ① stream 里只有 http_stream（flv）
        let only_flv = serde_json::json!({
            "playurl_info": { "playurl": { "stream": [
                { "protocol_name": "http_stream", "format": [
                    { "format_name": "flv", "codec": [
                        { "codec_name": "avc", "current_qn": 10000, "accept_qn": [10000],
                          "base_url": "/x.flv?", "url_info": [{ "host": "https://h", "extra": "e=1" }] }
                    ] }
                ] }
            ] } }
        });
        assert_eq!(pick_hls(&p, only_flv), "null", "只有 flv = 必须 null");

        // ② playurl_info 整个缺失（下播房间的真实形态）
        assert_eq!(
            pick_hls(&p, serde_json::json!({ "live_status": 0 })),
            "null",
            "没有 playurl_info = 必须 null（而不是 panic）"
        );

        // ③ http_hls 在，但只有 hevc
        let only_hevc = serde_json::json!({
            "playurl_info": { "playurl": { "stream": [
                { "protocol_name": "http_hls", "format": [
                    { "format_name": "ts", "codec": [
                        { "codec_name": "hevc", "current_qn": 10000, "accept_qn": [10000],
                          "base_url": "/h.m3u8?", "url_info": [{ "host": "https://h", "extra": "e=1" }] }
                    ] }
                ] }
            ] } }
        });
        assert_eq!(
            pick_hls(&p, only_hevc),
            "null",
            "★ 只有 hevc = 宁可 null（明确报「没有可用线路」），也不要给一条会黑屏的"
        );
    }

    /// ★ 真门禁：缓存结构校验（结构坏 = 判为无效，重新拉取）
    ///
    /// 这条守的是本仓某直播插件踩过的坑：**光换缓存 key 不够，
    /// 必须校验结构本身**（"用旧代码写新 key"总会发生）。
    #[test]
    fn live_cache_valid_rejects_bad_structure() {
        let p = JsPluginProvider::from_source(live_fixture_src()).unwrap();

        let call = |expr: &str| -> String {
            tokio::runtime::Runtime::new()
                .unwrap()
                .block_on(p.call_js(expr))
                .unwrap()
        };

        // 空 / 缺时间戳 / 空列表 —— 全部判无效
        assert_eq!(call("cacheValid(null)"), "false");
        assert_eq!(call("cacheValid({rooms:[{id:'1',name:'a'}]})"), "false", "缺 at");
        assert_eq!(call("cacheValid({at:1,rooms:[]})"), "false", "空列表");
        // 条目缺 id / 缺 name —— 也判无效
        assert_eq!(call("cacheValid({at:1,rooms:[{name:'a'}]})"), "false", "条目缺 id");
        assert_eq!(call("cacheValid({at:1,rooms:[{id:'1'}]})"), "false", "条目缺 name");
        // 阳性对照：结构完整 = true（否则上面的 false 可能恒真）
        assert_eq!(
            call("cacheValid({at:1,rooms:[{id:'1',name:'a'}]})"),
            "true",
            "★ 阳性对照：结构完整必须为 true，否则这条门禁等于恒 false"
        );
    }

    #[test]
    fn bad_plugin_does_not_block_others() {
        let dir = std::env::temp_dir().join(format!("dsh-plugin-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);

        std::fs::write(dir.join("good.js"), "/** @id good @name 好插件 */\n").unwrap();
        std::fs::write(dir.join("bad.js"), "// 没有 @id，应被拒绝\n").unwrap();
        std::fs::write(dir.join("notjs.txt"), "忽略非 .js 文件").unwrap();

        let (ok, bad) = load_plugins(&dir);
        let _ = std::fs::remove_dir_all(&dir);

        assert_eq!(ok.len(), 1, "好插件应被加载");
        assert_eq!(ok[0].manifest().id, "good");
        assert_eq!(bad.len(), 1, "坏插件应被记录而不是拖垮整体");
        assert_eq!(bad[0].0, "bad.js");
    }

    // ─────────── 命名风格转换（契约承诺「宿主自动转」）───────────

    /// `categoryId` → `category_id`，递归含嵌套与数组
    #[test]
    fn converts_camel_case_to_snake_recursively() {
        let js = serde_json::json!({
            "id": "a",
            "title": "区块A",
            "source": { "type": "category", "categoryId": "1" },
            "items": [{ "id": "v1", "pageCount": 3 }],
        });
        let rust = js_value_to_rust(js);

        assert_eq!(rust["source"]["category_id"], "1");
        assert_eq!(rust["items"][0]["page_count"], 3);
        // 原本就是小写的键不受影响
        assert_eq!(rust["source"]["type"], "category");
        assert_eq!(rust["title"], "区块A");
    }

    /// ★ `headers` 必须从对象转成键值对数组
    ///
    /// Rust 侧是 `Vec<(String, String)>`，插件按契约写 `{ Referer: 'x' }`，
    /// 不转的话 serde 会报 `invalid type: map, expected a sequence`。
    #[test]
    fn converts_headers_object_to_pairs() {
        let js = serde_json::json!({
            "url": "https://x/a.m3u8",
            "headers": { "Referer": "https://x/", "User-Agent": "UA" },
        });
        let rust = js_value_to_rust(js);

        let h = rust["headers"].as_array().expect("headers 应转成数组");
        assert_eq!(h.len(), 2);
        // 每项是 [key, value]
        assert!(h.iter().all(|p| p.as_array().map(|a| a.len()) == Some(2)));
    }

    /// 反向：Rust → 插件（`episode_id` → `episodeId`）
    #[test]
    fn converts_snake_case_to_camel_for_plugin_args() {
        let rust = serde_json::json!({
            "source_code": "line1",
            "episode_id": "ep5",
        });
        let js = rust_value_to_js(rust);
        assert_eq!(js["sourceCode"], "line1");
        assert_eq!(js["episodeId"], "ep5");
        // 不应残留 snake_case 键
        assert!(js.get("episode_id").is_none());
    }

    /// ★ 能力位必须能读到（含多词字段）
    ///
    /// 实测踩过：`hydrate_capabilities` 读的是 `loginRequired`，
    /// 但 `call_js` 出口已经把键转成 `login_required` 了 ——
    /// 于是 srca 的 `loginRequired: true` **完全没生效**：
    /// 界面不显示登录入口、会话状态是 `not_required`，用户没法登录。
    ///
    /// 这条测试覆盖「插件写 camelCase → 能力位正确落到 manifest」全链路。
    #[tokio::test]
    async fn hydrates_capabilities_including_multiword() {
        let src = r#"
/** @id caps @name 能力测试 */
globalThis.plugin = {
  capabilities: {
    vod: true,
    search: true,
    loginRequired: true,
    multiSource: true,
    serverSideHistory: true,
  },
};
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        // 执行前是保守默认值
        assert!(!p.manifest().capabilities.login_required);

        p.hydrate_capabilities().await;

        let c = &p.manifest().capabilities;
        assert!(c.vod, "vod 应被读到");
        assert!(c.search, "search 应被读到");
        assert!(
            c.login_required,
            "★ loginRequired 必须读到（多词字段，转换后是 login_required）"
        );
        assert!(c.multi_source, "★ multiSource 必须读到");
        assert!(c.server_side_history, "★ serverSideHistory 必须读到");
        // 没声明的要保持 false
        assert!(!c.live, "未声明的 live 不该变成 true");
    }

    // ═══════════════════════════════════════════════════════════════
    //  task-9 ③：resolve 的**第一个参数**选谁（Owner：「播放第二集实际还是第一集」）
    // ═══════════════════════════════════════════════════════════════

    /// ★★★ episode_id 是 http(s) URL ⇒ 用它当第一个参数
    ///
    /// # 为什么
    ///
    /// tvbox 转换插件的 ¤detail()¤ 里剧集 id **就是剧集地址**
    /// （¤154.js:369  id: e.url¤），而它的 ¤resolve(id)¤ 只认第一个参数、
    /// **完全忽略 req**（¤154.js:392¤）⇒ 宿主若传条目 id，它就去查详情、
    /// 取 ¤eps[0]¤ ⇒ **永远第一集**（Owner 报的 bug）。
    #[test]
    fn resolve_first_arg_uses_episode_url() {
        let src = "/** @id t9tvbox @name 测试 */\n";
        let p = JsPluginProvider::from_source(src).unwrap();

        // 插件把收到的第一个参数原样回吐（探针插件）
        let req = PlayRequest {
            source_code: None,
            episode_id: Some("https://cdn.test/e2.m3u8".into()),
            quality: None,
        };
        let arg = p.resolve_first_arg(&MediaId::new("t9tvbox", "150758"), &req);
        assert_eq!(
            arg, "https://cdn.test/e2.m3u8",
            "★ 第2集地址必须原样成为第一个参数（否则插件会退回第一集）"
        );
    }

    /// ★★ 反向控制：episode_id **不是** URL ⇒ 与改前**逐字相同**（传条目 id）
    ///
    /// 这条是"不许把某动画站打坏"的护栏：srca 拿 ¤episode_id¤ 当 section_id，
    /// 若不加判断地一律替换，它收到的东西就变了。
    #[test]
    fn resolve_first_arg_keeps_native_id_for_non_url() {
        let src = "/** @id srca @name 测试 */\n";
        let p = JsPluginProvider::from_source(src).unwrap();
        let id = MediaId::new("srca", "51463");

        for ep in [Some("51463"), Some("srca:51463"), Some(""), None] {
            let req = PlayRequest {
                source_code: None,
                episode_id: ep.map(|s| s.to_string()),
                quality: None,
            };
            assert_eq!(
                p.resolve_first_arg(&id, &req),
                "51463",
                "episode_id={ep:?} 时必须维持原行为（传剥过前缀的条目 id）"
            );
        }
    }

    /// ★ 前缀剥除仍然生效（改动的另一条护栏）
    #[test]
    fn resolve_first_arg_still_strips_prefix() {
        let src = "/** @id srca @name 测试 */\n";
        let p = JsPluginProvider::from_source(src).unwrap();
        let req = PlayRequest {
            source_code: None,
            episode_id: Some("srca:51463".into()),
            quality: None,
        };
        // 条目 id 带自己的前缀 ⇒ 剥掉
        assert_eq!(
            p.resolve_first_arg(&MediaId::new("srca", "srca:51463"), &req),
            "51463"
        );
        // 别的 provider 的前缀不动
        assert_eq!(
            p.resolve_first_arg(&MediaId::new("srca", "other:abc"), &req),
            "other:abc"
        );
    }

    /// ★★ 前缀只能加在**媒体条目**上，不能误伤剧集/线路/区块
    ///
    /// 实测踩到（Owner 报「从追更进入报错」）：
    /// `Episode` 也长着 `{id, title}` 的样子，于是剧集 id 被加前缀
    /// 变成 `srca:51463`，前端放进 `PlayRequest.episode_id` 传回来，
    /// 插件拿它当数字 id → 服务端报
    /// `bind uri "section_id": parsing "srca:51463": invalid syntax`。
    #[test]
    fn prefix_only_applies_to_media_items() {
        let src = "/** @id srca @name 测试 */\n";
        let p = JsPluginProvider::from_source(src).unwrap();

        let mut v = serde_json::json!({
            // 媒体条目 → 应加前缀
            "items": [{ "id": "900", "title": "作品", "cover": "x.jpg" }],
            // 剧集 → **不该**加（有 order）
            "episodes": [
                { "id": "51463", "title": "第01集", "order": 1 },
                { "id": "51464", "title": "第02集", "order": 2 }
            ],
            // 播放源 → 不该加（有 code + count）
            "sources": [{ "code": "CYC_Main", "title": "线路", "count": 12 }],
            // 区块 → 不该加（有 source）
            "sections": [
                { "id": "srca-rank-1", "title": "榜单", "source": { "type": "rank", "rankId": "1" } }
            ]
        });
        p.prefix_media_ids(&mut v);

        // 媒体条目：加了
        assert_eq!(v["items"][0]["id"], "srca:900", "媒体条目应加前缀");

        // ★ 剧集：必须保持原样（这是 bug 的核心）
        assert_eq!(
            v["episodes"][0]["id"], "51463",
            "剧集 id 不能加前缀 —— 加了会让取流接口报 invalid syntax"
        );
        assert_eq!(v["episodes"][1]["id"], "51464");

        // 播放源 / 区块：保持原样
        assert_eq!(v["sources"][0]["code"], "CYC_Main");
        assert_eq!(v["sections"][0]["id"], "srca-rank-1");
    }

    /// ★ 转换函数本身要正确（含边界）
    #[test]
    fn naming_helpers_are_correct() {
        assert_eq!(camel_to_snake("categoryId"), "category_id");
        assert_eq!(camel_to_snake("id"), "id");
        assert_eq!(camel_to_snake("notWebReady"), "not_web_ready");
        assert_eq!(camel_to_snake("drmProtected"), "drm_protected");

        assert_eq!(snake_to_camel("category_id"), "categoryId");
        assert_eq!(snake_to_camel("id"), "id");
        assert_eq!(snake_to_camel("not_web_ready"), "notWebReady");
    }

    // ─────────── 在线安装的地址解析 ───────────

    /// ★ GitHub 页面地址必须转成 **CDN 直链**
    ///
    /// 实测 `raw.githubusercontent.com` 国内直连 **12 秒超时**，
    /// 而 `cdn.jsdelivr.net` 1.1 秒可用 —— 所以默认必须走 jsDelivr，
    /// 否则用户粘了 GitHub 地址会一直转圈。
    #[test]
    fn converts_github_url_to_cdn() {
        assert_eq!(
            resolve_plugin_url("https://github.com/user/repo").unwrap(),
            "https://cdn.jsdelivr.net/gh/user/repo@main/index.js"
        );
        // 带 .git 后缀也要能处理
        assert_eq!(
            resolve_plugin_url("https://github.com/user/repo/").unwrap(),
            "https://cdn.jsdelivr.net/gh/user/repo@main/index.js"
        );
        // owner/repo 简写
        assert_eq!(
            resolve_plugin_url("user/repo").unwrap(),
            "https://cdn.jsdelivr.net/gh/user/repo@main/index.js"
        );
    }

    /// 指向具体文件的 GitHub 地址要保留路径与分支
    #[test]
    fn keeps_path_and_branch_for_blob_url() {
        assert_eq!(
            resolve_plugin_url("https://github.com/u/r/blob/main/src/x.js").unwrap(),
            "https://cdn.jsdelivr.net/gh/u/r@main/src/x.js"
        );
        assert_eq!(
            resolve_plugin_url("https://github.com/u/r/blob/dev/plugins/a.js").unwrap(),
            "https://cdn.jsdelivr.net/gh/u/r@dev/plugins/a.js"
        );
    }

    /// 已经是直链的原样返回（含自建服务器、jsDelivr、raw）
    #[test]
    fn passes_through_direct_urls() {
        for u in [
            "https://cdn.jsdelivr.net/gh/u/r@main/x.js",
            "https://raw.githubusercontent.com/u/r/main/x.js",
            "https://my-server.local/plugin.js",
        ] {
            assert_eq!(resolve_plugin_url(u).unwrap(), u, "直链不应被改写: {u}");
        }
    }

    /// 非法输入要给出**可操作的**提示，而不是笼统报错
    #[test]
    fn rejects_unrecognizable_input() {
        assert!(resolve_plugin_url("").unwrap_err().contains("请填写"));
        let e = resolve_plugin_url("这不是地址").unwrap_err();
        assert!(e.contains("GitHub") || e.contains("http"), "提示应说明支持什么，实际: {e}");
    }

    /// ★ 文件名由 id 派生，必须挡住目录穿越
    #[test]
    fn save_plugin_rejects_path_traversal() {
        let dir = std::env::temp_dir().join(format!("dsh-pl-save-{}", std::process::id()));
        // 这些 id 会拼出 `../../x.js` 之类，必须拒绝
        for bad in ["../evil", "a/b", "a\\b", "..", "a b"] {
            let r = save_plugin(&dir, bad, "/** @id x */");
            assert!(r.is_err(), "id={bad:?} 应被拒绝");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 正常 id 要能写入，且文件名可预期
    #[test]
    fn save_plugin_writes_expected_file() {
        let dir = std::env::temp_dir().join(format!("dsh-pl-ok-{}", std::process::id()));
        let (file, bytes) = save_plugin(&dir, "my-plugin_2", "/** @id my-plugin_2 */").unwrap();
        assert_eq!(file, "my-plugin_2.js");
        assert!(bytes > 0);
        assert!(dir.join(&file).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ═══════════════ 插件配置（声明式）═══════════════

    /// 造一个测试用的配置项
    fn field(key: &str, kind: &str) -> crate::model::ConfigField {
        crate::model::ConfigField {
            key: key.into(),
            label: format!("测试项 {key}"),
            kind: kind.into(),
            default: None,
            options: Vec::new(),
            hint: None,
            placeholder: None,
            show_if: std::collections::HashMap::new(),
            min: None,
            max: None,
        }
    }

    /// ★ 核心行为：**没配过就返回默认值**，配过就返回配置值
    ///
    /// 为什么这条重要：界面上如果没配过的项显示空白，
    /// 用户不知道"本来应该是什么"，也不敢乱改。
    #[test]
    fn config_returns_default_until_set() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-def-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let mut quality = field("quality", "select");
        quality.options = vec![crate::model::ConfigOption {
            value: "720".into(),
            label: "720P".into(),
            hint: None,
        }];
        quality.default = Some(serde_json::json!("720"));
        quality.sanitize(&mut Vec::new());

        let fields = vec![quality];

        // 没配过 → 拿到默认值
        let r = resolved_config(&dir, &fields, "p1");
        assert_eq!(r.get("quality"), Some(&serde_json::json!("720")));

        // 配过 → 拿到配置值
        let mut vals = serde_json::Map::new();
        vals.insert("quality".into(), serde_json::json!("720"));
        config_write_many(&dir, &fields, "p1", &vals).unwrap();
        let r = resolved_config(&dir, &fields, "p1");
        assert_eq!(r.get("quality"), Some(&serde_json::json!("720")));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ 类型校验：给 `switch` 传字符串必须被拒
    ///
    /// 为什么必须校验：界面传错类型的话，插件读到的不是布尔，
    /// 表现是"开关打开了但没生效"—— 这种 bug 极难查。
    #[test]
    fn config_rejects_wrong_type() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-type-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let fields = vec![field("proxy", "switch")];

        let mut bad = serde_json::Map::new();
        bad.insert("proxy".into(), serde_json::json!("true")); // 字符串！不是布尔
        assert!(
            config_write_many(&dir, &fields, "p1", &bad).is_err(),
            "给 switch 传字符串必须被拒"
        );

        let mut good = serde_json::Map::new();
        good.insert("proxy".into(), serde_json::json!(true));
        assert!(config_write_many(&dir, &fields, "p1", &good).is_ok());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `select` 的值必须在选项里（否则界面上显示不出来）
    #[test]
    fn config_select_value_must_be_in_options() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-sel-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let mut f = field("quality", "select");
        f.options = vec![
            crate::model::ConfigOption { value: "720".into(), label: "720P".into(), hint: None },
            crate::model::ConfigOption { value: "1080".into(), label: "1080P".into(), hint: None },
        ];
        let fields = vec![f];

        let mut bad = serde_json::Map::new();
        bad.insert("quality".into(), serde_json::json!("4k")); // 不在选项里
        assert!(config_write_many(&dir, &fields, "p1", &bad).is_err());

        let mut good = serde_json::Map::new();
        good.insert("quality".into(), serde_json::json!("1080"));
        assert!(config_write_many(&dir, &fields, "p1", &good).is_ok());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ 未声明的键被忽略而不是报错
    ///
    /// 场景：插件升级后删掉了某个配置项，但旧的 store 里还有那个值。
    /// 如果报错，用户会遇到"升级插件后一个都存不进去"。
    #[test]
    fn config_ignores_undeclared_keys() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-und-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let fields = vec![field("proxy", "switch")];

        let mut vals = serde_json::Map::new();
        vals.insert("proxy".into(), serde_json::json!(true));       // 已声明
        vals.insert("幽灵项".into(), serde_json::json!("x"));        // 未声明

        let n = config_write_many(&dir, &fields, "p1", &vals).unwrap();
        assert_eq!(n, 1, "只应写入已声明的那一个");

        // 未声明的值不该被写进去
        let r = resolved_config(&dir, &fields, "p1");
        assert!(r.get("幽灵项").is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 配置与 `host.store` **互不干扰**（同一文件、不同前缀）
    #[test]
    fn config_and_store_do_not_collide() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-mix-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        // store 写一个字符串
        store_write(&dir, "p1", "quality", Some("store的值".into())).unwrap();
        // config 写同名键（应落在 `cfg:` 前缀下）
        let fields = vec![field("quality", "text")];
        let mut vals = serde_json::Map::new();
        vals.insert("quality".into(), serde_json::json!("config的值"));
        config_write_many(&dir, &fields, "p1", &vals).unwrap();

        // 两者各自独立
        assert_eq!(store_read(&dir, "p1", "quality").as_deref(), Some("store的值"));
        assert_eq!(
            config_read(&dir, "p1", "quality"),
            Some(serde_json::json!("config的值"))
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ `sanitize` 把不合法的声明**降级**而不是让插件加载失败
    #[test]
    fn field_sanitize_degrades_bad_declarations() {
        let mut warn = Vec::new();

        // 不认识的 type → info
        let mut a = field("x", "colorpicker");
        a.sanitize(&mut warn);
        assert_eq!(a.kind, "info", "不认识的 type 应降级为 info");

        // select 但没有选项 → info（否则渲染出空下拉框）
        let mut b = field("y", "select");
        b.sanitize(&mut warn);
        assert_eq!(b.kind, "info", "无选项的 select 应降级");

        // select 默认值不在选项里 → 改用第一项
        let mut c = field("z", "select");
        c.options = vec![crate::model::ConfigOption {
            value: "a".into(), label: "A".into(), hint: None,
        }];
        c.default = Some(serde_json::json!("not-in-options"));
        c.sanitize(&mut warn);
        assert_eq!(c.default, Some(serde_json::json!("a")));

        // switch 默认值不是布尔 → false
        let mut d = field("w", "switch");
        d.default = Some(serde_json::json!("yes"));
        d.sanitize(&mut warn);
        assert_eq!(d.default, Some(serde_json::json!(false)));

        // min/max 写反 → 交换
        let mut e = field("n", "number");
        e.min = Some(100.0);
        e.max = Some(10.0);
        e.sanitize(&mut warn);
        assert_eq!(e.min, Some(10.0));
        assert_eq!(e.max, Some(100.0));

        // 每一处降级都应产生警告（用户/作者要知道）
        assert!(warn.len() >= 5, "应产生足够多的警告，实际 {}", warn.len());
    }

    /// 配置写入后能**跨实例**读到（模拟重启）
    #[test]
    fn config_persists_across_instances() {
        let dir = std::env::temp_dir().join(format!("dsh-cfg-persist-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let fields = vec![field("proxyUrl", "text")];
        let mut vals = serde_json::Map::new();
        vals.insert("proxyUrl".into(), serde_json::json!("http://127.0.0.1:7890"));
        config_write_many(&dir, &fields, "p1", &vals).unwrap();

        // 重新构造 fields（模拟重启后从插件源码重新声明）
        let fields2 = vec![field("proxyUrl", "text")];
        let r = resolved_config(&dir, &fields2, "p1");
        assert_eq!(
            r.get("proxyUrl"),
            Some(&serde_json::json!("http://127.0.0.1:7890")),
            "配置必须跨重启保留"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ═══════════════ 媒体 id 前缀 ═══════════════

    /// 造一个用于测前缀的插件（只关心 manifest.id）
    fn provider_with_id(id: &str) -> JsPluginProvider {
        let src = format!(
            r#"/** @id {id} @name 测试 @version 1.0.0 */
globalThis.plugin = {{ id: '{id}', async home() {{ return [] }} }};"#
        );
        JsPluginProvider::from_source(&src).unwrap()
    }

    /// ★★ id **含冒号**时也必须加前缀（Owner 报「某视频站点开显示没有路由」的根因）
    ///
    /// 原实现用 `!id.contains(':')` 判断"是否已加过前缀"，
    /// 于是 外部视频站插件的 `av:BV1u9ew6yEEP` 被误判为"已有前缀"而跳过 →
    /// 前端切第一个冒号拿到 `provider="av"` → 后端路由不到。
    #[test]
    fn prefix_added_even_when_id_contains_colon() {
        let p = provider_with_id("src-a");

        let mut v = serde_json::json!({
            "items": [
                { "id": "av:BV1u9ew6yEEP", "title": "《鸣潮》先约电台" },
                { "id": "BV1cSec6tEux", "title": "不带冒号的 id" },
            ]
        });
        p.prefix_media_ids(&mut v);

        let items = v.get("items").unwrap().as_array().unwrap();
        assert_eq!(
            items[0].get("id").unwrap().as_str().unwrap(),
            "src-a:av:BV1u9ew6yEEP",
            "★ 含冒号的 id 也必须加前缀（否则前端切出来 provider=av）"
        );
        assert_eq!(
            items[1].get("id").unwrap().as_str().unwrap(),
            "src-a:BV1cSec6tEux"
        );
    }

    /// 幂等：已经带**本插件**前缀的不重复加
    ///
    /// 数据会往返（前端把带前缀的 id 传回来，插件可能原样返回），
    /// 所以这个函数必须能被安全地反复调用。
    #[test]
    fn prefix_is_idempotent() {
        let p = provider_with_id("src-a");

        let mut v = serde_json::json!({
            "items": [{ "id": "src-a:av:BV1u9ew6yEEP", "title": "已带前缀" }]
        });
        p.prefix_media_ids(&mut v);
        p.prefix_media_ids(&mut v);

        assert_eq!(
            v["items"][0]["id"].as_str().unwrap(),
            "src-a:av:BV1u9ew6yEEP",
            "反复调用不能变成 src-a:src-a:..."
        );
    }

    /// 别的 provider 的前缀不该被当成"自己的前缀"而跳过
    ///
    /// 场景：跨源协作时 A 插件返回了 B 源的 id。那种 id 对 A 来说
    /// **不是**自己的前缀，应当照常加上 A 的前缀（由 A 负责解释它）。
    #[test]
    fn prefix_of_other_provider_is_not_treated_as_own() {
        let p = provider_with_id("src-a");

        let mut v = serde_json::json!({
            "items": [{ "id": "src-b:abc123", "title": "别的源的 id" }]
        });
        p.prefix_media_ids(&mut v);

        assert_eq!(
            v["items"][0]["id"].as_str().unwrap(),
            "src-a:src-b:abc123",
            "别人的前缀不是我的前缀 —— 判据必须精确匹配"
        );
    }

    /// 前缀 ↔ 剥前缀必须**严格互逆**（往返不能丢信息）
    ///
    /// 这是最核心的不变量：加完再剥必须回到原样，
    /// 否则详情/取流/剧集全都拿不到数据（而且不报错，极难查）。
    #[test]
    fn prefix_and_strip_are_inverse() {
        let p = provider_with_id("src-a");

        for native in [
            "av:BV1u9ew6yEEP", // 含冒号（外部视频站真实形态）
            "BV1cSec6tEux",    // 不含冒号
            "a:b:c:d",         // 多冒号
            "中文id",           // 非 ASCII
            "a/b?c#d",         // 各种特殊字符
        ] {
            let mut v = serde_json::json!({ "id": native, "title": "x" });
            p.prefix_media_ids(&mut v);
            let prefixed = v["id"].as_str().unwrap();

            assert_eq!(
                p.strip_prefix(prefixed),
                native,
                "往返失败：{native} → {prefixed} → {}",
                p.strip_prefix(prefixed)
            );
        }
    }

    /// 剧集 / 播放源 / 分区**不能**被加前缀（回归保护）
    ///
    /// 实测踩过：`Episode` 也有 `{id, title}`，被加前缀后
    /// 插件拿 `srca:51463` 当数字 id 用 → 服务端报
    /// `parsing "srca:51463": invalid syntax`。
    #[test]
    fn non_media_objects_are_not_prefixed() {
        let p = provider_with_id("src-a");

        let mut v = serde_json::json!({
            "episodes": [{ "id": "51463", "title": "第 1 集", "order": 1 }],
            "sources": [{ "code": "default", "name": "线路", "count": 3 }],
            "sections": [{ "id": "rank-1", "title": "榜单", "source": { "type": "rank" } }]
        });
        p.prefix_media_ids(&mut v);

        assert_eq!(v["episodes"][0]["id"].as_str().unwrap(), "51463", "剧集不该加前缀");
        assert_eq!(v["sections"][0]["id"].as_str().unwrap(), "rank-1", "分区不该加前缀");
    }

    // ═══════════════════════════════════════════════════════════════
    //  弹幕（task-T2，2026-10-16）
    // ═══════════════════════════════════════════════════════════════

    /// 一个「实现了弹幕两个方法」的插件源码
    ///
    /// `cidMode` 控制返回的弹幕**带不带 cid** —— 这是本组测试的核心变量：
    /// ```text
    /// "with"    每条都带 cid（dandanplay 风格，上游本来就给）
    /// "without" 一条都不带（外部视频源 XML 风格，上游没有这个概念）
    /// "mixed"   一半带一半不带（真实世界里最常见的形态）
    /// ```
    fn danmaku_plugin_src(cidMode: &str) -> String {
        let items = match cidMode {
            "with" => "{ cid: 101, p: '1.5,1,16777215,u1', m: '第一条' },\
                       { cid: 102, p: '3.0,5,255,u2', m: '第二条' }",
            "without" => "{ p: '1.5,1,16777215,u1', m: '第一条' },\
                          { p: '3.0,5,255,u2', m: '第二条' }",
            _ => "{ cid: 101, p: '1.5,1,16777215,u1', m: '第一条' },\
                   { p: '3.0,5,255,u2', m: '第二条' }",
        };
        format!(
            r#"/** @id dmp @name 弹幕插件 */
globalThis.plugin = {{
  id: 'dmp',
  capabilities: {{ vod: true, danmaku: true, danmakuSend: true }},
  async danmakuList(req) {{
    return {{
      items: [{items}],
      source: 'test:' + req.episodeId
    }};
  }},
  async danmakuSend(req) {{ return {{ ok: true, id: 'sent-1' }}; }},
}};"#
        )
    }

    /// ★★★ 核心：插件能提供弹幕，且**桥接真的接上了**
    ///
    /// 改前 `Capabilities.danmaku` 是个**假能力位** —— 界面上显示「弹幕」
    /// 标签，但宿主没有任何地方拿它去调插件。这条测试钉住「真的调了」。
    #[tokio::test]
    async fn danmaku_list_is_bridged_to_plugin() {
        let p = JsPluginProvider::from_source(&danmaku_plugin_src("with")).unwrap();
        let b = p
            .danmaku_list(DanmakuRequest {
                media_id: "m1".into(),
                episode_id: "ep1".into(),
                ..Default::default()
            })
            .await
            .expect("★ danmakuList 必须被桥接（改前是假能力位，永远不调插件）");
        assert_eq!(b.items.len(), 2, "应拿到插件返回的 2 条");
        assert_eq!(b.items[0].m, "第一条");
        assert_eq!(b.items[0].p, "1.5,1,16777215,u1");
        assert_eq!(b.source.as_deref(), Some("test:ep1"), "source 要如实带上剧集 id");
    }

    /// ★★★ 没有这一步，插件弹幕会**静默全丢**（本任务最关键的一条）
    ///
    /// # 依据（不是推测，是实测出来的）
    ///
    /// 宿主 `lib/core/danmaku.dart` 的 `DanmakuComment.fromJson` 逐字是：
    /// ```dart
    /// final cid = _asInt(j['cid']);
    /// if (cid == null) return null;   // ★ 整条丢弃
    /// ```
    /// 实测（`.probe/plugin-work/danmaku_wire_crosscheck_test.dart`）：
    /// 3 条只有 `{p, m}` 的 wire 喂进去 ⇒ **3 条全部被丢弃，且不抛异常**。
    /// 表现是「弹幕加载成功但一条都没有」—— 用户与插件作者都无从排查。
    ///
    /// ⇒ 桥接层必须给缺 cid 的弹幕补位（`fill_missing_cids`）。
    #[tokio::test]
    async fn danmaku_list_backfills_missing_cid() {
        let p = JsPluginProvider::from_source(&danmaku_plugin_src("without")).unwrap();
        let b = p
            .danmaku_list(DanmakuRequest { episode_id: "ep1".into(), ..Default::default() })
            .await
            .unwrap();

        assert_eq!(b.items.len(), 2, "两条都要在（不许因为缺 cid 就丢）");
        for (i, c) in b.items.iter().enumerate() {
            assert!(
                c.cid.is_some(),
                "★ 第 {i} 条必须被补上 cid —— 否则宿主 fromJson 会**静默丢弃整条**"
            );
        }
        // 补位规则：下标 + 1 ⇒ 1、2（从 1 开始，与真实 cid 习惯一致）
        assert_eq!(b.items[0].cid, Some(1), "第一条补 1");
        assert_eq!(b.items[1].cid, Some(2), "第二条补 2");
        // 补位不能破坏原有字段
        assert_eq!(b.items[0].m, "第一条");
        assert_eq!(b.items[1].p, "3.0,5,255,u2");
    }

    /// ★ 插件给的真 cid **不许被覆盖**（补位只补 None）
    #[tokio::test]
    async fn danmaku_list_keeps_real_cid() {
        let p = JsPluginProvider::from_source(&danmaku_plugin_src("mixed")).unwrap();
        let b = p
            .danmaku_list(DanmakuRequest { episode_id: "ep1".into(), ..Default::default() })
            .await
            .unwrap();
        assert_eq!(b.items[0].cid, Some(101), "第 1 条有真 cid ⇒ 必须原样保留");
        assert_eq!(b.items[1].cid, Some(2), "第 2 条缺 cid ⇒ 按下标+1 补成 2");
    }

    /// ★★ 「不支持」与「有但返回空」必须是**两件可区分的事**
    ///
    /// Lead 明确要求：否则用户没法判断是源不支持还是真没弹幕。
    #[tokio::test]
    async fn danmaku_unsupported_is_distinguishable_from_empty() {
        // ① 插件没实现 danmakuList ⇒ Unsupported（明确的不支持）
        let src_no = r#"/** @id no_dm @name 无弹幕插件 */
globalThis.plugin = { id: 'no_dm', capabilities: { vod: true } };
"#;
        let p = JsPluginProvider::from_source(src_no).unwrap();
        let e = p
            .danmaku_list(DanmakuRequest { episode_id: "ep1".into(), ..Default::default() })
            .await
            .expect_err("没实现 danmakuList ⇒ 必须报错，不能静默返回空列表");
        assert_eq!(
            e.kind,
            ErrorKind::Unsupported,
            "★ 必须是 Unsupported（调用方据此隐藏弹幕入口），实际: {:?} / {}",
            e.kind,
            e.message
        );

        // ② 插件实现了但这一集真没弹幕 ⇒ Ok(空列表)，**不是**错误
        let src_empty = r#"/** @id empty_dm @name 空弹幕插件 */
globalThis.plugin = {
  id: 'empty_dm',
  capabilities: { vod: true, danmaku: true },
  async danmakuList(req) { return { items: [], source: 'test:empty' }; },
};
"#;
        let p2 = JsPluginProvider::from_source(src_empty).unwrap();
        let b = p2
            .danmaku_list(DanmakuRequest { episode_id: "ep1".into(), ..Default::default() })
            .await
            .expect("★ 这一集真没弹幕是**合法结果**，不能报错");
        assert!(b.items.is_empty(), "空列表如实返回");
    }

    /// ★ 剧集 id 上的 `{provider}:` 前缀必须剥掉再给插件
    ///
    /// 不剥的后果实测过（本文件 L2119）：插件拿 `srca:51463` 当数字 id 用 → 上游 400。
    #[tokio::test]
    async fn danmaku_strips_provider_prefix_from_ids() {
        let src = r#"/** @id pf @name 前缀插件 */
globalThis.plugin = {
  id: 'pf',
  async danmakuList(req) {
    return { items: [], source: req.mediaId + '|' + req.episodeId };
  },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let b = p
            .danmaku_list(DanmakuRequest {
                media_id: "pf:m1".into(),
                episode_id: "pf:ep1".into(),
                ..Default::default()
            })
            .await
            .unwrap();
        assert_eq!(
            b.source.as_deref(),
            Some("m1|ep1"),
            "★ 插件收到的必须是裸 id（前缀已剥），否则上游会 400"
        );
    }

    /// ★★ 发送弹幕：能发就真的发，并把上游 id 带回来
    #[tokio::test]
    async fn danmaku_send_is_bridged_and_returns_id() {
        let p = JsPluginProvider::from_source(&danmaku_plugin_src("with")).unwrap();
        let r = p
            .danmaku_send(DanmakuSendRequest {
                episode_id: "ep1".into(),
                text: "你好".into(),
                ..Default::default()
            })
            .await
            .expect("danmakuSend 必须被桥接");
        assert!(r.ok, "ok 必须为 true");
        assert_eq!(r.id.as_deref(), Some("sent-1"), "上游 id 要带回来");
    }

    /// ★★★ 纪律：没实现发送 ⇒ **必须如实说不支持**，绝不假装成功
    ///
    /// 假装成功的后果最坏：用户以为发出去了 → 刷新找不到 → 反复发 →
    /// 在真站点上可能**已经触发风控封禁**。
    #[tokio::test]
    async fn danmaku_send_unsupported_when_not_implemented() {
        let src = r#"/** @id no_send @name 不能发的插件 */
globalThis.plugin = {
  id: 'no_send',
  capabilities: { vod: true, danmaku: true },
  async danmakuList(req) { return { items: [] }; },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let e = p
            .danmaku_send(DanmakuSendRequest { episode_id: "ep1".into(), text: "x".into(), ..Default::default() })
            .await
            .expect_err("★ 没实现发送 ⇒ 必须报 Unsupported，绝不能返回成功");
        assert_eq!(e.kind, ErrorKind::Unsupported, "实际: {:?} / {}", e.kind, e.message);
    }

    /// ★★★ 纪律兜底：插件返回 `{ok: false}` 也要被拒（不能当软失败放过去）
    ///
    /// 契约要求抛 `unsupported:`，但作者可能写成 `return { ok: false }`。
    /// 若宿主放过去，调用方会以为**发送成功了**。
    #[tokio::test]
    async fn danmaku_send_ok_false_is_rejected() {
        let src = r#"/** @id soft @name 软失败插件 */
globalThis.plugin = {
  id: 'soft',
  async danmakuSend(req) { return { ok: false }; },
};
"#;
        let p = JsPluginProvider::from_source(src).unwrap();
        let e = p
            .danmaku_send(DanmakuSendRequest { episode_id: "ep1".into(), text: "x".into(), ..Default::default() })
            .await
            .expect_err("★ ok=false 必须转成明确的 Unsupported，不能被当成「发过了」");
        assert_eq!(e.kind, ErrorKind::Unsupported, "实际: {:?} / {}", e.kind, e.message);
    }

    /// ★ 能力位：`danmaku` / `danmakuSend` 两个都要被读进来
    ///
    /// ⚠️ `hydrate_capabilities` 是**逐字段**读的，往结构体加字段**不会**
    ///    自动生效 —— 忘了在这里赋值，表现是「插件声明了却不出现入口」且不报错。
    #[tokio::test]
    async fn danmaku_capability_bits_are_hydrated() {
        let p = JsPluginProvider::from_source(&danmaku_plugin_src("with")).unwrap();
        let mut p = p;
        p.hydrate_capabilities().await;
        let c = &p.manifest().capabilities;
        assert!(c.danmaku, "danmaku 能力位必须被读进来");
        assert!(c.danmaku_send, "★ danmaku_send 能力位必须被读进来（漏了不报错）");
    }

    /// ★ 老插件（不声明弹幕）⇒ 两个能力位都必须是 **false**（行为与今天逐字相同）
    #[tokio::test]
    async fn danmaku_capability_defaults_to_false_for_old_plugins() {
        let src = r#"/** @id old @name 老插件 */
globalThis.plugin = { id: 'old', capabilities: { vod: true, search: true } };
"#;
        let mut p = JsPluginProvider::from_source(src).unwrap();
        p.hydrate_capabilities().await;
        let c = &p.manifest().capabilities;
        assert!(!c.danmaku, "★ 老插件不声明 ⇒ 必须是 false（否则界面会突然多出弹幕入口）");
        assert!(!c.danmaku_send, "★ 同上");
    }


    /// ★★★ 端到端：插件 → 宿主桥接 → 真实 wire JSON（供 Dart 侧交叉验证）
    ///
    /// # 这条测试为什么必须存在
    ///
    /// 上面那些测试各自只证明**一段**是对的：
    /// ```text
    /// danmaku_list_backfills_missing_cid  ⇒ 桥接层补了 cid
    /// （Dart 侧）danmaku_wire_crosscheck  ⇒ 真解析器能吃掉 wire
    /// ```
    /// 但**两段接起来**才是用户实际走的路。协议真正的风险恰恰在接缝上：
    /// 「插件输出的形状 ≠ 宿主能解析的形状」—— 那种 bug 不报错，
    /// 表现是「弹幕加载成功但一条都不显示」，最难查。
    ///
    /// # 它怎么把两段接起来
    /// ```text
    /// ① 本测试跑**真插件**（含故意不带 cid 的形态）过**真桥接层**
    /// ② 把桥接层吐出的 wire 打成一行带前缀的 JSON 打到 stdout
    /// ③ 外部脚本把那一行落成文件，交给 Dart 侧的真解析器
    ///    （.probe/plugin-work/e2e_danmaku_chain_test.dart）
    /// ```
    /// ⚠️ 用「打印」而不是「测试里写文件」：单元测试不该有副作用，
    ///    而且打印出来的**原始 cargo 输出本身就是证据**。
    #[tokio::test]
    async fn e2e_plugin_to_wire_json_for_dart() {
        // 故意用 "without"：一条 cid 都不给 —— 这正是最容易静默全丢的形态
        let p = JsPluginProvider::from_source(&danmaku_plugin_src("without")).unwrap();
        let b = p
            .danmaku_list(DanmakuRequest {
                media_id: "m1".into(),
                episode_id: "ep-e2e".into(),
                ..Default::default()
            })
            .await
            .expect("桥接必须成功");

        // 桥接层已补位 —— 这里断言，然后才打出去
        assert_eq!(b.items.len(), 2, "两条都要在");
        assert!(b.items.iter().all(|c| c.cid.is_some()), "★ 每条都必须有 cid");

        let wire = serde_json::json!({
            "items": b.items,
            "source": b.source,
            "truncated": b.truncated,
        });
        // ★ 这一行是给外部脚本抓的（前缀是约定，别改）
        println!("E2E_WIRE_JSON={}", serde_json::to_string(&wire).unwrap());
    }

    /// ★ 没实现弹幕的源，走 trait 默认实现必须是 Unsupported（不是 panic、不是空）
    #[tokio::test]
    async fn danmaku_default_impl_is_unsupported() {
        let p = provider_with_id("plain");
        let e = p
            .danmaku_list(DanmakuRequest::default())
            .await
            .expect_err("默认实现必须报 Unsupported");
        assert_eq!(e.kind, ErrorKind::Unsupported);
        let e2 = p
            .danmaku_send(DanmakuSendRequest::default())
            .await
            .expect_err("默认实现必须报 Unsupported");
        assert_eq!(e2.kind, ErrorKind::Unsupported);
    }

    // ══════════════════════════════════════════════════════════════════
    // ★★★ 2026-10-18（E2E 验证发现）：raw-deflate 解码
    // ══════════════════════════════════════════════════════════════════
    //
    // # 为什么要有这个测试
    // ```text
    // 缺陷现场：某些站返回 `Content-Encoding: deflate`，但内容是 raw-deflate
    //          （无 zlib 头），reqwest 按 zlib 解 ⇒ error decoding response body
    //          ⇒ 插件拿不到任何数据。
    //
    // 而"代码里有 DeflateDecoder 这一行"Dart 侧断言得出来 ——
    // 但那证明不了它**解得出东西**。
    // ⇒ 这个测试造真实 raw-deflate 字节流，解回原文并比对。
    // ```
    //
    // ⚠️ 用 flate2 自己压一份 raw-deflate（`DeflateEncoder`），再解回 —— 
    //    这是**往返验证**，能同时排除"压缩端写错"和"解压端写错"。
    #[test]
    fn raw_deflate_roundtrip() {
        use std::io::{Read as _, Write as _};

        const SAMPLE: &str = "<?xml version=\"1.0\"?><i><d p=\"3.84800,4,25,15138834\">                              测试弹幕 &amp; 符号</d></i>";

        // ① 压成 raw-deflate（注意是 DeflateEncoder，**不是** ZlibEncoder）
        let mut enc = flate2::write::DeflateEncoder::new(
            Vec::new(),
            flate2::Compression::default(),
        );
        enc.write_all(SAMPLE.as_bytes()).expect("压缩失败");
        let raw_bytes = enc.finish().expect("收尾失败");

        // ② 关键断言：它**不是** zlib 格式
        //    zlib 头固定以 0x78 开头（CMF 字节，deflate + 32K 窗口）
        //    若这里是 0x78，说明我们造的不是 raw-deflate，测试就失去意义
        assert_ne!(
            raw_bytes[0], 0x78,
            "★ 造出来的数据带 zlib 头 ⇒ 这个测试没覆盖 raw-deflate 场景"
        );

        // ③ 用生产代码同款解码器解回
        let mut out = String::new();
        flate2::read::DeflateDecoder::new(&raw_bytes[..])
            .read_to_string(&mut out)
            .expect("raw-deflate 解码失败");

        assert_eq!(out, SAMPLE, "★ 往返不一致 ⇒ 解码路径有问题");
    }

    // ═══════════════════════════════════════════════════════════════
    // ★★★ 2026-10-18（代理审查 + 注入实测发现）：client 配置必须被盯住
    // ═══════════════════════════════════════════════════════════════
    //
    // # 为什么前面两个测试不够（已实测）
    // ```text
    // raw_deflate_roundtrip                 ⇒ 测的是 flate2 的编解码往返
    // zlib_decoder_cannot_read_raw_deflate  ⇒ 测的是 ZlibDecoder 的行为
    //
    // ★ 两者都**不经过 reqwest、不测 no_gzip/no_deflate/no_brotli 配置**
    // ⇒ 实测：删掉 `        .no_deflate()` 后，
    //   这两个测试**仍然全绿**（2 passed; 0 failed）
    // ⇒ 而那正是 9ca4076 那次修复失效的根因。
    // ```
    //
    // # 这个测试怎么做到"会红"
    // ```text
    // 起一个本地 HTTP 服务器，返回真的 raw-deflate 字节
    // + `Content-Encoding: deflate`，然后调**生产代码里的 do_http()**。
    //
    // 这走的是完整真实链路：
    //   reqwest 自动解压 → 失败 → 我们的回退 → raw_client 重发 → 解压
    //   ⇒ 任何一环断了都会失败
    //
    // 如果删掉 `.no_deflate()`：raw_client 也会自动解压
    //   ⇒ 它拿到的就是"已解压后的文本被当成压缩流"⇒ 解码失败 ⇒ 本测试红。
    // ```
    //
    // ★ 本地服务器 = 不联网、不依赖外部站点、可离线跑。
    #[tokio::test]
    async fn do_http_decodes_raw_deflate_end_to_end() {
        use std::io::{Read as _, Write as _};
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

        const BODY: &str = "<i><d p=\"1,5,25,16711680\">端到端测试 raw-deflate</d></i>";

        // ① 压成 raw-deflate
        let mut enc =
            flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
        enc.write_all(BODY.as_bytes()).expect("压缩失败");
        let raw_bytes = enc.finish().expect("收尾失败");
        assert_ne!(
            raw_bytes[0], 0x78,
            "★ 带 zlib 头 ⇒ 这个测试失去意义"
        );

        // ② 起本地服务器（只服务一次）
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind 失败");
        let addr = listener.local_addr().expect("addr 失败");
        let body_for_srv = raw_bytes.clone();
        let srv = tokio::spawn(async move {
          // ★ 两次请求：第一次 reqwest 自动解压失败，第二次是回退
          for _ in 0..2 {
            let (mut sock, _) = listener.accept().await.expect("accept 失败");
            let mut buf = [0u8; 2048];
            let _ = sock.read(&mut buf).await;
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Encoding: deflate\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body_for_srv.len()
            );
            let _ = sock.write_all(head.as_bytes()).await;
            let _ = sock.write_all(&body_for_srv).await;
            let _ = sock.flush().await;
          }
        });

        // ③ 调**生产代码**
        let url = format!("http://{}/x.xml", addr);
        let headers = HashMap::new();
        let out = do_http(&None, "test-provider", "GET", &url, &headers, None).await;
        let _ = srv.await;

        // ④ 断言
        assert!(
            !out.starts_with("__ERR__"),
            "★ 回退失败，返回错误: {out}"
        );
        assert_eq!(out, BODY, "★ 解出来的内容不对 (len={})", out.len());
    }

    /// ★ 反向对照：`ZlibDecoder` 解 raw-deflate **必须失败**
    ///
    /// ```text
    /// 这条证明"为什么需要回退"：
    ///   reqwest 内部用的就是 zlib 语义 ⇒ 它解 raw-deflate 必然报错
    /// ⇒ 不写这条的话，将来有人把回退删掉，
    ///   只跑 raw_deflate_roundtrip 仍然绿（因为那是我们自己解压的）
    /// ```
    #[test]
    fn zlib_decoder_cannot_read_raw_deflate() {
        use std::io::{Read as _, Write as _};

        let mut enc = flate2::write::DeflateEncoder::new(
            Vec::new(),
            flate2::Compression::default(),
        );
        enc.write_all(b"hello raw deflate").expect("压缩失败");
        let raw_bytes = enc.finish().expect("收尾失败");

        let mut out = String::new();
        let r = flate2::read::ZlibDecoder::new(&raw_bytes[..]).read_to_string(&mut out);
        assert!(
            r.is_err(),
            "★ ZlibDecoder 竟然解开了 raw-deflate ⇒ 那这条回退就不必要了，\
             请重新评估缺陷是否真实存在"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  task-7：设置 → JS 插件卡片「源类型 · 上次源更新时间」
    //
    //  三组东西要证明：
    //    ① 头注释 @type / @updated 能解析，且**不被同前缀 tag 误命中**
    //    ② 老插件（没写这两个字段）解析成空串、不 panic、零回归
    //    ③ 运行时 sourceStatus 读得出来、坏数据降级不 panic
    // ═══════════════════════════════════════════════════════════════

    /// ★ ① 两个字段都有 → 正确解析（真实多行头注释形态）
    #[test]
    fn t7_meta_type_and_updated_parsed() {
        let src = "/**\n * 某站视频源\n *\n * @id site-a\n * @name 某站\n * \
                   @version 1.0.0\n * @type video-site\n \
                   * @updated 2026-10-23T09:10:00+08:00\n * @author dsh\n */\nconst x = 1;\n";
        let m = parse_meta(src);
        assert_eq!(m.kind, "video-site", "@type 没解析出来");
        assert_eq!(
            m.updated, "2026-10-23T09:10:00+08:00",
            "@updated 没解析出来"
        );
        // 老字段必须一字不变（新字段的加入不许影响既有解析）
        assert_eq!(m.id, "site-a");
        assert_eq!(m.name, "某站");
        assert_eq!(m.version, "1.0.0");
        assert_eq!(m.author, "dsh");

        // 真实世界最常见的「一行塞多个 tag」形态
        let m = parse_meta("/** @id s @name n @type aggregator @updated 2026-10-20T11:00:00+08:00 */");
        assert_eq!(m.kind, "aggregator");
        assert_eq!(m.updated, "2026-10-20T11:00:00+08:00");
    }

    /// ★ ② 老插件没有这两个字段 → 空串，且绝不 panic
    ///
    /// 仓里 31 个 legacy `.js` 全是这两种头部形态之一，
    /// 空串 = 界面**整行不显示**（见 settings_page 的渲染条件）。
    #[test]
    fn t7_meta_legacy_plugin_has_no_type_or_updated() {
        // 形态 A：一行式（`@name … @version … @author … @id srcl */`）
        let m = parse_meta("/** @name 某电视台站 @version 1.0.0 @author dsh @id srcl */\nfunction srcl(){}");
        assert_eq!(m.kind, "", "老插件不许凭空冒出一个类型");
        assert_eq!(m.updated, "", "老插件不许凭空冒出一个更新时间");
        assert_eq!(m.id, "srcl");

        // 形态 B：多行 + 中文说明 + 上游地址（TVBox 转换器生成的）
        let m = parse_meta(
            "/**\n * 影视天涯 —— 由 TVBox 源自动转换\n *\n * @id tyyszy\n \
             * @author tvbox-convert\n *\n * 上游接口（苹果CMS v10）：http://tyyszy.com/api.php/provide/vod\n */\nconst API = 1;",
        );
        assert_eq!(m.kind, "");
        assert_eq!(m.updated, "");

        // 退化输入：空串 / 半个注释 / 只有一个 `@` / 只有 `@type` —— 全都不许 panic
        for src in ["", "/", "   ", "/**", "@", "@type", "@type ", "/* @ */"] {
            let m = parse_meta(src);
            assert_eq!(m.kind, "", "输入 {src:?} 居然解析出了类型");
            assert_eq!(m.updated, "", "输入 {src:?} 居然解析出了时间");
        }
    }

    /// ★ ③ 带时区的时间串必须**逐字节完整保留**（不许被截成 `+08:00` 之前）
    #[test]
    fn t7_updated_keeps_timezone_offset() {
        let cases = [
            ("2026-10-23T09:10:00+08:00", "正偏移"),
            ("2026-10-22T21:10:00-05:00", "负偏移"),
            ("2026-10-23T01:10:00.123Z", "毫秒 + Z"),
            ("2026-10-23", "只有日期"),
        ];
        for (v, why) in cases {
            let src = format!("/*\n * @id x\n * @updated {v}\n */\n");
            let m = parse_meta(&src);
            assert_eq!(m.updated, v, "★ {why} 的时间串被改写了");
        }
        // 紧跟 `*/` 收尾（值的终止符是 `*/`）
        let m = parse_meta("/** @id x @updated 2026-10-23T09:10:00+08:00 */");
        assert_eq!(m.updated, "2026-10-23T09:10:00+08:00");
        // 后面还有别的 tag（值的终止符是下一个 `@`）—— 时间串本身就完整
        let m = parse_meta("/** @updated 2026-10-23T09:10:00+08:00 @id x */");
        assert_eq!(m.updated, "2026-10-23T09:10:00+08:00");
        assert_eq!(m.id, "x");
    }

    /// ★ ④ `get("type")` 不许被同前缀的其它 tag 误命中
    ///
    /// 这条是 Lead 点名要求的：`@typedef` / `@upstream` / `@typeX` 之类
    /// 若被当成 `@type`，卡片上会显示 `def {Object}` 这种垃圾。
    #[test]
    fn t7_type_not_hijacked_by_similar_tags() {
        // 只有 `@typedef` → 类型必须为空（老实现会返回 "def {Object}"）
        let m = parse_meta("/**\n * @typedef {Object} Foo\n * @id x\n * @type\n */");
        assert_eq!(m.kind, "", "★ @typedef 被当成 @type 了");

        // `@typedef` 在前、真 `@type` 在后 → 取真的
        let m = parse_meta("/** @typedef {Object} Foo @id x @type iptv */");
        assert_eq!(m.kind, "iptv");

        // JSDoc 的 `@type {Object}` 在前、真 `@type` 在后 → 跳过垃圾取真的
        let m = parse_meta("/** @type {Object} @id x @type emby */");
        assert_eq!(m.kind, "emby");

        // 异前缀 / 同前缀长 tag 都不许命中
        assert_eq!(parse_meta("/** @upstream http://a/b @id x */").kind, "");
        assert_eq!(parse_meta("/** @typeX video-site @id x */").kind, "");
        assert_eq!(parse_meta("/** @updatedAt 2026-10-23T09:10:00+08:00 */").updated, "");

        // 冒号写法也认
        assert_eq!(parse_meta("/** @type: aggregator @id x */").kind, "aggregator");

        // 带空格的错误写法 → 拒绝（宁可空，也不显示半截 "video site"）
        assert_eq!(parse_meta("/** @type video site @id x */").kind, "");

        // 值是 JSDoc 对象（没有第二个候选）→ 空
        assert_eq!(parse_meta("/** @type {Object} @id x */").kind, "");
    }

    /// ★ ④b 契约兼容：`@type:` / `@updated:` 的**冒号写法**必须认
    ///
    /// # 为什么要专门锁一条
    /// 契约原文写的是 `@type<空白>值`，但 `@type:video-site` 是**人会写**
    /// 的一种（Lead 2026-10-23 裁定：宽松成「空白或冒号」都认）。
    /// 这里把三种写法各锁一遍：紧贴（`@type:iptv`）、留空（`@type : emby`）、
    /// 以及时间值同样走冒号（`@updated:…`）—— 时间串里的 `+08:00`
    /// 必须**逐字保留**，不能被冒号剥离逻辑顺手吃掉。
    #[test]
    fn t7_colon_form_is_accepted_for_type_and_updated() {
        // ① 紧跟冒号、无空格
        let m = parse_meta("/**\n * @id x\n * @type:iptv\n * @updated:2026-10-23T09:10:00+08:00\n */");
        assert_eq!(m.kind, "iptv", "★ `@type:iptv` 必须认（冒号紧贴值）");
        assert_eq!(
            m.updated, "2026-10-23T09:10:00+08:00",
            "★ `@updated:…` 的值必须逐字保留（含 +08:00）"
        );

        // ② 冒号两侧都留空
        let m = parse_meta("// @type : emby\n// @updated : 2026-10-23T09:10:00+08:00\n@id x");
        assert_eq!(m.kind, "emby", "★ `@type : emby` 必须认");
        assert_eq!(m.updated, "2026-10-23T09:10:00+08:00");

        // ③ 冒号写法与空白写法同时存在时，取**第一个**净化后非空的
        let m = parse_meta("/** @type:other @type video-site @id x */");
        assert_eq!(m.kind, "other");
    }

    /// ★ ⑤ 序列化名必须是 `type`（Dart 侧按 `type` 读）
    #[test]
    fn t7_meta_serializes_key_type_not_kind() {
        let m = PluginMeta {
            id: "x".into(),
            name: "n".into(),
            kind: "iptv".into(),
            updated: "2026-10-23T09:10:00+08:00".into(),
            ..Default::default()
        };
        let j = serde_json::to_value(&m).expect("序列化失败");
        assert_eq!(
            j.get("type").and_then(|v| v.as_str()),
            Some("iptv"),
            "★ 序列化名必须是 type"
        );
        assert!(j.get("kind").is_none(), "★ 不许把 Rust 字段名 kind 泄到 JSON");
        assert_eq!(
            j.get("updated").and_then(|v| v.as_str()),
            Some("2026-10-23T09:10:00+08:00")
        );

        // 缺字段 → 空串（老数据、老前端都不炸）
        let back: PluginMeta = serde_json::from_str(r#"{"id":"x","name":"n"}"#).expect("反序列化失败");
        assert_eq!(back.kind, "");
        assert_eq!(back.updated, "");

        // 从 `type` 键读回来（Rust 字段叫 kind，但认 JSON 键 type）
        let back: PluginMeta = serde_json::from_str(
            r#"{"id":"x","name":"n","type":"emby","updated":"2026-10-23"}"#,
        )
        .expect("反序列化失败");
        assert_eq!(back.kind, "emby");
        assert_eq!(back.updated, "2026-10-23");
    }

    /// ★ ⑥ 运行时 sourceStatus：type 取第一个非空，updatedAt 取**最新**
    ///
    /// 「最新」按**时间点**比（`2026-10-23T02:00:00Z` 比
    /// `2026-10-23T09:10:00+08:00` 晚），不是按字符串比 —— 字符串比会取错。
    #[test]
    fn t7_runtime_status_reads_latest_updated_at() {
        let dir = std::env::temp_dir().join(format!("dsh-t7-srcstatus-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        // 契约：`sourceStatus` 是**字符串**（host.store 只收 String）
        let inner = serde_json::json!({
            "sources": [
                {"id": "demo-iptv", "type": "iptv", "updatedAt": "2026-10-20T11:00:00+08:00", "state": "ok"},
                {"id": "migu", "updatedAt": "2026-10-23T09:10:00+08:00", "state": "ok"},
                {"id": "z", "updatedAt": "2026-10-23T02:00:00Z"},
                {"id": "x", "type": "video-site", "updatedAt": "2026-10-01T00:00:00+08:00"}
            ]
        })
        .to_string();
        let body = serde_json::json!({ "token": "keep-me", "sourceStatus": inner });
        std::fs::write(
            dir.join("subhub.json"),
            serde_json::to_string(&body).unwrap(),
        )
        .expect("写测试数据失败");

        let st = read_source_status(&dir, "subhub");
        assert_eq!(st.kind, "iptv", "type 应取第一个非空");
        assert_eq!(
            st.updated, "2026-10-23T02:00:00Z",
            "★ updatedAt 应取时间点最新的那条（而不是第一条 / 字符串最大的）"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ ⑦ 坏数据全部降级，**绝不 panic**
    #[test]
    fn t7_runtime_status_degrades_on_bad_data() {
        let dir = std::env::temp_dir().join(format!("dsh-t7-srcbad-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let d = PluginSourceStatus::default();

        // ① 文件不存在
        assert_eq!(read_source_status(&dir, "nope"), d);

        // ② 文件不是合法 JSON
        std::fs::write(dir.join("corrupt.json"), "{不是 JSON").unwrap();
        assert_eq!(read_source_status(&dir, "corrupt"), d);

        // ③ sourceStatus 是字符串但里面不是合法 JSON
        std::fs::write(dir.join("badstr.json"), r#"{"sourceStatus":"{\"sources\":["}"#).unwrap();
        assert_eq!(read_source_status(&dir, "badstr"), d);

        // ④ sources 是空数组
        std::fs::write(dir.join("empty.json"), r#"{"sourceStatus":"{\"sources\":[]}"}"#).unwrap();
        assert_eq!(read_source_status(&dir, "empty"), d);

        // ⑤ sources 不是数组
        std::fs::write(dir.join("weird.json"), r#"{"sourceStatus":{"sources":"nope"}}"#).unwrap();
        assert_eq!(read_source_status(&dir, "weird"), d);

        // ⑥ updatedAt 不是合法时间串 → 丢掉时间，保留合法的 type
        std::fs::write(
            dir.join("badtime.json"),
            r#"{"sourceStatus":"{\"sources\":[{\"id\":\"a\",\"type\":\"iptv\",\"updatedAt\":\"昨天\"}]}"}"#,
        )
        .unwrap();
        let st = read_source_status(&dir, "badtime");
        assert_eq!(st.kind, "iptv", "type 合法就该留");
        assert_eq!(st.updated, "", "★ 非法时间串必须丢弃（由调用方回退头注释）");

        // ⑦ 老插件的 .data 文件（没有 sourceStatus 键）
        std::fs::write(dir.join("legacy.json"), r#"{"token":"t"}"#).unwrap();
        assert_eq!(read_source_status(&dir, "legacy"), d);

        // ⑧ 非 UTF-8 二进制垃圾
        std::fs::write(dir.join("bin.json"), &[0xffu8, 0xfe, 0x00, 0x7b]).unwrap();
        assert_eq!(read_source_status(&dir, "bin"), d);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ ⑧ 合成口径（Lead 批准：type 头注释优先、updated 运行时优先）
    #[test]
    fn t7_resolve_display_precedence() {
        // 两边都有 → type 用头注释，updated 用运行时
        let meta = PluginMeta {
            kind: "aggregator".into(),
            updated: "2026-10-01T00:00:00+08:00".into(),
            ..Default::default()
        };
        let rt = PluginSourceStatus {
            kind: "video-site".into(),
            updated: "2026-10-23T09:10:00+08:00".into(),
        };
        assert_eq!(
            resolve_source_display(&meta, &rt),
            (
                "aggregator".to_string(),
                "2026-10-23T09:10:00+08:00".to_string()
            )
        );

        // 头注释缺 type → 用运行时的
        let meta_no_kind = PluginMeta {
            updated: "2026-10-01T00:00:00+08:00".into(),
            ..Default::default()
        };
        assert_eq!(resolve_source_display(&meta_no_kind, &rt).0, "video-site");

        // 运行时缺 updated → 回落头注释
        let rt_empty = PluginSourceStatus::default();
        let meta_kind = PluginMeta {
            kind: "iptv".into(),
            updated: "2026-10-01T00:00:00+08:00".into(),
            ..Default::default()
        };
        assert_eq!(
            resolve_source_display(&meta_kind, &rt_empty),
            ("iptv".to_string(), "2026-10-01T00:00:00+08:00".to_string())
        );

        // 老插件两边都空 → 都空串（界面据此**整行不显示**）
        let (k, u) = resolve_source_display(&PluginMeta::default(), &rt_empty);
        assert_eq!((k.as_str(), u.as_str()), ("", ""));
    }
    /// 探针：`e.stack` 里的行号对插件源码**根本不可用**
    ///
    /// # 结论（2026-10-25 实测两次）
    /// 把错误分别放在插件源码第 2 行与第 5 行，`e.stack` 里都是
    /// ```text
    /// at boom (eval_script:1:1)
    /// ```
    /// ⇒ **QuickJS 对 `eval` 的脚本恒报 1:1**，不提供真实行号。
    ///
    /// 这个结论直接否掉了"在 catch 里多取一个 `e.stack` 就能给出行号"的方案：
    /// 展示一个**恒为 1:1** 的假行号，比不展示更糟 —— 插件作者会去第 1 行
    /// 找一个根本不存在的错误。
    ///
    /// 附带结论：`e.message` **是可用的**
    /// （实测得到 `cannot read property 'missing' of null`），
    /// 现有 `call_js` 取 `e.message` 的做法是正确的，不需要改。
    #[test]
    fn probe_stack_line_number_is_unusable() {
        use rquickjs::{Context, Runtime};
        let rt = Runtime::new().unwrap();
        let ctx = Context::full(&rt).unwrap();
        ctx.with(|ctx| {
            // 插件本体：第 1 行定义，第 2 行抛错
            // 故意把抛错放到第 5 行：若行号可信，stack 里应出现 ":5:"
            let plugin = "function boom() {
  const a = 1;
  const b = 2;
  const c = 3;
  return null.missing;
}
";
            ctx.eval::<(), _>(plugin).expect("插件本体应能加载");

            // 包装层（同步版，只为验行号；形状与 call_js 的 catch 一致）
            let wrapper = "(function () {
                 try {
                   const r = boom();
                   return JSON.stringify({ ok: true, data: r ?? null });
                 } catch (e) {
                   return JSON.stringify({ ok: false,
                     error: (e && e.message) ? e.message : String(e),
                     stack: (e && e.stack) ? String(e.stack) : \"\" });
                 }
               })()";
            let out: String = ctx.eval(wrapper).expect("包装层自身不该抛");
            println!("[EVIDENCE] wrapper_out = {out}");
            // 插件本体第 5 行报错 ⇒ 若行号可信，stack 里应出现 ":5:"
            let has_line2 = out.contains(":5:");
            println!("[EVIDENCE] points_to_plugin_line5 = {has_line2}");
        });
    }

    /// 探针：在 JS 层 try/catch 能否拿到 `e.stack`（含行号）？
    ///
    /// # 为什么接着探这个
    /// 上一个探针证明 `//# sourceURL` 不被 QuickJS 识别，且 Rust 侧拿到的
    /// 错误只有一句 "Exception generated by QuickJS" —— 连错误类型都没有。
    /// 那个信息量对插件作者等于零。
    ///
    /// 若能包一层 try/catch 把 `e.stack` 取出来，就能知道**插件第几行**出错，
    /// 这是真正可用的报错定位方案。
    #[test]
    fn probe_js_side_stack_capture() {
        use rquickjs::{Context, Runtime};
        let rt = Runtime::new().unwrap();
        let ctx = Context::full(&rt).unwrap();
        ctx.with(|ctx| {
            // 故意在第 3 行抛错
            let wrapped = "(function(){
                 try {
                   null.missing;
                 } catch (e) {
                   return (e && (e.stack || e.message)) || String(e);
                 }
               })()";
            match ctx.eval::<String, _>(wrapped) {
                Ok(s) => {
                    println!("[EVIDENCE] js_stack = {s}");
                    println!("[EVIDENCE] js_stack_has_line = {}",
                             s.contains("<anonymous>") || s.contains(":3:"));
                    assert!(!s.is_empty(), "拿到空字符串说明 e.stack/e.message 都不可用");
                }
                Err(e) => {
                    println!("[EVIDENCE] js_stack_capture_failed = {e}");
                    panic!("JS 层 try/catch 都拿不到信息（比预期更差）");
                }
            }
        });
    }

    /// 探针：`//# sourceURL=` 注释是否能让 QuickJS 的错误栈指向插件文件
    ///
    /// # 为什么先探测再动手
    /// `//# sourceURL` 是 **浏览器/V8** 的 Source Map 约定。QuickJS 是否认它
    /// 完全未知 —— 凭印象写进文档会导致插件作者按"报错带行号"去排查，
    /// 而实际拿到的仍是不带文件的错误。所以先实测。
    ///
    /// 判定：构造一个必错的脚本，把 `EVIDENCE` 打在日志里，
    /// 看错误消息里有没有 `plugin-probe.js`。
    #[test]
    fn probe_source_url_comment_support() {
        use rquickjs::{Context, Runtime};
        let rt = Runtime::new().unwrap();
        let ctx = Context::full(&rt).unwrap();
        ctx.with(|ctx| {
            let src = "//# sourceURL=plugin-probe.js
                       function boom(){ return null.missing; }
                       boom();";
            let e = match ctx.eval::<(), _>(src) {
                Ok(()) => {
                    println!("[EVIDENCE] source_url 探针：脚本居然没抛错（表达式无效）");
                    return;
                }
                Err(e) => e,
            };
            let msg = format!("{e}");
            println!("[EVIDENCE] source_url error = {msg}");
            // 栈里若能拿到，二者必有一个出现
            let saw_file = msg.contains("plugin-probe.js");
            println!("[EVIDENCE] source_url recognized = {saw_file}");
            // ★ 这个断言刻意写成"记录事实"而不是"要求必须支持"：
            //   探针的目的就是取证，探不到也要让日志留下结论。
            //   换成硬断言会在不支持的环境里红，反而掩盖了事实。
            assert!(!msg.is_empty(), "错误消息不该为空");
        });
    }

}

