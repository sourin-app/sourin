// ═══════════════════════════════════════════════════════════════════════
//  csp 类共用的**小工具**（R3-F Batch B）
// ═══════════════════════════════════════════════════════════════════════
//
// # ⚠️ 本文件**不许有任何注册项**
//
// ```text
// 这里只有 `pub fn` —— **一条 `inventory::submit!` 都不许有**。
// 判据（Lead 的门禁会钉）：共享文件里出现注册项 ⇒ 它就不是"共享工具"，
// 而是"借共享之名夹带了一个类"，那会让"一个类 = 一个文件"这条插件约定失效。
// ⇒ 想加类：新建 `csp/<class>.rs`，别往这里塞。
// ```
//
// # 为什么需要它（以及为什么不是"早点就该有"）
//
// R3-F Batch B 的 12 个类里，**同一个算法在多个类里重复**：
// ```text
// · `md5_hex`      —— AppYQK 签名、App3Q 签名（两个类的签名方案同源）
// · `sort_and_join` —— AppYQK/App3Q 的"按 key 排序后 k=v 用 & 连接"
// · `pick_str`     —— 所有 JSON 类都要"从嵌套 Value 里安全取一层字符串"
// ```
// 各写一份会漂（一处改了另一处没改）。**但也不做成"公共基类"**：
// ```text
// 普查已证：App* 类**各自独立**（方法骨架不同 + 零互相引用）
// ⇒ 这里只放**纯函数**（无状态、无字段、无 trait），不做 trait/基类。
//   一个类不 import 它也能编译；import 了也不改变它的协议。
// ```
//
// # 边界：这里**不许**出现的东西
// ```text
// ❌ trait / struct 基类      —— 会让"各类独立"变成"共享基类"（普查结论明确否掉）
// ❌ 任何注册项                —— 见上
// ❌ 宿主细节                  —— 不 use crate::state/hostpool/proxy/flutter
// ❌ 网络                     —— 纯计算，可在单测里直接断言
// ```

use serde_json::Value;

// ═══════════════════════════════════════════════════════════════════════
//  MD5（十六进制小写）
// ═══════════════════════════════════════════════════════════════════════

/// MD5 十六进制小写（32 字符）
///
/// # 为什么是 md5 而不是 sha256
/// ```text
/// 这不是"我们选的弱哈希"，是**上游协议就要求 md5** ——
/// csp_AppYQK 的签名串 `sign` 实测必须等于 `md5(排序 k=v + &appKey=…)`：
///   正确 md5 → 200 {"result":true}
///   错 md5 / 不给 / 换成 sha256 前 32 位 → 一律 {"result":false,"msg":"失败：sign error"}
/// ⇒ 换算法就对不上上游，与"哈希强度"无关（签名不是安全边界，是请求指纹）。
/// ```
/// 本仓 `Cargo.toml` 里已有 `md-5`（csp_Bili 的 WBI `w_rid` 用的就是它），
/// ⇒ **零新增依赖**。
pub fn md5_hex(s: &str) -> String {
    use md5::{Digest, Md5};
    let mut h = Md5::new();
    h.update(s.as_bytes());
    let d = h.finalize();
    let mut out = String::with_capacity(32);
    for b in d {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

// ═══════════════════════════════════════════════════════════════════════
//  签名串拼装（AppYQK / App3Q 同源）
// ═══════════════════════════════════════════════════════════════════════

/// 把 `[(key, value)]` **按 key 字典序**排好，用 `&` 连成 `k=v&k=v…`
///
/// # 为什么必须排序（不是可选的美化）
/// ```text
/// 上游是客户端按固定顺序拼接后取 md5，服务端**按同一顺序**重算比对。
/// 顺序错了 ⇒ 签名不匹配 ⇒ `失败：sign error`（实测确认）。
/// ⇒ 排序是协议的一部分，不是"顺手排一下"。
/// ```
pub fn sort_and_join(pairs: &[(String, String)]) -> String {
    let mut v: Vec<&(String, String)> = pairs.iter().collect();
    v.sort_by(|a, b| a.0.cmp(&b.0));
    v.iter()
        .map(|(k, val)| format!("{k}={val}"))
        .collect::<Vec<_>>()
        .join("&")
}

/// 上游协议里的 `sign = md5(<排序 k=v 串> + "&appKey=" + APPKEY)`
///
/// ⚠️ 判据来自**行为级负对照**（见 `md5_hex` 的注释），不是从常量"读起来像"。
pub fn app_sign(pairs: &[(String, String)], app_key: &str) -> String {
    md5_hex(&format!("{}&appKey={}", sort_and_join(pairs), app_key))
}

// ═══════════════════════════════════════════════════════════════════════
//  serde_json 的取值小工具
// ═══════════════════════════════════════════════════════════════════════

/// 从嵌套路径取一个 **JSON 字符串**（非字符串类型一律算"没有"）
///
/// ```text
/// pick_str(&v, &["data", "detail", "vod_name"])  ⇒ Some("…")
/// ```
/// ★ 数字/布尔**不**自动转字符串：`vod_id` 这类字段上游有时给数字有时给字符串，
///   自动转会把"上游把 id 变成了数字"这个**协议变化**静默吞掉。
///   要数字就用 [`pick_id_str`]（它明确接受两种形态）。
pub fn pick_str<'a>(v: &'a Value, path: &[&str]) -> Option<&'a str> {
    let mut cur = v;
    for p in path {
        cur = cur.get(*p)?;
    }
    cur.as_str()
}

/// 取一个"id 形态"的字段：**接受字符串或数字**，统一成字符串
///
/// # 为什么单独开一个函数（而不是让 `pick_str` 宽容一点）
/// ```text
/// `vod_id` 在真上游里两种形态都出现过（AppYQK 的 vodId 是数字 479233）。
/// 但"宽容"必须是**显式选择**：调用点写 `pick_id_str` 就等于声明
/// "这个字段我确认两种形态都合法"。让 `pick_str` 偷偷宽容，
/// 会把别的字段（如 vod_remarks）的意外类型变化一起吞掉。
/// ```
pub fn pick_id_str(v: &Value, path: &[&str]) -> Option<String> {
    let mut cur = v;
    for p in path {
        cur = cur.get(*p)?;
    }
    match cur {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

/// 从嵌套路径取一个 **数组**（不是数组就算"没有"）
pub fn pick_arr<'a>(v: &'a Value, path: &[&str]) -> Option<&'a Vec<Value>> {
    let mut cur = v;
    for p in path {
        cur = cur.get(*p)?;
    }
    cur.as_array()
}

/// 上游业务码 → 错误文案（**唯一的文案来源**，避免各处自己拼）
///
/// ```text
/// {"result":false,"msg":"失败：sign error"}    ⇒ 签名算错了（不是"站点坏了"）
/// {"result":false,"msg":"影视不存在"}          ⇒ 该条目已下架
/// {"result":false,"msg":"服务器忙，请稍后重试"}  ⇒ 上游限流，可重试
/// ```
/// ★ 为什么把上游 `msg` **原样带出来**：这三种失败的修法完全不同，
///   压成一句"请求失败"会让排查方向全错（签名算错却去查配置）。
pub fn upstream_err(prefix: &str, v: &Value) -> String {
    let msg = v
        .get("msg")
        .and_then(|m| m.as_str())
        .or_else(|| v.get("message").and_then(|m| m.as_str()))
        .unwrap_or("");
    if msg.is_empty() {
        format!("{prefix}（上游 result=false，未给 msg）")
    } else {
        format!("{prefix}：{msg}")
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  分类 id / 线路解析（多线路源的共用拼装）
// ═══════════════════════════════════════════════════════════════════════

/// 把 `vod_play_from` / `vod_play_url` 形态的 `$$$` 串解开成「线路 → 集」
///
/// ```text
/// from = "一起看APP$$$WJ$$$BF"
/// url  = "第01集$ep1#第02集$ep2$$$第01集$ep3#第02集$ep4$$$…"
/// ⇒ [("一起看APP", [("第01集","ep1"), ("第02集","ep2")]),
///    ("WJ",       [("第01集","ep3"), ("第02集","ep4")]), …]
/// ```
/// ★ 线路名挂在 `flag` 上（`CspEpisode.flag` 这个字段就是为它存在的）。
/// ★ **两串长度不一致**时按短的来（上游偶发少一条线路）—— 不 panic，不猜。
pub fn split_lines(play_from: &str, play_url: &str) -> Vec<(String, Vec<(String, String)>)> {
    let flags: Vec<&str> = play_from.split("$$$").map(|s| s.trim()).collect();
    let bodies: Vec<&str> = play_url.split("$$$").collect();
    let n = flags.len().min(bodies.len());
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let flag = if flags[i].is_empty() {
            format!("线路{}", i + 1)
        } else {
            flags[i].to_string()
        };
        let eps: Vec<(String, String)> = bodies[i]
            .split('#')
            .filter_map(|seg| {
                let seg = seg.trim();
                if seg.is_empty() {
                    return None;
                }
                match seg.split_once('$') {
                    Some((name, url)) => {
                        let name = name.trim();
                        // 上游偶发 `$url`（无名）⇒ 用地址自己当名字，别丢这一集
                        let name = if name.is_empty() { url.trim() } else { name };
                        Some((name.to_string(), url.trim().to_string()))
                    }
                    // 完全没有 `$` ⇒ 整个就是地址
                    None => Some((seg.to_string(), seg.to_string())),
                }
            })
            .collect();
        out.push((flag, eps));
    }
    out
}

// ═══════════════════════════════════════════════════════════════════════
//  门禁辅助：源码扫描（**只给测试用**）
// ═══════════════════════════════════════════════════════════════════════

/// 把 `include_str!` 拿到的整个文件切成**实现段**（去掉 `#[cfg(test)]` 之后的部分）
///
/// # 为什么这个函数必须存在（我踩了这个坑，留档）
/// ```text
/// 我写的第一版源码判据是这样：
///     let src = include_str!("app_yqk.rs");
///     assert!(src.contains("v.extend(extra.iter().cloned());"));
///
/// ★ 它是**假绿**：`include_str!` 把**整个文件**（含 `#[cfg(test)] mod tests`）
///   都读进来了，而**断言里那个字面量本身**就在同一个文件里
///   ⇒ 就算把实现里的那句删掉，字面量还在 ⇒ `contains` 仍然为真 ⇒ 门禁恒绿。
/// ⇒ 我在做注入验证（`.probe/r3-t20-inject.sh`）时当场发现了它：
///   注入"extra 不进签名" ⇒ 测试**没红**。若不做注入，这条假门禁会被当成"有牙口"。
///
/// 判据：`#[cfg(test)]` 之后的内容一律**排除**。这样 `assert!` 里的字面量
///   就不在扫描范围内了 —— 删掉实现里的那句话，门禁才会真红。
/// ```
/// ⚠️ 还有两个细节（都被实际门禁失败逼出来的）：
/// ```text
/// ① 归一化要**去掉所有空白**。否则"改个缩进/换行"就能让 `contains` 失败
///    —— 那会变成"格式一变就红"的脆门禁（另一种假信号）。
/// ② ★ **注释也必须剥掉**。我在 `wwys.rs` 里写：
///      ```
///      if !crate::tvbox::starts_http(ep_url) {
///          continue; // 非 http 的段（如相对路径/空）跳过，不伪造
///      }
///      ```
///    判据写的是 `contains("starts_http(ep_url){continue;}")`，
///    而真实源码归一化后是 `starts_http(ep_url){continue;//非http的段…}` ——
///    中间插了一句**解释这个 if 的注释** ⇒ 断言失败。
///    ⇒ 这是**脆门禁**：注释是"解释行为"的正当内容，不该被门禁禁止。
///      正确做法是**把注释剥掉再比对**，让判据只看**代码**。
///      （与 mod.rs 那条门禁"注释里描述改前是什么是留档，不许被逼着删"同一口径。）
/// ```
/// ⇒ 顺序：① 切实现段 ② 剥注释 ③ 去空白。
pub fn impl_src_only(full: &str) -> String {
    // ★★ 这里踩过**两层**真 bug，都留档（都靠门禁真红抓出来）：
    // ```text
    // 【第一层】顺序错：`full.split(LIT).next()` 而 LIT 在**文档注释里**也出现过
    //   ⇒ 切在文档注释处 ⇒ 之后的真代码全被丢。
    //   修：**先剥注释**。
    //
    // 【第二层】★ 更隐蔽：剥注释**不会剥字符串字面量**（那是故意的，见 `strip_comments` 的说明）
    //   ⇒ 而**本函数自己的函数体里**就写着 `split("#[cfg(test)]")` ——
    //     那个**字符串字面量**里含有 LIT ⇒ 剥完注释后再 split，
    //     仍会切在**自己的参数**上（实测：impl 段在 3248 字节处被截断，
    //     而 `b64_encode` 在它之后 ⇒ 门禁 `base64_is_self_contained...` 报
    //     "必须有自己的 b64_encode" 为假 = **真红**，抓对了）。
    //   ⇒ 修法：**行首锚定** —— 真的属性一定在**行首**，而参数里的字面量不在。
    //     用 `"\n#[cfg(test)]"` 切（并在前面补一个 `\n`，让首行形态也能匹配）。
    // ★ 教训：**"这个词出现在文件里" ≠ "它是那个语法结构"** ——
    //   字符串字面量与注释一样，都能让"按子串切"的工具自伤。
    // ```
    let stripped = strip_comments(full);
    let anchored = format!("\n{stripped}");
    let impl_part = anchored.split("\n#[cfg(test)]").next().unwrap_or(&anchored);
    impl_part.chars().filter(|c| !c.is_whitespace()).collect()
}

/// 剥掉 Rust 源码里的**注释**（行注释 `//` 与块注释 `/* */`），但不碰字符串字面量
///
/// # 为什么必须"不碰字符串"
/// ```text
/// 朴素实现（见 `tests/zz_r3_csp_registry.rs` 里那段同类逻辑）按**行首**判 `//`，
/// 这在本文件里够用，但会误伤形如 `let url = "https://x";` 的行内 `//`
/// （`https://` 里的 `//` 会被当注释起点 ⇒ 把后面整行代码吃掉）。
/// ⇒ 这里用**状态机**：跟踪"是否在字符串字面量 / 是否在块注释"，
///   只在**字符串外**才把 `//` 与 `/*` 当注释。
/// ★ 支持 `"…"`（含 `\"` 转义）与 `r#"…"#` 原始串的开始结束。
/// ```
pub fn strip_comments(src: &str) -> String {
    let b: Vec<char> = src.chars().collect();
    let mut out = String::with_capacity(src.len());
    let mut i = 0usize;
    let mut in_block = false;
    let mut in_str = false;
    let mut in_raw: Option<usize> = None; // 原始串的 `#` 个数
    while i < b.len() {
        let c = b[i];
        // ── 原始字符串 r#"…"# / r"…" ──
        if in_raw.is_none() && !in_str && !in_block {
            if c == 'r' && i + 1 < b.len() && (b[i + 1] == '"' || b[i + 1] == '#') {
                let mut j = i + 1;
                let mut hashes = 0usize;
                while j < b.len() && b[j] == '#' {
                    hashes += 1;
                    j += 1;
                }
                if j < b.len() && b[j] == '"' {
                    // 找到 r#…" 的开头 ⇒ 整段照抄直到对应结束
                    in_raw = Some(hashes);
                    for k in i..=j {
                        out.push(b[k]);
                    }
                    i = j + 1;
                    continue;
                }
            }
        }
        if let Some(h) = in_raw {
            out.push(c);
            if c == '"' {
                // 检查后面是否有 h 个 #
                let mut k = i + 1;
                let mut cnt = 0usize;
                while k < b.len() && b[k] == '#' && cnt < h {
                    cnt += 1;
                    k += 1;
                }
                if cnt == h {
                    for m in i + 1..k {
                        out.push(b[m]);
                    }
                    i = k;
                    in_raw = None;
                    continue;
                }
            }
            i += 1;
            continue;
        }
        // ── 块注释 ──
        if in_block {
            if c == '*' && i + 1 < b.len() && b[i + 1] == '/' {
                in_block = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        // ── 普通字符串（含转义）──
        if in_str {
            out.push(c);
            if c == '\\' && i + 1 < b.len() {
                out.push(b[i + 1]); // 转义的下一个字符原样带走
                i += 2;
                continue;
            }
            if c == '"' {
                in_str = false;
            }
            i += 1;
            continue;
        }
        // ── 字符串外：字符串开始 / 注释开始 ──
        if c == '"' {
            in_str = true;
            out.push(c);
            i += 1;
            continue;
        }
        if c == '/' && i + 1 < b.len() && b[i + 1] == '/' {
            // 行注释：吃到行尾（**吃掉换行前的全部**，换行保留以便归一化）
            while i < b.len() && b[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if c == '/' && i + 1 < b.len() && b[i + 1] == '*' {
            in_block = true;
            i += 2;
            continue;
        }
        out.push(c);
        i += 1;
    }
    out
}

// ═══════════════════════════════════════════════════════════════════════
//  base64（★ 自己写 —— 因为 `base64` crate **不是本仓的直接依赖**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要自己写（Lead 裁定 ②，逐字）
// ```text
// `base64 v0.22.1` 只在 `Cargo.lock` 的**传递依赖**里出现
//   （经 `reqwest` / `axum` / `hyper-util` / `ring`…）
// ⇒ 按本仓纪律：**不经 `Cargo.toml` 直接声明就不能 `use`**
//   （否则今天能编译、哪天上游换版本或去掉传递依赖就断）
// ⇒ 而 base64 是**纯函数**（标准字母表 + padding）⇒ 自己写 + 配单测更稳，
//   且**不动 `Cargo.toml`**（少一处要批的改动）。
// ★ 需要两种形态（Gulu 要标准、部分站点要 URL-safe）⇒ 都实现。
// ```

/// base64 字母表（标准）
const B64_STD: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
/// base64 字母表（URL-safe：`-` `_` 代替 `+` `/`）
const B64_URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// base64 编码（**标准**字母表 + `=` padding）
pub fn b64_encode(data: &[u8]) -> String {
    b64_encode_with(data, B64_STD, true)
}

/// base64 编码（**URL-safe** 字母表 + `=` padding）
pub fn b64_encode_url(data: &[u8]) -> String {
    b64_encode_with(data, B64_URL, true)
}

/// base64 编码（**标准**字母表，**无 padding**）
pub fn b64_encode_nopad(data: &[u8]) -> String {
    b64_encode_with(data, B64_STD, false)
}

/// base64 编码（指定字母表与是否 padding）
///
/// ```text
/// 3 字节 → 4 字符；余 1 字节 → 2 字符 + "=="；余 2 字节 → 3 字符 + "="
/// ```
pub fn b64_encode_with(data: &[u8], alphabet: &[u8; 64], pad: bool) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(alphabet[((n >> 18) & 0x3F) as usize] as char);
        out.push(alphabet[((n >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(alphabet[((n >> 6) & 0x3F) as usize] as char);
        } else if pad {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(alphabet[(n & 0x3F) as usize] as char);
        } else if pad {
            out.push('=');
        }
    }
    out
}

/// base64 解码（**宽容**：标准与 URL-safe 都收，padding 可有可无）
///
/// # 为什么宽容
/// ```text
/// 上游给的 base64 三种形态都见过：标准带 padding / URL-safe / 无 padding。
/// ⇒ 解码端**统一宽容**（编码端才需要区分）——
///   这样"上游换了字母表"不会让整条链路断。
/// ```
/// 非法字符 ⇒ `Err`（**不静默丢字符** —— 丢字符会让"解码成功但内容错"，最难查）
pub fn b64_decode(s: &str) -> Result<Vec<u8>, String> {
    let mut acc: u32 = 0;
    let mut nbits: u32 = 0;
    let mut out: Vec<u8> = Vec::with_capacity(s.len() * 3 / 4);
    let mut pad_seen = false;
    for c in s.chars() {
        // ★ 空白要**最先**跳过 —— 我第一版把这条放在 `pad_seen` 检查**之后**
        //   ⇒ `"/w==\n"`（上游常在长 base64 尾部带换行）会被判成
        //     "padding 之后还有数据" ⇒ **误报**。
        //   门禁 `b64_decode_is_lenient_about_alphabet_and_whitespace` 当场抓红（真红）。
        if c == '\n' || c == '\r' || c == ' ' || c == '\t' {
            continue;
        }
        if c == '=' {
            pad_seen = true;
            continue;
        }
        // ★ padding 之后不许再有**数据**（`AB=CD` 是坏的）—— 空白不算数据
        if pad_seen {
            return Err(format!("base64 在 padding 之后还有数据：位置在 `{c}`"));
        }
        let v = match c {
            'A'..='Z' => c as u32 - 'A' as u32,
            'a'..='z' => c as u32 - 'a' as u32 + 26,
            '0'..='9' => c as u32 - '0' as u32 + 52,
            '+' | '-' => 62,
            '/' | '_' => 63,
            _ => return Err(format!("base64 含非法字符：`{c}`")),
        };
        acc = (acc << 6) | v;
        nbits += 6;
        if nbits >= 8 {
            nbits -= 8;
            out.push(((acc >> nbits) & 0xFF) as u8);
        }
    }
    // ★ 余下的位必须是"补零位"（否则是截断的 base64）
    if nbits > 0 && (acc & ((1 << nbits) - 1)) != 0 {
        return Err(format!("base64 尾部有非零填充位（长度可能被截断）：剩 {nbits} 位"));
    }
    Ok(out)
}

// ═══════════════════════════════════════════════════════════════════════
//  测试（纯函数 ⇒ 可直接断言）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// ★ 实测向量（AppYQK 真网络验证过的**那个**签名）
    ///
    /// # 为什么用真向量而不是"自己算一遍再断言"
    /// ```text
    /// 自算自验 = 恒真（算法改了测试也跟着改，永远绿）。
    /// 这里的期望值来自 **2026-10-27 真打上游拿到 200 {"result":true}** 的那次请求，
    /// ⇒ 换掉算法（比如改成 sha256）这条立刻红。
    /// ```
    #[test]
    fn app_sign_matches_the_live_verified_vector() {
        let key = "3359de478f8d45638125e446a10ec541";
        // 真网络那次 playUrl 请求的参数（order 无关，函数自己排）
        let pairs: Vec<(String, String)> = vec![
            ("appId".into(), "e6ddefe09e0349739874563459f56c54".into()),
            ("cus1tom".into(), "aabbcc".into()),
            ("deviceInfo".into(), "Android".into()),
            ("reqDomain".into(), "yqk1.app".into()),
            ("requestId".into(), "11111111-2222-4333-8444-555555555555".into()),
            ("udid".into(), "0123456789abcdef".into()),
            ("version".into(), "1.2.7.104".into()),
        ];
        // 手算校验：串必须**按 key 字典序**
        let want_plain = "appId=e6ddefe09e0349739874563459f56c54\
&cus1tom=aabbcc\
&deviceInfo=Android\
&reqDomain=yqk1.app\
&requestId=11111111-2222-4333-8444-555555555555\
&udid=0123456789abcdef\
&version=1.2.7.104";
        assert_eq!(sort_and_join(&pairs), want_plain, "★ 必须按 key 字典序排序");
        let want_sign = md5_hex(&format!("{want_plain}&appKey={key}"));
        assert_eq!(app_sign(&pairs, key), want_sign);
        // 独立第三方实现（Python hashlib）算出来的同一个值 —— 防"我们两边一起错"
        assert_eq!(
            want_sign, "40cf2b66b30ae722b8c9da7970d4c3ab",
            "★ 独立实现（Python hashlib）算出的同一个值；改了算法/排序/连接符都会红"
        );
    }

    #[test]
    fn sort_and_join_is_actually_sorted_not_input_order() {
        // 反面：把顺序反过来 ⇒ 结果**必须相同**（证明函数真的在排，而不是照抄入参）
        let a = vec![("b".to_string(), "2".to_string()), ("a".to_string(), "1".to_string())];
        assert_eq!(sort_and_join(&a), "a=1&b=2");
        let b = vec![("a".to_string(), "1".to_string()), ("b".to_string(), "2".to_string())];
        assert_eq!(sort_and_join(&b), "a=1&b=2");
    }

    #[test]
    fn app_sign_appends_appkey_at_the_end_not_sorted_in() {
        /*
         * ★ 判据要瞄**缺陷形状**：如果实现把 appKey 也当成一个普通参数丢进排序，
         *   结果会不同（appKey 会排到最前，因为 'a' 最小）。
         * ⇒ 这里断言"appKey 在尾部"，把那个缺陷钉死。
         */
        let pairs = vec![("zzz".to_string(), "1".to_string())];
        let got = app_sign(&pairs, "KEY");
        assert_eq!(got, md5_hex("zzz=1&appKey=KEY"));
        // 若 appKey 参与排序，串会是 "appKey=KEY&zzz=1" ⇒ 哈希不同
        assert_ne!(got, md5_hex("appKey=KEY&zzz=1"), "★ appKey 必须**追加**在尾部");
    }

    #[test]
    fn pick_str_does_not_coerce_numbers() {
        let v = json!({"data": {"vod_id": 479233, "vod_name": "嫁金钗"}});
        assert_eq!(pick_str(&v, &["data", "vod_name"]), Some("嫁金钗"));
        // ★ 数字**不**自动转 —— 让"上游把 id 变数字"这个协议变化可见
        assert_eq!(pick_str(&v, &["data", "vod_id"]), None);
        // 想取数字请显式用 pick_id_str
        assert_eq!(pick_id_str(&v, &["data", "vod_id"]).as_deref(), Some("479233"));
        // 路径不存在 / 中途类型不对 ⇒ None，不 panic
        assert_eq!(pick_str(&v, &["data", "nope"]), None);
        assert_eq!(pick_str(&v, &["data", "vod_name", "deeper"]), None);
    }

    #[test]
    fn pick_arr_only_accepts_arrays() {
        let v = json!({"data": {"items": [1, 2], "obj": {"a": 1}}});
        assert_eq!(pick_arr(&v, &["data", "items"]).map(|a| a.len()), Some(2));
        assert!(pick_arr(&v, &["data", "obj"]).is_none(), "对象不是数组");
        assert!(pick_arr(&v, &["data", "nope"]).is_none());
    }

    #[test]
    fn upstream_err_keeps_the_upstream_wording() {
        // ★ 三种失败必须能分开：修法完全不同
        let v = json!({"result": false, "msg": "失败：sign error"});
        assert!(upstream_err("取流失败", &v).contains("sign error"));
        let v2 = json!({"result": false, "msg": "影视不存在"});
        assert!(upstream_err("详情失败", &v2).contains("影视不存在"));
        // 没有 msg ⇒ 不编一个，说清"上游没给"
        let v3 = json!({"result": false});
        let e = upstream_err("列表失败", &v3);
        assert!(e.contains("未给 msg"), "{e}");
        // message 是同义键（不同端点用不同拼法）
        let v4 = json!({"message": "unauthorized"});
        assert!(upstream_err("x", &v4).contains("unauthorized"));
    }

    #[test]
    fn impl_src_only_strips_test_module_and_normalizes_whitespace() {
        // ★ 这个函数的存在理由就是"别让断言自己的字面量把门禁喂饱"（见其文档注释）。
        //   判据：测试段剥掉 + 空白归一化 + 实现段留着。
        let fake = "fn keep_me() { x(); }\n#[cfg(test)]\nmod tests { fn t() { /* marker_here */ } }\n";
        let flat = impl_src_only(fake);
        assert!(flat.contains("fnkeep_me(){x();}"), "实现段保留 + 空白归一化：{flat}");
        assert!(!flat.contains("marker_here"), "★ 测试段必须剥掉：{flat}");
        // 没有 `#[cfg(test)]` ⇒ 原样（只归一化）
        assert_eq!(impl_src_only("a b\nc"), "abc");
        // 反面：如果**不**剥，字面量会残留 —— 证明这个函数不是"恒空"
        let full: String = fake.chars().filter(|c| !c.is_whitespace()).collect();
        assert!(full.contains("marker_here"), "对照：全文扫描**确实**会带上测试段");
    }

    #[test]
    fn impl_src_only_strips_comments_so_gates_do_not_break_on_explanatory_notes() {
        /*
         * ★★ 这条是为了修一个**我自己门禁的假红**（wwys.rs 里真实发生）：
         * ```rust
         * if !starts_http(u) {
         *     continue; // 非 http 的段跳过，不伪造      ← 中间插了注释
         * }
         * ```
         * 判据写 `contains("starts_http(u){continue;}")` 时**失败**了 ——
         * 因为归一化后中间夹着注释文本。
         * ⇒ 注释是"解释行为"的正当内容，**不该被门禁禁止** ⇒ 必须先剥注释再看代码。
         */
        let src = "fn f() { if !g(u) {\n    continue; // 解释这句话的注释\n} }";
        let flat = impl_src_only(src);
        assert!(
            flat.contains("if!g(u){continue;}"),
            "★ 注释必须被剥掉，判据才能只看代码：{flat}"
        );
        assert!(!flat.contains("解释这句话"), "注释文本不许留在扫描结果里：{flat}");
        // 块注释同样要剥
        assert_eq!(impl_src_only("a /* x */ b").chars().collect::<String>(), "ab");
        // 行内块注释
        assert_eq!(impl_src_only("a/*x*/b"), "ab");
    }

    /// ★★ 元门禁：这条守"**工具自己**不许被注释里的同名串截断"（真 bug，必须钉住）
    ///
    /// ```text
    /// `impl_src_only` 第一版是 `full.split("#[cfg(test)]").next()`
    ///   —— 它在**第一次出现那个字面串**处切，
    ///   而本文件在**文档注释里**也写了 `#[cfg(test)]`（就是解释这个函数自己的那段，
    ///   位置在 impl 段**中间**）⇒ 切在文档注释处 ⇒
    ///   之后的所有**真代码**（含 `b64_encode`）都被当"测试段"丢掉。
    /// ⇒ 症状：门禁 `base64_is_self_contained...` 断言 `flat.contains("fnb64_encode")`
    ///   为假 ⇒ **真红**（我自己的门禁暴露了我自己的工具 bug）。
    /// ⇒ 修法：**先剥注释，再切测试段**。
    /// ```
    #[test]
    fn impl_src_only_strips_comments_before_splitting_the_test_module() {
        let fake = "// doc mentions #[cfg(test)] inside a comment\n\
                    fn real_impl() { keep(); }\n\
                    #[cfg(test)]\nmod tests { fn t() {} }\n";
        let flat = impl_src_only(fake);
        assert!(
            flat.contains("fnreal_impl()"),
            "★ 真代码不许被「注释里的 #[cfg(test)]」截掉：{flat}"
        );
        assert!(!flat.contains("modtests"), "★ 测试模块仍要被切掉：{flat}");

        /*
         * ★★ 第二层（更隐蔽）：**函数体自己的字符串字面量**里也有那个词。
         * `strip_comments` **不会**剥字符串（那是故意的）⇒ 单纯"先剥注释再 split"
         * 仍会切在**自己的参数**上。
         * ⇒ 判据：把"参数里的那个字面量"放进样本，看真代码还在不在。
         */
        let self_referential = "fn f() { let x = \"#[cfg(test)]\"; keep_me(); }\n\
                                #[cfg(test)]\nmod tests { fn t() {} }\n";
        let flat2 = impl_src_only(self_referential);
        assert!(
            flat2.contains("keep_me()"),
            "★ 真代码不许被「字符串字面量里的 #[cfg(test)]」截掉：{flat2}"
        );
        assert!(!flat2.contains("modtests"), "★ 测试模块仍要被切掉：{flat2}");

        // ★ 反向对照：不带行首锚定会丢掉真代码（证明"行首锚定"是必需的）
        let no_anchor = self_referential.split("#[cfg(test)]").next().unwrap()
            .chars().filter(|c| !c.is_whitespace()).collect::<String>();
        assert!(
            !no_anchor.contains("keep_me()"),
            "★ 对照：不锚定行首确实会丢掉真代码（这就是第二层那个 bug）"
        );
    }

    #[test]
    fn strip_comments_does_not_eat_string_literals() {
        /*
         * ★ 这条防的是"朴素实现"的经典误伤：
         *   `let url = "https://x";` 里的 `//` 会被当成注释起点 ⇒ 吃掉后面整行代码。
         *   ⇒ 必须跟踪"是否在字符串里"，只在字符串外才认注释。
         */
        let src = r#"let url = "https://x/y"; let n = 1;"#;
        let flat = impl_src_only(src);
        assert!(flat.contains("https://x/y"), "★ 字符串里的 // 不许被当注释：{flat}");
        assert!(flat.contains("letn=1;"), "★ 字符串之后的代码不许被吃掉：{flat}");
        // 转义引号不许提前结束字符串
        let esc = r#"let s = "a\"//b"; let n = 2;"#;
        let f2 = impl_src_only(esc);
        assert!(f2.contains("letn=2;"), "★ 转义引号后面的代码不许被吃掉：{f2}");
        assert!(f2.contains("//b"), "★ 字符串内的 // 要留着：{f2}");
        // 原始字符串 r#"…"# 里的 // 也要留住
        let raw = r####"let s = r#"// not a comment"#; let n = 3;"####;
        let f3 = impl_src_only(raw);
        assert!(f3.contains("//notacomment"), "★ 原始串里的 // 要留着：{f3}");
        assert!(f3.contains("letn=3;"), "★ 原始串之后的代码不许被吃掉：{f3}");
    }

    #[test]
    fn split_lines_handles_real_multiline_shape() {
        let from = "一起看APP$$$WJ$$$BF";
        let url = "第01集$ep1#第02集$ep2$$$第01集$ep3#第02集$ep4$$$第1集$ep5";
        let lines = split_lines(from, url);
        assert_eq!(lines.len(), 3, "三条线路");
        assert_eq!(lines[0].0, "一起看APP");
        assert_eq!(lines[0].1.len(), 2);
        assert_eq!(lines[0].1[0], ("第01集".to_string(), "ep1".to_string()));
        assert_eq!(lines[1].0, "WJ");
        assert_eq!(lines[2].1[0], ("第1集".to_string(), "ep5".to_string()));
    }

    #[test]
    fn split_lines_tolerates_upstream_raggedness() {
        // 线路名缺一个 ⇒ 补"线路N"，不许 panic，也不许丢整条线
        let lines = split_lines("A$$$", "x$1$$$y$2");
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[1].0, "线路2");
        // 集名缺失（`$url`）⇒ 用地址当名字，别丢这一集
        let l2 = split_lines("A", "$https://a/1.m3u8");
        assert_eq!(l2[0].1[0].1, "https://a/1.m3u8");
        assert_eq!(l2[0].1[0].0, "https://a/1.m3u8", "无名时用地址兜底，不许空标题");
        // 完全没有 `$` ⇒ 整段当地址
        let l3 = split_lines("A", "https://b/2.m3u8");
        assert_eq!(l3[0].1[0].1, "https://b/2.m3u8");
        // 空段跳过
        let l4 = split_lines("A", "#x$1##y$2#");
        assert_eq!(l4[0].1.len(), 2, "空集段要跳过");
    }

    #[test]
    fn split_lines_two_strings_of_unequal_length_takes_the_shorter() {
        // 上游偶发少给一条线路的 url ⇒ 按短的来（不 panic、不臆造空线路）
        let lines = split_lines("A$$$B$$$C", "x$1");
        assert_eq!(lines.len(), 1, "url 串只有一条 ⇒ 只出那一条");
        assert_eq!(lines[0].0, "A");
    }

    #[test]
    fn md5_hex_matches_known_vectors() {
        assert_eq!(md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
        // 必须是小写 32 位（上游比对是逐字字符串比较，大小写错就 sign error）
        assert_eq!(md5_hex("abc").len(), 32);
        assert_eq!(md5_hex("ABC"), md5_hex("ABC").to_lowercase());
    }

    // ── ★★ base64（自己写的，所以必须用**官方测试向量**钉住） ──────────
    //
    // ★ 用 RFC 4648 的**标准向量**（不是我自己造的"编码后再解码"——
    //   那样两边同时错也会"通过"，是典型的假绿）。
    #[test]
    fn b64_encode_matches_rfc4648_vectors() {
        // RFC 4648 §10 的标准向量，覆盖 padding 三态（无 / "=" / "=="）
        assert_eq!(b64_encode(b""), "", "空输入 ⇒ 空串（不是 `====`）");
        assert_eq!(b64_encode(b"f"), "Zg==", "余 1 字节 ⇒ `==`");
        assert_eq!(b64_encode(b"fo"), "Zm8=", "余 2 字节 ⇒ `=`");
        assert_eq!(b64_encode(b"foo"), "Zm9v", "整除 3 ⇒ 无 padding");
        assert_eq!(b64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(b64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(b64_encode(b"foobar"), "Zm9vYmFy");
        // 高位字节（非 ASCII / 二进制）
        assert_eq!(b64_encode(&[0xFF]), "/w==", "0xFF ⇒ `/w==`（标准字母表用 `/`）");
        assert_eq!(b64_encode(&[0x00]), "AA==");
    }

    #[test]
    fn b64_url_safe_and_nopad_forms_differ_as_expected() {
        // ★ URL-safe：`+`→`-`，`/`→`_`
        // `[0xFB,0xFF]` 标准是 `+/8=`，URL-safe 应为 `-_8=`
        assert_eq!(b64_encode(&[0xFB, 0xFF]), "+/8=");
        assert_eq!(b64_encode_url(&[0xFB, 0xFF]), "-_8=");
        // ★ 无 padding 形态（长度不是 4 的倍数）
        assert_eq!(b64_encode_nopad(b"f"), "Zg");
        assert_eq!(b64_encode_nopad(b"fo"), "Zm8");
        assert_eq!(b64_encode_nopad(b"foo"), "Zm9v", "整除 ⇒ 与带 padding 相同");
        assert_eq!(b64_encode_nopad(&[0xFB, 0xFF]), "+/8");
    }

    /// ★★ 编码→解码**回环**（覆盖所有长度余数）+ 解码**宽容**三种字母表形态
    #[test]
    fn b64_roundtrips_every_length_remainder() {
        for n in 0..=64usize {
            let data: Vec<u8> = (0..n).map(|i| (i * 37 % 256) as u8).collect();
            // 标准带 padding
            assert_eq!(b64_decode(&b64_encode(&data)).unwrap(), data, "n={n} 标准回环");
            // URL-safe 带 padding
            assert_eq!(b64_decode(&b64_encode_url(&data)).unwrap(), data, "n={n} URL-safe 回环");
            // 无 padding
            assert_eq!(b64_decode(&b64_encode_nopad(&data)).unwrap(), data, "n={n} 无 padding 回环");
        }
    }

    #[test]
    fn b64_decode_is_lenient_about_alphabet_and_whitespace() {
        // ★ 宽容：同一个值的三种形态都要能解
        let v = b64_decode("/w==").unwrap();
        assert_eq!(v, vec![0xFF]);
        assert_eq!(b64_decode("_w==").unwrap(), v, "URL-safe 的 `_` 要认");
        assert_eq!(b64_decode("_w").unwrap(), v, "无 padding 要认");
        assert_eq!(b64_decode("  /w==\n").unwrap(), v, "换行/空白要认（上游会插换行）");
        assert_eq!(b64_decode("+/-_").is_ok(), true, "两种字母表混用也不炸（宽容）");
    }

    /// ★★ 非法输入必须**报错**（不静默丢字符 —— 丢字符会让"解码成功但内容错"）
    #[test]
    fn b64_decode_rejects_invalid_input_instead_of_silently_dropping() {
        assert!(b64_decode("AB*CD").is_err(), "非法字符必须 Err");
        assert!(b64_decode("中文").is_err(), "非 ASCII 必须 Err");
        assert!(b64_decode("Zg==Zg").is_err(), "padding 之后还有数据必须 Err");
        // 尾部非零填充位 = 截断的 base64（`Zh` 是 `f` 的坏编码）
        assert!(b64_decode("Zh").is_err(), "尾部非零填充位必须 Err");
        // 合法的最短形态
        assert!(b64_decode("").is_ok());
        assert_eq!(b64_decode("").unwrap(), Vec::<u8>::new());
    }

    /// ★ 元门禁：base64 必须是**自己写的**（不许偷偷 `use base64::…`）
    #[test]
    fn base64_is_self_contained_not_a_transitive_dependency() {
        let flat = impl_src_only(include_str!("shared.rs"));
        assert!(
            !flat.contains("use base64::") && !flat.contains("base64::engine"),
            "★ 不许用 `base64` crate（它不是本仓直接依赖，只在 Cargo.lock 的传递树里）"
        );
        // 也不许走"先转成 hex 再塞"之类的旁路
        // ⚠️ 归一化会**去掉所有空白** ⇒ 判据里也不许带空格
        //    （`fn b64_encode` 会变成 `fnb64_encode`；带空格断言必然不匹配 ——
        //     这是我自己门禁的坑，czsapp 上踩过一次，这里预先写对）
        assert!(flat.contains("fnb64_encode"), "★ 必须有自己的 b64_encode");
        assert!(flat.contains("fnb64_decode"), "★ 必须有自己的 b64_decode");
    }
}