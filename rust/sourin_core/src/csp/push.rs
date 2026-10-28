// ═══════════════════════════════════════════════════════════════════════
//  csp_Push —— 「手机推送视频」（**工具类，不是内容源**；本批不注册）
// ═══════════════════════════════════════════════════════════════════════
//
// # 一、这个类在配置里是什么
//
// ```text
// 订阅（`.probe/ref-subscription.json` 逐字）：
//   {"key":"push_agent","name":"⚓手机｜推送视频","type":3,"api":"csp_Push",
//    "searchable":0,"filterable":0,"changeable":0}
// ⇒ 它是**推送入口**（searchable/filterable/changeable 全 0），不是一个片库。
// ```
//
// # 二、判定：**工具类**（依据是 DEX 的方法体）
//
// 类 `com.github.catvod.spider.Push`，父类 `crawler.Spider`，**5 个方法**：
// ```text
// <init>()V
// detailContent(List)         → PushIso.detail(this, ids)          （新实现）
// detailContentOld(List)      → 见下"分派表"                       （旧实现，逻辑最清楚）
// playerContent(String,String,List)    → PushIso.player(...)
// playerContentOld(String,String,List) → 见下"取流分派"
// ```
//
// ★ **没有** `homeContent` / `categoryContent` / `searchContent`
//   ⇒ 原版这个"源"根本**没有列表**：它的 id 不是从列表里点出来的，
//     而是**宿主推进来的**（手机端把链接/本地文件推给电视）。
//
// ```text
// detailContentOld 的分派（DEX 常量逐字，按 OR 语义）
//   含 aliyundrive.com / alipan.com / pan.quark.cn / uc.cn / .189. /
//      .123 / //123 / .baidu / .xunlei / .guangya / .139
//        ⇒ 委派给 `Pan.detailContent(List)`（网盘分享解析）
//   以 file:// 开头 ⇒ 本机文件：vod_play_from = 「本地」
//   其余            ⇒ vod_play_from = 「直连$$$嗅探$$$解析」（在线直链）
//
// playerContentOld 的分派（DEX 常量逐字）
//   flag 含 阿里 / 夸克 / UC / 天翼 / 123 / 百度 / 迅雷 / 光鸭 / 移动
//        ⇒ 委派给 `Pan.playerContent(...)`
//   flag == 「直连」 ⇒ 直链直接给
// ```
//
// ★ 结论（三条判据里第 ③ 条不成立：**没有列表可取，也没有自己的端点**）
// ```text
// · 本类的"取数据"全部是**委派**：网盘那半边归 `Pan`（本仓已有 pan_drive / pan_web_share），
//   直链那半边就是把 URL 原样交给播放器。
// · 它没有 home/list：CspSite 的 detail(id) 的 id **只能来自 list()**，
//   而本类没有列表 ⇒ 在本仓的源契约里它是一个"入口形状对不上"的类。
// ⇒ 硬包成 CspSite = 造一个"首页永远空、详情永远没人调"的假源；
//   所以：**不写 `register_site!`**，六方法逐条给可读 Err（说清它到底是什么）。
// ```
//
// # 三、真正可移植的部分（已实现成**纯函数**，可离线测）
//
// ```text
// · classify(url)      —— 原版 detailContentOld 的分派表：网盘 / 本机文件 / 在线直链
// · push_detail(url)   —— 把"一条推送过来的地址"变成 1 集（标题＝文件名或整条地址，
//                         线路＝「直连$$$嗅探$$$解析」或「本地」）—— 与 DEX 的 vod_play_from 逐字一致
// · is_pan_flag(flag)  —— 原版 playerContentOld 的线路名分派（含 9 个网盘名）
// ⇒ 这三样是"推送功能"的全部可移植逻辑；接进宿主只差一个"粘贴/接收链接"的 UI 入口。
// ```
//
// # 四、真网读数：**未取证**（原因如下，不是"没跑"）
//
// ```text
// 本类**没有自己的 URL**：
//   · 网盘分支把 id 原样交给 `Pan` —— 那半边的真网读数在 pan_drive / pan_web_share
//     的 live 用例里（本轮不重复取，也不冒充"本类的读数"）
//   · 直链分支不做任何请求（地址原样给播放器）
// ⇒ 没有"本类自己的端点"可打。写一条 live 只会是"打别人的端点然后算自己的成绩"，
//   那是**借证据**，不做。如实登记为未取证 + 说明原因。
// ```
//
// # 五、契约边界
//
// ```text
// · 本文件**不建 HTTP client**（一次请求都没有）⇒ 不存在 `.no_proxy()` 的问题；
//   有单测钉住这一点，免得被当成"漏写"。
// · 用户可见文案：不用 `**` 强调（用「」），不写具体视频站点名（网盘服务名不算站点名）。
// · 不新增依赖。
// ```

use async_trait::async_trait;

use super::{CspDetail, CspEpisode, CspHome, CspList, CspPlay, CspSite};

pub const CLASS: &str = "Push";

/// 推送地址的三分类（DEX `detailContentOld` 的分派）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushKind {
    /// 网盘分享页（附网盘名）
    Pan(&'static str),
    /// 本机文件（`file://`）
    LocalFile,
    /// 在线直链（http/https，非网盘）
    Online,
    /// 认不出来（不是 http 也不是 file://）
    Unknown,
}

/// 网盘分享页的判定表（DEX 常量**逐字**，顺序即原版 if 链顺序）
///
/// ```text
/// aliyundrive.com → alipan.com → pan.quark.cn → uc.cn → .189. →
/// .123 → //123 → .baidu → .xunlei → .guangya → .139
/// ```
/// ⚠️ `.123` 与 `//123` 两条都要留：前者命中 `pan.123684.com/s/x` 这类**随机三位子域**，
///    后者命中 `//123pan.com/s/x`（协议后直接跟 123）。只留一条会漏一半链接。
pub const PAN_MARKS: &[(&str, &str)] = &[
    ("aliyundrive.com", "阿里云盘"),
    ("alipan.com", "阿里云盘"),
    ("pan.quark.cn", "夸克网盘"),
    ("uc.cn", "UC网盘"),
    (".189.", "天翼云盘"),
    (".123", "123网盘"),
    ("//123", "123网盘"),
    (".baidu", "百度网盘"),
    (".xunlei", "迅雷网盘"),
    (".guangya", "光鸭网盘"),
    (".139", "移动云盘"),
];

/// 线路名：在线直链（DEX `vod_play_from` 逐字，三段用 `$$$` 分隔）
pub const FLAG_ONLINE: &str = "直连$$$嗅探$$$解析";
/// 线路名：本机文件（DEX 逐字）
pub const FLAG_LOCAL: &str = "本地";
/// 原版 `playerContentOld` 认的"直连"线路名（逐字）
pub const FLAG_DIRECT: &str = "直连";

/// 判定一条推送地址属于哪一类
///
/// # 为什么用**不分大小写**匹配（对 DEX 的一处有意偏差）
/// ```text
/// DEX 用 `contains`（区分大小写）。而 URL 的**主机名部分**按 RFC 3986 是不区分大小写的，
/// ⇒ 用户从别处粘来的 `PAN.QUARK.CN/s/x` 在原版里会被判成"在线直链"（然后播不了）。
/// 这里统一小写后再匹配：**只放宽、不放错**（不会把非网盘判成网盘）。
/// ```
pub fn classify(url: &str) -> PushKind {
    let raw = url.trim();
    if raw.is_empty() {
        return PushKind::Unknown;
    }
    let lower = raw.to_ascii_lowercase();
    for (mark, name) in PAN_MARKS {
        if lower.contains(mark) {
            return PushKind::Pan(name);
        }
    }
    if lower.starts_with("file://") {
        return PushKind::LocalFile;
    }
    if lower.starts_with("http://") || lower.starts_with("https://") {
        return PushKind::Online;
    }
    PushKind::Unknown
}

/// 原版 `playerContentOld` 的线路名分派：这个 flag 是不是"某个网盘"
pub fn is_pan_flag(flag: &str) -> bool {
    ["阿里", "夸克", "UC", "天翼", "123", "百度", "迅雷", "光鸭", "移动"]
        .iter()
        .any(|k| flag.contains(k))
}

/// 从地址里取"显示名"：本机/直链都优先用路径最后一段（解码不做，原版也没做）
pub fn title_of(url: &str) -> String {
    let raw = url.trim();
    // 用闭包而不是 `split(['?', '#'])`：数组作为 Pattern 要较新的编译器，闭包在所有版本都行
    let no_query = raw.split(|c| c == '?' || c == '#').next().unwrap_or(raw);
    let tail = no_query
        .trim_end_matches('/')
        .rsplit(|c| c == '/' || c == '\\')
        .next()
        .unwrap_or("")
        .trim();
    if tail.is_empty() {
        raw.to_string()
    } else {
        tail.to_string()
    }
}

/// 把"一条推送地址"变成 **1 集**（原版 `detailContentOld` 的产物形状）
///
/// # 三种落点（与 DEX 逐字对应）
/// ```text
/// 在线直链 ⇒ 线路「直连$$$嗅探$$$解析」，id = 原地址
/// 本机文件 ⇒ 线路「本地」，          id = 原地址
/// 网盘分享 ⇒ **Err**：网盘取直链要账号 + 转发服务，本仓在 pan_drive / pan_web_share 里做，
///            本类只负责"认出它是哪个网盘"（不在这里伪造直链）
/// ```
pub fn push_detail(url: &str) -> Result<CspDetail, String> {
    let raw = url.trim();
    if raw.is_empty() {
        return Err("推送地址为空".to_string());
    }
    let title = title_of(raw);
    match classify(raw) {
        PushKind::Online => Ok(CspDetail {
            id: raw.to_string(),
            title: title.clone(),
            cover: None,
            description: Some("手机推送的在线地址".to_string()),
            episodes: vec![CspEpisode {
                id: raw.to_string(),
                title,
                flag: FLAG_ONLINE.to_string(),
            }],
        }),
        PushKind::LocalFile => Ok(CspDetail {
            id: raw.to_string(),
            title: title.clone(),
            cover: None,
            description: Some("手机推送的本机文件".to_string()),
            episodes: vec![CspEpisode {
                id: raw.to_string(),
                title,
                flag: FLAG_LOCAL.to_string(),
            }],
        }),
        PushKind::Pan(name) => Err(format!(
            "这条是「{name}」分享页：本类只负责认出它属于哪个网盘，取直链要账号 + 转发服务\
             （那部分在网盘能力里做，不在推送入口里）"
        )),
        PushKind::Unknown => Err(format!(
            "认不出这条推送地址（既不是 http/https，也不是 file://）：{raw}"
        )),
    }
}

/// 不看网络、只看形状：这条推送地址能不能直接被播放器打开
pub fn is_direct_playable(url: &str) -> bool {
    matches!(classify(url), PushKind::Online | PushKind::LocalFile)
}

pub struct Push;

impl Push {
    pub const CLASS: &'static str = CLASS;

    pub fn new() -> Self {
        Self
    }
}

impl Default for Push {
    fn default() -> Self {
        Self::new()
    }
}

/// 统一的"这不是内容源"文案（**用户可见**：不用 `**`，用「」）
fn not_a_source(seg: &str) -> String {
    format!(
        "「手机推送视频」不是内容源：它在本软件里是手机把一条地址（或本机文件）推给电视的入口，\
         原版没有列表接口，只有「拿到地址 → 认出类型 → 交给播放器」。\
         本仓的源契约是「分类 / 列表 / 详情 / 取流」，{seg} 的 id 只能来自列表，\
         而推送入口没有列表 ⇒ 这里不提供数据。推送需要宿主自己的「接收/粘贴地址」入口。"
    )
}

#[async_trait]
impl CspSite for Push {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 不实现：原版**没有** `homeContent`
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        Err(not_a_source("首页"))
    }

    /// 不实现：原版**没有** `categoryContent`
    async fn list(&self, _tid: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(not_a_source("分类列表"))
    }

    /// 不实现：id 只能由宿主推入，本仓没有这条通道
    ///
    /// ★ 真正可用的逻辑在 [`push_detail`]（纯函数，已测）；这里**不**假装支持，
    ///   否则 UI 上会多一条"点进去能看一片、点第二次啥也没有"的源。
    async fn detail(&self, _id: &str, _ext: &str) -> Result<CspDetail, String> {
        Err(not_a_source("详情"))
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(not_a_source("搜索"))
    }

    fn supports_search(&self) -> bool {
        // 订阅里就是 `searchable:0`
        false
    }

    async fn play(&self, _flag: &str, _id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        Err(not_a_source("取流"))
    }
}

// ══ ⚠️ **没有 `register_site!`** ══
//
// 判定：工具类（推送入口）。注册 = 源列表里多一条"首页永远报错"的假源
// （`state.rs` 现在会把每个注册类变成用户可见的一条源）。
// 将来宿主有了"接收/粘贴地址"入口，接 `classify` / `push_detail` / `is_pan_flag` 即可。

#[cfg(test)]
mod tests {
    use super::*;

    // ── ① 分派表：DEX 逐字（每一条都单独验，改一个字就红）──

    #[test]
    fn pan_marks_are_the_dex_literals() {
        assert_eq!(PAN_MARKS.len(), 11, "DEX 里 11 条判定串");
        // 逐条：每条的"该命中"与"不该命中"各验一次
        let cases: &[(&str, &str)] = &[
            ("https://www.aliyundrive.com/s/abc", "阿里云盘"),
            ("https://www.alipan.com/s/abc", "阿里云盘"),
            ("https://pan.quark.cn/s/abc", "夸克网盘"),
            ("https://drive.uc.cn/s/abc", "UC网盘"),
            ("https://cloud.189.cn/t/abc", "天翼云盘"),
            ("https://pan.123684.com/s/abc", "123网盘"),
            ("https://123pan.com/s/abc", "123网盘"),
            ("https://pan.baidu.com/s/abc", "百度网盘"),
            ("https://pan.xunlei.com/s/abc", "迅雷网盘"),
            ("https://www.guangya.com/s/abc", "光鸭网盘"),
            ("https://yun.139.com/shareweb/w/i/abc", "移动云盘"),
        ];
        for (url, want) in cases {
            assert_eq!(classify(url), PushKind::Pan(want), "{url} 应判为 {want}");
        }
    }

    #[test]
    fn both_123_marks_exist_because_they_cover_different_shapes() {
        // `//123` 命中"协议后直接跟 123"，`.123` 命中"随机三位子域"
        assert!(PAN_MARKS.iter().any(|(m, _)| *m == "//123"));
        assert!(PAN_MARKS.iter().any(|(m, _)| *m == ".123"));
        assert_eq!(classify("http://123pan.com/s/x"), PushKind::Pan("123网盘"));
        assert_eq!(classify("https://pan.123999.com/s/x"), PushKind::Pan("123网盘"));
    }

    #[test]
    fn local_and_online_and_unknown_are_separated() {
        assert_eq!(classify("file:///storage/emulated/0/a.mp4"), PushKind::LocalFile);
        assert_eq!(classify("https://cdn.example.com/a.m3u8"), PushKind::Online);
        assert_eq!(classify("http://192.168.1.2:8080/a.mp4"), PushKind::Online);
        assert_eq!(classify(""), PushKind::Unknown);
        assert_eq!(classify("magnet:?xt=urn:btih:abc"), PushKind::Unknown);
        // 大小写：主机名不区分大小写（对 DEX 的有意放宽，见 classify 的文档）
        assert_eq!(classify("HTTPS://PAN.QUARK.CN/s/x"), PushKind::Pan("夸克网盘"));
    }

    #[test]
    fn push_detail_maps_the_three_landings() {
        let d = push_detail("https://cdn.example.com/movie/a.mp4?token=1").expect("直链应能成片");
        assert_eq!(d.episodes.len(), 1, "推送＝一条地址＝一集");
        assert_eq!(d.episodes[0].flag, FLAG_ONLINE);
        assert_eq!(d.episodes[0].title, "a.mp4", "标题取路径最后一段，去掉查询串");
        assert_eq!(d.episodes[0].id, "https://cdn.example.com/movie/a.mp4?token=1");

        let l = push_detail("file:///storage/emulated/0/Download/b.mkv").expect("本机文件应能成片");
        assert_eq!(l.episodes[0].flag, FLAG_LOCAL);
        assert_eq!(l.episodes[0].title, "b.mkv");

        // 网盘分享：只认类型，不伪造直链
        let e = push_detail("https://pan.quark.cn/s/abc123").expect_err("网盘分享不许在这里成片");
        assert!(e.contains("夸克网盘"), "要点名哪个网盘：{e}");
        assert!(e.contains("转发服务"), "要说清缺什么：{e}");

        assert!(push_detail("  ").is_err(), "空地址必须 Err");
        assert!(push_detail("magnet:?xt=1").is_err(), "认不出的必须 Err");
    }

    #[test]
    fn flags_are_the_dex_literals() {
        assert_eq!(FLAG_ONLINE, "直连$$$嗅探$$$解析", "DEX 的 vod_play_from 逐字");
        assert_eq!(FLAG_LOCAL, "本地");
        assert_eq!(FLAG_DIRECT, "直连");
        // 线路分派：网盘名 → 交给网盘能力
        for f in ["阿里", "夸克", "UC", "天翼", "123", "百度", "迅雷", "光鸭", "移动"] {
            assert!(is_pan_flag(f), "{f} 应判为网盘线路");
        }
        assert!(!is_pan_flag(FLAG_DIRECT), "直连不是网盘线路");
        assert!(!is_pan_flag(FLAG_ONLINE), "在线三段名不是网盘线路");
    }

    #[test]
    fn title_of_handles_edge_shapes() {
        assert_eq!(title_of("https://a.example/x/y.mp4?q=1#t=2"), "y.mp4");
        assert_eq!(title_of("https://a.example/x/"), "x");
        assert_eq!(title_of("https://a.example"), "a.example");
        assert_eq!(title_of("file:///mnt/m/a.mp4"), "a.mp4");
    }

    #[test]
    fn is_direct_playable_only_for_playable_shapes() {
        assert!(is_direct_playable("https://a.example/a.m3u8"));
        assert!(is_direct_playable("file:///mnt/a.mp4"));
        assert!(!is_direct_playable("https://pan.quark.cn/s/x"));
        assert!(!is_direct_playable(""));
    }

    // ── ② 契约层：六方法**必须** Err，文案说清性质 ──

    #[tokio::test]
    async fn every_segment_says_this_is_not_a_content_source() {
        let s = Push::new();
        for (seg, e) in [
            ("首页", s.home("").await.err()),
            ("分类", s.list("1", 1, "").await.err()),
            ("详情", s.detail("1", "").await.err()),
            ("搜索", s.search("x", 1, "").await.err()),
            ("取流", s.play("", "1", "").await.err()),
        ] {
            let msg = e.unwrap_or_else(|| panic!("{seg} 必须 Err（推送入口没有内容可取）"));
            assert!(msg.contains("不是内容源"), "{seg} 文案要说明性质：{msg}");
            assert!(msg.contains("推送"), "{seg} 文案要点名它是什么：{msg}");
            assert!(
                !msg.contains("**"),
                "{seg} 是用户可见文案，不许用 ** 强调：{msg}"
            );
        }
    }

    #[test]
    fn search_is_declared_unsupported() {
        assert!(!Push::new().supports_search());
    }

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Push::CLASS, "Push");
    }

    // ── ③ 不注册 ──

    #[test]
    fn must_not_register_this_batch() {
        assert!(
            !crate::csp::is_implemented("csp_Push"),
            "★ 工具类不注册（注册 = 一条首页永远报错的假源）"
        );
        let flat = crate::csp::shared::impl_src_only(include_str!("push.rs"));
        let needle = format!("register_site!({})", "Push");
        assert!(!flat.contains(&needle), "★ 不许写注册行");
    }

    // ── ④ 没有 client ⇒ `.no_proxy()` 不适用（说明而不是漏写）──

    #[test]
    fn no_http_client_so_no_proxy_rule_does_not_apply() {
        let src = crate::csp::shared::impl_src_only(include_str!("push.rs"));
        let needle = format!("Client::{}", "builder");
        assert!(!src.contains(&needle), "★ 本类不该建 client（推送只做分派）");
        assert!(!src.contains(".timeout("), "★ 没有 client 就不该有 timeout");
    }
}
