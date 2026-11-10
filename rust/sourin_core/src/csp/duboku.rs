// ═══════════════════════════════════════════════════════════════════════
//  csp_Duboku —— TVBox `csp_Duboku` 的 Rust 重写（「毒布谷」蓝光秒播）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```json
// {"key":"毒布谷","name":"🍿毒布谷丨蓝光秒播","type":3,"api":"csp_Duboku",
//  "searchable":1,"quickSearch":1,"filterable":1}
// ```
// ⇒ **没有 ext**：站点写死 `https://www.duboku.tv/`（DEX `c()` 里的 Referer 常量）。
//
// # ★★ 分档：**参数 bug 已修；上游仍然不可用**（两件事分开记）
//
// ```text
// 2026-10-27 实测（第一轮，当时误判为"上游死了，与参数无关"）：
//   GET https://api.dbokutv.com/home   ⇒ HTTP **400 / 7b body=`Failure`**
//   GET https://www.duboku.tv/         ⇒ **连接失败（000）**
//   GET https://dbokutv.com/           ⇒ 空响应
//
// 2026-10-29 重测（**这一轮把"参数"和"上游"拆开了**，证据在
//   `.probe/api-fix/duboku_token_probe.out.txt`）：
//   GET /home、/vodshow/…、/vodsearch…、/、/zzz-nonexistent（**不要任何参数**）
//        ⇒ 全部 HTTP 400 / `Failure`（catch-all，不区分路径）
//   GET 同批路径 **带上 DEX `b()` 的 `?sign=&ssid=&token=`**
//        ⇒ 全部 HTTP **417** / `Failure`；`/` 那次变 500 + Cloudflare troubleshooting JSON
//   ⇒ 结论 ①：**400 有一半是我们的 bug** —— 本类以前**从未**调用过 `token_query()`，
//              而上游确实按这三段分叉（400 → 417 是服务端行为变化，不是巧合）。
//   ⇒ 结论 ②：417/500 是 **worker 已转发、origin 不响应** ⇒ **上游当前不可用**，
//              这一档不是我们能修的，也不许假装修好。
//   ⇒ 域名侧：`duboku.tv` 的 NS 已是 `ns1/ns2.662.parklogic.com`（**停放商**，A=162.4.84.239），
//              `w.duboku.io`（DEX 播放器的 origin/referer，:629/:632）**已不解析**，
//              `api.dbokutv.com` 仍由 Cloudflare 承载但 origin 死。
// ```
//
// # 协议复原（DEX 逐条 + **离线判据**验证）
//
// ```text
// ① 请求头（DEX `c()` 逐字）
//      Connection: Keep-Alive
//      User-Agent: Chrome151 那条
//      Referer:    https://www.duboku.tv/
// ② `b()` 生成 token 串，形态：`?sign=<sign>&ssid=<ssid>&token=<token>`
// ③ `d(String)` 是**它的逆**：
//      UTF-18? 不 —— 是每 **3 字符一组反转** → `'.'`→`'='` → **Base64.decode** → UTF-8
//    而 `b()` 的编码半正是：
//      `getBytes()` → `Base64.encodeToString` → `'='`→`'.'` → 每 3 字符一组反转
// ④ 两张字符表（DEX 常量逐字）
//      T1 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"    （跳 33 分支）
//      T2 = "XYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVW"    （跳 88 分支）
//      调用：`sign = a(60,60,33)`（T1）  `ssid = a(38,38,88)`（T2）
// ```
//
// ## ★ 上游死的情况下，我给出的**最强证据**（不假装验证过）
// ```text
// `.probe/r3-duboku-proto-check.py` 做三件事：
//   判据 1：我复刻的 **`b()` 编码半与 `d()` 互为逆**（DEX 两侧逐字对照）
//           ⇒ **6/6 通过**（含空串 / 单字符 / 中文 / 真 URL）
//           ⇒ 这证明"我抄的变换**没抄反**"（不能证明服务端会接受）
//   判据 2：两张字符表在 DEX 常量里**各出现 1 次**（逐字命中）
//   判据 3：`?sign=` / `&ssid=` / `&token=` 三个参数名**逐字命中**（1/1/2 次）
// ★ 边界：**不能**证明"Duboku 服务端会接受我们的 sign/ssid/token" —— 上游 400 ⇒ 无法真网验证。
//   已如实写在这里，也会如实写进交付读数。
// ```
//
// # ⚠️ 已知缺口（按契约"不许静默丢、不许自己造"）
// ```text
// ① `mProxy`：DEX 方法表里**没有**（`<init>/a/b/c/d/categoryContent/detailContent/
//    homeContent/init/playerContent/searchContent`）⇒ 本批"mProxy 不做"对该类零影响。
// ② `loadPic`：也没有 ⇒ 封面取图走源 `cover_headers`（声明式）。
//    ⚠️ 但 `CspSite` **没有** `cover_headers()` 能力位（与 csp_Douban/csp_AppGet 同一处缺口，已报 Lead）。
// ③ `initApi`：没有（`Duboku.init` 是空方法体 —— 见 DEX :570，0 条 const-string）。
// ④ `isVideoFormat` / `manualVideoCheck`：DEX 里**没有这两个方法** ⇒ 不存在这两个位。
// ★ ⑤ `b()` 的**前几步**（`Random(seed)` 与那串交错取字符）：
//    DEX 里涉及 `nextInt(0x2faf0800)` 与几个十六进制常量（`0x5f5e100`=100000000、
//    `0x35a4e900`=900000000）。**我读出了结构，但"seed 的精确算法"在两个版本之间
//    有歧义**（`currentTimeMillis()*1000` vs `/1000`）。
//    ⇒ 处置：把 `token` 的**编码变换**按 DEX 逐字实现（那部分有互逆判据，可靠），
//      而 `seed` 部分**按 DEX 指令顺序**实现并**标注"上游不可用 ⇒ 未验证"**。
//      **不**把"没验证过"说成"验证过"。
//```

use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use regex::Regex;
use serde_json::Value;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
const SITE: &str = "https://www.duboku.tv";
const REFERER: &str = "https://www.duboku.tv/";
const API: &str = "https://api.dbokutv.com";

// ═══════════════════════════════════════════════════════════════════════
//  纯函数：编码/解码（全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// 字符表 T1（DEX 常量逐字；`a(...,33)` 分支）
pub const T1: &str = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
/// 字符表 T2（DEX 常量逐字；`a(...,88)` 分支）
pub const T2: &str = "XYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVW";

/// 每 3 字符一组**反转**（DEX `d()` 与 `b()` 共用的同一个变换）
pub fn rev3(s: &str) -> String {
    let cs: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < cs.len() {
        let end = (i + 3).min(cs.len());
        for k in (i..end).rev() {
            out.push(cs[k]);
        }
        i += 3;
    }
    out
}

/// `b()` 的**编码半**：UTF-8 → Base64 → `=`→`.` → 每 3 字符反转
///
/// ★ 这是与 DEX `d()` **互逆**的那一段 ⇒ 有离线判据（见测试 `b_and_d_are_inverses`）。
pub fn encode_token(plain: &str) -> String {
    use super::app99::b64_encode;
    let b64 = b64_encode(plain.as_bytes());
    rev3(&b64.replace('=', "."))
}

/// DEX `d(String)` 的等价：每 3 字符反转 → `.`→`=` → Base64 解码 → UTF-8
pub fn decode_token(s: &str) -> Result<String, String> {
    use super::app99::b64_decode;
    let joined = rev3(s).replace('.', "=");
    /*
     * ⚠️ 门禁 `b_and_d_are_inverses` 抓到过一处：`"abc"` 这种**长度不足 4** 的输入，
     *    `rev3` 之后 Base64 的"字符数必须是 4 的倍数"这条会被破坏。
     *    DEX 的 `Base64.decode(..., flags)` 在 Java 侧**宽容**（默认 flags 会忽略尾巴），
     *    而本仓的 `b64_decode` 是**严格**实现 ⇒ 这里补上 `=` 到 4 的倍数再解。
     *    ⇒ 语义：**把 Java 的宽容度补回来**，而不是改 `b64_decode`（那是 App99 的共享函数）。
     */
    let mut padded = joined.clone();
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    let raw = b64_decode(&padded)?;
    String::from_utf8(raw).map_err(|e| format!("解码结果不是 UTF-8：{e}"))
}

/// `a(I,J,I)` 的等价：以时间/计数器为种子，从**字符表**里取 `len` 个字符
///
/// # DEX 结构（`.probe/r3-batchA-Duboku.disasm.txt:6-48`）
/// ```text
/// seed  = Random(System.currentTimeMillis() * 1000)
/// 表    = (第三参 == 33) ? T1 : (第三参 == 88) ? T2 : T1
/// 循环 len 次：取 rnd.nextInt(表长) 处的字符
/// ```
/// ⚠️ **seed 的精确形态未经验证**（上游 400）—— 见文件头「已知缺口 ⑤」。
///    这里按 DEX 的**指令顺序**实现（`currentTimeMillis()*1000` 作种子），
///    并把"未验证"如实标在返回值的注释里（不是标在日志里 —— 日志会被忽略）。
pub fn rand_str(len: usize, table: &str) -> String {
    let cs: Vec<char> = table.chars().collect();
    if cs.is_empty() {
        return String::new();
    }
    /*
     * ★ 种子里必须掺入"调用序" —— 只用时间会有**同毫秒碰撞**：
     *   实测 `rand_str(60,T1)` 连续两次拿到**完全相同**的串（门禁 `token_query_shape` 抓到）。
     *   后果不是"好看不好看"：`sign`/`ssid` 本该每次不同，撞了就等于**签名字段失去变化性**，
     *   服务端若拿它做防重放，同一毫秒内的请求会被判重。
     * ⇒ 加一个进程内的自增计数器（等价于 DEX 里 `Random(seed)` 每次新建实例的意图）。
     */
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
        .wrapping_mul(1000)
        .wrapping_add(seq);
    // ★ 0 种子会让 xorshift 恒 0 ⇒ 加个非零常量
    if seed == 0 {
        seed = 0x9E37_79B9_7F4A_7C15;
    }
    // xorshift（等价于"给定种子的伪随机序列"；**不是**要复刻 Java Random 的位级实现，
    // 因为服务端只把它当"变化的值"，不重建种子流水）
    let mut out = String::with_capacity(len);
    for _ in 0..len {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        out.push(cs[(seed % cs.len() as u64) as usize]);
    }
    out
}

/// `java.util.Random` 的**位级复刻**（48 位 LCG；JDK 的 `nextInt(bound)` 拒绝采样）
///
/// # 为什么必须位级复刻（不是"随便造个随机数"）
/// ```text
/// DEX `b()` 的第 0..22 条指令是：
///   new Random(System.currentTimeMillis() * 1000)
///   r = Math.abs(rnd.nextInt(0x2faf0800))       ← 0x2faf0800 = 800000000
///   然后再用 r 去算明文里的两段数字（见 `b_plain`）
/// ⇒ 服务端要复算的是**同一个 Java Random 序列**。用 xorshift 之类的自造 PRNG 会得到
///   完全不同的 r，明文就"不是那个算法算出来的"了。
/// ⇒ 这里按 JDK 的 `Random` 实现逐条移植：seed = (seed ^ 0x5DEECE66D) & ((1<<48)-1)，
///   next(bits) = (seed = seed*0x5DEECE66D + 0xB) >> (48-bits)，nextInt 用拒绝采样。
/// ```
/// 判据：`dex_b_plain_vectors` 用 Python 侧（同一算法）算出的定值向量逐字比对。
struct JavaRandom {
    seed: u64,
}

const LCGP_MUL: u64 = 0x5DEE_CE66D;
const LCGP_ADD: u64 = 0xB;
const MASK48: u64 = (1 << 48) - 1;

impl JavaRandom {
    fn new(seed: u64) -> Self {
        Self {
            seed: (seed ^ LCGP_MUL) & MASK48,
        }
    }

    fn next(&mut self, bits: u32) -> u64 {
        self.seed = (self
            .seed
            .wrapping_mul(LCGP_MUL)
            .wrapping_add(LCGP_ADD))
            & MASK48;
        self.seed >> (48 - bits)
    }

    /// JDK `nextInt(bound)`：2 的幂走乘法路径，否则拒绝采样
    fn next_int(&mut self, bound: u64) -> u64 {
        if bound == 0 {
            return 0;
        }
        if bound & bound.wrapping_neg() == bound {
            return (bound * self.next(31)) >> 31;
        }
        loop {
            let bits = self.next(31);
            let val = bits % bound;
            /*
             * ★ 必须是 **32 位有符号**溢出语义（JDK 的 `bits - val + (bound-1) < 0` 是 int 运算）：
             *   用 u64 算永远 ≥ 0 ⇒ 拒绝采样形同不存在 ⇒ 与 JDK 序列分叉。
             */
            let probe = (bits as i32)
                .wrapping_sub(val as i32)
                .wrapping_add(bound as i32 - 1);
            if probe >= 0 {
                return val;
            }
        }
    }
}

/// DEX `b()` 的**明文**（交错串；`Base64` 之前的那一层）
///
/// ```text
/// s2 = String.valueOf(System.currentTimeMillis())          ← 13 位
/// s3 = String.valueOf(0x5f5e100 + r) + String.valueOf(0x35a4e900 - r)   ← 9+9 位
/// 明文 = 逐字符交错(s2, s3) 到 min(len)，再把两边剩下的各自接上
/// ```
/// 判据：`dex_b_plain_vectors`（定值向量来自 `.probe/api-fix/duboku_vectors.out.txt`）。
pub fn b_plain(now_ms: u64) -> String {
    let mut rnd = JavaRandom::new(now_ms.wrapping_mul(1000));
    let r = rnd.next_int(0x2FAF_0800) % 0x2FAF_0801;
    let s2 = format!("{now_ms}");
    let s3 = format!("{}{}", 100_000_000u64.wrapping_add(r), 900_000_000u64.wrapping_sub(r));
    let a: Vec<char> = s2.chars().collect();
    let b: Vec<char> = s3.chars().collect();
    let n = a.len().min(b.len());
    let mut out = String::with_capacity(a.len() + b.len());
    for i in 0..n {
        out.push(a[i]);
        out.push(b[i]);
    }
    out.extend(a[n..].iter());
    out.extend(b[n..].iter());
    out
}

/// `b()` 的 token 段：`encode_token(明文)`（UTF-8 → Base64 → `=`→`.` → 每 3 字符反转）
pub fn b_token(now_ms: u64) -> String {
    encode_token(&b_plain(now_ms))
}

/// 组装 `b()` 的三段（DEX 逐字：`?sign=` + sign + `&ssid=` + ssid + `&token=` + token）
///
/// ```text
/// sign  = a(60, 60, 33)      ← T1（DEX 的 sign 是"随机串"，服务端不复算）
/// ssid  = a(38, 38, 88)      ← T2
/// token = encode_token(明文) ← 服务端**要复算**（见 `b_plain`）
/// ```
///
/// ★ 2026-10-29 实测（`.probe/api-fix/duboku_token_probe.out.txt`）：
/// ```text
///   不带这三段：GET /home ⇒ HTTP 400 body=`Failure`
///   带这三段  ：GET /home ⇒ HTTP 417 body=`Failure`（worker 换了分支 ⇒ 参数被接受，origin 不可达）
/// ⇒ 这三段是**上游必需参数**，不是"可选装饰"。本函数以前**从来没被请求路径调用过**，
///   那正是 400 的一半原因。
/// ```
pub fn token_query_at(now_ms: u64) -> String {
    let sign = rand_str(60, T1);
    let ssid = rand_str(38, T2);
    let token = b_token(now_ms);
    format!("?sign={sign}&ssid={ssid}&token={token}")
}

/// 当前时刻的 `b()` 参数串
pub fn token_query() -> String {
    token_query_at(now_millis())
}

/// 拼一个**带 `b()` 参数**的 API 地址（DEX 里每个入口都 `append(b())`，见下）
///
/// ```text
/// home    : 'https://api.dbokutv.com/home'        + b()          （DEX :497/:499-501）
/// search  : 'https://api.dbokutv.com/vodsearch'   + b() + '&wd=' + kw  （DEX :642-651）
/// list    : 'https://api.dbokutv.com/vodshow/…'   + b()          （DEX :250-268）
/// detail  : 'https://api.dbokutv.com' + d(DId)    + b()          （DEX :350-355）
/// ⇒ `b()` 是 **query 串**（以 `?` 开头）⇒ 地址里已经有 `?` 时必须用 `&` 接。
/// ```
pub fn api_url(path_and_query: &str) -> String {
    let q = token_query();
    if path_and_query.contains('?') {
        format!("{API}{path_and_query}&{}", &q[1..])
    } else {
        format!("{API}{path_and_query}{q}")
    }
}

fn now_millis() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 上游判据：Duboku 用数字 `code`（**1 = 成功**）—— 与 DEX 里 `getInt("code")` 一致
///
/// ★ 缺 `code` 不当作成功。
pub fn ensure_ok<'a>(v: &'a Value, what: &str) -> Result<&'a Value, String> {
    match v.get("code").and_then(|c| c.as_i64()) {
        Some(1) => Ok(v),
        Some(c) => Err(format!(
            "上游 {what} 返回 code={c}（msg={}）",
            v.get("msg").and_then(|m| m.as_str()).unwrap_or("")
        )),
        None => Err(format!(
            "上游 {what} 响应里没有 code 字段 —— ★ 实测本站当前返回 「HTTP 400 / `Failure`」，\
             即上游不可用（不是我们少带了参数）"
        )),
    }
}

/// `list[]` → 条目；**0 条 ⇒ Err**
pub fn items_of(v: &Value, what: &str) -> Result<Vec<CspItem>, String> {
    ensure_ok(v, what)?;
    let arr = v.get("list").and_then(|l| l.as_array()).ok_or_else(|| {
        format!(
            "上游 {what} 响应里没有 list（实际顶层键：{:?}）",
            v.as_object()
                .map(|o| o.keys().take(8).cloned().collect::<Vec<_>>())
                .unwrap_or_default()
        )
    })?;
    let out: Vec<CspItem> = arr
        .iter()
        .filter_map(|o| {
            let id = o.get("vod_id").map(|x| x.to_string().trim_matches('"').to_string())?;
            let title = o.get("vod_name").and_then(|x| x.as_str())?.trim().to_string();
            if id.is_empty() || title.is_empty() {
                return None;
            }
            Some(CspItem {
                id,
                title,
                cover: o
                    .get("vod_pic")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.trim().is_empty())
                    .map(|s| s.trim().to_string()),
                subtitle: o
                    .get("vod_remarks")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.trim().is_empty())
                    .map(|s| s.trim().to_string()),
            })
        })
        .collect();
    if out.is_empty() {
        return Err(format!(
            "上游 {what} 的 list 解析出 0 条（list 有 {} 项）",
            arr.len()
        ));
    }
    Ok(out)
}

/// `type_list[]` → 分类（DEX homeContent 用 `type_list`）；**0 条 ⇒ Err**
pub fn cats_of(v: &Value) -> Result<Vec<CspCategory>, String> {
    ensure_ok(v, "首页")?;
    let arr = v
        .get("type_list")
        .and_then(|l| l.as_array())
        .ok_or_else(|| {
            format!(
                "上游首页响应里没有 type_list（实际顶层键：{:?}）",
                v.as_object()
                    .map(|o| o.keys().take(8).cloned().collect::<Vec<_>>())
                    .unwrap_or_default()
            )
        })?;
    let out: Vec<CspCategory> = arr
        .iter()
        .filter_map(|o| {
            let id = o.get("type_id").map(|x| x.to_string().trim_matches('"').to_string())?;
            let name = o.get("type_name").and_then(|x| x.as_str())?.trim().to_string();
            if id.is_empty() || name.is_empty() {
                return None;
            }
            Some(CspCategory { id, name })
        })
        .collect();
    if out.is_empty() {
        return Err(format!(
            "上游首页 type_list 解析出 0 个分类（type_list 有 {} 项）",
            arr.len()
        ));
    }
    Ok(out)
}

/// 剧集：`vod_play_url` 的 `名$址` 形态（`#` 分集）
pub fn episodes_of(v: &Value, id: &str) -> Result<Vec<CspEpisode>, String> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let _ = RE.get_or_init(|| Regex::new(r"x").expect("noop"));
    let d = v.get("data").unwrap_or(v);
    let url_str = d
        .get("vod_play_url")
        .and_then(|x| x.as_str())
        .or_else(|| d.get("url").and_then(|x| x.as_str()))
        .unwrap_or("");
    let flag = d
        .get("vod_play_from")
        .and_then(|x| x.as_str())
        .filter(|s| !s.trim().is_empty())
        .unwrap_or("默认")
        .trim()
        .to_string();
    let mut eps = Vec::new();
    for (i, seg) in url_str.split('#').enumerate() {
        let seg = seg.trim();
        if seg.is_empty() {
            continue;
        }
        let (name, url) = match seg.split_once('$') {
            Some((a, b)) => (a.trim().to_string(), b.trim().to_string()),
            None => (format!("第{}集", i + 1), seg.to_string()),
        };
        if url.is_empty() {
            continue;
        }
        eps.push(CspEpisode {
            id: format!("{id}@{flag}|{i}|{url}"),
            title: if name.is_empty() { format!("第{}集", i + 1) } else { name },
            flag: flag.clone(),
        });
    }
    if eps.is_empty() {
        return Err(format!(
            "上游详情 {id} 的 vod_play_url 解析出 0 集（键名或分隔符可能变了）"
        ));
    }
    Ok(eps)
}

/// 拆集 id（`{vodId}@{flag}|{idx}|{url}`）
pub fn split_ep_id(ep: &str) -> Option<(String, String, usize, String)> {
    let (vid, rest) = ep.split_once('@')?;
    let mut it = rest.splitn(3, '|');
    let flag = it.next()?.to_string();
    let idx: usize = it.next()?.parse().ok()?;
    let url = it.next().unwrap_or("").to_string();
    if vid.is_empty() {
        return None;
    }
    Some((vid.to_string(), flag, idx, url))
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct Duboku {
    client: super::http_context::CspHttpContext,
}

/// 上游非 2xx 的**分档**（把"我们的参数错"与"上游死"分开，别混成一句话）
///
/// # 2026-10-29 真网判据（`.probe/api-fix/duboku_token_probe.out.txt`）
/// ```text
/// 不带 b() 三段：/home、/vodshow/…、/vodsearch、/、/zzz-nonexistent ⇒ **400** `Failure`
/// 带 b() 三段  ：同一批路径                                       ⇒ **417** `Failure`
///                （`/` 那次甚至是 500 + Cloudflare 的 troubleshooting JSON）
/// ⇒ 400 = "少了上游要求的参数"（我们的 bug，已修）；
///   417/5xx = worker 已在按 origin 转发 ⇒ **上游不可用**（不是我们能修的）。
/// ```
/// 注入：把 `417 | 500..=599` 那支删掉 ⇒ `real_upstream_transcripts_classify` 红。
pub fn classify_upstream(status: u16, body: &str) -> &'static str {
    match status {
        400 => "上游 400：缺上游要求的参数（本站要 DEX 的 b() 三段 sign/ssid/token）",
        401 | 403 => "上游拒绝：鉴权/风控",
        404 => "上游路由不存在：路径形态与上游不符",
        417 => "上游不可用：worker 已转发但 origin 不响应（417 Expectation Failed）",
        500..=599 => "上游不可用：origin 5xx",
        _ => {
            if body.trim() == "Failure" {
                "上游异常：body 就是英文 `Failure`（不是 JSON 错误体）"
            } else {
                "上游异常"
            }
        }
    }
}

impl Duboku {
    pub const CLASS: &'static str = "Duboku";

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| reqwest::Client::builder()
            // Unbound sites remain direct; the context applies the current app policy.
            .no_proxy()
            .user_agent(UA)
            .timeout(std::time::Duration::from_secs(20))
        );
        Self { client }
    }

    /// DEX `c()` 的三个头 + `b()` 的参数串
    async fn get_json(&self, url: &str, what: &str) -> Result<Value, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .header(reqwest::header::CONNECTION, "Keep-Alive")
            .header(reqwest::header::REFERER, REFERER)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(|e| format!("请求 Duboku 失败（{url}）：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取 Duboku 响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            /*
             * ★ 实测本站当前就是 HTTP 400 + body `Failure`。
             *   把 body 带出来 —— 让"上游不可用"与"我们参数错"在读数上**能分开**
             *   （`Failure` 这种 7 字节英文 body 不像"参数校验失败"那种 JSON）。
             */
            let head = body.chars().take(60).collect::<String>();
            return Err(format!(
                "上游 Duboku 返回 HTTP {status}（{url}）：body={head:?} —— {}；\
                 分档：400=我方缺参数（本站要 DEX 的 b() 三段）；417/5xx=上游不可用\
                 （实测 2026-10-29 就是这条：带 b() 三段后由 400 变 417）\
                 （证据：.probe/api-fix/duboku_token_probe.out.txt）",
                classify_upstream(status.as_u16(), &body)
            ));
        }
        serde_json::from_str(&body).map_err(|e| {
            format!(
                "上游 {what} 响应不是合法 JSON（{e}）；前 100 字：{}",
                body.chars().take(100).collect::<String>()
            )
        })
    }
}

impl Default for Duboku {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for Duboku {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        // DEX homeContent：`https://api.dbokutv.com/home` + `b()`
        let v = self.get_json(&api_url("/home"), "首页").await?;
        Ok(CspHome {
            categories: cats_of(&v)?,
            items: Vec::new(),
        })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        /*
         * ⚠️ 路径形态如实分档（**不猜**）：
         * ```text
         * DEX 的 list 入口是 `/vodshow/` + cateId + 4 段筛选 + page（const-string 只有
         *   '/vodshow/'、'-'、'----'、'---'，中间那几个 `merge.b.x.a(...)` 的参数顺序
         *   没能逐字复原）⇒ 本实现**保留**原来的 `/list/{tid}/{page}` 形态并明确标注
         *   "细节待证"，只补齐**已由实测证明必需**的 `b()` 三段。
         * ```
         */
        let v = self
            .get_json(&api_url(&format!("/list/{tid}/{page}")), &format!("分类 {tid} 第 {page} 页"))
            .await?;
        Ok(CspList {
            items: items_of(&v, &format!("分类 {tid}"))?,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        // DEX searchContent 逐字：`https://api.dbokutv.com/vodsearch` + b() + `&wd=` + URLEncoder.encode(kw)
        let url = api_url(&format!("/vodsearch?wd={}", urlencoding::encode(kw)));
        let v = self.get_json(&url, "搜索").await?;
        Ok(CspList {
            items: items_of(&v, "搜索")?,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        true
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let v = self
            .get_json(&api_url(&format!("/detail/{id}")), &format!("详情 {id}"))
            .await?;
        let d = v.get("data").unwrap_or(&v);
        Ok(CspDetail {
            id: id.to_string(),
            title: d
                .get("vod_name")
                .and_then(|x| x.as_str())
                .filter(|s| !s.trim().is_empty())
                .unwrap_or(id)
                .trim()
                .to_string(),
            cover: d.get("vod_pic").and_then(|x| x.as_str()).map(String::from),
            description: d
                .get("vod_content")
                .and_then(|x| x.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(|s| s.trim().to_string()),
            episodes: episodes_of(&v, id)?,
        })
    }

    /// 取流：把详情已给的地址交回（**不再打上游** —— 详情里的地址可能带时效签名）
    ///
    /// ★ **不拼**任何宿主侧代理地址（本类 DEX 里没有 `mProxy`，见文件头「已知缺口 ①」）。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let (_vid, flag, _idx, url) = split_ep_id(id).ok_or_else(|| {
            format!("取流 id 必须是 `{{vodId}}@{{flag}}|{{idx}}|{{url}}` 形态（原始 id={id:?}）")
        })?;
        if url.trim().is_empty() {
            return Err(format!(
                "取流 id 里没有地址（原始 id={id:?}）—— 详情应把地址一起编进集 id"
            ));
        }
        Ok(vec![CspPlay {
            url: url.trim().to_string(),
            headers: vec![
                ("User-Agent".to_string(), UA.to_string()),
                ("Referer".to_string(), REFERER.to_string()),
            ],
            label: Some(if flag.is_empty() { "默认".to_string() } else { flag }),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册
// ═══════════════════════════════════════════════════════════════════════
crate::csp::register_site!(Duboku);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
#[path = "duboku_proxy_tests.rs"]
mod proxy_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// ★★ `b()` 的编码半与 DEX `d()` **互为逆**（6/6，含空串/单字符/中文/真 URL）
    ///
    /// # 为什么这条是"上游不可用"时最强的一条
    /// ```text
    /// 两侧都在 DEX 里逐字读到（`encodeString` / `Base64.decode` 那两步），
    /// 而上游 400 ⇒ **无法用真网验证协议** ⇒ 只能证明"变换没抄反"。
    /// 这条门禁做的正是这件事：任意明文 → 我复刻的编码 → 我复刻的解码 → 原始明文。
    /// ```
    /// 注入：把 `rev3` 改成"不反转"（直接原样）⇒ 本条红（编码/解码都不对）。
    #[test]
    fn b_and_d_are_inverses() {
        for plain in [
            "https://www.duboku.tv/vod/1.html",
            "1104007",
            "abc",
            "",
            "a",
            "中文测试",
        ] {
            let enc = encode_token(plain);
            let back = decode_token(&enc).unwrap_or_else(|e| panic!("解码失败：{e}"));
            assert_eq!(back, plain, "★ b() 与 d() 必须互逆（明文 {plain:?} → {enc:?}）");
        }
        // 形态判据：编码结果里不该有 `=`（DEX 把它换成了 `.`）
        let e = encode_token("a");
        assert!(!e.contains('='), "★ `=` 必须被换成 `.`：{e}");

        /*
         * ★ 尾巴不足 3 字符的**分组**行为（这才是本条测试原本想验的东西）
         *
         * ⚠️ 第一版我写的是 `decode_token("abc").is_ok()` —— **那条断言是错的**：
         *    `"abc"` 经 rev3 → `"cba"` → 补 `=` → Base64 解出字节 `0x71 0xB6`，
         *    **不是合法 UTF-8** ⇒ 正确地返回 **Err**（不是 panic）。
         *    ⇒ 改成验真正该验的两件事：
         *      ① `rev3` 在尾巴不足 3 字符时**不 panic、不丢字符**；
         *      ② 解不出 UTF-8 时返回 **Err 而不是 panic**（错误路径要干净）。
         */
        assert_eq!(rev3("ab"), "ba", "★ 2 字符尾巴整体反转");
        assert_eq!(rev3("a"), "a", "★ 1 字符尾巴原样");
        assert_eq!(rev3("abcdef"), "cbafed", "★ 3 的倍数：逐组反转");
        assert_eq!(rev3("abcd"), "cbad", "★ 4 字符：首组反转 + 尾巴原样");
        assert!(
            decode_token("abc").is_err(),
            "★ 解出的字节不是 UTF-8 ⇒ 必须 Err（不 panic、不静默乱码）"
        );
    }

    #[test]
    /// ★★ 两张字符表**逐字**与 DEX 常量一致（各 62 字符，且内容不能是"以为的样子"）
    ///
    /// T2 是 `XYZ` **提到最前**的表 —— 若照 T1 抄，`ssid` 会生成错表字符。
    /// 注入：把 `T2` 改成 `T1` ⇒ 本条红。
    #[test]
    fn char_tables_are_verbatim() {
        assert_eq!(T1.len(), 62);
        assert_eq!(T2.len(), 62);
        assert_eq!(
            T1,
            "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        );
        assert_eq!(
            T2,
            "XYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVW"
        );
        assert_ne!(T1, T2, "★ 两张表必须不同（T2 把 XYZ 提到最前）");
        assert!(T2.starts_with("XYZ"), "{T2}");
        assert!(T1.starts_with("0123"), "{T1}");
        // 表里的字符必须不重复（否则"取表长模"的分布会偏）
        for (t, name) in [(T1, "T1"), (T2, "T2")] {
            let mut seen = std::collections::HashSet::new();
            for c in t.chars() {
                assert!(seen.insert(c), "★ {name} 里有重复字符 {c}");
            }
        }
    }

    #[test]
    /// ★★ 参数串形态逐字：`?sign=<60> &ssid=<38> &token=<非空>`
    ///
    /// 三个长度也来自 DEX（`a(60,60,33)` / `a(38,38,88)`）—— 抄错长度会让签名长度不对。
    /// token 的明文必须**等于** `b_plain(now)`（DEX 的交错串算法），不是任意占位。
    /// 注入：把 `rand_str(60, T1)` 改成 `rand_str(8, T1)` ⇒ 本条红。
    #[test]
    fn token_query_shape() {
        let now = 1_793_256_000_123u64;
        let q = token_query_at(now);
        assert!(q.starts_with("?sign="), "{q}");
        assert!(q.contains("&ssid="), "{q}");
        assert!(q.contains("&token="), "{q}");
        let sign = q
            .trim_start_matches("?sign=")
            .split("&ssid=")
            .next()
            .unwrap_or("");
        assert_eq!(sign.chars().count(), 60, "★ sign 长度 60（DEX a(60,60,33)）");
        assert!(sign.chars().all(|c| T1.contains(c)), "★ sign 必须全来自 T1：{sign}");
        let rest = q.split("&ssid=").nth(1).unwrap();
        let ssid = rest.split("&token=").next().unwrap();
        assert_eq!(ssid.chars().count(), 38, "★ ssid 长度 38（DEX a(38,38,88)）");
        assert!(ssid.chars().all(|c| T2.contains(c)), "★ ssid 必须全来自 T2：{ssid}");
        let token = q.split("&token=").nth(1).unwrap();
        assert!(!token.is_empty(), "token 不该空");
        assert_eq!(
            decode_token(token).unwrap(),
            b_plain(now),
            "★ token 必须解回 DEX 的 b() 明文（交错串），不是任意占位"
        );
        // rand_str 的变化性（同一进程内两次调用不该完全相同）
        assert_ne!(rand_str(60, T1), rand_str(60, T1), "★ 伪随机串该有变化");
        assert_eq!(rand_str(0, T1), "", "长度 0 ⇒ 空");
    }

    #[test]
    /// ★★ `b()` 明文的**定值向量**（Java Random 位级复刻的判据）
    ///
    /// 向量由 `.probe/api-fix/duboku_vectors.py` 生成，输出存在
    /// `.probe/api-fix/duboku_vectors.out.txt`（同一算法的 Python 侧独立实现）。
    /// 注入：把 `JavaRandom::next_int` 的拒绝采样改成 `% bound` 直接取 ⇒ 本条红（值会差）。
    #[test]
    fn dex_b_plain_vectors() {
        for (now, want_plain, want_token) in [
            (
                1_793_256_000_123u64,
                "1673933426566902040316263533076",
                "YTMzM3MzkyQzUjNjN2Mwk0AjMDMjNxM2IzUzAzMgN3..",
            ),
            (
                1_793_256_000_999u64,
                "1676963829516400060393939108594",
                "YTMjN3M2kygzUTOjNxMwQ2ADMDMzM5OzkwETUDOAN5..",
            ),
            (1u64, "1825110487174889513", "gTMTNyMxE4QDEzNDN3O4gxUT.wM."),
            (0u64, "0869741360130258640", "gDMTO2M0c2MTEDMDMzO1I0YD.AM."),
        ] {
            assert_eq!(b_plain(now), want_plain, "★ b() 明文不对（now={now}）");
            assert_eq!(b_token(now), want_token, "★ b() token 不对（now={now}）");
        }
        // 明文形态：长度 = len(now)+18（交错后拼接），且全是数字
        let p = b_plain(1_793_256_000_123);
        assert_eq!(p.chars().count(), 13 + 18, "★ 明文长度 = 13 位时间 + 18 位数字");
        assert!(p.chars().all(|c| c.is_ascii_digit()), "★ 明文必须是纯数字：{p}");
    }

    #[test]
    /// ★★ **每个 API 入口都必须带 `b()` 三段**（这是 400 变 417 的那个开关）
    ///
    /// 2026-10-29 真网（`.probe/api-fix/duboku_token_probe.out.txt`）：
    /// ```text
    /// /home            无 token ⇒ 400；带 token ⇒ 417
    /// /vodshow/…       无 token ⇒ 400；带 token ⇒ 417
    /// /vodsearch…      无 token ⇒ 400；带 token ⇒ 417
    /// ```
    /// 注入：把 `api_url` 里 `token_query()` 那段删掉（只返回 `{API}{path}`）⇒ 本条红。
    #[test]
    fn api_url_carries_token() {
        for path in [
            "/home",
            "/list/1/1",
            "/vodsearch?wd=%E8%80%81%E8%88%85",
            "/detail/1104007",
        ] {
            let u = api_url(path);
            assert!(u.starts_with("https://api.dbokutv.com"), "{u}");
            for k in ["sign=", "ssid=", "token="] {
                assert!(u.contains(k), "★ {path} 少了 `{k}` ⇒ 上游必 400：{u}");
            }
            // 已有 `?` 的路径必须用 `&` 接（否则 `?a=1?sign=` 是坏 query）
            assert!(!u.contains("?sign") || !u.contains("??"), "{u}");
            if path.contains('?') {
                assert!(u.contains("&sign="), "★ 已带 query 的路径必须用 & 接：{u}");
                assert!(!u.matches('?').count().gt(&1), "★ 只该有 1 个 `?`：{u}");
            }
        }
    }

    #[test]
    /// ★★ 真实响应转录的**分档判据**（离线；转录文件在 `.probe/api-fix/`）
    ///
    /// ```text
    /// duboku_token_probe.out.txt：
    ///   `== 无 token ==`   /home -> 400 b'Failure'
    ///   `== 带 DEX 复刻 token ==` /home -> 417 b'Failure'
    /// ```
    /// 注入：把 `classify_upstream` 的 `417` 支删掉 ⇒ 本条红（417 会落到"上游异常"）。
    #[test]
    fn real_upstream_transcripts_classify() {
        // 逐字来自 .probe/api-fix/duboku_token_probe.out.txt 的真实 body
        let body = "Failure";
        assert_eq!(
            classify_upstream(400, body),
            "上游 400：缺上游要求的参数（本站要 DEX 的 b() 三段 sign/ssid/token）",
            "★ 400 必须落在「我们缺参数」这一档"
        );
        assert_eq!(
            classify_upstream(417, body),
            "上游不可用：worker 已转发但 origin 不响应（417 Expectation Failed）",
            "★ 417 必须落在「上游不可用」这一档（这是今天真读数的那一档）"
        );
        assert!(classify_upstream(502, body).contains("上游不可用"));
        assert!(classify_upstream(403, "").contains("鉴权"));
        assert!(classify_upstream(404, "").contains("路由"));
        // 三档必须互不相同（否则"分档"是假的）
        let a = classify_upstream(400, body);
        let b = classify_upstream(417, body);
        assert_ne!(a, b);
    }

    #[test]
    /// ★★ 反空真：分类/条目/剧集 解析出 0 条 ⇒ **必须 Err**；缺 code 时报"上游不可用"
    ///
    /// 注入：删掉任一处 `is_empty()`/`ok_or_else` 的 Err ⇒ 对应断言红。
    #[test]
    fn empty_parses_are_errors() {
        let no_code: Value = serde_json::from_str(r#"{"list":[]}"#).unwrap();
        let e = ensure_ok(&no_code, "首页").expect_err("★ 缺 code 必须 Err");
        assert!(
            e.contains("上游不可用") || e.contains("400"),
            "★ 缺 code 时要如实指向「上游不可用」（实测就是 400/Failure）：{e}"
        );

        let empty: Value = serde_json::from_str(r#"{"code":1,"type_list":[]}"#).unwrap();
        assert!(cats_of(&empty).is_err(), "★ 0 分类必须 Err");
        let no_key: Value = serde_json::from_str(r#"{"code":1}"#).unwrap();
        let e2 = cats_of(&no_key).expect_err("★ 缺 type_list 必须 Err");
        assert!(e2.contains("type_list"), "{e2}");

        let empty_list: Value = serde_json::from_str(r#"{"code":1,"list":[]}"#).unwrap();
        assert!(items_of(&empty_list, "分类").is_err(), "★ 0 条目必须 Err");

        let no_ep: Value =
            serde_json::from_str(r#"{"code":1,"data":{"vod_play_url":""}}"#).unwrap();
        let e3 = episodes_of(&no_ep, "1").expect_err("★ 0 集必须 Err");
        assert!(e3.contains("0 集"), "{e3}");
    }

    /// 真实形态解析（逐字按 DEX 用的键名构造）
    #[test]
    fn parses_dex_field_names() {
        let home: Value = serde_json::from_str(
            r#"{"code":1,"msg":"ok","type_list":[
                 {"type_id":1,"type_name":"电影"},{"type_id":2,"type_name":"连续剧"}]}"#,
        )
        .unwrap();
        let c = cats_of(&home).unwrap();
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].id, "1");
        assert_eq!(c[0].name, "电影");

        let list: Value = serde_json::from_str(
            r#"{"code":1,"list":[{"vod_id":1104007,"vod_name":"上甘岭",
                 "vod_pic":"https://p/a.jpg","vod_remarks":"HD"}]}"#,
        )
        .unwrap();
        let l = items_of(&list, "分类").unwrap();
        assert_eq!(l[0].id, "1104007", "★ vod_id 数字 ⇒ 字符串");
        assert_eq!(l[0].title, "上甘岭");
        assert_eq!(l[0].subtitle.as_deref(), Some("HD"));

        // 详情：`名$址` + `#` 分集（DEX 的 vod_play_url 形态）
        let det: Value = serde_json::from_str(
            r#"{"code":1,"data":{"vod_name":"上甘岭","vod_pic":"https://p/a.jpg",
                 "vod_content":"简介","vod_play_from":"duboku",
                 "vod_play_url":"正片$https://cdn/1.m3u8#第2集$https://cdn/2.m3u8"}}"#,
        )
        .unwrap();
        let eps = episodes_of(&det, "1104007").unwrap();
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0].title, "正片");
        assert_eq!(eps[0].flag, "duboku");
        assert!(eps[1].id.contains("https://cdn/2.m3u8"), "{}", eps[1].id);
    }

    /// 取流：从集 id 交回地址 + 带 UA/Referer；形态不对 ⇒ Err
    ///
    /// 注入：把 `play` 里那句形态检查删掉 ⇒ 本条红。
    ///
    /// ⚠️ 只留 `#[tokio::test]`（叠 `#[test]` 会报 async functions cannot be used for tests）。
    #[tokio::test]
    async fn play_requires_well_formed_id_and_returns_url_with_headers() {
        let s = Duboku::new();
        // ① 正常：详情编的形态
        let p = s
            .play("duboku", "1104007@duboku|0|https://cdn/1.m3u8", "")
            .await
            .expect("应成功");
        assert_eq!(p[0].url, "https://cdn/1.m3u8");
        let has = |k: &str| p[0].headers.iter().any(|(kk, _)| kk == k);
        assert!(has("User-Agent"), "★ 必须带 UA");
        assert!(has("Referer"), "★ 必须带 Referer（DEX 的 c() 里逐字有）");
        assert_eq!(p[0].label.as_deref(), Some("duboku"));

        // ② 缺 `@…` 段 ⇒ Err（不猜）
        let e = s.play("", "1104007", "").await.expect_err("★ 形态不对必须 Err");
        assert!(e.contains("形态"), "{e}");
        // ③ 有段但没地址 ⇒ Err
        let e2 = s.play("", "1104007@duboku|0|", "").await.expect_err("★ 没地址必须 Err");
        assert!(e2.contains("没有地址"), "{e2}");
    }

    #[test]
    /// ★ 上游不可用时错误文案**必须能让读者区分"上游死"与"我们参数错"**
    ///
    /// 实测：本站当前返 400 + body `Failure`（7 字节英文），而"参数校验失败"通常返 JSON。
    ///
    /// # ⚠️ 这条门禁**第一版没有牙**（注入 H 真不红 ⇒ 我按纪律查了原因，并修好）
    /// ```text
    /// 第一版判据：`include_str!("duboku.rs").contains("Failure")` /
    ///             `.contains("上游不可用")` / `.contains("body=")`
    /// 问题：`"Failure"` 与 `"上游不可用"` 在**文件别处**也有（文件头文档块、以及本测试自己）
    ///       ⇒ 把 `get_json` 里**真正构造错误文案**那一处删掉，这三条断言**照样全绿**。
    ///       ⇒ 那是"打在文档上"而不是"打在代码路径上"的判据（**假绿**）。
    /// 修法：判据改成两条**只能由那段实现满足**的形态：
    ///   ① `let head = body.chars()…`（取 body 前缀那一句）+ 紧随的 `body={head:?}`
    ///      必须是**同一段连续文本**（把这两句连起来做单次 `contains`）；
    ///   ② 实现里必须真的把 `Failure` 与「上游不可用」**放进同一个 format!**
    ///      （即错误串里同时出现这两者 —— 用"那段 format 的连续文本"做判据）。
    /// ```
    /// 注入 H（把带 body 的 format! 换成只报状态码）⇒ 本条必须红。
    #[test]
    fn upstream_down_is_distinguishable_from_our_param_error() {
        let src = include_str!("duboku.rs");
        // ① 取 body 前缀那句 + 用它拼错误串 —— 必须**连续出现**在同一段实现里
        let pair = [
            "let head = body.chars().take(60).collect::<String>();",
            "body={head:?}",
        ];
        assert!(
            src.contains(pair[0]),
            "★ 必须先把 body 前缀取出来（注入 H 就是删掉这一句）"
        );
        assert!(
            src.contains(pair[1]),
            "★ 错误串里必须把 body 带出来（`body={{head:?}}`）"
        );
        // ② 判据必须与**实现那段代码**绑定 —— 且要防"自证陷阱"
        /*
         * ⚠️ 这一条我修了**两次**，两次都是"判据没打在实现上"（如实留档）：
         *   第一版：`src.contains("Failure")` / `.contains("上游不可用")` —— 假绿，
         *           因为这两个词在**文件头文档**与**本测试自己**里都有。
         *   第二版：按行找 `body={head:?}` 且同行/邻行含结论词 —— **仍然假绿**，
         *           因为**本测试的判据行自己**就同时含这两个词（`764/768` 行），
         *           而 `include_str!` 读到的是**整份源码（含测试）** ⇒ 自证陷阱。
         *   ⇒ 第三版（现在）：**先按函数切开**，只在 `get_json` 的函数体里找。
         *      判据 = 「取 body 前缀」那句 + 「用它拼错误串」那句，必须落在**同一个函数体**内。
         */
        let body_impl = src
            .split("async fn get_json")
            .nth(1)
            .and_then(|rest| rest.split("impl Default for Duboku").next())
            .unwrap_or("");
        assert!(
            body_impl.contains("let head = body.chars()"),
            "★★ `get_json` 里必须先把 body 前缀取出来（注入 H 就是删掉这一句）—— \
             注意：判据只在函数体里找，不许被文件别处/本测试的字面量满足"
        );
        assert!(
            body_impl.contains("body={head:?}"),
            "★★ `get_json` 的错误串里必须把 body 带出来"
        );
        assert!(
            body_impl.contains("上游不可用"),
            "★★ `get_json` 的错误串里必须给出「上游不可用」这个结论（读得出是哪一种错）"
        );
        // ③ 反面：文件头文档里也提到 `Failure` 是会发生的 —— 所以**不能**只判它出现
        assert!(
            src.matches("Failure").count() >= 2,
            "★ 文件里应同时有「实测记录」与「实现引用」两处 `Failure`（判据要能区分它们）"
        );
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    /// ★★ 这条**预期是"上游不可用"**，所以它的判据不是"必须成功"，
    ///    而是"**必须如实报出上游不可用**，且读起来与'我们参数错'能分开"。
    ///
    /// 2026-10-29 实测：带 `b()` 三段后上游由 400 变 **417**（worker 已转发、origin 不响应）。
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_duboku -- --ignored --nocapture"]
    async fn csp_live_duboku_reports_upstream_state() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = Duboku::new();
        match s.home("").await {
            Ok(h) => eprintln!(
                "[LIVE] home 成功：分类 {} 个（首={}）—— ★ 上游**活了**（与 2026-10-29 的 417 不同）",
                h.categories.len(),
                h.categories.first().map(|c| c.name.clone()).unwrap_or_default()
            ),
            Err(e) => {
                eprintln!("[LIVE] home 如实失败：{e}");
                // ★ 判据：错误里必须能看出"上游不可用"（而不是含糊的失败）
                assert!(
                    e.contains("上游不可用")
                        || e.contains("HTTP 400")
                        || e.contains("HTTP 417")
                        || e.contains("Failure"),
                    "★ 上游不可用要报得明确（读得出是哪一种错）：{e}"
                );
                eprintln!("[LIVE] ⇒ 结论：**该站上游当前不可用**（协议已复刻，无从真网验证）");
            }
        }
    }

    /// ★★ 真网络：**token 是 400→417 的开关**（这条是"我们参数错"与"上游死"的分界线）
    ///
    /// 判据（不做假成功）：
    /// ```text
    /// ① 不带 b() 三段 ⇒ 必须 400（证明缺参数确实是 400 的原因）
    /// ② 带 b() 三段   ⇒ 必须 **不是 400**（417/5xx/200 都算通过；今天实测 417）
    /// ③ 两条都打印真实状态码与 body 前 60 字
    /// ```
    /// 注入：把 `api_url` 的 token 去掉 ⇒ ② 红（会变成 400）。
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_duboku_token -- --ignored --nocapture"]
    async fn csp_live_duboku_token_transition() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let c = reqwest::Client::builder()
            .no_proxy()
            .user_agent(UA)
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .expect("client");
        let get = |u: String| {
            let c = c.clone();
            async move {
                let r = c
                    .get(u)
                    .header(reqwest::header::REFERER, REFERER)
                    .header(reqwest::header::ACCEPT, "application/json")
                    .send()
                    .await
                    .map_err(|e| e.to_string())?;
                let st = r.status().as_u16();
                let b = r.text().await.unwrap_or_default();
                Ok::<(u16, String), String>((st, b))
            }
        };
        let bare = format!("{API}/home");
        let (s1, b1) = get(bare.clone()).await.expect("裸请求应能拿到响应");
        eprintln!("[LIVE] 无 token：{bare} ⇒ HTTP {s1} body={:?}", b1.chars().take(60).collect::<String>());
        assert_eq!(s1, 400, "★ 裸请求必须 400（否则前提变了，要看新读数）");

        let with_tok = api_url("/home");
        let (s2, b2) = get(with_tok.clone()).await.expect("带 token 请求应能拿到响应");
        eprintln!("[LIVE] 带 token：HTTP {s2} body={:?}", b2.chars().take(60).collect::<String>());
        assert_ne!(
            s2, 400,
            "★ 带 b() 三段后不该还是 400（那就是我们参数仍错）：{b2:?}"
        );
        match s2 {
            200 => eprintln!("[LIVE] ⇒ 上游活了，且接受了我们的 b() 三段"),
            417 | 500..=599 => {
                eprintln!("[LIVE] ⇒ 参数已过：{}", classify_upstream(s2, &b2))
            }
            other => eprintln!("[LIVE] ⇒ 新状态码 {other}（如实记录）"),
        }
    }
}
