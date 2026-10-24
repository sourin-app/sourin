//! 源个性化覆盖层（Override Layer）—— P1：模型 + L1 字段映射
//!
//! # 它解决什么
//!
//! Owner 原话（2026-10-24 裁定）：
//! > js插件也要支持,你想想方案吧,必须全部都可以,比如 只是链接,可以对数据二次编排修改,或者做劫持
//! > js,可视化可自由编辑支持支持的,但不能影响原有插件本身,属于是个性化
//! > 声明式还是一样,不修改本身
//! > 可视化编排还是属于二次修改劫持的产物需求
//!
//! ⇒ 这不是"给某个源补一个表单"，而是**一层凌驾于任意源之上的个性化改造**：
//!   覆盖层与源文件**物理分离**，只读原件、只写自己的文件，删除即完全回退。
//!
//! # 为什么挂在 `call_js` 里而不是逐个 provider 方法
//!
//! 插件返回值统一经 `PluginProvider::call_js()` → `{ok, data}` → `js_value_to_rust`。
//! 若在 16 个 provider 方法里各插一次，必然漂移（本仓 `save_hook` 有"两条路径
//! 发散"的实测教训）。所以**单点**挂在 `call_js` 取出 `data` 之后。
//!
//! # 能力分层（本文件只实现 L1，L2/L3 见后续阶段）
//!
//! ```text
//! 原始 JSON
//!   ↓ L1 字段映射（本文件：rename / 常量覆盖 / 路径取值，纯数据，不跑 JS）
//!   ↓ L2 数据变换（过滤/排序/替换/正则）—— 待 P3
//!   ↓ L3 JS 劫持（rquickjs 沙箱）—— 待 P4
//!   ↓ 交给 js_value_to_rust
//! ```
//!
//! # 铁律（门禁逐条守）
//!
//! 1. 无覆盖层 ⇒ 输出与改造前**逐字节一致**。
//! 2. `enabled=false` 或文件损坏 ⇒ **原样透出**，不静默清空。
//! 3. 覆盖层只写 `<数据目录>/overrides/`，绝不碰插件与声明式源文件。

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// 覆盖层文件所在的子目录（相对数据目录）
pub const OVERRIDES_DIR: &str = "overrides";

/// 一条 L1 字段映射规则
///
/// 三种动作，够表达"改名 / 覆盖成常量 / 从别处取一个路径的值"：
/// - `rename`：把 `from` 键的值搬到 `to` 键（可保留原键，见 `keep`）
/// - `set`：把 `to` 键设成 `value`（常量覆盖）
/// - `copy`：把 `from`（点号路径，如 `pager.total`）的值搬到 `to`
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum MapRule {
    /// 改名：`from` 的值写到 `to`；`keep=true` 时保留原键
    Rename {
        from: String,
        to: String,
        #[serde(default)]
        keep: bool,
    },
    /// 常量覆盖：`to` = `value`
    Set { to: String, value: Value },
    /// 从点号路径取值写到 `to`（路径不存在则跳过，不写 null）
    Copy { from: String, to: String },
}

/// L2 数据变换规则 —— 对**列表**做过滤/排序/去重/替换
///
/// # 为什么 L2 单独一层，不并进 L1
/// L1 是"逐条改字段"，L2 是"改整个集合"。混在一起会让规则顺序难以推理
/// （先删还是先改名，结果不同），所以固定 **L1 → L2** 两段执行。
///
/// # 所有变换都作用在"条目数组"上
/// 顶层是数组就直接用；顶层是对象则取它的 `items` / `list` 键。
/// 找不到数组 ⇒ 该规则**静默跳过**（不是错误：详情页本来就没有列表）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum TransformRule {
    /// 过滤：保留 `field` 的值**包含** `contains` 的条目
    ///
    /// 用"包含"而不是"等于"，因为标题类字段常带前缀/后缀，
    /// 精确等于在可视化编辑器里几乎不可用。
    FilterContains { field: String, contains: String },
    /// 过滤：**排除** `field` 的值包含 `contains` 的条目
    FilterNotContains { field: String, contains: String },
    /// 过滤：`field` 的值匹配正则的保留（正则非法 ⇒ 跳过该规则并记日志）
    FilterRegex { field: String, pattern: String },
    /// 排序：按 `field` 升/降序（数字按数值比，字符串按字典序；缺失字段排最后）
    SortBy {
        field: String,
        #[serde(default)]
        desc: bool,
    },
    /// 去重：按 `field` 的值去重，保留**第一次**出现的那条
    DedupBy { field: String },
    /// 截断：只保留前 `limit` 条（`limit=0` ⇒ 清空，用于"这个区块我不要"）
    TakeFirst { limit: usize },
    /// 字段内文本替换：把 `field` 值里的 `from` 换成 `to`
    ReplaceInField {
        field: String,
        from: String,
        to: String,
    },
}

/// 一层覆盖层配置（对应 `<数据目录>/overrides/<targetId>.json`）
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OverrideLayer {
    /// 绑定的源 id（插件 @id 或声明式源 id）
    pub target_id: String,
    /// 总开关；false ⇒ 完全不生效（门禁 2）
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// 只对这些方法生效（白名单）。空 = 对所有数据方法生效。
    ///
    /// ★ 用**白名单**而不是黑名单：`call_js` 也跑 `login` / `qr_login_poll`
    ///   这类非数据调用，新增方法时默认**不**应用覆盖层更安全。
    #[serde(default)]
    pub methods: Vec<String>,
    /// L1 字段映射规则（按顺序应用）
    #[serde(default)]
    pub mappings: Vec<MapRule>,
    /// L2 数据变换规则（在 L1 **之后**按顺序应用）
    #[serde(default)]
    pub transforms: Vec<TransformRule>,
    /// L3 JS 劫持片段（在 L2 **之后**执行，最后一道）
    ///
    /// # 契约（写进编辑器提示，也写进门禁）
    /// - 片段是**语句体**，可读全局 `data`（已解析的 JSON），
    ///   结果取 `return` 的值；不 `return`（或返回 undefined）则视为"不改"。
    /// - **默认不给网络与 host.store**：只做纯数据变换。
    ///   这是刻意的权限收窄 —— 放开网络等价于任意代码执行，
    ///   而覆盖层没有插件安装那样的显式授权环节。
    /// - 执行受 `JS_HOOK_BUDGET_MS` 熔断，死循环会被中断并**原样透出**原数据。
    #[serde(default)]
    pub js_hook: String,
    /// 人类可读备注（排障时看）
    #[serde(default)]
    pub note: String,
}

fn default_true() -> bool {
    true
}

/// 覆盖层应用结果 —— 让调用方能区分"没配" / "配了但没生效" / "生效了"
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverrideOutcome {
    /// 没有该源的覆盖层文件
    Absent,
    /// 有文件但 enabled=false
    Disabled,
    /// 有文件但方法不在白名单
    NotApplicable,
    /// 文件损坏（解析失败）—— **必须原样透出**，不能静默清空
    Broken,
    /// 已应用
    Applied,
}

/// 覆盖层目录（`<数据目录>/overrides`）
pub fn overrides_dir(data_dir: &Path) -> PathBuf {
    data_dir.join(OVERRIDES_DIR)
}

/// 单个源的覆盖层文件路径
pub fn layer_path(data_dir: &Path, target_id: &str) -> PathBuf {
    // ★ 文件名净化：target_id 来自插件 @id，理论上安全，但仍做最小防护，
    //   避免 `../` 之类的 id 把文件写到 overrides 目录之外。
    let safe: String = target_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c
            } else {
                '_'
            }
        })
        .collect();
    overrides_dir(data_dir).join(format!("{safe}.json"))
}

/// 读取覆盖层（不存在 ⇒ None；损坏 ⇒ Err 带原因）
pub fn load_layer(data_dir: &Path, target_id: &str) -> Result<Option<OverrideLayer>, String> {
    let p = layer_path(data_dir, target_id);
    if !p.exists() {
        return Ok(None);
    }
    let text = std::fs::read_to_string(&p)
        .map_err(|e| format!("读覆盖层失败（{}）: {e}", p.display()))?;
    let layer: OverrideLayer = serde_json::from_str(&text)
        .map_err(|e| format!("覆盖层 JSON 解析失败（{}）: {e}", p.display()))?;
    Ok(Some(layer))
}

/// 删除覆盖层（= 完全回到原行为）
///
/// 返回是否真的删掉了文件（`false` = 本来就没有）。删除是**幂等**的：
/// 没有该文件不算错误 —— 用户点"恢复默认"两次不该报错。
pub fn delete_layer(data_dir: &Path, target_id: &str) -> Result<bool, String> {
    let p = layer_path(data_dir, target_id);
    if !p.exists() {
        return Ok(false);
    }
    std::fs::remove_file(&p).map_err(|e| format!("删除覆盖层失败: {e}"))?;
    Ok(true)
}

/// 保存覆盖层 —— **只允许**写 overrides 目录
///
/// 返回写入的路径，便于调用方在日志里如实报"写到哪了"。
pub fn save_layer(data_dir: &Path, layer: &OverrideLayer) -> Result<PathBuf, String> {
    let dir = overrides_dir(data_dir);
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建覆盖层目录失败: {e}"))?;
    let p = layer_path(data_dir, &layer.target_id);
    let text = serde_json::to_string_pretty(layer)
        .map_err(|e| format!("覆盖层序列化失败: {e}"))?;
    std::fs::write(&p, text).map_err(|e| format!("写覆盖层失败: {e}"))?;
    Ok(p)
}

/// 按点号路径取值：`"a.b.0"` 支持对象键与数组下标
fn get_path<'a>(v: &'a Value, path: &str) -> Option<&'a Value> {
    let mut cur = v;
    for seg in path.split('.') {
        if seg.is_empty() {
            continue;
        }
        cur = match cur {
            Value::Object(m) => m.get(seg)?,
            Value::Array(a) => {
                let i: usize = seg.parse().ok()?;
                a.get(i)?
            }
            _ => return None,
        };
    }
    Some(cur)
}

/// 在**对象**上应用一条规则；非对象返回 false（表示这条规则没生效）
fn apply_rule_on_object(obj: &mut serde_json::Map<String, Value>, rule: &MapRule) -> bool {
    match rule {
        MapRule::Rename { from, to, keep } => {
            let Some(val) = obj.get(from).cloned() else {
                return false;
            };
            obj.insert(to.clone(), val);
            if !*keep && from != to {
                obj.remove(from);
            }
            true
        }
        MapRule::Set { to, value } => {
            obj.insert(to.clone(), value.clone());
            true
        }
        MapRule::Copy { from, to } => {
            let snapshot = Value::Object(obj.clone());
            let Some(val) = get_path(&snapshot, from).cloned() else {
                return false;
            };
            obj.insert(to.clone(), val);
            true
        }
    }
}

/// 对一棵 JSON 树应用规则
///
/// 规则作用于**媒体条目对象**：顶层是数组就逐项处理；顶层是对象就处理它自己，
/// 并额外处理它下面常见的列表键（`items` / `list`）里的每一项。
/// 这样同一份覆盖层既能改「列表里的每一条」，也能改「详情页那一个对象」。
fn apply_rules(v: &mut Value, rules: &[MapRule]) {
    match v {
        Value::Array(items) => {
            for it in items.iter_mut() {
                if let Value::Object(o) = it {
                    for r in rules {
                        apply_rule_on_object(o, r);
                    }
                }
            }
        }
        Value::Object(o) => {
            // 先处理对象自身（详情页形态）
            for r in rules {
                apply_rule_on_object(o, r);
            }
            // 再处理它下面的列表（列表页形态：{items:[...]} 或 {list:[...]}）
            for key in ["items", "list"] {
                if let Some(Value::Array(items)) = o.get_mut(key) {
                    for it in items.iter_mut() {
                        if let Value::Object(io) = it {
                            for r in rules {
                                apply_rule_on_object(io, r);
                            }
                        }
                    }
                }
            }
        }
        _ => {}
    }
}

/// 对一次 `call_js` 的结果应用覆盖层
///
/// # 返回值语义（门禁 2 的核心）
/// - `Absent` / `Disabled` / `NotApplicable` / `Broken` ⇒ **`data` 原样不动**，
///   调用方必须继续用原始数据。`Broken` 只记日志，不抛错、不清空。
/// - `Applied` ⇒ `data` 已就地改写。
pub fn apply_override(
    data_dir: Option<&Path>,
    target_id: &str,
    method: &str,
    data: &mut Value,
) -> OverrideOutcome {
    let Some(dir) = data_dir else {
        return OverrideOutcome::Absent;
    };
    let layer = match load_layer(dir, target_id) {
        Ok(None) => return OverrideOutcome::Absent,
        Ok(Some(l)) => l,
        Err(e) => {
            // ★ 损坏时**原样透出**，只记日志。绝不因为覆盖层坏了就让源不可用。
            log::warn!("覆盖层不可用，已按原始数据透出：{e}");
            return OverrideOutcome::Broken;
        }
    };
    if !layer.enabled {
        return OverrideOutcome::Disabled;
    }
    if !layer.methods.is_empty() && !layer.methods.iter().any(|m| m == method) {
        return OverrideOutcome::NotApplicable;
    }
    if layer.mappings.is_empty() && layer.transforms.is_empty() && layer.js_hook.trim().is_empty() {
        return OverrideOutcome::NotApplicable;
    }
    // ★ 顺序固定：L1（逐条改字段）→ L2（改整个集合）→ L3（任意 JS 改写）。
    //   反过来会让"先过滤再改名"与"先改名再过滤"结果不同，用户无法推理。
    if !layer.mappings.is_empty() {
        apply_rules(data, &layer.mappings);
    }
    if !layer.transforms.is_empty() {
        apply_transforms(data, &layer.transforms);
    }
    if !layer.js_hook.trim().is_empty() {
        apply_js_hook(data, &layer.js_hook);
    }
    OverrideOutcome::Applied
}

/// L3 JS 劫持的熔断预算（比插件的 10s 短：这里只做纯数据变换，不需要网络等待）
const JS_HOOK_BUDGET_MS: u64 = 2_000;

/// 在**独立沙箱**里执行用户的 JS 劫持片段
///
/// # 权限（刻意的收窄）
/// 只注入一个全局 `data`，**不注入** `host.http` / `host.store` / 任何网络能力。
/// 理由：覆盖层没有插件安装那样的显式授权环节，放开网络等价于任意代码执行。
///
/// # 失败语义（与 L1/L2 一致：绝不因覆盖层出错让源不可用）
/// - 语法错 / 运行抛错 / 超时 / 返回值不是合法 JSON ⇒ **原样保留 `data`**，只记日志。
/// - 返回 `undefined` / `null` ⇒ 视为"不改"。
fn apply_js_hook(data: &mut Value, src: &str) {
    use rquickjs::{Context, Runtime};

    let rt = match Runtime::new() {
        Ok(r) => r,
        Err(e) => {
            log::warn!("L3 劫持：创建 JS 运行时失败，已跳过：{e}");
            return;
        }
    };
    // ★ 复用插件的熔断思路（墙钟截止），但预算是独立的
    let start = std::time::Instant::now();
    rt.set_interrupt_handler(Some(Box::new(move || {
        start.elapsed().as_millis() as u64 > JS_HOOK_BUDGET_MS
    })));

    let ctx = match Context::full(&rt) {
        Ok(c) => c,
        Err(e) => {
            log::warn!("L3 劫持：创建 JS 上下文失败，已跳过：{e}");
            return;
        }
    };

    let input = serde_json::to_string(data).unwrap_or_else(|_| "null".into());

    let out: Result<String, String> = ctx.with(|ctx| {
        // 把数据塞进全局 data
        let setup = format!("globalThis.data = {input};");
        if let Err(e) = ctx.eval::<(), _>(setup) {
            return Err(format!("注入 data 失败: {e}"));
        }
        // 包成函数体：用户写 `return ...` 才生效；不 return 视为 undefined
        let wrapped = format!(
            "(function(){{ {} }})()",
            src
        );
        let v: rquickjs::Value = ctx
            .eval(wrapped)
            .map_err(|e| format!("执行失败: {e}"))?;
        if v.is_undefined() || v.is_null() {
            return Err("__NO_CHANGE__".into());
        }
        // 转成 JSON 文本：优先用 JSON.stringify，保证与宿主解析一致
        let stringify = ctx
            .eval::<rquickjs::Function, _>("JSON.stringify")
            .map_err(|e| format!("取 JSON.stringify 失败: {e}"))?;
        let s: String = stringify
            .call((v,))
            .map_err(|e| format!("结果无法序列化为 JSON: {e}"))?;
        Ok(s)
    });

    match out {
        Ok(json_text) => match serde_json::from_str::<Value>(&json_text) {
            Ok(newv) => {
                // 只接受"同类形态"的结果，避免把详情对象替换成数组这种误用
                if std::mem::discriminant(&newv) == std::mem::discriminant(data) {
                    *data = newv;
                } else {
                    log::warn!("L3 劫持：返回值形态与原始数据不一致，已忽略");
                }
            }
            Err(e) => log::warn!("L3 劫持：返回值不是合法 JSON，已忽略：{e}"),
        },
        Err(e) if e == "__NO_CHANGE__" => { /* 用户没 return，视为不改 */ }
        Err(e) => log::warn!("L3 劫持未生效（已原样透出原始数据）：{e}"),
    }
}

/// 取出可变换的条目数组（顶层数组 / 对象的 `items` / `list`）
fn entries_mut(v: &mut Value) -> Option<&mut Vec<Value>> {
    match v {
        Value::Array(a) => Some(a),
        Value::Object(o) => {
            // 先用不可变借用判断哪个键存在，再取可变借用 ——
            // 直接 `get` + `get_mut` 会同时持有两个借用（E0502/E0499）。
            let key = ["items", "list"]
                .into_iter()
                .find(|k| matches!(o.get(*k), Some(Value::Array(_))))?;
            match o.get_mut(key) {
                Some(Value::Array(a)) => Some(a),
                _ => None,
            }
        }
        _ => None,
    }
}

/// 按字段名取字符串值（非字符串返回 None，用于过滤/去重）
fn field_str<'a>(item: &'a Value, field: &str) -> Option<&'a str> {
    match item {
        Value::Object(o) => o.get(field).and_then(|v| v.as_str()),
        _ => None,
    }
}

/// 数组里有没有**任何一条**含该字段（且值是字符串）
///
/// # 为什么需要它（2026-10-24 实测缺陷）
/// `FilterContains` 原本写 `field_str(it, field).map(..).unwrap_or(false)` ——
/// 字段不存在 ⇒ 判 false ⇒ **丢弃该条**。对 `MediaItem` 列表这是对的
/// （没标题的条目本就该滤掉），但对 `StreamCandidate` 是**灾难**：
/// 它没有 `title` 字段，用户照列表页习惯配一条 `filter_contains{title}`
/// ⇒ **所有候选流被删光** ⇒ 点播放没有任何线路，且日志显示"已应用"。
///
/// ⇒ 判据改成：**整组都没有该字段**时视为"规则不适用"，跳过并 warn。
///   这区分了两种情形：
///   · 部分条目有该字段 ⇒ 正常过滤（"只保留有封面的"是合法需求）
///   · 一条都没有     ⇒ 配错了字段/方法不适用，跳过而不是清空
fn any_item_has_field(items: &[Value], field: &str) -> bool {
    items.iter().any(|it| field_str(it, field).is_some())
}

/// 应用 L2 变换
///
/// # 设计取舍
/// - **正则非法 ⇒ 跳过该规则并记日志**，不让整条链路失败（用户手写正则出错很常见）
/// - **找不到条目数组 ⇒ 静默跳过**（详情页本来没有列表，不是错误）
/// - **`TakeFirst{0}` ⇒ 清空**，这是"这个区块我不想要"的合法表达
fn apply_transforms(v: &mut Value, rules: &[TransformRule]) {
    for rule in rules {
        let Some(items) = entries_mut(v) else {
            continue;
        };
        match rule {
            TransformRule::FilterContains { field, contains } => {
                // ★ 整组都没有该字段 ⇒ 规则不适用，跳过而不是清空（见 any_item_has_field）
                if !items.is_empty() && !any_item_has_field(items, field) {
                    log::warn!(
                        "覆盖层过滤规则不适用：没有任何条目含字段 `{field}`，已跳过（不清空数据）"
                    );
                } else {
                    items.retain(|it| {
                        field_str(it, field)
                            .map(|s| s.contains(contains.as_str()))
                            .unwrap_or(false)
                    });
                }
            }
            TransformRule::FilterNotContains { field, contains } => {
                if !items.is_empty() && !any_item_has_field(items, field) {
                    log::warn!(
                        "覆盖层排除规则不适用：没有任何条目含字段 `{field}`，已跳过（保持原样）"
                    );
                } else {
                    items.retain(|it| {
                        field_str(it, field)
                            .map(|s| !s.contains(contains.as_str()))
                            .unwrap_or(true)
                    });
                }
            }
            TransformRule::FilterRegex { field, pattern } => {
                match regex::Regex::new(pattern) {
                    Ok(re) => {
                        items.retain(|it| {
                            field_str(it, field).map(|s| re.is_match(s)).unwrap_or(false)
                        });
                    }
                    Err(e) => {
                        // 用户正则写错不该让源不可用
                        log::warn!("覆盖层正则非法，已跳过该条规则（{pattern}）: {e}");
                    }
                }
            }
            TransformRule::SortBy { field, desc } => {
                items.sort_by(|a, b| {
                    let av = a.as_object().and_then(|o| o.get(field));
                    let bv = b.as_object().and_then(|o| o.get(field));
                    let ord = match (av, bv) {
                        (Some(x), Some(y)) => {
                            if let (Some(xn), Some(yn)) = (x.as_f64(), y.as_f64()) {
                                xn.partial_cmp(&yn).unwrap_or(std::cmp::Ordering::Equal)
                            } else {
                                let xs = x.as_str().unwrap_or("");
                                let ys = y.as_str().unwrap_or("");
                                xs.cmp(ys)
                            }
                        }
                        // 缺失字段一律排最后（无论升降序），避免它们插在中间干扰阅读
                        (Some(_), None) => std::cmp::Ordering::Less,
                        (None, Some(_)) => std::cmp::Ordering::Greater,
                        (None, None) => std::cmp::Ordering::Equal,
                    };
                    if *desc {
                        ord.reverse()
                    } else {
                        ord
                    }
                });
            }
            TransformRule::DedupBy { field } => {
                let mut seen = std::collections::HashSet::new();
                items.retain(|it| match field_str(it, field) {
                    Some(s) => seen.insert(s.to_string()),
                    // 没有该字段的条目**保留**（去重只针对有值的）
                    None => true,
                });
            }
            TransformRule::TakeFirst { limit } => {
                items.truncate(*limit);
            }
            TransformRule::ReplaceInField { field, from, to } => {
                for it in items.iter_mut() {
                    if let Value::Object(o) = it {
                        if let Some(Value::String(s)) = o.get(field) {
                            if s.contains(from.as_str()) {
                                let replaced = s.replace(from.as_str(), to.as_str());
                                o.insert(field.clone(), Value::String(replaced));
                            }
                        }
                    }
                }
            }
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tmpdir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("sourin_ovr_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn absent_layer_leaves_data_untouched() {
        let dir = tmpdir("absent");
        let mut data = json!({"items": [{"id": "a", "title": "旧标题"}]});
        let before = data.clone();
        let out = apply_override(Some(&dir), "nope", "list", &mut data);
        assert_eq!(out, OverrideOutcome::Absent);
        assert_eq!(data, before, "无覆盖层时数据必须逐字节一致");
    }

    #[test]
    fn rename_applies_to_list_items() {
        let dir = tmpdir("rename");
        let layer = OverrideLayer {
            target_id: "src1".into(),
            enabled: true,
            methods: vec![],
            mappings: vec![MapRule::Rename {
                from: "title".into(),
                to: "name".into(),
                keep: false,
            }],
            transforms: vec![],
            js_hook: String::new(),
            note: String::new(),
        };
        save_layer(&dir, &layer).unwrap();
        let mut data = json!({"items": [{"id": "a", "title": "T1"}, {"id": "b", "title": "T2"}]});
        let out = apply_override(Some(&dir), "src1", "list", &mut data);
        assert_eq!(out, OverrideOutcome::Applied);
        assert_eq!(data["items"][0]["name"], json!("T1"));
        assert!(data["items"][0].get("title").is_none(), "keep=false 应删原键");
        assert_eq!(data["items"][1]["name"], json!("T2"));
    }

    #[test]
    fn set_overrides_constant() {
        let dir = tmpdir("set");
        let layer = OverrideLayer {
            target_id: "src2".into(),
            enabled: true,
            methods: vec!["detail".into()],
            mappings: vec![MapRule::Set {
                to: "subtitle".into(),
                value: json!("已个性化"),
            }],
            transforms: vec![],
            js_hook: String::new(),
            note: String::new(),
        };
        save_layer(&dir, &layer).unwrap();
        let mut data = json!({"id": "x", "title": "T", "subtitle": "原副标题"});
        let out = apply_override(Some(&dir), "src2", "detail", &mut data);
        assert_eq!(out, OverrideOutcome::Applied);
        assert_eq!(data["subtitle"], json!("已个性化"));
    }

    #[test]
    fn method_whitelist_blocks_other_methods() {
        let dir = tmpdir("whitelist");
        let layer = OverrideLayer {
            target_id: "src3".into(),
            enabled: true,
            methods: vec!["detail".into()],
            mappings: vec![MapRule::Set {
                to: "title".into(),
                value: json!("X"),
            }],
            transforms: vec![],
            js_hook: String::new(),
            note: String::new(),
        };
        save_layer(&dir, &layer).unwrap();
        let mut data = json!({"title": "原"});
        let out = apply_override(Some(&dir), "src3", "search", &mut data);
        assert_eq!(out, OverrideOutcome::NotApplicable);
        assert_eq!(data["title"], json!("原"), "不在白名单时不得改动");
    }

    #[test]
    fn disabled_layer_is_ignored() {
        let dir = tmpdir("disabled");
        let layer = OverrideLayer {
            target_id: "src4".into(),
            enabled: false,
            methods: vec![],
            mappings: vec![MapRule::Set {
                to: "title".into(),
                value: json!("X"),
            }],
            transforms: vec![],
            js_hook: String::new(),
            note: String::new(),
        };
        save_layer(&dir, &layer).unwrap();
        let mut data = json!({"title": "原"});
        let out = apply_override(Some(&dir), "src4", "list", &mut data);
        assert_eq!(out, OverrideOutcome::Disabled);
        assert_eq!(data["title"], json!("原"));
    }

    #[test]
    fn broken_layer_falls_back_to_original() {
        let dir = tmpdir("broken");
        let p = layer_path(&dir, "src5");
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, "{ 这不是合法 JSON").unwrap();
        let mut data = json!({"title": "原"});
        let before = data.clone();
        let out = apply_override(Some(&dir), "src5", "list", &mut data);
        assert_eq!(out, OverrideOutcome::Broken);
        assert_eq!(data, before, "覆盖层损坏必须原样透出，不得静默清空");
    }

    #[test]
    fn copy_uses_dotted_path() {
        let dir = tmpdir("copy");
        let layer = OverrideLayer {
            target_id: "src6".into(),
            enabled: true,
            methods: vec![],
            mappings: vec![MapRule::Copy {
                from: "pager.total".into(),
                to: "total".into(),
            }],
            transforms: vec![],
            js_hook: String::new(),
            note: String::new(),
        };
        save_layer(&dir, &layer).unwrap();
        let mut data = json!({"items": [], "pager": {"total": 42}});
        let out = apply_override(Some(&dir), "src6", "list", &mut data);
        assert_eq!(out, OverrideOutcome::Applied);
        assert_eq!(data["total"], json!(42));
    }

    #[test]
    fn copy_missing_path_does_not_write_null() {
        let dir = tmpdir("copy_missing");
        let layer = OverrideLayer {
            target_id: "src7".into(),
            enabled: true,
            methods: vec![],
            mappings: vec![MapRule::Copy {
                from: "no.such.path".into(),
                to: "total".into(),
            }],
            transforms: vec![],
            js_hook: String::new(),
            note: String::new(),
        };
        save_layer(&dir, &layer).unwrap();
        let mut data = json!({"items": []});
        apply_override(Some(&dir), "src7", "list", &mut data);
        assert!(data.get("total").is_none(), "路径不存在时不得写入 null");
    }

    #[test]
    fn layer_path_is_sanitized() {
        let dir = tmpdir("sanitize");
        let p = layer_path(&dir, "../../etc/passwd");
        let parent = p.parent().unwrap();
        assert_eq!(
            parent,
            overrides_dir(&dir),
            "带 ../ 的 id 不得把文件写出 overrides 目录"
        );
    }

    #[test]
    fn delete_restores_original_behaviour() {
        let dir = tmpdir("delete");
        let layer = OverrideLayer {
            target_id: "src8".into(),
            enabled: true,
            methods: vec![],
            mappings: vec![MapRule::Set {
                to: "title".into(),
                value: json!("被覆盖"),
            }],
            transforms: vec![],
            js_hook: String::new(),
            note: String::new(),
        };
        save_layer(&dir, &layer).unwrap();

        // 有覆盖层时确实生效
        let mut data = json!({"title": "原"});
        assert_eq!(
            apply_override(Some(&dir), "src8", "list", &mut data),
            OverrideOutcome::Applied
        );
        assert_eq!(data["title"], json!("被覆盖"));

        // 删除后必须**完全回到原行为**
        assert!(delete_layer(&dir, "src8").unwrap(), "第一次删除应真的删掉");
        let mut data2 = json!({"title": "原"});
        assert_eq!(
            apply_override(Some(&dir), "src8", "list", &mut data2),
            OverrideOutcome::Absent
        );
        assert_eq!(data2["title"], json!("原"), "删除后必须回到原始数据");

        // 幂等：再删一次不算错误，只报 existed=false
        assert!(!delete_layer(&dir, "src8").unwrap(), "第二次删除应报 existed=false");
    }

    // ─────────── L2 数据变换 ───────────

    fn layer_with(transforms: Vec<TransformRule>) -> OverrideLayer {
        OverrideLayer {
            target_id: "t".into(),
            enabled: true,
            methods: vec![],
            mappings: vec![],
            transforms,
            js_hook: String::new(),
            note: String::new(),
        }
    }

    fn run(dir: &Path, l: &OverrideLayer, data: &mut Value) -> OverrideOutcome {
        save_layer(dir, l).unwrap();
        apply_override(Some(dir), &l.target_id, "list", data)
    }

    #[test]
    fn filter_contains_keeps_matching() {
        let dir = tmpdir("l2_filter");
        let mut data = json!({"items": [
            {"title": "番剧 · 第一季"},
            {"title": "电影 · 某某"},
            {"title": "番剧 · 第二季"}
        ]});
        let out = run(&dir, &layer_with(vec![TransformRule::FilterContains {
            field: "title".into(),
            contains: "番剧".into(),
        }]), &mut data);
        assert_eq!(out, OverrideOutcome::Applied);
        assert_eq!(data["items"].as_array().unwrap().len(), 2);
        assert_eq!(data["items"][0]["title"], json!("番剧 · 第一季"));
        assert_eq!(data["items"][1]["title"], json!("番剧 · 第二季"));
    }

    #[test]
    fn filter_not_contains_excludes() {
        let dir = tmpdir("l2_excl");
        let mut data = json!({"items": [
            {"title": "预告"},
            {"title": "正片 01"}
        ]});
        run(&dir, &layer_with(vec![TransformRule::FilterNotContains {
            field: "title".into(),
            contains: "预告".into(),
        }]), &mut data);
        assert_eq!(data["items"].as_array().unwrap().len(), 1);
        assert_eq!(data["items"][0]["title"], json!("正片 01"));
    }

    #[test]
    fn filter_regex_works_and_bad_regex_is_skipped() {
        let dir = tmpdir("l2_regex");
        let mut data = json!({"items": [{"t": "EP01"}, {"t": "OP"}, {"t": "EP02"}]});
        run(&dir, &layer_with(vec![TransformRule::FilterRegex {
            field: "t".into(),
            pattern: r"^EP\d+$".into(),
        }]), &mut data);
        assert_eq!(data["items"].as_array().unwrap().len(), 2);

        // 非法正则 ⇒ 跳过该规则，数据原样（不得清空）
        let dir2 = tmpdir("l2_regex_bad");
        let mut d2 = json!({"items": [{"t": "a"}, {"t": "b"}]});
        let before = d2.clone();
        run(&dir2, &layer_with(vec![TransformRule::FilterRegex {
            field: "t".into(),
            pattern: "([".into(),
        }]), &mut d2);
        assert_eq!(d2, before, "非法正则必须跳过而不是清空数据");
    }

    #[test]
    fn sort_by_number_and_string() {
        let dir = tmpdir("l2_sort");
        let mut data = json!({"items": [
            {"n": 3, "s": "c"},
            {"n": 1, "s": "a"},
            {"n": 2, "s": "b"}
        ]});
        run(&dir, &layer_with(vec![TransformRule::SortBy {
            field: "n".into(),
            desc: false,
        }]), &mut data);
        assert_eq!(data["items"][0]["n"], json!(1));
        assert_eq!(data["items"][2]["n"], json!(3));

        let dir2 = tmpdir("l2_sort_desc");
        let mut d2 = json!({"items": [{"s": "a"}, {"s": "c"}, {"s": "b"}]});
        run(&dir2, &layer_with(vec![TransformRule::SortBy {
            field: "s".into(),
            desc: true,
        }]), &mut d2);
        assert_eq!(d2["items"][0]["s"], json!("c"));
        assert_eq!(d2["items"][2]["s"], json!("a"));
    }

    #[test]
    fn dedup_keeps_first_occurrence() {
        let dir = tmpdir("l2_dedup");
        let mut data = json!({"items": [
            {"id": "x", "v": 1},
            {"id": "y", "v": 2},
            {"id": "x", "v": 3}
        ]});
        run(&dir, &layer_with(vec![TransformRule::DedupBy {
            field: "id".into(),
        }]), &mut data);
        let arr = data["items"].as_array().unwrap();
        assert_eq!(arr.len(), 2);
        assert_eq!(arr[0]["v"], json!(1), "必须保留第一次出现的那条");
        assert_eq!(arr[1]["v"], json!(2));
    }

    #[test]
    fn take_first_truncates_and_zero_clears() {
        let dir = tmpdir("l2_take");
        let mut data = json!({"items": [1, 2, 3, 4]});
        run(&dir, &layer_with(vec![TransformRule::TakeFirst { limit: 2 }]), &mut data);
        assert_eq!(data["items"].as_array().unwrap().len(), 2);

        let dir2 = tmpdir("l2_take0");
        let mut d2 = json!({"items": [1, 2, 3]});
        run(&dir2, &layer_with(vec![TransformRule::TakeFirst { limit: 0 }]), &mut d2);
        assert_eq!(d2["items"].as_array().unwrap().len(), 0, "limit=0 表示清空该区块");
    }

    #[test]
    fn replace_in_field_changes_text() {
        let dir = tmpdir("l2_replace");
        let mut data = json!({"items": [{"title": "【官方】作品"}]});
        run(&dir, &layer_with(vec![TransformRule::ReplaceInField {
            field: "title".into(),
            from: "【官方】".into(),
            to: "".into(),
        }]), &mut data);
        assert_eq!(data["items"][0]["title"], json!("作品"));
    }

    #[test]
    fn l1_runs_before_l2() {
        // 顺序不变量：先改名（L1）再按新名字过滤（L2）。
        // 若顺序反了，过滤时字段还不叫 name ⇒ 全部被滤掉。
        let dir = tmpdir("l2_order");
        let l = OverrideLayer {
            target_id: "t".into(),
            enabled: true,
            methods: vec![],
            mappings: vec![MapRule::Rename {
                from: "title".into(),
                to: "name".into(),
                keep: false,
            }],
            transforms: vec![TransformRule::FilterContains {
                field: "name".into(),
                contains: "要".into(),
            }],
            js_hook: String::new(),
            note: String::new(),
        };
        let mut data = json!({"items": [{"title": "要保留"}, {"title": "丢弃"}]});
        run(&dir, &l, &mut data);
        let arr = data["items"].as_array().unwrap();
        assert_eq!(arr.len(), 1, "L1 必须先于 L2 —— 否则按 name 过滤时字段还不存在");
        assert_eq!(arr[0]["name"], json!("要保留"));
    }

    #[test]
    fn filter_on_absent_field_does_not_wipe_the_list() {
        // ★ 回归测试（2026-10-24 实测缺陷）：
        //   StreamCandidate 没有 title 字段，用户照列表页习惯配一条
        //   filter_contains{title} ⇒ 旧实现会把所有候选流删光 ⇒ 点播放没线路。
        //   现在必须：整组都没有该字段 ⇒ 跳过规则，数据原样保留。
        let dir = tmpdir("l2_absent_field");
        let mut data = json!([
            {"url": "http://a/1.m3u8", "kind": "hls"},
            {"url": "http://b/2.m3u8", "kind": "hls"}
        ]);
        let before = data.clone();
        let out = run(&dir, &layer_with(vec![TransformRule::FilterContains {
            field: "title".into(),
            contains: "4K".into(),
        }]), &mut data);
        assert_eq!(out, OverrideOutcome::Applied);
        assert_eq!(
            data, before,
            "整组没有该字段时必须跳过规则；旧实现会清空全部候选流"
        );
    }

    #[test]
    fn filter_on_partially_present_field_still_filters() {
        // 反向对照：只要有**部分**条目含该字段，就必须正常过滤
        // （"只保留有封面的"是合法需求，不能被上一条的护栏吃掉）
        let dir = tmpdir("l2_partial_field");
        let mut data = json!([
            {"title": "有标题", "cover": "x"},
            {"cover": "y"},
            {"title": "也有标题", "cover": "z"}
        ]);
        run(&dir, &layer_with(vec![TransformRule::FilterContains {
            field: "title".into(),
            contains: "标题".into(),
        }]), &mut data);
        let arr = data.as_array().unwrap();
        assert_eq!(arr.len(), 2, "部分条目有该字段时必须正常过滤");
        assert_eq!(arr[0]["title"], json!("有标题"));
    }

    #[test]
    fn exclude_on_absent_field_keeps_everything() {
        let dir = tmpdir("l2_absent_excl");
        let mut data = json!([{"url": "u1"}, {"url": "u2"}]);
        let before = data.clone();
        run(&dir, &layer_with(vec![TransformRule::FilterNotContains {
            field: "title".into(),
            contains: "预告".into(),
        }]), &mut data);
        assert_eq!(data, before, "字段不存在时排除规则必须保持原样");
    }

    #[test]
    fn transforms_on_detail_object_without_list_are_noop() {
        // 详情页没有 items/list ⇒ 变换静默跳过，不是错误
        let dir = tmpdir("l2_nolist");
        let mut data = json!({"id": "x", "title": "详情"});
        let before = data.clone();
        let out = run(&dir, &layer_with(vec![TransformRule::TakeFirst { limit: 0 }]), &mut data);
        assert_eq!(out, OverrideOutcome::Applied);
        assert_eq!(data, before, "没有列表时变换必须原样跳过");
    }

    // ─────────── L3 JS 劫持 ───────────

    fn hook_layer(src: &str) -> OverrideLayer {
        OverrideLayer {
            target_id: "t".into(),
            enabled: true,
            methods: vec![],
            mappings: vec![],
            transforms: vec![],
            js_hook: src.into(),
            note: String::new(),
        }
    }

    #[test]
    fn js_hook_can_rewrite_data() {
        let dir = tmpdir("l3_rewrite");
        let mut data = json!({"items": [{"title": "a"}, {"title": "b"}]});
        let out = run(
            &dir,
            &hook_layer("for (const it of data.items) { it.title = '★' + it.title; } return data;"),
            &mut data,
        );
        assert_eq!(out, OverrideOutcome::Applied);
        assert_eq!(data["items"][0]["title"], json!("★a"));
        assert_eq!(data["items"][1]["title"], json!("★b"));
    }

    #[test]
    fn js_hook_without_return_keeps_data() {
        let dir = tmpdir("l3_noret");
        let mut data = json!({"items": [{"title": "a"}]});
        let before = data.clone();
        run(&dir, &hook_layer("data.items.push({title:'c'});"), &mut data);
        assert_eq!(data, before, "没 return 视为不改");
    }

    #[test]
    fn js_hook_syntax_error_keeps_data() {
        let dir = tmpdir("l3_syntax");
        let mut data = json!({"items": [{"title": "a"}]});
        let before = data.clone();
        run(&dir, &hook_layer("this is not javascript ###"), &mut data);
        assert_eq!(data, before, "语法错必须原样透出，不得清空");
    }

    #[test]
    fn js_hook_runtime_error_keeps_data() {
        let dir = tmpdir("l3_runtime");
        let mut data = json!({"items": []});
        let before = data.clone();
        run(&dir, &hook_layer("throw new Error('boom')"), &mut data);
        assert_eq!(data, before, "运行抛错必须原样透出");
    }

    #[test]
    fn js_hook_infinite_loop_is_interrupted() {
        let dir = tmpdir("l3_loop");
        let mut data = json!({"items": [{"title": "a"}]});
        let before = data.clone();
        let t0 = std::time::Instant::now();
        run(&dir, &hook_layer("while(true){}"), &mut data);
        let elapsed = t0.elapsed();
        assert_eq!(data, before, "死循环被熔断后必须原样透出");
        assert!(
            elapsed.as_millis() < 15_000,
            "熔断必须真的生效（实际耗时 {elapsed:?}）"
        );
    }

    #[test]
    fn js_hook_cannot_reach_network_or_store() {
        let dir = tmpdir("l3_noperm");
        // ⚠️ 第一版写成 `typeof host === 'undefined' ? data : null`，
        //    注入 host 后**仍然通过** —— 因为 `null` 被当作"不改"，
        //    两个分支结果相同 ⇒ 假绿。改成显式改写数据才能区分。
        let mut data = json!({"items": []});
        run(
            &dir,
            &hook_layer(
                "if (typeof host !== 'undefined') { data.items.push({leak:1}); } return data;",
            ),
            &mut data,
        );
        assert_eq!(
            data["items"].as_array().unwrap().len(),
            0,
            "L3 不得能访问 host（网络/存储）；能访问就会把 leak 塞进来"
        );
    }

    #[test]
    fn js_hook_runs_after_l2() {
        // 顺序不变量：L2 先截断成 1 条，L3 再读到的也应是 1 条
        let dir = tmpdir("l3_order");
        let l = OverrideLayer {
            target_id: "t".into(),
            enabled: true,
            methods: vec![],
            mappings: vec![],
            transforms: vec![TransformRule::TakeFirst { limit: 1 }],
            js_hook: "data.items[0].title = 'only' + data.items.length; return data;".into(),
            note: String::new(),
        };
        let mut data = json!({"items": [{"title": "a"}, {"title": "b"}, {"title": "c"}]});
        run(&dir, &l, &mut data);
        assert_eq!(data["items"].as_array().unwrap().len(), 1);
        assert_eq!(
            data["items"][0]["title"],
            json!("only1"),
            "L3 必须在 L2 之后看到已截断的数据"
        );
    }
}
