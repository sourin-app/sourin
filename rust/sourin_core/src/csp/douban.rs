// ═══════════════════════════════════════════════════════════════════════
//  csp_Douban —— TVBox `csp_Douban` 的 Rust 重写（豆瓣推荐/榜单源）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么（实测取自 `.probe/ref-subscription.json`）
//
// ```json
// {"key":"豆瓣","name":"🔰豆瓣丨影视推荐","type":3,"api":"csp_Douban",
//  "indexs":1,"searchable":0}
// ```
// ⇒ **没有 ext**：站点写死 `frodo.douban.com`，`apikey` 也写死在类里
//   （`0ac44ae016490db2204ce0a042db2916`，DEX `<init>` 的常量）。
//
// # ★ 协议（反汇编复原 + 真网络实证，2026-10-27）
//
// ### ① 两个请求头集合（**不一样，不能混**）
// ```text
// A. 内容接口（home 预取的 subject_collection、list 的三类接口）
//    Host: frodo.douban.com
//    Connection: Keep-Alive
//    Referer: https://servicewechat.com/wx2f9b06c1de1ccfca/84/page-frame.html
//    User-Agent: Mozilla/5.0 (Windows NT 6.1; WOW64) … MicroMessenger/7.0.9.501
//                NetType/WIFI MiniProgramEnv/Windows WindowsWechat
//    ★ 实测：**缺 Referer/UA 就是 HTTP 400 / 154 字节**；带上 ⇒ 200 + 真数据
// B. 封面（`pic.normal`）—— DEX 在 URL 尾部拼了 `@Referer=https://api.douban.com/@User-Agent=<Chrome151>`
//    （TVBox 的"地址@头=值"约定）。本仓没有这种地址语法 ⇒ 见文件头「已知缺口 ③」。
// ```
//
// ### ② 八个分类（DEX homeContent 的两个字符串数组**按位对应**，逐字）
// ```text
// key                 name          请求形态
// hot_gaia            热门电影      /movie/hot_gaia?…&sort=&area=&start=&count=20        → items[]
// tv_hot              热播剧集      /subject_collection/tv_hot/items?…                 → subject_collection_items[]
// anime_hot           热门动漫      /tv/recommend?…&sort=&tags=动画                     → items[]
// show_hot            热播综艺      /subject_collection/show_hot/items?…               → subject_collection_items[]
// movie               电影筛选      /movie/recommend?…&sort=&tags=                         → items[]
// tv                  电视筛选      /tv/recommend?…&sort=&tags=                            → items[]
// rank_list_movie     电影榜单      /subject_collection/<榜单值>/items?…               → subject_collection_items[]
// rank_list_tv        电视剧榜单    /subject_collection/<榜单值>/items?…               → subject_collection_items[]
// ```
// ★ `homePage`（`/peizhi.json`）能裁剪分类：`homePage` 逗号分隔**只留列出的** key。
//   实测该文件**取不到**（见「上游可用性」）⇒ 按 DEX 的兜底：**全 8 个都上**
//   （DEX 里 `if (!TextUtils.isEmpty(homePage)) set.addAll(...)`，取不到就不裁剪）。
//
// ### ③ 三种条目形态（**字段名不同，必须分开认**）
// ```text
// 形态 1 `items[]`（hot_gaia / movie / tv recommend）
//     id / title / pic.normal / rating.value / card_subtitle
// 形态 2 `subject_collection_items[]`（tv_hot / show_hot / 各榜单）
//     id / title / pic.normal / rating.value / episodes_info / card_subtitle
// 形态 3 榜单里的条目可能只有 `cover_url`（无 `pic` 对象）—— DEX 里单独一条分支
// ```
//
// ★ **实证读数（2026-10-27 真打 frodo.douban.com，全部带上面 A 那组头）**
// ```text
// /movie/hot_gaia?…sort=recommend&area=全部&start=0&count=20  ⇒ 200 42266b items=**19** …
// /movie/recommend?…sort=T&tags=&start=0&count=20             ⇒ 200 20764b items=**9**   …
// /tv/recommend?…sort=T&tags=动画&start=0&count=20            ⇒ 200 57536b items=**20**  …
// /subject_collection/tv_hot/items?…&count=20                 ⇒ 200 42670b items=**20**
// /subject_collection/movie_real_time_hotest/items?…&count=10 ⇒ 200 22123b items=**10**
// ⚠️ 不带 Referer/UA ⇒ 400（实测 154 字节）
// ```
//
// # ⚠️ 已知缺口（如实登记，按契约"不许静默丢、不许自己造"）
//
// ```text
// ① ★★ `msearch:`（**宿主钩子，本仓无等价位**）
//    DEX 把每个条目的 id 拼成 **`msearch:<豆瓣id>`**，并在**每条**上都拼。
//    这是 TVBox 的约定：以 `msearch:` 开头的 id 表示"**宿主去按标题跨源搜索**"
//    （豆瓣本身不提供播放，它的详情/播放靠别的源搜同一个片名）。
//    实测本仓**没有任何地方处理 `msearch:` 前缀**（`grep -rn msearch rust/sourin_core/src/`
//    零命中）⇒ 若我们照抄前缀，`detail()` 会把 `msearch:12345` 原样发给上游 ⇒ 必错。
//    ⇒ 处置：`CspItem.id` 存**裸 id**（`detail()` 才可能用得上），
//       并在 `detail()` 里**手写 Err 说明这个缺口**（不假装能播）。
//    ⇒ **本仓无等价位，未实现**（按契约原话登记）。
//
// ② ★ `detailContent` / `playerContent` / `searchContent`：**DEX 里 Douban 就没有这三段**
//    （`.probe/decompiled/r3dex-spider.json` 的 methods 清单只有 init/homeContent/
//      categoryContent + 七个 process* + 三个私有工具 ⇒ **没有 detail/play/search**）。
//    这不是"我们没写"，而是**这个源本来就不提供**：它是推荐/榜单源，点进去要靠宿主的
//      `msearch:` 跨源找片。
//    ⇒ 三段都**手写结构化 Err**（点名"上游不提供 + 本仓无 msearch: 等价位"），
//       `supports_search() = false`。**不占位返回空**。
//
// ③ ★ 封面头（`@Referer=https://api.douban.com/@User-Agent=<Chrome151>`）
//    DEX 走的是 **TVBox 的"地址@头=值"约定**（把取图要用的头**写在 URL 尾巴上**）。
//    契约说 `loadPic` ⇒ 写进该源的 `cover_headers`（声明式）。
//    ⚠️ **但现在没有地方能写**：`CspProvider::new` 里 `cover_headers: Vec::new()` 是**写死**的
//      （`csp/provider.rs:118`），而 `CspSite` trait **没有** `cover_headers()` 这个方法
//      ⇒ 类**无法**声明自己的取图头。**这是契约缺的能力位**，已报 Lead。
//    ⇒ 本实现对 `cover` 返回**裸 URL**（不带 `@头=值` 尾巴 —— 带了本仓只会当成 URL 的一部分），
//      并在测试里钉住"不许把 `@Referer=…` 塞进 cover URL"。
//```

use async_trait::async_trait;
use serde_json::Value;

use super::{CspCategory, CspDetail, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `<init>` 里写死的 apikey
pub const APIKEY: &str = "0ac44ae016490db2204ce0a042db2916";

/// 内容接口的 UA（逐字来自 DEX `a()`，**不是**浏览器那种通用 UA）
pub const MSG_UA: &str = "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/53.0.2785.143 Safari/537.36 MicroMessenger/7.0.9.501 \
NetType/WIFI MiniProgramEnv/Windows WindowsWechat";

/// 内容接口的 Referer（逐字来自 DEX `a()`）
pub const MSG_REFERER: &str =
    "https://servicewechat.com/wx2f9b06c1de1ccfca/84/page-frame.html";

/// 内容接口 host（DEX `a()` 的 `Host` 头）
pub const MSG_HOST: &str = "frodo.douban.com";

/// 封面上要带的 `Referer`（DEX 把 `@Referer=https://api.douban.com/` 拼在 URL 尾部）
///
/// ★ 暴露成常量是为了让"契约缺口 ③"能被测试钉住：本仓没能力位，但**值不能丢**。
pub const COVER_REFERER: &str = "https://api.douban.com/";
/// 封面上要带的 UA（DEX 里拼在 `@User-Agent=` 后面）
pub const COVER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

const API: &str = "https://frodo.douban.com/rexxar/api/v2";

// ═══════════════════════════════════════════════════════════════════════
//  分类表（DEX homeContent 两个数组按位对应，逐字）
// ═══════════════════════════════════════════════════════════════════════

/// `(key, 显示名, 请求种类)` —— 请求种类决定打哪个端点、条目在哪个数组里
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// `/movie/hot_gaia` → `items[]`
    HotGaia,
    /// `/movie/recommend` → `items[]`
    MovieRec,
    /// `/tv/recommend` → `items[]`
    TvRec,
    /// `/subject_collection/{v}/items` → `subject_collection_items[]`
    Collection,
}

/// 八个分类，顺序即 DEX 里的数组顺序（菜单顺序）
pub const CATS: &[(&str, &str, Kind)] = &[
    ("hot_gaia", "热门电影", Kind::HotGaia),
    ("tv_hot", "热播剧集", Kind::Collection),
    ("anime_hot", "热门动漫", Kind::TvRec),
    ("show_hot", "热播综艺", Kind::Collection),
    ("movie", "电影筛选", Kind::MovieRec),
    ("tv", "电视筛选", Kind::TvRec),
    ("rank_list_movie", "电影榜单", Kind::Collection),
    ("rank_list_tv", "电视剧榜单", Kind::Collection),
];

/// 豆瓣默认值（DEX 里各 `process*` 的默认参数，逐字）
///
/// ```text
/// movie/hot_gaia  ⇒ sort=recommend, area=全部
/// movie|tv recommend、anime_hot ⇒ sort=T, tags=<分类相关>
/// subject_collection ⇒ 榜单值随分类而变（见 collection_value）
/// ```
pub const DEFAULT_SORT_HOT: &str = "recommend";
pub const DEFAULT_AREA: &str = "全部";
pub const DEFAULT_SORT_REC: &str = "T";

/// 榜单/合集类分类的**取值**（`rank_list_movie` / `rank_list_tv` 用 `q` 的 `榜单` 值）
///
/// # 为什么不写死第一个榜单值
/// ```text
/// DEX 里 `rank_list_movie` 的取值来自 `q`（筛选器 `榜单` 的 `value`），
/// 配置里默认是 `movie_real_time_hotest`；换筛选值就是另一个榜。
/// ⇒ 这里只在**没有 q** 时用 DEX 的默认值（实测 `movie_real_time_hotest` 200 + 10 条）。
/// ```
pub const DEFAULT_RANK: &str = "movie_real_time_hotest";

/// **电视剧榜单**的默认取值（★ 与 [`DEFAULT_RANK`] **不同**，DEX 里是另一项）
///
/// 实测该值可用：`/subject_collection/tv_real_time_hotest/items` ⇒ 200 + 真数据。
/// 若错用电影的榜单值 ⇒ 两个榜单会给出**同一份**电影数据（真网读数抓到过）。
pub const DEFAULT_RANK_TV: &str = "tv_real_time_hotest";

/// `anime_hot` 的固定 tags（DEX 里是硬编码的 `动画`）
pub const ANIME_TAGS: &str = "动画";

/// ★★ **合集类分类的默认取值是"按分类各自给"的** —— 两处都是门禁/真网读数逼出来的
///
/// # 依据（DEX homeContent 里那份筛选器 JSON 的 `value` 第一项）
/// ```text
/// tv_hot          ⇒ {n:"综合", v:"tv_hot"}                （默认就是自己的 key）
/// show_hot        ⇒ {n:"综合", v:"show_hot"}
/// rank_list_movie ⇒ {n:"实时热门电影", v:"movie_real_time_hotest"}
/// rank_list_tv    ⇒ {n:"实时热门电视", v:"tv_real_time_hotest"}   ← ★ 与电影**不同**
/// ```
/// # 两次都栽在同一个形态上（值得留档）
/// ```text
/// 第一版：一律用 movie_real_time_hotest
///   ⇒ ①「热播剧集」会拉到「实时热门电影」（点剧集出电影）
///   ⇒ ② 真网读数直接把 ② 打出来：两个榜单**首条完全相同**（都是「生日快乐」）
///      [LIVE] list(rank_list_movie / 电影榜单): 10 条 首=生日快乐
///      [LIVE] list(  rank_list_tv / 电视剧榜单): 10 条 首=生日快乐   ← 同一份数据
/// ★ 这类错的特点是"**有数据、不报错、只是错**" —— 只能靠"按分类比对预期"抓，
///   不能靠"请求成功没成功"抓。判据见 `collection_defaults_per_category`。
/// ```
/// 注入：让 `collection_value` 恒返回 `DEFAULT_RANK` ⇒ 该门禁红。
pub fn collection_value(tid: &str, tag: &str) -> String {
    let t = tag.trim();
    if !t.is_empty() {
        return t.to_string();
    }
    match tid {
        "tv_hot" | "show_hot" => tid.to_string(),
        "rank_list_tv" => DEFAULT_RANK_TV.to_string(),
        _ => DEFAULT_RANK.to_string(),
    }
}

/// 一个分类怎么打（返回 `(url, 条目所在键)`）
///
/// ★ `tag` 是分类侧可覆盖的值（如榜单值 / 筛选 tags）—— 来自 ext 的 `q`
pub fn request_of(tid: &str, page: u32, tag: &str) -> Option<(String, &'static str)> {
    let start = page.saturating_sub(1) * 20;
    let cat = CATS.iter().find(|(k, _, _)| *k == tid)?;
    let url = match cat.2 {
        Kind::HotGaia => {
            let area = if tag.trim().is_empty() { DEFAULT_AREA } else { tag.trim() };
            format!(
                "{API}/movie/hot_gaia?apikey={APIKEY}&sort={DEFAULT_SORT_HOT}\
                 &area={}&start={start}&count=20",
                urlencoding::encode(area)
            )
        }
        Kind::MovieRec => format!(
            "{API}/movie/recommend?apikey={APIKEY}&sort={DEFAULT_SORT_REC}\
             &tags={}&start={start}&count=20",
            urlencoding::encode(tag.trim())
        ),
        Kind::TvRec => {
            // `anime_hot` 固定 tags=动画（DEX 硬编码）；`tv` 走 `q` 给的 tags（可空）
            let tags = if tid == "anime_hot" {
                ANIME_TAGS.to_string()
            } else {
                tag.trim().to_string()
            };
            format!(
                "{API}/tv/recommend?apikey={APIKEY}&sort={DEFAULT_SORT_REC}\
                 &tags={}&start={start}&count=20",
                urlencoding::encode(&tags)
            )
        }
        Kind::Collection => {
            let v = collection_value(tid, tag);
            format!(
                "{API}/subject_collection/{}/items?apikey={APIKEY}&start={start}&count=20",
                urlencoding::encode(&v)
            )
        }
    };
    let key = match cat.2 {
        Kind::Collection => "subject_collection_items",
        _ => "items",
    };
    Some((url, key))
}

/// 首页预取的合集（DEX homeContent 的末尾：`subject_real_time_hotest`）
pub fn home_prefetch_url() -> String {
    format!("{API}/subject_collection/subject_real_time_hotest/items?apikey={APIKEY}")
}

// ═══════════════════════════════════════════════════════════════════════
//  解析（纯函数，全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// 从条目里取 id（**数字或字符串都认**；实测 `id` 两种形态都出现过）
pub fn id_of(o: &Value) -> Option<String> {
    let x = o.get("id")?;
    let s = if let Some(n) = x.as_i64() {
        n.to_string()
    } else {
        x.as_str()?.trim().to_string()
    };
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// 从条目里取封面（**三种形态**：`pic.normal` / `cover_url` / `images[0]`）
///
/// ★ 返回**裸 URL**：DEX 会在尾部拼 `@Referer=…@User-Agent=…`（TVBox 约定），
///   但本仓的地址不带这种语法 ⇒ 见文件头「已知缺口 ③」。
pub fn cover_of(o: &Value) -> Option<String> {
    if let Some(u) = o.get("pic").and_then(|p| p.get("normal")).and_then(|x| x.as_str()) {
        if !u.trim().is_empty() {
            return Some(u.trim().to_string());
        }
    }
    if let Some(u) = o.get("cover_url").and_then(|x| x.as_str()) {
        if !u.trim().is_empty() {
            return Some(u.trim().to_string());
        }
    }
    if let Some(a) = o.get("images").and_then(|x| x.as_array()) {
        if let Some(u) = a.iter().find_map(|x| x.as_str()).filter(|s| !s.trim().is_empty()) {
            return Some(u.trim().to_string());
        }
    }
    if let Some(a) = o.get("photos").and_then(|x| x.as_array()) {
        if let Some(u) = a.iter().find_map(|x| x.as_str()).filter(|s| !s.trim().is_empty()) {
            return Some(u.trim().to_string());
        }
    }
    None
}

/// 从条目里取"评分：<值>"备注（DEX 的 `评分：` + `rating.value`）
pub fn remark_of(o: &Value) -> Option<String> {
    if let Some(v) = o.get("rating").and_then(|r| r.get("value")) {
        let s = if let Some(f) = v.as_f64() {
            if f > 0.0 {
                format!("评分：{f}")
            } else {
                String::new()
            }
        } else {
            v.as_str()
                .filter(|s| !s.trim().is_empty() && *s != "0")
                .map(|s| format!("评分：{s}"))
                .unwrap_or_default()
        };
        if !s.is_empty() {
            return Some(s);
        }
    }
    // 退到 `card_subtitle`（实测大部分条目都有：`2026 / 中国大陆 / 犯罪 武侠 古装 / 刘文普`）
    o.get("card_subtitle")
        .or_else(|| o.get("episodes_info"))
        .and_then(|x| x.as_str())
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().to_string())
}

/// `items[]` / `subject_collection_items[]` → 条目；**0 条 ⇒ Err**
///
/// # 为什么必须 Err（铁律 149）
/// ```text
/// 豆瓣的"某分类今天没内容"与"上游改协议了"在**空数组**上长得一模一样。
/// ⇒ 空数组一律当错报出来（错误里带 key 名 + 数组长度 + 前几个顶层键），
///   而不是"成功返回 0 条"让用户看到一个永远空着的分类。
/// ```
pub fn items_of(v: &Value, key: &str, what: &str) -> Result<Vec<CspItem>, String> {
    let arr = v.get(key).and_then(|x| x.as_array()).ok_or_else(|| {
        format!(
            "上游 {what} 响应里没有 {key}（实际顶层键：{:?}）",
            v.as_object()
                .map(|o| o.keys().take(8).cloned().collect::<Vec<_>>())
                .unwrap_or_default()
        )
    })?;
    let mut out = Vec::new();
    for o in arr {
        let Some(id) = id_of(o) else { continue };
        let title = match o.get("title").and_then(|x| x.as_str()) {
            Some(t) if !t.trim().is_empty() => t.trim().to_string(),
            _ => match o.get("name").and_then(|x| x.as_str()) {
                Some(t) if !t.trim().is_empty() => t.trim().to_string(),
                _ => continue,
            },
        };
        // DEX 的 filterItemsWithoutPic：**没有图的条目直接丢**（豆瓣榜单里混着人物条目）
        let Some(cover) = cover_of(o) else { continue };
        out.push(CspItem {
            id,
            title,
            cover: Some(cover),
            subtitle: remark_of(o),
        });
    }
    if out.is_empty() {
        return Err(format!(
            "上游 {what} 的 {key} 解析出 0 条（{key} 有 {} 项）—— \
             上游改协议、或该分类当下确实没有带图的条目",
            arr.len()
        ));
    }
    Ok(out)
}

/// 从 ext 的 `q` 里取一个键的裸值（如 `榜单` / `tags` / `area`）
///
/// ⚠️ 刻意只做**裸键值**扫描：ext 可能是字符串也可能是对象，本仓契约是"原样文本"。
///
/// ★ 第一版只认 `key=` 与 `"key":"v"` 两种，**漏了 JSON 里常见的 `"key":"v"` 之外
///   那种"值在键后面隔着冒号"的形态**（实测喂 `{"tags":"动画"}` 返回 None ⇒ 门禁红）。
///   ⇒ 改为：先按分隔符切段，再在每段里找 `<key><sep><value>`，且**剥掉包围的引号**
///     与尾部标点。判据见 `q_value_scans_bare_keys`。
pub fn q_value(ext: &str, key: &str) -> Option<String> {
    let t = ext.trim();
    if t.is_empty() {
        return None;
    }
    for seg in t.split(['&', '?', '{', '}', ',']) {
        let s = seg.trim();
        if s.is_empty() {
            continue;
        }
        for sep in ['=', ':'] {
            let pat = format!("{key}{sep}");
            if let Some(rest) = s.strip_prefix(&pat) {
                // 剥掉包围的引号 + 去掉尾部可能的引号
                let v = rest.trim().trim_matches('"').trim().trim_end_matches('"').trim();
                if !v.is_empty() {
                    return Some(v.to_string());
                }
                // 该键存在但值为空 ⇒ 继续找下一个段（可能还有别处给了值）
            }
        }
        // 键在段中间（`…"tags":"动画"…` 被上面的 `,`/`{}"` 切过之后一般已经对齐，
        // 但 `:` 两侧带空格时 rest 会带前导空格 —— trim 已处理）
    }
    // 兜底：整段里直接找 `"key": "v"` / `key: v` 形态（容忍空格）
    let pat = format!("\"{key}\"");
    if let Some(pos) = t.find(&pat) {
        let after = &t[pos + pat.len()..];
        let after = after.trim_start();
        let after = after.strip_prefix(':').or_else(|| after.strip_prefix('='))?.trim();
        let v = after.trim_start_matches('"').split('"').next().unwrap_or("").trim();
        if !v.is_empty() {
            return Some(v.to_string());
        }
    }
    None
}

/// `homePage`（`/peizhi.json`）能裁剪分类：逗号分隔**只留列出的** key
///
/// 取不到 / 空 ⇒ **返回全部 8 个**（DEX 的兜底就是这个：`isEmpty` 就不裁剪）。
pub fn cats_of_homepage(home_page: &str) -> Vec<CspCategory> {
    let wanted: Vec<&str> = home_page
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    CATS.iter()
        .filter(|(k, _, _)| wanted.is_empty() || wanted.contains(k))
        .map(|(k, n, _)| CspCategory {
            id: k.to_string(),
            name: n.to_string(),
        })
        .collect()
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct Douban {
    client: reqwest::Client,
}

impl Douban {
    pub const CLASS: &'static str = "Douban";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            /*
             * ★ `.no_proxy()` —— 本仓 csp 的**既定惯例**（app3q/app99/app_drama/app_fox/
             *   app_qi/app_sy/app_yqk/app_ys … 都这么做），**我第一版全部漏了**。
             *
             * # 真网后果（HDMoli 那次实测抓到的根因，是**系统性问题**）
             * ```text
             * 本机 `https_proxy=http://127.0.0.1:7890/`（curl/reqwest/urllib 都会读它），
             * 而该代理对某些站点不通 ⇒
             *     reqwest 走代理      ⇒ `operation timed out`
             *     Python no-proxy     ⇒ **HTTP 200**
             *     Python via-proxy    ⇒ TLS 握手超时
             *   ⇒ 失败与"上游"无关，是"我们没绕开本机代理"。
             * ```
             * # 为什么 csp 类必须 `.no_proxy()`
             * ```text
             * ① 这些源是面向**公网直连**的（本机代理不是它们的依赖）；
             * ② 本仓既有 8 个类已这么做 ⇒ 不做就是**偏离惯例**；
             * ③ 装不装代理**不该改变 csp 源的行为**（否则用户装代理就一半源失效）。
             * ```
             */
            .no_proxy()
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self { client }
    }

    /// DEX `a()` 那组内容头（**缺了就是 400**，实测）
    async fn get_json(&self, url: &str) -> Result<Value, String> {
        let resp = self
            .client
            .get(url)
            .header("Host", MSG_HOST)
            .header(reqwest::header::CONNECTION, "Keep-Alive")
            .header(reqwest::header::REFERER, MSG_REFERER)
            .header(reqwest::header::USER_AGENT, MSG_UA)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(|e| format!("请求豆瓣失败（{url}）：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取豆瓣响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            let head = body.chars().take(80).collect::<String>();
            return Err(format!(
                "豆瓣返回 HTTP {status}（{url}）：{head} —— \
                 实测缺 Referer/UA 会 400，故这一组头是必需的"
            ));
        }
        serde_json::from_str(&body).map_err(|e| {
            format!(
                "豆瓣响应不是合法 JSON（{url}）：{e}；前 100 字：{}",
                body.chars().take(100).collect::<String>()
            )
        })
    }

    /// `/peizhi.json` 取 `homePage`（裁剪用）；取不到 ⇒ 空串（= 不裁剪）
    ///
    /// ⚠️ DEX 是**读本地文件** `/peizhi.json`（`merge.m.k.d/a` 那对 File API），
    ///    不是网络请求 —— 那是 TVBox 的"配置目录下放一个 peizhi.json 就能裁剪首页"的能力。
    ///    本仓**没有**等价的"每源本地配置文件"机制（无能力位）⇒ 这里如实留空，
    ///    即**全 8 个分类都上**（与 DEX 在文件缺失时的兜底**行为一致**）。
    fn home_page_of(_ext: &str) -> String {
        String::new()
    }
}

impl Default for Douban {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for Douban {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let categories = cats_of_homepage(&Self::home_page_of(ext));
        // 首页预取（DEX 末段：subject_real_time_hotest/items → subject_collection_items）
        let items = match self.get_json(&home_prefetch_url()).await {
            Ok(v) => items_of(&v, "subject_collection_items", "首页预取")
                .map(|l| l.into_iter().take(20).collect())
                .unwrap_or_default(),
            Err(_) => Vec::new(),
        };
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tag = q_value(ext, "榜单")
            .or_else(|| q_value(ext, "tag"))
            .or_else(|| q_value(ext, "tags"))
            .or_else(|| q_value(ext, "area"))
            .unwrap_or_default();
        let (url, key) = request_of(tid, page, &tag).ok_or_else(|| {
            format!(
                "未知分类 {tid:?}（本类只有这 8 个：{:?}）",
                CATS.iter().map(|(k, _, _)| *k).collect::<Vec<_>>()
            )
        })?;
        let v = self.get_json(&url).await?;
        let items = items_of(&v, key, &format!("分类 {tid} 第 {page} 页"))?;
        Ok(CspList {
            items,
            page,
            // 豆瓣这三类接口**不给总页数/total**（实测响应里没有）⇒ 如实 None，不编
            page_count: None,
            total: None,
        })
    }

    /// ★ **本类不支持搜索** —— DEX 里 Douban **没有** `searchContent`
    ///   （见文件头「已知缺口 ②」）。手写 Err 点名原因，不占位返回空。
    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("Douban 不支持搜索（上游类本来就不提供 searchContent：它是推荐/榜单源；\
             原实现是靠宿主 `msearch:` 钩子按标题跨源找片，本仓无该等价位）"
            .to_string())
    }

    fn supports_search(&self) -> bool {
        false
    }

    /// ★ **本类不提供详情** —— DEX 里 Douban **没有** `detailContent`
    ///   （见文件头「已知缺口 ①②」）。
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        Err(format!(
            "Douban 不提供详情（上游类没有 detailContent；它是推荐/榜单源，\
             条目 id={id:?} 在原实现里靠宿主 `msearch:` 钩子按标题跨源找片，\
             本仓无该等价位 ⇒ 本仓无等价位，未实现）"
        ))
    }

    /// ★ **本类不提供播放** —— DEX 里 Douban **没有** `playerContent`。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        Err(format!(
            "Douban 不提供播放（上游类没有 playerContent；它是推荐/榜单源，\
             条目 id={id:?} 在原实现里靠宿主 `msearch:` 钩子跨源找片，\
             本仓无该等价位 ⇒ 本仓无等价位，未实现）"
        ))
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册
// ═══════════════════════════════════════════════════════════════════════
crate::csp::register_site!(Douban);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// ★★ 八分类**按位对应**（DEX 两个数组的顺序），且三种请求形态不能混
    ///
    /// # 防的是什么
    /// ```text
    /// 两串 key 与 name 在 DEX 里是**两个相邻的数组字面量**，错位一格就会把
    /// "热门动漫"挂到 `tv_hot` 上 —— 现象是"点热门动漫出来剧集"（静默、很难查）。
    /// ```
    /// 注入：把 `CATS` 里任一项的顺序改掉 ⇒ 本条红。
    #[test]
    fn cats_are_positionally_paired() {
        assert_eq!(CATS.len(), 8);
        let pairs: Vec<(&str, &str)> = CATS.iter().map(|(k, n, _)| (*k, *n)).collect();
        assert_eq!(
            pairs,
            vec![
                ("hot_gaia", "热门电影"),
                ("tv_hot", "热播剧集"),
                ("anime_hot", "热门动漫"),
                ("show_hot", "热播综艺"),
                ("movie", "电影筛选"),
                ("tv", "电视筛选"),
                ("rank_list_movie", "电影榜单"),
                ("rank_list_tv", "电视剧榜单"),
            ],
            "★ key 与显示名必须按 DEX 的数组顺序逐位对应"
        );
        // 三个 recommend/hot_gaia 类走 items[]，四个 collection 类走 subject_collection_items[]
        let items_kind = CATS.iter().filter(|(_, _, k)| *k != Kind::Collection).count();
        assert_eq!(items_kind, 4, "hot_gaia/movie/tv/anime_hot 走 items[]");
        assert_eq!(8 - items_kind, 4, "tv_hot/show_hot/rank_* 走 subject_collection_items[]");
    }

    #[test]
    /// ★★ 请求形态：端点 + 条目键 + 实测参数（逐条对齐上面那份真网读数）
    ///
    /// 注入：把 `anime_hot` 的固定 `tags=动画` 去掉、或把 `Collection` 的键写成 `items`
    /// ⇒ 本条红。
    #[test]
    fn request_shape_matches_live_readings() {
        let (u, k) = request_of("hot_gaia", 1, "").unwrap();
        assert!(u.contains("/movie/hot_gaia?"), "{u}");
        assert!(u.contains("apikey=0ac44ae016490db2204ce0a042db2916"), "{u}");
        assert!(u.contains("sort=recommend"), "{u}");
        assert!(u.contains("area=%E5%85%A8%E9%83%A8"), "默认 area=全部 要编码：{u}");
        assert!(u.contains("start=0&count=20"), "{u}");
        assert_eq!(k, "items");

        let (u2, k2) = request_of("tv_hot", 1, "").unwrap();
        assert!(
            u2.contains("/subject_collection/tv_hot/items?"),
            "★ 合集类走 subject_collection，且默认值是该分类自己的 key：{u2}"
        );
        assert_eq!(k2, "subject_collection_items", "★ 合集类条目键不同：{k2}");

        let (u3, k3) = request_of("anime_hot", 1, "").unwrap();
        assert!(u3.contains("/tv/recommend?"), "{u3}");
        assert!(
            u3.contains("tags=%E5%8A%A8%E7%94%BB"),
            "★ anime_hot 的 tags 固定为「动画」（DEX 硬编码）：{u3}"
        );
        assert_eq!(k3, "items");

        // 榜单类用 tag（没给就用默认榜单值）
        let (u4, _) = request_of("rank_list_movie", 1, "").unwrap();
        assert!(u4.contains(&format!("/subject_collection/{DEFAULT_RANK}/items?")), "{u4}");
        let (u5, _) = request_of("rank_list_tv", 1, "").unwrap();
        assert!(
            u5.contains(&format!("/subject_collection/{DEFAULT_RANK_TV}/items?")),
            "★ 电视剧榜单的默认值要是 tv_real_time_hotest：{u5}"
        );
        let (u5b, _) = request_of("rank_list_tv", 1, "tv_chinese_best_weekly").unwrap();
        assert!(u5b.contains("/subject_collection/tv_chinese_best_weekly/items?"), "{u5b}");

        // ★★ 合集类的默认值**按分类而不同**（tv_hot/show_hot 用自己的 key）
        assert_eq!(collection_value("tv_hot", ""), "tv_hot");
        assert_eq!(collection_value("show_hot", ""), "show_hot");
        assert_eq!(collection_value("rank_list_movie", ""), DEFAULT_RANK);
        // 有 tag 就用 tag（换榜单）
        assert_eq!(collection_value("tv_hot", "tv_domestic"), "tv_domestic");
        let (u7, _) = request_of("show_hot", 1, "").unwrap();
        assert!(u7.contains("/subject_collection/show_hot/items?"), "{u7}");

        // 分页：start = (page-1)*20（实测 start= 是偏移量）
        let (u6, _) = request_of("hot_gaia", 3, "").unwrap();
        assert!(u6.contains("start=40&count=20"), "★ 第 3 页 ⇒ start=40：{u6}");

        // 未知分类 ⇒ None（由 list() 报错，不猜）
        assert!(request_of("不存在", 1, "").is_none());

        // 首页预取末尾那一条（DEX homeContent）
        assert!(
            home_prefetch_url()
                .contains("/subject_collection/subject_real_time_hotest/items?apikey="),
            "{}",
            home_prefetch_url()
        );
    }

    #[test]
    /// ★★ 反空真：`items` / `subject_collection_items` 解析出 0 条 ⇒ **必须 Err**
    ///
    /// 注入：把 `items_of` 的 `if out.is_empty()` 段删掉（改成 `Ok(out)`）⇒ 本条红。
    #[test]
    fn empty_items_are_an_error() {
        // 键名变了
        let wrong: Value = serde_json::from_str(r#"{"itmes":[{"id":1,"title":"x"}]}"#).unwrap();
        let e = items_of(&wrong, "items", "热门电影").expect_err("★ 键名变了必须 Err");
        assert!(e.contains("items"), "错误要点名缺的键：{e}");
        assert!(e.contains("itmes"), "错误要带回实际的顶层键便于定位：{e}");

        // 数组空
        let empty: Value = serde_json::from_str(r#"{"items":[]}"#).unwrap();
        let e2 = items_of(&empty, "items", "热门电影").expect_err("★ 0 条必须 Err");
        assert!(e2.contains("0 条"), "{e2}");

        // 有项但全没图（DEX 的 filterItemsWithoutPic 会把它们丢掉 ⇒ 结果仍是 0 条）
        let nopic: Value =
            serde_json::from_str(r#"{"items":[{"id":1,"title":"人物条目"}]}"#).unwrap();
        let e3 = items_of(&nopic, "items", "热门电影").expect_err("★ 全无图也必须 Err");
        assert!(e3.contains("0 条"), "{e3} → 这正是「空集恒真」的反面形态");
    }

    #[test]
    /// 真实条目形态（三种：`pic.normal` / `cover_url` / `images[]`）+ 评分备注
    fn parses_three_item_shapes() {
        // 形态 1：items[] 标准（实测 hot_gaia 的字段）
        let v1: Value = serde_json::from_str(
            r#"{"items":[{"id":"35724561","title":"怒刺","pic":{"normal":"https://img9/p1.jpg"},
                 "rating":{"value":4.6},"card_subtitle":"2026 / 中国大陆 / 犯罪 武侠 古装"},
                {"id":36675942,"title":"剧集A","pic":{"normal":"https://img9/p2.jpg"},
                 "rating":{"value":0},"card_subtitle":"2026 / 中国大陆 / 剧情"}]}"#,
        )
        .unwrap();
        let l = items_of(&v1, "items", "热门电影").unwrap();
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].id, "35724561", "★ id 是字符串形态");
        assert_eq!(l[0].title, "怒刺");
        assert_eq!(l[0].cover.as_deref(), Some("https://img9/p1.jpg"));
        assert_eq!(l[0].subtitle.as_deref(), Some("评分：4.6"));
        assert_eq!(
            l[1].subtitle.as_deref(),
            Some("2026 / 中国大陆 / 剧情"),
            "★ 评分为 0 ⇒ 退到 card_subtitle（不是「评分：0」）"
        );

        // 形态 2：subject_collection_items[]，id 是**数字**
        let v2: Value = serde_json::from_str(
            r#"{"subject_collection_items":[{"id":36675942,"title":"小城大事",
                 "pic":{"normal":"https://img3/p.jpg"},"episodes_info":"更新至第14集"}]}"#,
        )
        .unwrap();
        let l2 = items_of(&v2, "subject_collection_items", "热播剧集").unwrap();
        assert_eq!(l2[0].id, "36675942", "★ 数字 id 要转字符串");
        assert_eq!(l2[0].subtitle.as_deref(), Some("更新至第14集"));

        // 形态 3：榜单里的 cover_url
        let v3: Value = serde_json::from_str(
            r#"{"subject_collection_items":[{"id":1,"title":"榜单片",
                 "cover_url":"https://img1/c.jpg"}]}"#,
        )
        .unwrap();
        let l3 = items_of(&v3, "subject_collection_items", "电影榜单").unwrap();
        assert_eq!(l3[0].cover.as_deref(), Some("https://img1/c.jpg"), "★ 退到 cover_url");

        // 形态 3b：photos[]
        let v4: Value = serde_json::from_str(
            r#"{"items":[{"id":"2","title":"照片片","photos":["https://img/p.jpg"]}]}"#,
        )
        .unwrap();
        assert_eq!(
            items_of(&v4, "items", "x").unwrap()[0].cover.as_deref(),
            Some("https://img/p.jpg")
        );
    }

    #[test]
    /// ★★ 封面必须是**裸 URL** —— 不许把 TVBox 的 `@Referer=…@User-Agent=…` 尾巴塞进去
    ///
    /// # 为什么这条必须钉
    /// ```text
    /// DEX 确实往 cover 尾部拼了那串（TVBox 的"地址@头=值"约定）。
    /// 但**本仓的地址不带这种语法** ⇒ 照抄会把 `…jpg@Referer=https://api.douban.com/@…`
    /// 整串当成 URL 去请求 ⇒ 必然 404。而现象只是"封面不显示"（静默）。
    /// ★ 正确做法是走 `cover_headers`（声明式），但**本仓缺这个能力位**（已报 Lead）。
    /// ```
    /// 注入：给 `cover_of` 的返回值接上 `format!("{u}@Referer=…")` ⇒ 本条红。
    #[test]
    fn cover_is_a_bare_url_without_tvbox_header_suffix() {
        let v: Value = serde_json::from_str(
            r#"{"items":[{"id":"1","title":"x","pic":{"normal":"https://img9/p.jpg"}}]}"#,
        )
        .unwrap();
        let c = items_of(&v, "items", "x").unwrap()[0].cover.clone().unwrap();
        assert_eq!(c, "https://img9/p.jpg");
        assert!(!c.contains('@'), "★ 不许带 @ 尾巴（本仓没有那个地址语法）：{c}");
        assert!(!c.contains("Referer"), "★ 不许把 Referer 拼进 URL：{c}");

        // 值本身不能丢 —— 它现在只能挂在常量上（等能力位）
        assert_eq!(COVER_REFERER, "https://api.douban.com/");
        assert!(COVER_UA.contains("Chrome/151"), "逐字是 Chrome151 那条：{COVER_UA}");
        // 并在源码里登记"缺能力位"这件事（防止将来被当成"忘了写"）
        let src = include_str!("douban.rs");
        assert!(
            src.contains("cover_headers"),
            "★ 必须登记缺的是 cover_headers 这个能力位"
        );
    }

    /// ★★ 三段"上游不提供"必须**手写 Err**（不是 `Ok(空)`），能力位必须是 false
    ///
    /// DEX 依据：Douban 的 methods 清单里**没有** detailContent/playerContent/searchContent。
    /// 注入：把任一段改成 `Ok(Default::default())` ⇒ 本条红。
    ///
    /// ⚠️ 用 `#[tokio::test]` 时**不能**再叠 `#[test]`。
    #[tokio::test]
    async fn unsupported_segments_error_instead_of_returning_empty() {
        let s = Douban::new();
        assert!(!s.supports_search(), "★ 不提供搜索 ⇒ 能力位必须 false");

        let e1 = s.search("庆余年", 1, "").await.expect_err("★ 搜索必须 Err");
        assert!(e1.contains("不支持搜索"), "{e1}");
        assert!(e1.contains("msearch"), "要点名真实原因（本仓无 msearch: 等价位）：{e1}");

        let e2 = s.detail("35724561", "").await.expect_err("★ 详情必须 Err");
        assert!(e2.contains("不提供详情"), "{e2}");
        assert!(e2.contains("35724561"), "错误要带上 id 便于定位：{e2}");
        assert!(e2.contains("无等价位"), "要点名缺口：{e2}");

        let e3 = s.play("", "35724561", "").await.expect_err("★ 播放必须 Err");
        assert!(e3.contains("不提供播放"), "{e3}");
    }

    #[test]
    /// `homePage` 裁剪：空 ⇒ 全 8 个；给了逗号列表 ⇒ 只留列出的（且**保持 CATS 顺序**）
    fn homepage_trims_categories_in_order() {
        assert_eq!(cats_of_homepage("").len(), 8, "★ 取不到 peizhi ⇒ 全上（DEX 兜底）");
        let three = cats_of_homepage("movie,tv,hot_gaia");
        assert_eq!(three.len(), 3);
        assert_eq!(
            three.iter().map(|c| c.id.clone()).collect::<Vec<_>>(),
            vec!["hot_gaia", "movie", "tv"],
            "★ 顺序按 CATS，不按 homePage 里写的顺序"
        );
        // 全是空白 ⇒ 视作没给
        assert_eq!(cats_of_homepage("  , ,  ").len(), 8);
        // 写了个不存在的 key ⇒ 只留匹配上的（不报错、不猜）
        assert_eq!(cats_of_homepage("不存在的key").len(), 0);
    }

    #[test]
    /// ★★ 合集类的默认取值**按分类而不同** —— 门禁打出来的真缺口（第一版全用榜单默认值）
    ///
    /// # 防的是什么
    /// ```text
    /// DEX homeContent 里 `tv_hot` 的筛选器第一项是 `{n:"综合", v:"tv_hot"}`、
    /// `show_hot` 是 `{n:"综合", v:"show_hot"}` ⇒ 默认值**就是分类自己的 key**。
    /// 第一版一律用 `movie_real_time_hotest` ⇒ **「热播剧集」会拉到「实时热门电影」**
    /// （现象是"点剧集出电影"，静默、很难查）。
    /// ```
    /// 注入：让 `collection_value` 恒返回 `DEFAULT_RANK` ⇒ 本条红。
    #[test]
    fn collection_defaults_per_category() {
        assert_eq!(collection_value("tv_hot", ""), "tv_hot", "★ 剧集用 tv_hot");
        assert_eq!(collection_value("show_hot", ""), "show_hot", "★ 综艺用 show_hot");
        assert_eq!(
            collection_value("rank_list_movie", ""),
            DEFAULT_RANK,
            "榜单没给 q 时用实测可用的默认值"
        );
        assert_eq!(
            collection_value("rank_list_tv", ""),
            DEFAULT_RANK_TV,
            "★ 电视剧榜单要用**电视**的榜单值（真网读数曾把两个榜单打成同一份电影数据）"
        );
        assert_ne!(
            collection_value("rank_list_movie", ""),
            collection_value("rank_list_tv", ""),
            "★ 两个榜单的默认值不该相同 —— 相同就会返回同一份数据"
        );
        assert_ne!(DEFAULT_RANK, DEFAULT_RANK_TV);
        assert_eq!(DEFAULT_RANK_TV, "tv_real_time_hotest");
        assert_eq!(
            collection_value("tv_hot", "tv_domestic"),
            "tv_domestic",
            "ext 给了值就用给的"
        );
        assert_ne!(
            collection_value("tv_hot", ""),
            collection_value("rank_list_movie", ""),
            "★ 两者不该相同（第一版就是这个问题）"
        );
    }

    #[test]
    /// ext 的 `q` 值扫描（`榜单` 等）
    fn q_value_scans_bare_keys() {
        assert_eq!(q_value("", "榜单"), None);
        assert_eq!(q_value("榜单=movie_top250", "榜单").as_deref(), Some("movie_top250"));
        assert_eq!(
            q_value(r#"{"q":"a=1&榜单=tv_global_best_weekly&b=2"}"#, "榜单").as_deref(),
            Some("tv_global_best_weekly")
        );
        assert_eq!(q_value(r#"{"tags":"动画"}"#, "tags").as_deref(), Some("动画"));
        assert_eq!(q_value("榜单=", "榜单"), None, "空值视作没给");
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_douban -- --ignored --nocapture"]
    async fn csp_live_douban_home_and_all_categories() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = Douban::new();
        let home = s.home("").await.expect("home 应成功");
        eprintln!(
            "[LIVE] home: 分类 {} 个，预取 {} 条（首={}）",
            home.categories.len(),
            home.items.len(),
            home.items.first().map(|i| i.title.clone()).unwrap_or_default()
        );
        assert_eq!(home.categories.len(), 8);
        let mut ok = 0;
        for c in &home.categories {
            match s.list(&c.id, 1, "").await {
                Ok(l) => {
                    ok += 1;
                    eprintln!("[LIVE] list({:>14} / {}): {} 条 首={}", c.id, c.name, l.items.len(), l.items[0].title);
                }
                Err(e) => eprintln!("[LIVE] list({}) 如实失败：{e}", c.id),
            }
        }
        eprintln!("[LIVE] 八分类通了 {ok}/8");
        assert!(ok >= 6, "★ 至少 6 个分类要能真取到数据（实测 8/8）");
    }
}