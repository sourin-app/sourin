// ═══════════════════════════════════════════════════════════════════════
//  csp_Config —— 「网盘配置中心」（**工具类，不是内容源**；本批不注册）
// ═══════════════════════════════════════════════════════════════════════
//
// # 一、这个类在配置里是什么
//
// ```text
// 订阅（`.probe/ref-subscription.json` 逐字）：
//   {"key":"配置中心","name":"📥网盘丨配置中心","type":3,"api":"csp_Config",
//    "searchable":0,"changeable":0,"indexs":0,"style":{"type":"oval"}}
// ⇒ 它在订阅里是**一条设置入口**（`searchable:0` / `changeable:0` / `indexs:0`，
//   连"能不能换源/能不能当首页"都被关掉了），不是一个片库。
// ```
//
// # 二、判定：**工具类**（依据是 DEX 的方法体，不是名字）
//
// 类 `com.github.catvod.spider.Config`，父类 `crawler.Spider`，**34 个方法**。
// 证据来自 `.probe/csp-parity/Config.txt` + `r3_disasm_v2.py` 的逐方法反汇编（**未起 jadx**）。
//
// ```text
// ① homeContentOld 返回的是**设置菜单**（DEX 里那条 JSON 逐字）：
//      {"网盘账号信息":"quark","网盘配置登录":"uc","网盘配置清除":"baidu",
//       "网盘画质设置":"xunlei","网盘线程设置":"guangya","其他设置":"other"}
//    ⇒ 6 个 key 是**菜单标题**，6 个 value 是**菜单 id**。没有一条是影片。
//
// ② homeContent = homeContentOld + `Cfg115.home(...)`（一个 115 状态模块），
//    依旧没有 vod 列表。
//
// ③ categoryContentOld 的产物是**网盘账号卡片**（id / 标题 / 封面图 / cookie 文件）：
//      alipan  → BlockAli     阿里云盘       /peizhi.json（读 panBlock 开关）
//      quark   → newquark     夸克个人中心   /quark_cookie.txt
//      （同形状还有 newuc newbaidu new123 newxunlei newaliyun new189 newguangya /
//        newbili —— 见下面 PAN_CARDS，9 张全逐字）
//    ⇒ 卡片点下去是「登录/清除/开关」，**不是**选集。
//
// ④ `action(String)` 的实现是 `Init.execute(Runnable)` 然后返回空串
//    ⇒ 它是**副作用动作**（改设置），不是"取一集内容"。
//
// ⑤ 34 个方法里，一半是 `get*Options()`：读**本地** `/peizhi.json` 的
//    `quarkQuality` / `ucQuality` / `baiduQuality` / `123Quality` 等字段，
//    把 `"夸克原画|夸克普画"` 这种串拆成画质选项列表；另有 `enableUpdateCheck` /
//    `disableUpdateCheck` / `is1314GoProxyActive` 之类。
//    ⇒ 全部是**本机读写 + 宿主 UI**，没有自己的远程内容端点。
// ```
//
// ★ 结论（三条判据里第 ③ 条不成立，而且不是"暂时取不到"，是**没有内容可取**）：
// ```text
// 本仓的源契约只有四件事：分类 / 列表 / 详情 / 取流（`CspSite`）。
// 而本类提供的是「设置页」：菜单 + 卡片 + 副作用动作 + 本地配置读写。
// ⇒ 硬把它包成 CspSite = 造一个"点进去全是设置项"的假源；
//   所以：**不写 `register_site!`**，六方法逐条给可读 Err（说清它到底是什么）。
// ```
//
// # 三、真正可移植的部分（已实现成**纯函数**，可离线测）
//
// ```text
// · SETTINGS_MENU  —— DEX 那条菜单 JSON，6 项逐字（顺序也照抄：Android 的
//                     JSONObject 用 LinkedHashMap 保序）
// · PAN_CARDS      —— 9 张网盘卡片：卡片 id / 标题 / 该卡读的本地 cookie 文件名（逐字）
// · quality_options —— get*Options() 的解析逻辑：把 `画质A|画质B` 拆成有序列表，
//                      空串/全空 ⇒ 回落到默认值（DEX 里默认是 `夸克原画` 一类）
// ⇒ 这三样是"原版到底怎么组织设置页"的事实，将来若宿主长出设置页，直接接这三个。
// ```
//
// # 四、真网读数：**未取证**（原因如下，不是"没跑"）
//
// ```text
// 本类**没有任何远程端点**：
//   · home/category 读的是本地 `/peizhi.json` + `/quark_cookie.txt` 等（Android 私有目录）
//   · action 走宿主 UI 线程
//   · 唯一的网络动作是**登录流程**，而登录是 WebView + 用户扫码/输入（原版交给宿主），
//     不是"一个可复现的 HTTP 接口"
// ⇒ 没有"直连打一次拿 JSON"这种读数可写。本轮**如实登记为未取证**，
//   并把判断依据（上面 ①–⑤）当证据 —— 判定"它没有内容端点"本身是可以复核的。
//
// ★ 唯一一项**可打**的网络行为（不是取内容，是探活）：
//   `is1314GoProxyActive()` → `GET http://127.0.0.1:5266/api/ping`，body 严格等于 `ok` ⇒ true。
//   它是**本机回环**地址（本机转发服务的健康检查），不是远程端点；
//   本仓没有这个转发服务 ⇒ 真网读数必然是"连不上"，且那是**我们没装**，不是"站点死"。
//   读数与结论写在 `.probe/parity-infra-live.log`。
// ```
//
// # 五、契约边界（本仓纪律）
//
// ```text
// · 本文件**不建 HTTP client**（一次请求都没有；探活那条也只保留成常量 + 纯函数，
//   不在这里发请求）⇒ 不存在 `.no_proxy()` 的问题；
//   这一点有单测钉住（`no_http_client_so_no_proxy_rule_does_not_apply`），
//   免得 reviewer/门禁以为我漏了那一行。
// · 用户可见文案：不用 `**` 强调（用「」），不写具体站点名。
// · 不新增依赖（Cargo.toml 零 diff）。
// ```

use async_trait::async_trait;

use super::{CspDetail, CspHome, CspItem, CspList, CspPlay, CspSite};

pub const CLASS: &str = "Config";

/// 首页菜单（DEX `homeContentOld` 里那条 JSON，**逐字**；顺序即插入顺序）
///
/// ```text
/// {"网盘账号信息":"quark","网盘配置登录":"uc","网盘配置清除":"baidu",
///  "网盘画质设置":"xunlei","网盘线程设置":"guangya","其他设置":"other"}
/// ```
/// 左边＝菜单标题，右边＝菜单 id（原版点进去按 id 走不同设置页）。
pub const SETTINGS_MENU: &[(&str, &str)] = &[
    ("网盘账号信息", "quark"),
    ("网盘配置登录", "uc"),
    ("网盘配置清除", "baidu"),
    ("网盘画质设置", "xunlei"),
    ("网盘线程设置", "guangya"),
    ("其他设置", "other"),
];

/// 一张网盘账号卡片（DEX `categoryContentOld` 里 `c.e(id, 标题, 封面, 副标题)` 的 id/标题/文件）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PanCard {
    /// 卡片 id（点它触发的动作键）
    pub card_id: &'static str,
    /// 卡片标题（逐字）
    pub title: &'static str,
    /// 这张卡读的**本地** cookie/配置文件（Android 私有目录下的文件名，逐字）
    pub cookie_file: &'static str,
}

/// 9 张网盘卡片（DEX 逐字）
///
/// # tid → 卡片 的**归组**我没有硬写
/// ```text
/// 原版是 per-tid 的 if 链（`equals("alipan")` / `equals("quark")` …）。
/// 只有 `alipan`、`quark` 两个分支的字面量在常量池里能直接对到（其余 tid 的
/// `equals` 实参复用了池里的其它同形串）。
/// ⇒ 按纪律：**能确证的写，推断的不写**。这里只给"有哪些卡片、每张读哪个文件"，
///   不给"哪个 tid 出哪张卡" —— 后者对宿主没用（我们没有设置页），写错反而误人。
/// ```
pub const PAN_CARDS: &[PanCard] = &[
    PanCard {
        card_id: "BlockAli",
        title: "阿里云盘",
        cookie_file: "/peizhi.json",
    },
    PanCard {
        card_id: "newquark",
        title: "夸克个人中心",
        cookie_file: "/quark_cookie.txt",
    },
    PanCard {
        card_id: "newuc",
        title: "UC个人中心",
        cookie_file: "/uc_cookie.txt",
    },
    PanCard {
        card_id: "newbaidu",
        title: "百度个人中心",
        cookie_file: "/baidu.txt",
    },
    PanCard {
        card_id: "new123",
        title: "123个人中心",
        cookie_file: "/cloud123.txt",
    },
    PanCard {
        card_id: "newxunlei",
        title: "迅雷个人中心",
        cookie_file: "/xunlei.txt",
    },
    PanCard {
        card_id: "newaliyun",
        title: "阿里个人中心",
        cookie_file: "/.aliyun",
    },
    PanCard {
        card_id: "new189",
        title: "天翼个人中心",
        cookie_file: "/cloud189.txt",
    },
    PanCard {
        card_id: "newguangya",
        title: "光鸭个人中心",
        cookie_file: "/guangya.txt",
    },
];

/// 菜单 → 条目列表（id＝菜单 id，标题＝菜单标题）
///
/// 它**不是**给 CspSite 用的（`home()` 会 Err）；这是"原版首页长什么样"的可测事实。
pub fn menu_items() -> Vec<CspItem> {
    SETTINGS_MENU
        .iter()
        .map(|(title, tid)| CspItem {
            id: (*tid).to_string(),
            title: (*title).to_string(),
            cover: None,
            subtitle: None,
        })
        .collect()
}

/// 本机转发服务的探活地址（DEX `is1314GoProxyActive()` 逐字）
///
/// # 它是什么（也是本仓的一个已知缺口）
/// ```text
/// 原版用 `GET http://127.0.0.1:5266/api/ping`，body 严格等于 "ok" 就认为
/// 「本机转发服务在跑」（返回值 true）。
/// ⇒ 这是本类**唯一**的网络行为：不是取内容，是问"本机的转发服务活着吗"。
/// ★ 本仓没有这个转发服务（`pan_web_share.rs` 里也写着同一件事），所以真网读数
///   必然是"连不上" —— 那是**我们这边没装**，不是"上游站点死"（两件事不许混）。
/// ```
pub const PROXY_PING: &str = "http://127.0.0.1:5266/api/ping";
/// 探活成功的**严格**应答体（DEX 里就是字符串比较，不是 JSON 解析）
pub const PROXY_PONG: &str = "ok";

/// 菜单 id / 网盘 tid → 显示名（DEX `n(String)` 逐字：quark→夸克、uc→UC、其余→阿里）
pub fn pan_label_of(tid: &str) -> &'static str {
    let t = tid.trim();
    if t.starts_with("quark") {
        "夸克"
    } else if t.starts_with("uc") {
        "UC"
    } else {
        "阿里"
    }
}

/// `get*Options()` 的解析逻辑：`"夸克原画|夸克普画"` → 有序两项
///
/// # 与 DEX 的对应
/// ```text
/// 原版逐个 `equals("夸克原画")` / `equals("夸克原画|夸克普画")` …
/// 效果等价于：按 `|` 切开、去空、去重保序；**空串/全空 ⇒ 回落默认值**
/// （原版末尾那条 `add('夸克原画')` 就是默认值，见反汇编 124–139）。
/// 这里写成通用纯函数，供任何网盘复用（原版是 9 个近乎重复的方法）。
/// ```
pub fn quality_options(raw: &str, default: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for part in raw.split('|') {
        let p = part.trim();
        if p.is_empty() {
            continue;
        }
        if !out.iter().any(|x| x == p) {
            out.push(p.to_string());
        }
    }
    if out.is_empty() {
        let d = default.trim();
        if !d.is_empty() {
            out.push(d.to_string());
        }
    }
    out
}

pub struct Config;

impl Config {
    pub const CLASS: &'static str = CLASS;

    pub fn new() -> Self {
        Self
    }
}

impl Default for Config {
    fn default() -> Self {
        Self::new()
    }
}

/// 统一的"这不是内容源"文案（**用户可见**：不用 `**`，用「」）
fn not_a_source(seg: &str) -> String {
    format!(
        "「配置中心」不是内容源：它在本软件里是网盘账号、画质、线程等设置的入口\
         （原版的首页返回的是 6 项设置菜单，不是影片列表），没有可播放的内容。\
         本仓的源契约只有「分类 / 列表 / 详情 / 取流」，没有设置页这一层 ⇒ {seg} 不提供数据。\
         设置类功能需要宿主自己的设置页，不在源契约里。"
    )
}

#[async_trait]
impl CspSite for Config {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 不实现：原版首页是**设置菜单**，不是分类表/影片
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        Err(not_a_source("首页"))
    }

    async fn list(&self, _tid: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(not_a_source("分类列表"))
    }

    async fn detail(&self, _id: &str, _ext: &str) -> Result<CspDetail, String> {
        Err(not_a_source("详情"))
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(not_a_source("搜索"))
    }

    fn supports_search(&self) -> bool {
        // ★ 订阅里本来就是 `searchable:0`；声明 true 会让这个"源"被拉进搜索，每次都 Err
        false
    }

    async fn play(&self, _flag: &str, _id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        Err(not_a_source("取流"))
    }
}

// ══ ⚠️ **没有 `register_site!`** ══
//
// 判定：工具类（设置页）。注册 = 在源列表里多加一条"点进去全是设置项"的假源，
// 而 `state.rs` 现在会把**每个注册类**变成用户可见的一条源 ⇒ 不注册。
// 若将来宿主补上"设置页/推送入口"，可接的三样是：`SETTINGS_MENU` / `PAN_CARDS` /
// `quality_options`（都已有单测）。

#[cfg(test)]
mod tests {
    use super::*;

    // ── ① 事实层：菜单 / 卡片 / 画质解析（全部 DEX 逐字，离线可测）──

    #[test]
    fn settings_menu_is_the_dex_json_verbatim() {
        assert_eq!(SETTINGS_MENU.len(), 6, "DEX 那条 JSON 正好 6 个 key");
        assert_eq!(
            SETTINGS_MENU,
            &[
                ("网盘账号信息", "quark"),
                ("网盘配置登录", "uc"),
                ("网盘配置清除", "baidu"),
                ("网盘画质设置", "xunlei"),
                ("网盘线程设置", "guangya"),
                ("其他设置", "other"),
            ]
        );
        // 菜单 id 不重复（重复会让两项点出同一个设置页）
        let mut ids: Vec<&str> = SETTINGS_MENU.iter().map(|(_, id)| *id).collect();
        ids.sort_unstable();
        let n = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), n);
    }

    #[test]
    fn menu_items_carry_the_menu_ids() {
        let items = menu_items();
        assert_eq!(items.len(), 6);
        assert_eq!(items[0].id, "quark");
        assert_eq!(items[0].title, "网盘账号信息");
        assert_eq!(items[5].id, "other");
        assert!(items.iter().all(|i| i.cover.is_none()), "设置项没有封面");
    }

    #[test]
    fn pan_cards_are_nine_and_point_at_local_cookie_files() {
        assert_eq!(PAN_CARDS.len(), 9, "DEX 里 9 张账号卡");
        // 卡片 id 唯一（否则一次点击会触发两个动作）
        let mut ids: Vec<&str> = PAN_CARDS.iter().map(|c| c.card_id).collect();
        ids.sort_unstable();
        let n = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), n, "卡片 id 重复");
        // 每条 cookie_file 都是**本机路径**，不是 http 地址（这是"工具类"的关键证据）
        for c in PAN_CARDS {
            assert!(
                c.cookie_file.starts_with('/'),
                "{} 的配置应是本机文件名：{}",
                c.card_id,
                c.cookie_file
            );
            assert!(
                !c.cookie_file.starts_with("http"),
                "{} 不该指向网络地址",
                c.card_id
            );
        }
        // 抽两条逐字核对（DEX 常量池里能直接对上的）
        let q = PAN_CARDS.iter().find(|c| c.card_id == "newquark").unwrap();
        assert_eq!(q.title, "夸克个人中心");
        assert_eq!(q.cookie_file, "/quark_cookie.txt");
        let a = PAN_CARDS.iter().find(|c| c.card_id == "BlockAli").unwrap();
        assert_eq!(a.cookie_file, "/peizhi.json");
    }

    #[test]
    fn pan_label_follows_the_dex_prefix_rules() {
        // DEX `n(String)`：startsWith("quark")→夸克；startsWith("uc")→UC；其余→阿里
        assert_eq!(pan_label_of("quark"), "夸克");
        assert_eq!(pan_label_of("quark_cookie"), "夸克");
        assert_eq!(pan_label_of("uc"), "UC");
        assert_eq!(pan_label_of("uc_token"), "UC");
        assert_eq!(pan_label_of("aliyun"), "阿里");
        assert_eq!(pan_label_of(""), "阿里", "认不出就是兜底值（DEX 也是这么 return 的）");
        // 全部菜单 id 都能得到非空标签（设置页不会出现空白名）
        for (_, tid) in SETTINGS_MENU {
            assert!(!pan_label_of(tid).is_empty(), "{tid} 应有显示名");
        }
    }

    #[test]
    fn proxy_probe_constants_are_the_dex_literals() {
        // 唯一"会发请求"的行为：本机转发服务探活（不是取内容）
        assert_eq!(PROXY_PING, "http://127.0.0.1:5266/api/ping");
        assert_eq!(PROXY_PONG, "ok", "DEX 里是字符串严格比较，不是 JSON");
        // 它是**本机**地址：这正是"本类没有远程内容端点"的又一条证据
        assert!(PROXY_PING.contains("127.0.0.1"), "必须是本机回环地址");
    }

    #[test]
    fn quality_options_splits_and_dedups_in_order() {
        assert_eq!(
            quality_options("夸克原画|夸克普画", "夸克原画"),
            vec!["夸克原画".to_string(), "夸克普画".to_string()]
        );
        // 顺序颠倒也要原样保留（原版对 `普画|原画` 也有一条专门分支）
        assert_eq!(
            quality_options("夸克普画|夸克原画", "夸克原画"),
            vec!["夸克普画".to_string(), "夸克原画".to_string()]
        );
        // 单值
        assert_eq!(quality_options("夸克无限", "夸克原画"), vec!["夸克无限".to_string()]);
        // 重复项只留一份
        assert_eq!(
            quality_options("A|A|B", "A"),
            vec!["A".to_string(), "B".to_string()]
        );
        // 空 ⇒ 回落默认值（原版末尾那条 add 就是默认值）
        assert_eq!(quality_options("", "夸克原画"), vec!["夸克原画".to_string()]);
        assert_eq!(quality_options("  |  ", "夸克原画"), vec!["夸克原画".to_string()]);
        // 默认值也空 ⇒ 空列表（不编一条假选项）
        assert!(quality_options("", "").is_empty());
    }

    // ── ② 契约层：六方法**必须** Err，且文案说清"它是什么"（不许静默空列表）──

    #[tokio::test]
    async fn every_segment_says_this_is_not_a_content_source() {
        let s = Config::new();
        for (seg, e) in [
            ("首页", s.home("").await.err()),
            ("分类", s.list("1", 1, "").await.err()),
            ("详情", s.detail("1", "").await.err()),
            ("搜索", s.search("x", 1, "").await.err()),
            ("取流", s.play("", "1", "").await.err()),
        ] {
            let msg = e.unwrap_or_else(|| panic!("{seg} 必须 Err（工具类没有内容可取）"));
            assert!(msg.contains("不是内容源"), "{seg} 文案要说明性质：{msg}");
            assert!(msg.contains("配置中心"), "{seg} 文案要点名它是什么：{msg}");
            assert!(
                !msg.contains("**"),
                "{seg} 是用户可见文案，不许用 ** 强调：{msg}"
            );
        }
    }

    #[test]
    fn search_is_declared_unsupported() {
        assert!(!Config::new().supports_search(), "订阅里就是 searchable:0");
    }

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Config::CLASS, "Config");
    }

    // ── ③ 不注册：问**运行时**注册表，不读源码里有没有那行 ──

    #[test]
    fn must_not_register_this_batch() {
        assert!(
            !crate::csp::is_implemented("csp_Config"),
            "★ 工具类不注册（注册 = 用户能看到一条点进去全是设置项的假源）"
        );
        // 反面：源码里也不许出现注册那一行（去掉注释与测试段后再判，避免自伤）
        let flat = crate::csp::shared::impl_src_only(include_str!("config.rs"));
        let needle = format!("register_site!({})", "Config");
        assert!(!flat.contains(&needle), "★ 不许写注册行");
    }

    // ── ④ 本文件一次 HTTP 都不发 ⇒ `.no_proxy()` 这条判据不适用（说明而不是漏写）──

    #[test]
    fn no_http_client_so_no_proxy_rule_does_not_apply() {
        let src = crate::csp::shared::impl_src_only(include_str!("config.rs"));
        // ★ 判据不能引用被测对象：针的名字用拼接，避免本函数自己的字面量把判据喂饱
        let needle = format!("Client::{}", "builder");
        assert!(
            !src.contains(&needle),
            "★ 本类不该建 client；若将来真要发请求，必须补 .timeout() 后的 .no_proxy()"
        );
        assert!(
            !src.contains(".timeout("),
            "★ 没有 client 就不该有 timeout —— 出现它说明有人加了网络请求却没加代理纪律"
        );
    }
}
