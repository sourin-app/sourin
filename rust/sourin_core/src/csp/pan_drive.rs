// ═══════════════════════════════════════════════════════════════════════
//  csp_PanQuark / csp_PanUC —— 夸克 / UC 网盘（**一份实现，两份数据**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这两家能合并（task-15 普查的结论，有实测依据）
//
// ```text
// R3-A 普查（`.probe/r3-decompile-survey.md` 表⑤）：
//   · 两类的**协议特有方法集逐字相同**：(action, isBusy, setBusy)
//   · override 集合也相同：(<init>, detailContent, init)
//   · 静态常量**都没有** ⇒ 差异确实只在「地址 + 参数」
//  ⇒ 这是 본批扫描出的**唯一高置信可归并对**。
// ```
//
// # ★ 数据外置（Owner 的"插件化"约束要求，也是合并的**唯一前提**）
//
// ```text
// 参考实现里两家的 `homeContent` 各自**写死**一串分享 ID：
//   PanQuark: [{"name":"我的夸克网盘","folders":[{"shareId":"","folder":"0"}]},
//              {"name":"软件商店下载","folders":[{"shareId":"756ffcc6f734",…}]},
//              {"name":"电影4K-iso原盘",…}]
//   PanUC   : 同形但**串不同**（"我的UC网盘"/"动漫"/"电影"…）
// ⇒ 若把这些串抄进代码，两家的差异就变成**两份代码**（没法合并，且用户改不了）。
// ⇒ 本实现把它们做成 `PanDriveSpec` 的 `shelves` 字段（**数据**），
//    代码只有一份 ⇒ 这正是 Owner 要的「一个实现 + N 份配置」。
// ```
//
// # 取证来源（行为层，逐字取端点；**不抄 Java**）
//
// ```text
// `.probe/r3c-dexstrings.py` 解的 dex 方法体字符串常量：
//   夸克（merge/b/w）：share 详情 / 文件列表 / 转存 / 下载 / dl-token 等
//   UC  （merge/b/B）：同形，host 换成 pc-api.uc.cn、pr=UCBrowser
// 完整清单：`.probe/r3c-pan-dexstrings.log`
// ```
//
// # ⚠️ 诚实边界（**不许当已交付的承诺**）
//
// ```text
// · 取数需要**登录态**（cookie）—— 两家都有逐字的"还未登录…"提示（见 `LOGIN_HINT`）。
//   本实现在无 cookie 时**如实报错**，绝不返回空列表冒充成功。
// · cookie 由 `pan_auth` 从系统钥匙串读（写由 `pan_login` 的扫码链路负责）。
// · **实网读数尚缺**（需要 Owner 真账号）⇒ 本文件里的端点/参数**取自参考实现，未真跑通**。
//   凡是没验过的，注释里都标了"未验"。
// · 播放需要"转发服务"把 Referer/Cookie 带上 —— 本仓有 `streamproxy::register(url, headers)`
//   等价能力，但**尚未实测**接通（未验）。
// ```
//
// # 为什么 `supports_search() == false`（硬依据，不是省事）
//
// ```text
// 订阅里这两站都是 `"searchable":0`（`.probe/ref-subscription.json`）。
// 而 `registry.rs:287` 用 `capabilities.search` 决定"要不要把这个源拉进搜索"
//   ⇒ 若这里返 true，用户搜任何词都会多打一轮**注定失败**的请求。
// ⇒ 返 false，并在 `search()` 里如实报"本类不支持搜索"（不占位返回空）。
// ```

use async_trait::async_trait;
use std::time::Duration;

use crate::pan::PanKind;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 无 cookie 时的提示 —— **逐字取自参考实现**（用户可见文案属行为层，应与原版一致）
fn login_hint(kind: PanKind) -> String {
    match kind {
        PanKind::Quark => "还未登录夸克账号,请前往【配置中心】登录".to_string(),
        PanKind::Uc => "还未登录UC账号,请前往【配置中心】登录".to_string(),
        other => format!("还未登录{}账号，请前往【配置中心】登录", other.display()),
    }
}

/// 一个"货架"（首页上的一组分享）
///
/// # 为什么用 `share_id` + `folder` 两个字段
/// ```text
/// 参考实现的 homeContent JSON 里正是这两个键：
///   {"name":"…","folders":[{"shareId":"…","folder":"0"}]}
/// ⇒ 照它的**数据形状**（那是上游协议的一部分），但**位置**从"代码里的字符串"
///   换到"数据里的字段"（Owner 要的可配置形态）。
/// ```
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Shelf {
    /// 货架名（用户看到的分组名，如"软件商店下载"）
    pub name: String,
    /// 分享 id（空串 = "我的网盘根目录"，参考实现里"我的夸克网盘"那项就是空）
    pub share_id: String,
    /// 分享内的子目录 id（"0" = 根）
    pub folder: String,
}

/// 一家网盘的**数据**（代码一份，本结构多份）
#[derive(Debug, Clone)]
pub struct PanDriveSpec {
    pub kind: PanKind,
    /// API 根（夸克 `drive-pc.quark.cn` / UC `pc-api.uc.cn`）
    pub api_host: &'static str,
    /// 各家固定的 query 前缀（`pr=ucpro&fr=pc` vs `pr=UCBrowser&fr=pc`）
    pub pr_fr: &'static str,
    /// 每页条数（**两家不同**：夸克 50 / UC 200 —— 逐字来自参考实现）
    ///
    /// # 为什么要做成字段而不是常量
    /// ```text
    /// 我第一版写死 200（那是 UC 的值）⇒ 夸克那边**参数不是逐字**。
    /// 这类"跨盘参数串了"**不会报错**（接口照样返回），只是结果集大小不符 ⇒ **难查**。
    /// ⇒ 让它在数据里，与其它差异并列（这样"差异全在数据"这句话才成立）。
    /// ```
    pub page_size: u32,
    /// 首页货架清单（**数据**，不是代码里的字符串常量）
    pub shelves: Vec<Shelf>,
    /// 分享页 host（拼分享 URL 用）
    pub share_host: &'static str,
}

/// 夸克的默认数据
///
/// ★ 货架清单**逐字取自参考实现**的 `homeContent` 常量（那是上游给的内容，
///   属于"数据"而非"逻辑"）⇒ 用户可以用 `pan_drive_spec_set` 覆盖。
pub fn quark_spec() -> PanDriveSpec {
    PanDriveSpec {
        kind: PanKind::Quark,
        api_host: "drive-pc.quark.cn",
        pr_fr: "pr=ucpro&fr=pc",
        page_size: 50, // ★ 夸克：参考实现用 50
        share_host: "https://pan.quark.cn",
        shelves: vec![
            Shelf {
                name: "我的夸克网盘".into(),
                share_id: String::new(),
                folder: "0".into(),
            },
            Shelf {
                name: "软件商店下载".into(),
                share_id: "756ffcc6f734".into(),
                folder: "0".into(),
            },
        ],
    }
}

/// UC 的默认数据（同形、不同串 —— 这正是"两份数据"的意义）
pub fn uc_spec() -> PanDriveSpec {
    PanDriveSpec {
        kind: PanKind::Uc,
        api_host: "pc-api.uc.cn",
        pr_fr: "pr=UCBrowser&fr=pc",
        page_size: 200, // ★ UC：参考实现用 200
        share_host: "https://drive.uc.cn",
        shelves: vec![
            Shelf {
                name: "我的UC网盘".into(),
                share_id: String::new(),
                folder: "0".into(),
            },
            Shelf {
                name: "软件商店下载".into(),
                share_id: "ba2e2f0417114".into(),
                folder: "0".into(),
            },
        ],
    }
}

/// 一次 HTTP 的预算（网盘接口偶发慢；8s 是"还能忍"的上限）
const HTTP_TIMEOUT: Duration = Duration::from_secs(8);

/// ★★★ 临时转存的**专用目录名**（2026-10-29 Owner 明确要求）
///
/// # Owner 原话
/// ```text
/// 「这些网盘我都还要用，都放在根目录我就没办法用了」
/// ```
/// 改前：`share/sharepage/save` 的 `to_pdir_fid` 写死 `"0"`（= 网盘根目录）
/// ⇒ 每播一次就往用户根目录扔一个视频文件，播完删（失败就留），
///    用户自己的文件全被顶到后面去了。
///
/// # 为什么用**固定名字**而不是带设备 id
/// ```text
/// ① 同一账号多机登录时，共用一个 `sourin-temp` 才不会在根目录堆出
///    `sourin-temp-abc`/`sourin-temp-def` 一串目录（那正是用户抱怨的形态）；
/// ② 清理只删**我们自己记下的 fid**（`temp_saved()`），不整目录清空 ⇒
///    两台机器各删各的，不会互删正在播的文件；
/// ③ 参考实现用的也是固定名（dex 实证 `Quarktemp` / `UCtemp`，见
///    `mkdir_*` 的取证注释）—— 固定名是这条路线的既有惯例。
/// ```
/// ⚠️ 刻意**不复用**参考实现的名字（`Quarktemp`/`UCtemp`）：
///    那是原版客户端的目录，混用会让"我们没清掉的残留"和"原版的"分不清。
pub const TEMP_DIR_NAME: &str = "sourin-temp";

/// 建目录的 URL（**纯函数**；dex 实证：`merge.b.w.m`(夸克) / `merge.b.B.m`(UC)）
///
/// ```text
/// 夸克：https://drive-pc.quark.cn/1/clouddrive/file?pr=ucpro&fr=pc
/// UC  ：https://pc-api.uc.cn/1/clouddrive/file?pr=UCBrowser&fr=pc
/// ```
/// ★★ **不是** `file/mkdir` —— 真网实测该路径 **HTTP 404**
///    （`{"status":404,"error":"Not Found","path":"/1/clouddrive/file/mkdir"}`）；
///    而 `POST .../clouddrive/file` 在有体、无 cookie 时回 **401
///    `{"code":31001,"message":"require login [guest]"}`** ⇒ 路由存在、只缺登录。
///    原始请求/响应见 `.probe/pan-mkdir-live.md`。
fn mkdir_url(spec: &PanDriveSpec) -> String {
    format!("{}/1/clouddrive/file?{}", api_root(spec), spec.pr_fr)
}

/// API 根（`https://<api_host>`；生产恒此形，逐字节同旧实现）
///
/// ★ 测试缝（N-23018 v2 假网盘夹具）：`cfg!(test)` 运行时判别 —— 夹具把根
/// 换成 `http://127.0.0.1:<port>`（drive API 明文 JSON，本地 TCP 可回放）。
/// 实现与存储都在**文件尾的测试缝块**（share_referer 门禁按首个测试 cfg
/// 标记切生产段，标记不许落在生产代码之前）。
fn api_root(spec: &PanDriveSpec) -> String {
    if cfg!(test) {
        if let Some(base) = PanDrive::test_api_base_for(&spec.api_host) {
            return base;
        }
    }
    format!("https://{}", spec.api_host)
}

/// 建目录的请求体（**纯函数**；键名逐字来自 dex 的 const-string）
///
/// dex 取证（`merge.b.w.m`，夸克）：`pdir_fid` `"0"` / `file_name` / `dir_path` /
/// `dir_init_lock`；成功后取 `data.fid`；失败时类里有常量 `Quark_temp_folder_error`
/// （UC 那份是 `UC_temp_folder_error`）。
fn mkdir_body(name: &str) -> String {
    mkdir_body_under(name, "0")
}

/// 建目录的请求体（**指定父目录**版）—— `pdir_fid` = 父目录 fid（`"0"` = 根目录）
///
/// ★ N-23018 v2：21001 自愈的最后一次尝试要在一个**一次性子目录**里转存，
/// 确定性躲开"同名目录内去重"（对内容级去重无效但无害，见 degrade_attempt 注释）。
/// 根目录形态（[`mkdir_body`]）逐字节不变 —— 既有门禁钉着它的取证形状。
fn mkdir_body_under(name: &str, pdir_fid: &str) -> String {
    format!(
        "{{\"pdir_fid\":{},\"file_name\":{},\"dir_path\":\"\",\"dir_init_lock\":false}}",
        serde_json::Value::String(pdir_fid.to_string()),
        serde_json::Value::String(name.to_string())
    )
}

/// 从建目录响应里取 `data.fid`（**纯函数**；取不到 ⇒ 空串，由调用方如实报错）
fn mkdir_fid_of(v: &serde_json::Value) -> String {
    v.get("data")
        .and_then(|d| d.get("fid"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string()
}

/// 转存请求体（**纯函数**）——`to_pdir_fid` / `pdir_fid` 必须是**目标目录**
///
/// # 为什么抽成纯函数
/// 这是本卡的门禁故障注入点：把 `to_pdir_fid` 改回 `"0"`，
/// `t_pan_temp_dir::save_body_targets_temp_dir_not_root` 必须立刻变红。
fn share_save_body(
    fid: &str,
    fid_token: &str,
    share_id: &str,
    stoken: &str,
    to_pdir_fid: &str,
) -> String {
    format!(
        "{{\"fid_list\":[{}],\"fid_token_list\":[{}],\"to_pdir_fid\":{},\
          \"pwd_id\":{},\"stoken\":{},\"pdir_fid\":{},\"scene\":\"link\"}}",
        serde_json::Value::String(fid.to_string()),
        serde_json::Value::String(fid_token.to_string()),
        serde_json::Value::String(to_pdir_fid.to_string()),
        serde_json::Value::String(share_id.to_string()),
        serde_json::Value::String(stoken.to_string()),
        serde_json::Value::String(to_pdir_fid.to_string()),
    )
}

/// 临时目录不可用时的**退回决策**（纯函数，门禁可测）
///
/// 返回 `(要用的目录 fid, 失败原因)`：
/// ```text
/// Ok(fid)  → (fid, None)         正常：转存进 sourin-temp
/// Err(why) → ("0", Some(why))    退回根目录（**不阻断播放**，由调用方打 warn）
/// ```
/// ★ 为什么允许退回：Owner 要的是"别堆根目录"，但**播放不能因此失败**——
///   建目录失败（权限/账号限流/接口改版）时，宁可这一次落根目录并留下 warn，
///   也不要让用户点了播放什么都放不出来。
fn temp_dir_or_root(r: Result<String, String>) -> (String, Option<String>) {
    match r {
        Ok(fid) if !fid.trim().is_empty() => (fid, None),
        // 空 fid 与 Err 同待遇：拿不到有效目录就不许往那里转存
        Ok(_) => ("0".to_string(), Some("建目录没有返回 fid".to_string())),
        Err(e) => ("0".to_string(), Some(e)),
    }
}

/// 进程内的"临时目录 fid"缓存（按盘 kind 分开：两家盘 fid 不通用）
///
/// ★ 为什么必须缓存：`resolve_share_play` 每次都先列根目录再建目录，
///   会把播放延迟拉长一截；并且同一进程里重复建同名目录在某些账号上会
///   返回 `相同文件已存在` 一类错误。缓存后同一进程只探/建一次。
static TEMP_DIR_CACHE: std::sync::OnceLock<std::sync::Mutex<Vec<(String, String)>>> =
    std::sync::OnceLock::new();

fn temp_dir_cache() -> &'static std::sync::Mutex<Vec<(String, String)>> {
    TEMP_DIR_CACHE.get_or_init(|| std::sync::Mutex::new(Vec::new()))
}


/// 浏览器 UA（两端共用；参考实现在轮询/取数上用 Chrome UA）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 夸克 / UC 网盘源（**逻辑只有这一份**）
///
/// # `class` 为什么是字段而不是常量
/// ```text
/// 一个 `PanDrive` 要能代表两家 ⇒ 类名必须**随 spec 变**。
/// 若写成 `const CLASS = "PanQuark"`，UC 那个实例会报错类名 ⇒ 注册键与实现不符
///   （用户看到 "csp_PanUC" 却是夸克的行为 = 跨盘错绑）。
/// ```
pub struct PanDrive {
    class: &'static str,
    spec: PanDriveSpec,
    client: reqwest::Client,
}

impl PanDrive {

    /// 把分享里的一个文件**转存到我的网盘**，返回转存后的 fid
    ///
    /// # 三步（夸克/UC 同族；端点已从参考实现取证）
    /// ```text
    /// ① POST share/sharepage/token {pwd_id, passcode}                → data.stoken
    /// ② POST share/sharepage/save  {fid_list, fid_token_list, to_pdir_fid:"0",
    ///                               pwd_id, stoken, pdir_fid:"0", scene:"link"}
    ///      → data.task_id
    /// ③ GET  task?task_id=…&retry_index=0 轮询到 status=2 →
    ///      data.save_as.top_fid / data.save_as.save_as.top_fid（取到就返回）
    /// ```
    /// # 为什么必须有它
    /// ```text
    /// 分享里的文件**不能直接下**（CDN 只认自己网盘里的 fid）。
    /// 原版就是这样做的；不转存就只能拿到分享页（播放器报"格式解不了"）。
    /// ```
    async fn share_save(
        &self,
        cookie: &str,
        share_id: &str,
        passcode: &str,
        fid: &str,
        fid_token: &str,
        // 转到哪个目录（`sourin-temp` 的 fid；退回时才是 `"0"`）
        to_pdir_fid: &str,
    ) -> Result<String, String> {
        /*
         * ★★★ 2026-10-28 真网读数（Owner 现场 403/`41020 转存文件token校验异常`）：
         * ```text
         * `share_fid_token` 绑定在**换出它的那次 stoken** 上。
         * 我第一版：用 A 次 stoken 列目录拿 token，再让本函数换一个 B 次 stoken 去 save
         *   ⇒ 服务端判"校验异常"，真网复现两次。
         * ⇒ 现在按 fid 重新取回 `(stoken, token)` **一对**，save 用同一对。
         * ```
         */
        let referer = share_referer(&self.spec, share_id)?;
        let (fresh_stoken, fresh_token) = self
            .refresh_fid_token(cookie, share_id, passcode, fid)
            .await
            .unwrap_or_default();
        let fid_token = if fresh_token.is_empty() {
            fid_token
        } else {
            fresh_token.as_str()
        };
        // ① 换 share token（refresh 已经换过一次 ⇒ 只有它失败时才自己再换）
        let stoken = if fresh_stoken.is_empty() {
            self.share_stoken(cookie, share_id, passcode).await?
        } else {
            fresh_stoken
        };

        // ② 转存
        let save_url = self.api(&format!("share/sharepage/save?{}", self.spec.pr_fr));
        /*
         * ★★★ 2026-10-29：目标目录**不再是根目录**。
         *
         * 改前这里写死 `"to_pdir_fid":"0","pdir_fid":"0"` ⇒ 每播一次就在用户
         * 网盘根目录扔一个视频（Owner 原话：「这些网盘我都还要用，都放在根目录
         * 我就没办法用了」）。现在由调用方（`save_into_temp_dir`）传
         * `sourin-temp` 的 fid 进来；只有建目录失败时才会是 `"0"`（并打 warn）。
         */
        let save_body = share_save_body(fid, fid_token, share_id, &stoken, to_pdir_fid);
        let resp = self
            .client
            .post(&save_url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", &referer)
            .header("Cookie", cookie)
            .body(save_body)
            .send()
            .await
            .map_err(|e| format!("转存请求失败：{e}"))?;
        let text = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        let v: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| format!("转存返回的不是 JSON（{e}）：{}", short(&text)))?;
        let task_id = v
            .get("data")
            .and_then(|d| d.get("task_id"))
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        if task_id.is_empty() {
            return Err(format!("转存没有拿到 task_id（响应：{}）", short(&text)));
        }

        // ③ 轮询任务（最多 ~30 秒；超时如实报，不猜地址）
        //
        // ★ 2026-10-28 现场：9 秒窗口对真分享（64GB ISO 那种）不够；并且成功态是
        //   `status:2` + `save_as.save_as_top_fids:[…]`（数组），
        //   我第一版找 `save_as.top_fid`（单数）⇒ 永远取不到 ⇒ 空转超时。真读数见提交说明。
        let mut last = String::new();
        for _ in 0..30 {
            tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
            let task_url = self.api(&format!(
                "task?{}&task_id={}&retry_index=0",
                self.spec.pr_fr, task_id
            ));
            let resp = self
                .client
                .get(&task_url)
                .header("Accept", "application/json, text/plain, */*")
                .header("Referer", &referer)
                .header("Cookie", cookie)
                .send()
                .await
                .map_err(|e| format!("查询转存任务失败：{e}"))?;
            let text = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
            let v: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
            // 真读数：成功态 status=2，fid 在 `save_as.save_as_top_fids[0]`（数组）
            let saved = v
                .get("data")
                .and_then(|d| d.get("save_as"))
                .and_then(|s| {
                    s.get("save_as_top_fids")
                        .or_else(|| s.get("save_as_select_top_fids"))
                })
                .and_then(|a| a.as_array())
                .and_then(|a| a.first())
                .and_then(|x| x.as_str())
                .filter(|x| !x.is_empty())
                .map(|x| x.to_string())
                .or_else(|| {
                    v.get("data")
                        .and_then(|d| d.get("save_as"))
                        .and_then(|s| s.get("top_fid"))
                        .and_then(|x| x.as_str())
                        .filter(|x| !x.is_empty())
                        .map(|x| x.to_string())
                });
            if let Some(saved) = saved {
                return Ok(saved);
            }
            let status = v
                .get("data")
                .and_then(|d| d.get("status"))
                .and_then(|x| x.as_i64())
                .unwrap_or(-1);
            if status == 3 {
                return Err(format!("转存任务失败（status=3，响应：{}）", short(&text)));
            }
            last = text;
        }
        Err(format!(
            "转存任务 30 秒未完成 ⇒ 现在给不出地址，不伪造（最后一次响应：{}）",
            last
        ))
    }

    /// 在指定父目录下拿到（必要时**创建**）名为 `name` 的**子目录** fid
    ///
    /// ★ N-23018 v2：从 [`ensure_temp_dir`] 泛化出来 —— "列父目录找同名 → 没有就建"
    /// 是同一套动作，临时目录与自愈的**一次性重试子目录**共用一份实现
    /// （两处各写一份必然漂移）。不带缓存 —— 进程内缓存只有常驻的临时目录需要。
    /// ⚠️ 只认**目录**：同名文件不算（否则转存会落在一个非目录 fid 上）。
    async fn ensure_dir_under(
        &self,
        cookie: &str,
        parent_fid: &str,
        name: &str,
    ) -> Result<String, String> {
        // ① 先找（★ 必须用**含子目录**的列法 —— `list_dir` 是 `_fetch_sub_dirs=0`，
        //    用它找目录永远找不到 ⇒ 每启动一次多建一个 sourin-temp，真机实测踩过）
        let found = if let Ok(entries) = self.list_dir_with_subdirs(cookie, parent_fid).await {
            entries
                .into_iter()
                .find(|e| e.is_dir && e.name == name)
                .map(|e| e.fid)
        } else {
            None
        };
        if let Some(fid) = found {
            return Ok(fid);
        }
        // ② 建
        let kind = self.spec.kind.code();
        let resp = self
            .client
            .post(mkdir_url(&self.spec))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", self.spec.share_host)
            .header("Cookie", cookie)
            .body(mkdir_body_under(name, parent_fid))
            .send()
            .await
            .map_err(|e| format!("建目录 {name} 请求失败：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        let v: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
        let fid = mkdir_fid_of(&v);
        if fid.is_empty() {
            return Err(format!(
                "建目录 {name} 没有拿到 fid（HTTP {status}，响应：{}）",
                short(&text)
            ));
        }
        log::info!(
            "[PAN] 已建目录 kind={kind} name={name} fid={fid}（父目录 {parent_fid}）"
        );
        Ok(fid)
    }

    /// ★★★ 拿到（必要时**创建**）临时转存目录的 fid
    ///
    /// # 判据（Owner 硬要求：网盘根目录不许再堆临时转存）
    /// ```text
    /// ① 先 `file/sort` 列根目录找同名目录（夸克/UC 都可能已存在，比如上次登录建的）
    /// ② 找不到 ⇒ `POST file` 建目录（dex 实证的端点与请求体，见 `mkdir_url`）
    /// ③ 成功 ⇒ 记进进程内缓存，同一进程只探/建一次
    /// ④ 失败 ⇒ 原样 Err（**不在这里吞**：退回根目录的决定与日志在
    ///    `save_into_temp_dir`，那里才看得到"这次是退回了"的上下文）
    /// ```
    /// ⚠️ 只认**目录**：同名文件（极少数用户会自己建个 sourin-temp 文件）不算，
    ///    否则转存会失败在一个根本不是目录的 fid 上。
    async fn ensure_temp_dir(&self, cookie: &str) -> Result<String, String> {
        let kind = self.spec.kind.code().to_string();
        // ① 缓存
        {
            let guard = temp_dir_cache().lock().unwrap_or_else(|e| e.into_inner());
            if let Some((_, fid)) = guard.iter().find(|(k, _)| k == &kind) {
                if !fid.trim().is_empty() {
                    return Ok(fid.clone());
                }
            }
        }
        // ②③ 找/建（泛化实现，见 [`ensure_dir_under`]）
        let fid = self.ensure_dir_under(cookie, "0", TEMP_DIR_NAME).await?;
        // ④ 缓存
        {
            let mut guard = temp_dir_cache().lock().unwrap_or_else(|e| e.into_inner());
            guard.retain(|(k, _)| k != &kind);
            guard.push((kind, fid.clone()));
        }
        Ok(fid)
    }

    /// 21001 自愈第 3 档：在临时目录下拿一个**一次性重试子目录**
    ///
    /// 名字由 [`retry_subdir_name`] 保证唯一 ⇒ 子目录里不可能已有同名文件 ⇒
    /// save 的同名去重必然落空（对内容级去重无效但无害 —— 见 `degrade_attempt`）。
    /// 目录 fid 由调用方 `remember_temp` 记账（purge LIFO：先删文件再删本目录，
    /// 别只建不清 —— 又一个目录垃圾源）。
    async fn ensure_retry_subdir(&self, cookie: &str, temp_fid: &str) -> Result<String, String> {
        let name = retry_subdir_name();
        self.ensure_dir_under(cookie, temp_fid, &name).await
    }

    /// 转存到**临时目录**（建目录失败 ⇒ 退回根目录 + warn，绝不整体失败）
    ///
    /// 两个调用点（`play` 的分享分支、`resolve_share_play`）都走这里，
    /// 保证"往哪转"只有一份判断 —— 两处各写一份必然漂移。
    async fn save_into_temp_dir(
        &self,
        cookie: &str,
        share_id: &str,
        passcode: &str,
        fid: &str,
        fid_token: &str,
    ) -> Result<String, String> {
        let (dir, fallback) = temp_dir_or_root(self.ensure_temp_dir(cookie).await);
        if let Some(why) = fallback.as_deref() {
            // ⚠️ PAN 侧日志必须走 applog::write_file_log（log 门面在本 crate 无 sink）
            crate::applog::write_file_log(
                "PAN",
                &format!(
                    "临时目录 {TEMP_DIR_NAME} 不可用（{why}）⇒ 本次转存退回网盘根目录（不阻断播放）"
                ),
            );
        }
        match self
            .share_save(cookie, share_id, passcode, fid, fid_token, &dir)
            .await
        {
            Ok(saved) => Ok(saved),
            // ★ 文案里必须写清"这次是退回了根目录" —— 否则用户看到根目录里又多一个
            //   文件，会以为修复没生效（那正是 Owner 这次要解决的问题）。
            Err(e) => Err(match fallback {
                Some(why) => format!("{e}（临时目录不可用，已退回根目录：{why}）"),
                None => e,
            }),
        }
    }

    pub fn with_spec(class: &'static str, spec: PanDriveSpec) -> Self {        // ⚠️ 与 `pan_web_share.rs` 同一条纪律：reqwest 默认读环境代理，
        //    而用户机器上的代理会把"接口可用"测成"全失败"。
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(HTTP_TIMEOUT)
            .no_proxy()
            .build()
            .expect("HTTP client 构建失败（TLS 后端不可用）—— 不许退回无 no_proxy 的兜底");
        Self { class, spec, client }
    }

    /// 本盘的登录 cookie（没有 ⇒ 返回 `None`，由调用方如实报错）
    ///
    /// ★ **每次现读**（不是启动时缓存）：
    /// ```text
    /// Owner 的硬要求是"开关/登录状态要热生效，不必重启"。
    /// 而 `pan_auth::load` 直读系统钥匙串 ⇒ 天然热。
    /// 若这里缓存到字段里，用户刚扫码成功、这边还用旧值 = "要重启"的观感。
    /// ```
    fn cookie(&self) -> Option<String> {
        if let Some(c) = self.test_cookie_override() {
            return Some(c);
        }
        crate::pan_auth::load(self.spec.kind).map(|c| c.cookie)
    }

    /// ★ 测试缝（**仅测试编译存在**，release 构建恒 None）：
    /// 假服务器夹具需要"已登录"态，而真 cookie 在系统钥匙串里 ——
    /// 注入/清除走文件尾的 `debug_set_test_cookie`（实现也放文件尾：
    /// `share_chain_wires_share_referer` 门禁按首个**测试 cfg 标记**切生产段，
    /// 测试缝的标记必须落在全部生产代码之后，别把边界截短）。
    #[cfg(not(test))]
    fn test_cookie_override(&self) -> Option<String> {
        None
    }

    /// 拼一个 API URL（把 `{pr_fr}` 之类的固定参数带上）
    fn api(&self, path: &str) -> String {
        format!("{}/1/clouddrive/{}", api_root(&self.spec), path)
    }

    /// 带 cookie 发一次 GET（缺 cookie ⇒ 由调用方先拦）
    async fn get_json(&self, cookie: &str, url: &str) -> Result<serde_json::Value, String> {
        let resp = self
            .client
            .get(url)
            .header("Cookie", cookie)
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", self.spec.share_host)
            .send()
            .await
            .map_err(|e| format!("{} 请求失败：{e}", self.spec.kind.display()))?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!(
                "{} 返回 HTTP {status}：{}",
                self.spec.kind.display(),
                short(&body)
            ));
        }
        serde_json::from_str(&body)
            .map_err(|e| format!("{} 返回的不是 JSON（{e}）：{}", self.spec.kind.display(), short(&body)))
    }

    /// 文件列表（某个目录下的条目）—— 核心取数
    ///
    /// # ★ 逐字对齐参考实现（我第一版**串了参数**，靠交叉核对抓到）
    /// ```text
    /// 夸克（merge/b/w）：https://drive-pc.quark.cn/1/clouddrive/file/sort?
    ///     pr=ucpro&fr=pc&**uc_param_str=**&pdir_fid=0&_page=1&**_size=50**&_fetch_total=1…
    /// UC  （merge/b/B）：https://pc-api.uc.cn/1/clouddrive/file/sort?
    ///     pr=UCBrowser&fr=pc&pdir_fid=0&_page=1&**_size=200**&_fetch_total=1…
    /// ⇒ **两家的 query 不同**：
    ///     · 夸克带 `uc_param_str=`（空值，但**必须在**）
    ///     · `_size` 夸克 **50**、UC **200**
    /// ⚠️ 我第一版把 `_size` 写死成 200（那是 UC 的值）⇒ 夸克那边参数不是逐字。
    ///    这类"跨盘参数串了"**不会报错**（接口照样返回），只会让结果集大小不符 ⇒ 难查。
    ///    ⇒ 改成从 `spec` 取（两家各自的真实值）。
    /// ```
    async fn list_dir(&self, cookie: &str, dir: &str) -> Result<Vec<DriveEntry>, String> {
        let url = list_dir_url(&self.spec, dir);
        let v = self.get_json(cookie, &url).await?;
        Ok(parse_entries(&v))
    }

    /// 列目录（**含子目录**）—— 只给 `ensure_temp_dir` 用（见 `list_dir_url_with_subdirs` 的注释）
    async fn list_dir_with_subdirs(
        &self,
        cookie: &str,
        dir: &str,
    ) -> Result<Vec<DriveEntry>, String> {
        let url = list_dir_url_with_subdirs(&self.spec, dir);
        let v = self.get_json(cookie, &url).await?;
        Ok(parse_entries(&v))
    }
}

/// 网盘里的一个条目（文件或目录）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DriveEntry {
    pub fid: String,
    pub name: String,
    /// true = 目录
    pub is_dir: bool,
    /// 文件大小（目录为 0）
    pub size: u64,
    /// ★ 2026-10-28：分享条目自带的 `share_fid_token` —— **转存那一步必须带**
    /// （`fid` 单独不够：`sharepage/save` 要 `fid_token_list` 与 `fid_list` 一一对应）。
    /// 自己网盘（`file/sort` 那一路）没有这个字段 ⇒ `None`。
    pub fid_token: Option<String>,
}

/// 从 file/sort 的响应里抽条目
///
/// ★ 形状按参考实现在用的字段名（`fid` / `file_name` / `dir` / `size`）——
///   **未真跑通**，若真响应不同，改这里一处（不散在别处）。
fn parse_entries(v: &serde_json::Value) -> Vec<DriveEntry> {
    let mut out = Vec::new();
    let Some(arr) = v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|l| l.as_array())
    else {
        return out;
    };
    for it in arr {
        let fid = it.get("fid").and_then(|x| x.as_str()).unwrap_or("").to_string();
        if fid.is_empty() {
            continue; // 没 id 的条目没法用 —— 丢掉而不是编一个
        }
        out.push(DriveEntry {
            fid,
            name: it
                .get("file_name")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string(),
            // ⚠️ `dir` / `size` **不是**取证来的字段名 —— 我第一版"猜"了它们。
            //    ★ 交叉核对结果：参考实现（merge/b/w、merge/b/B）的方法体字符串里
            //      **只有** `fid` / `file_name` / `pdir_fid` / `dir_path` / `data`，
            //      **没有** `dir`、也**没有** `size`
            //      （全 dex 里 `"dir"` 只出现在无关的 `merge.A0.*` 库类里；
            //        `"size"` 只在 `merge/b/m`（123 的助手）里 ⇒ 不是夸克/UC 的字段名）。
            //    ⇒ 按"不猜"的纪律：**不把这几个未取证字段当已知**，
            //      改成"尽力而为 + 明确标注不确定"：
            //        目录判定优先用已取证的 `dir_path`（有值 = 目录），退而用已知字段名；
            //        大小字段**不臆造**，拿不到就 0（由 UI 显示空）。
            //    ★ 为什么不像 URL 那样直接去掉：`is_dir` 影响 UI 行为（能不能点进去），
            //      所以给"多路尝试"比"恒 false"更贴近真实；但**必须标明这是未验的**。
            is_dir: it.get("dir").and_then(|x| x.as_bool()).unwrap_or_else(|| {
                // 未取证字段 ⇒ 用"有没有 dir_path"作**代理判据**（那是取证到的字段）
                it.get("dir_path").map(|v| !v.is_null()).unwrap_or(false)
            }),
            // 大小：**只信取证到的字段**；一个都没有 ⇒ 0（不臆造、不编）
            size: it
                .get("size")
                .or_else(|| it.get("file_size"))
                .or_else(|| it.get("fsize"))
                .and_then(|x| x.as_u64())
                .unwrap_or(0),
            // ★ 分享条目带 `share_fid_token`（转存要用）；自己网盘没有 ⇒ None
            fid_token: it
                .get("share_fid_token")
                .and_then(|x| x.as_str())
                .map(|t| t.to_string())
                .filter(|t| !t.is_empty()),
        });
    }
    out
}

/// 摘要（报错时给用户看，别甩整页 HTML）
fn short(s: &str) -> String {
    let t = s.trim();
    let cut = t.char_indices().nth(200).map(|(i, _)| i).unwrap_or(t.len());
    format!("{}…（共 {} 字节）", &t[..cut], t.len())
}

/// 拼"列文件"的 URL（**纯函数** —— 抽出来是为了能断言 URL 逐字）
///
/// # 为什么单独抽出来
/// ```text
/// URL 拼错**不会报错**（接口照样返回 200），只是结果不对 ⇒ 属于"静默错"。
/// 抽成纯函数后就能**断言逐字**（对照参考实现的字符串）而不必发网络。
/// ```
fn list_dir_url(spec: &PanDriveSpec, dir: &str) -> String {
    format!(
        "{}/1/clouddrive/file/sort?{}&uc_param_str=&pdir_fid={dir}\
         &_page=1&_size={}&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,file_name:asc",
        api_root(spec),
        spec.pr_fr, spec.page_size
    )
}

/// 拼"列文件（**含子目录**）"的 URL —— 只给"找临时目录"用
///
/// # 为什么必须单独一条（真网实测抓到的真缺陷）
/// ```text
/// `list_dir_url` 是 `_fetch_sub_dirs=0`（照参考实现逐字，门禁还钉着它）⇒
/// **列不出目录条目**。而 `ensure_temp_dir` 第一步就是"在根目录找同名目录"：
///   用 list_dir 找 ⇒ 永远找不到 ⇒ **每启动一次就在根目录多建一个 sourin-temp**。
/// 2026-10-29 真机读数（我自己的登录态）：
///   [PAN-DIR] PanQuark 临时目录 sourin-temp fid=430959de…
///   [PAN-DIR] PanQuark 根目录条目 10 个；其中 sourin-temp = None   ← 找不着
/// ⇒ 找目录必须 `_fetch_sub_dirs=1`；**列货架仍用 0**（那条不能动，门禁逐字断言）。
/// ```
fn list_dir_url_with_subdirs(spec: &PanDriveSpec, dir: &str) -> String {
    list_dir_url(spec, dir).replace("_fetch_sub_dirs=0", "_fetch_sub_dirs=1")
}

/// 解析货架下标（**纯函数** —— 抽出来是为了让判据不依赖凭据）
///
/// # 为什么要抽成纯函数（这是判据可用性的要求，不是审美）
/// ```text
/// `list()` 开头有"登录闸" ⇒ 无凭据时**永远先报登录**，拿不到 tid 的报错
///   ⇒ 若把 tid 断言写在 `list()` 的用例里，判据就**依赖一个不确定的前置状态**
///     （我第一版就这么写 ⇒ 假红，报错是"还未登录…"而不是"必须是数字…"）。
/// ⇒ 抽出来：判"非数字 tid 报什么"与凭据**无关** ⇒ 判据确定。
/// ```
fn parse_shelf_index(tid: &str) -> Result<usize, String> {
    let t = tid.trim();
    if t.is_empty() {
        return Err("货架 id 为空（应是首页给出的数字下标）".to_string());
    }
    t.parse::<usize>().map_err(|_| {
        format!("货架 id 必须是数字（首页给的下标），实际收到 '{t}'")
    })
}

/// 解析 `<货架下标>` 或 `<货架下标>:<目录 fid>`
///
/// # 为什么要两段式（2026-10-28 实测的缺陷）
/// ```text
/// 网盘条目分目录与文件，而列表接口靠 `pdir_fid` 决定"列哪一层"。
/// 只传下标 ⇒ 永远列根 ⇒ 用户点了目录还是看到根（实测：5 项全目录，点进去还是这 5 项）。
/// ⇒ 目录条目的 id 用 `<idx>:<fid>`，`list` 就列那一层。
/// 只给裸 fid（旧数据/外部调用）⇒ 按第 0 个货架处理，保持向后兼容。
/// ```
fn parse_shelf_and_dir(tid: &str) -> Result<(usize, Option<String>), String> {
    let t = tid.trim();
    if t.is_empty() {
        return Err("货架 id 为空（应是首页给出的数字下标）".to_string());
    }
    match t.split_once(':') {
        Some((idx, fid)) => {
            let i = parse_shelf_index(idx)?;
            let fid = fid.trim();
            Ok((i, if fid.is_empty() { None } else { Some(fid.to_string()) }))
        }
        None => {
            if let Ok(i) = t.parse::<usize>() {
                Ok((i, None))
            } else {
                Ok((0, Some(t.to_string())))
            }
        }
    }
}

/// 按下标取货架（**纯函数**，同上）
///
/// ⚠️ 越界**必须报错**，不许 `unwrap_or(第一个)`：
///   那会让用户点"第 9 个货架"却看到第 1 个的内容（**静默取错数据**）。
fn shelf_of<'a>(spec: &'a PanDriveSpec, idx: usize) -> Result<&'a Shelf, String> {
    spec.shelves.get(idx).ok_or_else(|| {
        format!("货架 {idx} 不存在（本盘共 {} 个）", spec.shelves.len())
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  条目 id 的编解码 —— 分享上下文（shareId / fid / share_fid_token）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须编进 id（这是"分享链接能播"的唯一支点）
//
// ```text
// play() 只收到一个字符串 id。分享里的文件**不能直接下**（CDN 只认自己网盘里的
// fid）⇒ 必须先 `sharepage/save` 转存，而转存要三样东西：
//     ① pwd_id  = shareId
//     ② fid     = 分享内那个文件的 fid
//     ③ fid_token = 响应里的 `share_fid_token`（`fid_token_list` 与 `fid_list` 一一对应）
// ③ 只在**列目录那一次的响应**里出现，之后就拿不到了 ⇒ 不编进 id 就等于丢掉。
// ```
//
// # 形状（改它 = 改协议，必须同时改这三个函数与门禁）
//
// ```text
// 自己网盘   目录 → `<货架下标>:<fid>`     文件 → `<fid>`
// 分享货架   目录/文件 → `share:<shareId>:<fid>:<fidToken>`
// ```
//
// ⚠️ 分享里的**目录也走 `share:` 形状**：`list_target` 解出来的 fid 正好是分享内的
//    `pdir_fid` ⇒ 点目录能下钻。改前目录与文件同形会让下钻分不清（两者都进了 play）。

/// 分享条目 id 的前缀
const SHARE_ITEM_PREFIX: &str = "share:";

/// 列表里一个条目的 id（**编码端**；解码端是同文件的 [`parse_share_item`] / [`list_target`]）
fn item_id_of(shelf: &Shelf, idx: usize, e: &DriveEntry) -> String {
    if shelf.share_id.is_empty() {
        if e.is_dir {
            format!("{idx}:{}", e.fid)
        } else {
            e.fid.clone()
        }
    } else {
        format!(
            "{SHARE_ITEM_PREFIX}{}:{}:{}",
            shelf.share_id,
            e.fid,
            e.fid_token.clone().unwrap_or_default()
        )
    }
}

/// 把条目 id 解回分享三要素 `(shareId, fid, fidToken)`；不是分享条目 ⇒ `None`
///
/// ★ token 允许为空（有些分享不带 `share_fid_token`）—— 那一步会由接口报错，
///   而不是在这里假装成功。
fn parse_share_item(id: &str) -> Option<(String, String, String)> {
    let rest = id.trim().strip_prefix(SHARE_ITEM_PREFIX)?;
    let mut it = rest.splitn(3, ':');
    let share_id = it.next().unwrap_or("").trim().to_string();
    let fid = it.next().unwrap_or("").trim().to_string();
    let token = it.next().unwrap_or("").trim().to_string();
    if share_id.is_empty() || fid.is_empty() {
        return None;
    }
    Some((share_id, fid, token))
}

/// `list(tid)` 的目标：`(货架下标, 要列的目录 fid)`
///
/// # 三种形状（**一份判据**，`list` 与门禁共用）
/// ```text
/// `2`                                    → (2, 货架2 的 folder)
/// `0:<fid>`                              → (0, <fid>)          自己网盘下钻
/// `share:<shareId>:<fid>[:<token>]`      → (该 share 的货架, <fid>)  分享内下钻
/// ```
fn list_target(spec: &PanDriveSpec, tid: &str) -> Result<(usize, String), String> {
    if let Some((share_id, fid, _token)) = parse_share_item(tid) {
        let idx = spec
            .shelves
            .iter()
            .position(|s| s.share_id == share_id)
            .ok_or_else(|| {
                format!(
                    "条目属于分享 {share_id}，但本盘没有这个货架\
                     （可能是货架被改过）—— 请回首页重新打开"
                )
            })?;
        return Ok((idx, fid));
    }
    let (idx, sub) = parse_shelf_and_dir(tid)?;
    let shelf = shelf_of(spec, idx)?;
    Ok((idx, sub.unwrap_or_else(|| shelf.folder.clone())))
}

// ═══════════════════════════════════════════════════════════════════════
//  UC 分享货架的两步链路 —— 2026-10-28 **实测接通**（本文件唯一被改动的语义）
// ═══════════════════════════════════════════════════════════════════════
//
// # 改前是什么（`list_shared` 里那句"~~不~~猜参数"）
//
// ```text
// 原文如实写着：`sharepage/token` 各种形状一律 `{"status":500,"code":15000}`，
// 而 `file/sort` 无 cookie 时是 `401/31001` ⇒ 确认 15000 ≠ "需要登录"，
// 但**试不出该补哪个字段** ⇒ 当时正确地选择了"不猜"。
// ```
//
// # ★ 2026-10-28 拿到的对照读数（真网、直连、`--noproxy '*'`）
//
// ```text
// ① 表单形状  POST …/share/sharepage/token?pr=UCBrowser&fr=pc
//              body: pwd_id=<share>&passcode=            ⇒ 500 / code 15000
// ② JSON 形状 同 URL，body: {"pwd_id":"<share>","passcode":""}
//              Content-Type: application/json            ⇒ **200 / code 0**
//              data = {stoken, title, file_num, author{…}, expired_at}
// ③ 列目录    GET …/share/sharepage/detail?pr=UCBrowser&fr=pc
//              &pwd_id=<share>&stoken=<urlenc>&pdir_fid=0&force=0
//              &_page=1&_size=50&_fetch_total=1
//              &_sort=file_type:asc,updated_at:desc      ⇒ **200 / code 0**
//              list[0] = {fid, file_name, file_type:0, size:0, dir:true,
//                         share_fid_token:"401a4dc4…"}
// ④ 反面：同一台 host 换成 `drive.uc.cn` ⇒ **403**（匿名 token 只在 `pc-api` 上）
// ```
// ⇒ 差别只在 **body 的形状**（JSON vs 表单）。这就是"不猜"能落地成"确定"的全部原因。
//
// # ⚠️ 边界（别把这条读数推广到别家）
//
// ```text
// · 只对 **夸克/UC 同族**做（`sharepage/*` 两条路径逐字相同，host/pr 从 spec 取）。
//   其它盘（百度/115/阿里/天翼/迅雷/123/光鸭）的分享流程**结构不同**
//   ⇒ 仍然走"如实未接通"，一个字都不改。
// · 提取码：原版四格里的分享**都没有提取码**，`Shelf` 也没有这个字段 ⇒ 一律空串。
//   将来要支持带码分享，得先给 `Shelf` 加字段（那要改数据形状，不在本次范围）。
// · 空结果 ⇒ Err（本仓硬约束一），不许返回空列表冒充"这个货架是空的"。
// ```

/// 取直链时带的桌面 UA（CDN 认这个头；参考实现同样带）
const PAN_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                      (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

/// 换 token 的 URL（**按 spec 拼**：夸克 `drive-pc.quark.cn` / UC `pc-api.uc.cn`）
///
/// ★ 2026-10-28：从"写死 UC 的 host/pr"改成"跟着 spec 走" —— 这是夸克能共用
///   同一份实现的前提（否则 UC 的实现会给夸克发错 host）。
fn share_token_url(spec: &PanDriveSpec) -> String {
    format!(
        "{}/1/clouddrive/share/sharepage/token?{}",
        api_root(spec),
        spec.pr_fr
    )
}

/// 分享链路共用的 Referer（`{share_host}/s/{share_id}`）
///
/// # ★ 2026-10-31（T4-C）：构造点显式校验，**不可能产出非法 header**
/// ```text
/// share_id 会被拼进 Referer（token/save/detail 三处）。http crate 的 HeaderValue
/// 拒绝控制字符（\x00-\x1F、\x7F）⇒ 脏值一路 format! 到 reqwest `.send()` 才爆
/// `Error::builder` —— 客户端构造失败，一个字节没发出去，报错毫无指向性
/// （10-31 真机审计 C 类「夸克网盘 换分享 token 请求失败：builder error」×6 的形态，
///   根因是复合剧集 id 双重拼接后 `\u{1}` 落进了 share_id，见 provider.rs 判据注释）。
/// ⇒ 在构造点拒绝并返回**带原值**的明确错误（Debug 转义让 \u{1} 可见）；
///   入口侧 `parse_share_page` 同步把这类垃圾挡掉（pan_share_play.rs）。
/// ```
fn share_referer(spec: &PanDriveSpec, share_id: &str) -> Result<String, String> {
    if share_id.chars().any(char::is_control) {
        return Err(format!(
            "分享 id 含非法控制字符，拒绝构造请求（原始值：{share_id:?}）—— \
             通常是上游把剧集 id 分隔符（\\u{{1}}）之类混进了分享链接"
        ));
    }
    Ok(format!("{}/s/{share_id}", spec.share_host))
}

/// 换 token 的 body —— **JSON**（表单一律 500/15000，见上面对照读数 ①②）
fn share_token_body(share_id: &str, passcode: &str) -> String {
    format!(
        "{{\"pwd_id\":{},\"passcode\":{}}}",
        serde_json::Value::String(share_id.to_string()),
        serde_json::Value::String(passcode.to_string())
    )
}

/// 列分享目录的 URL（`stoken` 必须 URL 编码：实测值含 `+` `/` `=`）
fn share_detail_url(
    spec: &PanDriveSpec,
    share_id: &str,
    stoken: &str,
    folder: &str,
    page: u32,
) -> String {
    format!(
        "{}/1/clouddrive/share/sharepage/detail?{}\
         &pwd_id={share_id}&stoken={}&pdir_fid={folder}&force=0\
         &_page={}&_size=50&_fetch_total=1\
         &_sort=file_type:asc,updated_at:desc",
        api_root(spec),
        spec.pr_fr,
        urlencode_min(stoken),
        if page == 0 { 1 } else { page }
    )
}

/// 最小 URL 编码（`stoken` 里出现的就这几个字符；不引依赖，`Cargo.toml` 零 diff）
fn urlencode_min(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        let keep = b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~');
        if keep {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// 从分享 `detail` 的响应里抽条目
///
/// ★ 字段名全部来自**实测响应**（读数 ③）：`fid` / `file_name` / `file_type` /
///   `size` / `dir` / `share_fid_token`。与 `parse_entries`（`file/sort` 那一路）
///   **分开放**：两边的取证来源不同，混用一个函数会让"哪条证据支持哪个字段"糊掉。
fn parse_share_entries(v: &serde_json::Value) -> Vec<DriveEntry> {
    let Some(arr) = v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|l| l.as_array())
    else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let fid = it.get("fid").and_then(|x| x.as_str()).unwrap_or("").to_string();
        if fid.is_empty() {
            continue; // 没 id 的条目进不了详情
        }
        out.push(DriveEntry {
            fid,
            name: it
                .get("file_name")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string(),
            // 实测两种都有：布尔 `dir` 与 `file_type`（0=目录、1=文件）
            is_dir: it
                .get("dir")
                .and_then(|x| x.as_bool())
                .or_else(|| it.get("file_type").and_then(|x| x.as_i64()).map(|t| t == 0))
                .unwrap_or(false),
            size: it.get("size").and_then(|x| x.as_u64()).unwrap_or(0),
            // ★ 分享响应带 `share_fid_token`；自己网盘没有 ⇒ None
            fid_token: it
                .get("share_fid_token")
                .and_then(|x| x.as_str())
                .map(|t| t.to_string())
                .filter(|t| !t.is_empty()),
        });
    }
    out
}

/// 空结果 ⇒ Err（硬约束一：不许把"没取到"当"这个货架是空的"）
fn require_share_entries(
    entries: Vec<DriveEntry>,
    share_id: &str,
) -> Result<Vec<DriveEntry>, String> {
    if entries.is_empty() {
        return Err(format!(
            "分享 {share_id} 一条都没解析到 —— 可能是分享已失效、提取码变了，\
             或接口形状改了（不是「这个货架是空的」）"
        ));
    }
    Ok(entries)
}

/// 同族信封：`{"status":200,"code":0,…}` —— 非 0 一律失败（200 里也可能带非 0 业务码）
///
/// ★ `kind` 只用于**报错文案点名是哪一家**（夸克/UC 共用这一份判据；
///   文案里写错盘名会让用户按错的方向去排查）。
fn share_envelope(kind: &str, body: &str, what: &str) -> Result<serde_json::Value, String> {
    let v: serde_json::Value = serde_json::from_str(body)
        .map_err(|e| format!("{kind} {what} 返回的不是 JSON（{e}）：{}", short(body)))?;
    let status = v.get("status").and_then(|c| c.as_i64());
    let code = v.get("code").and_then(|c| c.as_i64());
    if !matches!((status, code), (Some(200), Some(0))) {
        let msg = v.get("message").and_then(|m| m.as_str()).unwrap_or("");
        return Err(format!(
            "{kind} {what} 报错（status={status:?} code={code:?}）：{msg}"
        ));
    }
    Ok(v)
}

/// 这一家是否走「同族两步链路」（`sharepage/token` + `sharepage/detail`）
///
/// # 为什么抽成纯函数
/// ```text
/// 路由判断本身是"分享能不能列"的全部判据，但 `list_shared` 一走就是**真网络**
/// （无 cookie 也会发请求）⇒ 把断言写在 `list_shared` 用例里会变成"测网络"。
/// 抽出来后：判据离线确定，`list_shared` 与门禁共用同一份（不会漂移）。
/// 注入验证：把 `matches!` 改成只 `Uc` ⇒ `quark_shares_use_the_family_chain` 红。
/// ```
fn share_family_wired(kind: PanKind) -> bool {
    matches!(kind, PanKind::Uc | PanKind::Quark)
}

#[async_trait]
impl CspSite for PanDrive {
    fn class(&self) -> &'static str {
        self.class
    }

    /// 首页 = **货架清单**（数据驱动）
    ///
    /// # 与影视站源的差别（别照着别人的样子写）
    /// ```text
    /// 影视站：home 去抓站点首页 HTML，解析出分类。
    /// 网盘源：home **就是作者/用户给的那串货架** —— 没有"分类页"可抓。
    /// ⇒ 这里不发网络（除了可选的登录态检查），直接由 `spec.shelves` 产出。
    ///    ★ 这也解释了订阅里的 `"changeable":0` —— 它本就没有可换的分类。
    /// ```
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        // ★ 无 cookie ⇒ **如实报错**（不是返回空首页 —— 那会让用户以为"这个盘是空的"）
        if self.cookie().is_none() {
            return Err(login_hint(self.spec.kind));
        }
        let categories: Vec<CspCategory> = self
            .spec
            .shelves
            .iter()
            .enumerate()
            .map(|(i, s)| CspCategory {
                // ★ tid 用**下标**而不是 share_id：
                //   share_id 可能是空串（"我的网盘"那项）⇒ 拿它当 key 会与别的空串撞。
                id: i.to_string(),
                name: s.name.clone(),
            })
            .collect();
        Ok(CspHome {
            categories,
            // 首屏条目留给 list 去取（这里不预取：网盘首页可能很大，预取会拖慢启动）
            items: Vec::new(),
        })
    }

    /// 列表：`tid` = 首页给出的**货架下标**
    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let Some(cookie) = self.cookie() else {
            return Err(login_hint(self.spec.kind));
        };
        /*
         * ★★★ 2026-10-28（Owner：「必须要能播放」—— 真跑时发现点目录没反应）
         * ```text
         * 改前：`list` 只认"货架下标"，收到的 id 一律忽略 ⇒ 点进任何目录都**还是根目录**
         *   （实测：列根 5 项全是目录 → 点「夸克上传文件」再列，还是那 5 项）
         *   ⇒ 永远走不到文件 ⇒ 取直链无从谈起。
         * 现在：`tid` 支持 `<货架下标>:<目录 fid>` 两段式；只有 fid 时按第 0 个货架处理。
         * ```
         */
        let (idx, folder) = list_target(&self.spec, tid)?;
        let shelf = shelf_of(&self.spec, idx)?;

        // ⚠️ 空 share_id = "我的网盘根目录" ⇒ 直接列根；
        //    非空 = 别人分享的货架 ⇒ 需要先换 share token（两步）
        // ★ 2026-10-28：分享货架同样支持下钻（`folder` 就是分享内的 pdir_fid）
        let entries = if shelf.share_id.is_empty() {
            self.list_dir(&cookie, &folder).await?
        } else {
            self.list_shared(&cookie, &shelf.share_id, &folder).await?
        };

        let items = entries
            .iter()
            .map(|e| CspItem {
                /*
                 * ★★★ 2026-10-28（Owner 图：分享页点播放 ⇒ "这个格式解不了"）
                 * ```text
                 * 改前分享条目的 id 只带 fid ⇒ play 拿不到 share_id / fid_token
                 * ⇒ 转存那一步做不了 ⇒ 只能吐出分享页/无法解析的东西（播放器报"格式解不了"）。
                 * ⇒ 编码收进 `item_id_of`（与 `list_target` / `parse_share_item` 成对，
                 *   谁改了形状都会被 `share_item_id_roundtrip` 抓住）。
                 * ```
                 */
                id: item_id_of(shelf, idx, e),
                title: e.name.clone(),
                cover: None,
                subtitle: if e.is_dir {
                    Some("目录".to_string())
                } else {
                    Some(human_size(e.size))
                },
            })
            .collect();
        Ok(CspList {
            items,
            page: if page == 0 { 1 } else { page },
            // 网盘列表目前只取第一页（参考实现也是逐页取；分页未验）
            page_count: None,
            total: None,
        })
    }

    /// 详情：网盘条目没有"剧集"概念 ⇒ 把单个条目包装成"1 集"给 UI
    ///
    /// # 为什么不是"直接报不支持"
    /// ```text
    /// UI 的播放链路是 list → detail → play。若 detail 报错，用户点了条目就断。
    /// 而网盘条目**确实**有可播内容（文件）⇒ 如实包装成 1 集是**行为正确**的。
    /// ```
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        if self.cookie().is_none() {
            return Err(login_hint(self.spec.kind));
        }
        // ★ 2026-10-28：分享条目的 id 是**编码过的**（`share:shareId:fid:token`）——
        //   直接把它当标题会把一长串内部编码洒到界面上 ⇒ 只显示 fid 那一段。
        let title = parse_share_item(id)
            .map(|(_, fid, _)| fid)
            .unwrap_or_else(|| id.to_string());
        Ok(CspDetail {
            id: id.to_string(),
            title,
            cover: None,
            description: None,
            episodes: vec![CspEpisode {
                id: id.to_string(),
                title: "播放".to_string(),
                flag: "默认".to_string(),
            }],
        })
    }

    /// ★ 本类**不支持搜索** —— 硬依据见文件头（订阅 `searchable:0`）
    fn supports_search(&self) -> bool {
        false
    }
    /// ★ 2026-10-28（Owner：「要逐类标注」）：本类**不填 ext 不能用**
    ///
    /// 依据：未登录必然 Err（分享页 token 需要 passcode/session）
    /// ⇒ 默认不自动暴露（用户导入带 ext 的站点时照常出现）。
    fn needs_ext(&self) -> bool {
        true
    }


    /// 搜索：如实报"不支持"（**不许**占位返回空 —— 那会被当成"搜了但没结果"）
    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(format!(
            "{} 不支持搜索（它只列出你指定的那几个货架）",
            self.spec.kind.display()
        ))
    }

    /// 取播放地址
    ///
    /// # 实现状态（**如实**）
    /// ```text
    /// 参考实现的取流链路：file/info → acquire_dl_token → file/download ⇒ 得到一个
    /// **需要带 Cookie/Referer 的直链**，再由「本机转发服务」把它转成播放器能用的 URL。
    /// 本仓的等价能力是 `streamproxy::register(url, headers)`（streamproxy.rs:819），
    /// ⚠️ 但**尚未实测**接通（302 链 + Range 透传未验）。
    /// ⇒ 我**不**在这里伪造一个 m3u8（那只会让用户点进去 404）。
    ///   做到哪一步说哪一步：本函数目前如实报"取流链路未接通"。
    /// ```
    /// ★★★ 2026-10-28（Owner：「我登录了夸克，我用这个源播放 夸克网盘也还是不能播放」）
    ///
    /// # 改前为什么必然播不了
    /// ```text
    /// 这里直接返回"取流链路尚未接通"—— 一行网络请求都没发。
    /// 用户登录了、也点到了文件，但实现根本不去要地址。
    /// ```
    /// # 现在
    /// ```text
    /// POST https://{api_host}/1/clouddrive/file/download?{pr_fr}
    ///   {"fids":["<fid>"]}     + Cookie
    /// → data[0].download_url
    /// ★ 响应头会下发 `Set-Cookie: __puus=…` —— **CDN 认的正是它**：
    ///   不并进直链的 Cookie 头，一律 403 `require login [auth miss]`
    ///   （真网试了 6 种 Referer/UA/Cookie 组合全 403，读到响应头才定位到）。
    /// ⇒ 这里读 Set-Cookie 并进 Cookie，再把 url + 三个头交给 streamproxy。
    /// ```
    /// # 为什么分享链接的取流仍不猜
    /// ```text
    /// `play` 只拿到 `fid`，**没有 share_id / fid_token** ⇒ 做不了"转存到我的网盘"那一步。
    /// 要做分享直链，得先把 share 信息编进条目 id（改 list/detail 的 id 协议）——
    /// 那是另一件事，本轮不猜。
    /// ```
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let cookie = match self.cookie() {
            Some(c) => c,
            None => return Err(login_hint(self.spec.kind)),
        };
        let raw_id = id.trim();
        if raw_id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        /*
         * ★ 2026-10-28：`share:<shareId>:<fid>:<fidToken>` ⇒ 先**转存到我自己的网盘**
         *   再按自己网盘的流程取直链（分享里的文件不能直接下）。
         *   自己网盘的文件（裸 fid）走原来的路。
         *   ★ 解码收进 `parse_share_item`（与 `item_id_of` 成对，形状由门禁钉死）。
         */
        let fid = if let Some((share_id, sfid, token)) = parse_share_item(raw_id) {
            // ★ 走临时目录（建不出来才退回根目录），见 `save_into_temp_dir`
            self.save_into_temp_dir(&cookie, &share_id, "", &sfid, &token)
                .await?
        } else {
            raw_id.to_string()
        };
        let url = self.api(&format!("file/download?{}", self.spec.pr_fr));
        let body = format!(
            "{{\"fids\":[{}]}}",
            serde_json::Value::String(fid.to_string())
        );
        let resp = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", self.spec.share_host)
            .header("Cookie", &cookie)
            .body(body)
            .send()
            .await
            .map_err(|e| format!("{} 取下载地址请求失败：{e}", self.spec.kind.display()))?;
        let status = resp.status();
        // ★ 必须**在 text() 之前**收：响应体一读，headers 就没了
        let mut set_cookie: Vec<String> = Vec::new();
        for v in resp.headers().get_all("set-cookie") {
            if let Ok(t) = v.to_str() {
                if let Some(kv) = t.split(';').next() {
                    let kv = kv.trim();
                    if !kv.is_empty() {
                        set_cookie.push(kv.to_string());
                    }
                }
            }
        }
        let text = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        if !status.is_success() {
            // ★ N-23018（2026-11-01，lead 批复③）：夸克 21001「file not found」=
            //   **文件已不存在**（真机实锤：重试被自己上一次解析的 purge 竞态删掉；
            //   也可能是分享者删源）。它与登录毫无关系（Owner 已登录仍复现），
            //   与网络抖动也无关 ⇒ 归"文件已不存在"终态，人话点破"换一条线路"。
            if is_file_not_found_21001(&text) {
                return Err(format!(
                    "{} 文件已不存在（code=21001 file not found），无法播放，请换一条线路",
                    self.spec.kind.display()
                ));
            }
            return Err(format!(
                "{} 取下载地址返回 HTTP {status}：{}",
                self.spec.kind.display(),
                short(&text)
            ));
        }
        let v: serde_json::Value = serde_json::from_str(&text).map_err(|e| {
            format!(
                "{} 取下载地址返回的不是 JSON（{e}）：{}",
                self.spec.kind.display(),
                short(&text)
            )
        })?;
        let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(-1);
        let msg = v.get("message").and_then(|m| m.as_str()).unwrap_or("");
        if code != 0 {
            let text = format!(
                "{} 取下载地址失败（code={code}）：{msg}",
                self.spec.kind.display()
            );
            let lower = msg.to_lowercase();
            // 三态分清：登录问题要让 UI 弹扫码，不是报"文件不存在"
            if lower.contains("login") || msg.contains("登录") || msg.contains("未授权") {
                return Err(format!("NEED_LOGIN:{}|{text}", self.spec.kind.code()));
            }
            // ★ 2026-10-30（任务 5）：单文件超下载上限（23018）是**文件属性问题**，
            //   不是网络/登录故障 —— 文案要点破，用户才知道该换线路而不是重试。
            if is_size_limit_error(&text) {
                return Err(format!("{text}（该文件超出账号单文件下载上限）"));
            }
            return Err(text);
        }
        let direct = v
            .get("data")
            .and_then(|d| d.as_array())
            .and_then(|a| a.first())
            .and_then(|f| f.get("download_url"))
            .and_then(|u| u.as_str())
            .unwrap_or("");
        if direct.is_empty() {
            return Err(format!(
                "{} 取下载地址成功但没有 download_url（响应：{}）",
                self.spec.kind.display(),
                short(&text)
            ));
        }
        // 把 Set-Cookie（主要是 `__puus`）并进 Cookie —— 缺它 CDN 一律 403
        let mut merged = cookie.clone();
        for kv in &set_cookie {
            let key = kv.split('=').next().unwrap_or("").trim();
            if key.is_empty() {
                continue;
            }
            let kept: Vec<&str> = merged
                .split(';')
                .map(|p| p.trim())
                .filter(|p| !p.is_empty() && !p.starts_with(&format!("{key}=")))
                .collect();
            merged = if kept.is_empty() {
                kv.clone()
            } else {
                format!("{}; {}", kept.join("; "), kv)
            };
        }
        Ok(vec![CspPlay {
            url: direct.to_string(),
            headers: vec![
                ("Cookie".to_string(), merged),
                ("Referer".to_string(), self.spec.share_host.to_string()),
                ("User-Agent".to_string(), PAN_UA.to_string()),
            ],
            label: Some("原画".to_string()),
        }])
    }
}

impl PanDrive {
    /// 列出**别人分享**的货架（需要两步：换 token → 取详情）
    ///
    /// # ★★ 2026-10-28：夸克也接了（此前只有 UC）
    ///
    /// ```text
    /// 改前 `match self.spec.kind { Uc => …, _ => Err("尚未接通") }` ——
    ///   理由是"JSON/表单的对照实验只在 UC 上做过，对夸克照抄同族形状就是猜"。
    /// 现在接夸克的**依据**（不是猜，是换掉了"猜"这个词的定义）：
    ///   ① 两家的 `sharepage/token` / `sharepage/detail` **端点路径逐字相同**，
    ///      只有 host 与 `pr/fr` 不同 —— 而这两样是 `PanDriveSpec` 里的数据；
    ///   ② 差别只在 **body 形状**（JSON vs 表单），这一点已在 UC 上做了对照实验
    ///      （表单 500/15000、JSON 200/0）；夸克照用同一个 body 形状；
    ///   ③ Owner 的验收要求是"夸克/UC 分享页点开能真的播" ⇒ 只做 UC 等于没做。
    /// ⚠️ 夸克这条**尚未真网跑通**（无真分享样本），批末实机验证时一并确认；
    ///    失败就会如实报接口错误，不会伪造成功。
    /// ```
    ///
    /// # 端点（参考实现逐字，**真网络探测过**）
    /// ```text
    /// ① POST https://<host>/1/clouddrive/share/sharepage/token?<pr_fr>
    ///      JSON：{"pwd_id":<share>,"passcode":"<提取码，可为空>"}
    /// ② GET  https://<host>/1/clouddrive/share/sharepage/detail?<pr_fr>&pwd_id=<share>
    ///      &stoken=<来自 ①>&pdir_fid=<目录>&force=0&_page=1&_size=100&_sort=…
    /// ```
    ///
    /// # ★ 实测读数（2026-10-27，curl 直连 `--noproxy '*'`）
    /// ```text
    /// · ① 用 GET ⇒ **405 Method Not Allowed** ⇒ 确认是 **POST**
    /// · ① POST + **表单** ⇒ 一律 `{"status":500,"code":15000,"message":"inner error"}`
    /// · ① POST + **JSON**  ⇒ **200 / code 0**（`data.stoken`）—— 2026-10-28 拿到
    /// · 对照：需要登录的接口（`file/sort`）无 cookie 时是 `401/31001`
    ///   ⇒ 15000 从来不是"要登录"，而是"请求形状不对"。
    /// ```
    async fn list_shared(
        &self,
        cookie: &str,
        share_id: &str,
        folder: &str,
    ) -> Result<Vec<DriveEntry>, String> {
        if share_family_wired(self.spec.kind) {
            // ★ 同族两家（端点路径逐字相同，host/pr 来自 spec）
            return self.share_list_family(cookie, share_id, "", folder).await;
        }
        Err(format!(
            "分享货架（share_id={share_id}）需要先换 share token（两步接口），\
             本实现尚未接通 —— 端点已取证（「POST」 确认；表单形状返 500/15000），\
             而 JSON 形状的对照实验只做在夸克/UC 这一族 ⇒ 这家不猜参数"
        ))
    }

    /// 同族（夸克/UC）的两步链路：换 token（JSON）→ 列分享目录
    ///
    /// # 为什么要带 cookie
    /// ```text
    /// 实测**匿名**就能换到 stoken 并列目录（分享页会给一个 ctoken cookie）。
    /// 但调用本函数的前提是 `list()` 已经过了登录闸（用户登录过）——
    /// 把 cookie 一起带上不会更糟，且账号自己的分享能看到完整列表（未验）。
    /// ```
    async fn share_list_family(
        &self,
        cookie: &str,
        share_id: &str,
        passcode: &str,
        folder: &str,
    ) -> Result<Vec<DriveEntry>, String> {
        let stoken = self.share_stoken(cookie, share_id, passcode).await?;
        self.share_detail_with_stoken(cookie, share_id, &stoken, folder)
            .await
    }

    /// 换 share token（**唯一生产点**；`list` 与 `save` 都用它，保证同一次会话）
    async fn share_stoken(
        &self,
        cookie: &str,
        share_id: &str,
        passcode: &str,
    ) -> Result<String, String> {
        let kind = self.spec.kind.display();
        let referer = share_referer(&self.spec, share_id)?;
        let resp = self
            .client
            .post(share_token_url(&self.spec))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", &referer)
            .header("Cookie", cookie)
            .body(share_token_body(share_id, passcode))
            .send()
            .await
            .map_err(|e| format!("{kind} 换分享 token 请求失败：{e}"))?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("{kind} 换分享 token 返回 HTTP {status}：{}", short(&body)));
        }
        let v = share_envelope(&kind, &body, "换分享 token")?;
        let stoken = v
            .get("data")
            .and_then(|d| d.get("stoken"))
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string();
        if stoken.is_empty() {
            return Err(format!(
                "{kind} 换分享 token 成功但没有 stoken（响应：{}）",
                short(&body)
            ));
        }
        Ok(stoken)
    }

    /// 用**指定的 stoken** 列分享目录（不自己换 token —— save 必须与它配对）
    async fn share_detail_with_stoken(
        &self,
        cookie: &str,
        share_id: &str,
        stoken: &str,
        folder: &str,
    ) -> Result<Vec<DriveEntry>, String> {
        let kind = self.spec.kind.display();
        let referer = share_referer(&self.spec, share_id)?;
        let url = share_detail_url(&self.spec, share_id, stoken, folder, 1);
        let resp = self
            .client
            .get(&url)
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", &referer)
            .header("Cookie", cookie)
            .send()
            .await
            .map_err(|e| format!("{kind} 列分享目录请求失败：{e}"))?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("{kind} 列分享目录返回 HTTP {status}：{}", short(&body)));
        }
        let v = share_envelope(&kind, &body, "列分享目录")?;
        require_share_entries(parse_share_entries(&v), share_id)
    }

    /// 按 fid 反查**与同一次 stoken 配套**的 `share_fid_token`，返回 `(stoken, token)`
    ///
    /// ★ 真网读数：token 与 stoken 是**一对**；分开取必被判 `41020 校验异常`。
    async fn refresh_fid_token(
        &self,
        cookie: &str,
        share_id: &str,
        passcode: &str,
        fid: &str,
    ) -> Result<(String, String), String> {
        let stoken = self.share_stoken(cookie, share_id, passcode).await?;
        let mut frontier: Vec<String> = vec!["0".to_string()];
        for depth in 0..=SHARE_PICK_MAX_DEPTH {
            let mut next: Vec<String> = Vec::new();
            for folder in &frontier {
                let entries = self
                    .share_detail_with_stoken(cookie, share_id, &stoken, folder)
                    .await?;
                for e in entries {
                    if e.fid == fid {
                        return Ok((stoken, e.fid_token.unwrap_or_default()));
                    }
                    if e.is_dir && depth < SHARE_PICK_MAX_DEPTH {
                        next.push(e.fid);
                    }
                }
            }
            if next.is_empty() {
                break;
            }
            frontier = next;
        }
        Ok((stoken, String::new()))
    }

    /// 清掉**上一次**播放留下的临时转存（best-effort；只清同一家盘）
    ///
    /// ★★★ N-23018（2026-11-01，lead 批复 A）：删完**等删除任务到终态**再返回
    /// ```text
    /// 改前：POST file/delete 只看 HTTP 状态就走 —— 但删除是异步任务（回收站），
    ///       随后的 sharepage/save 对同名文件**去重**，会回吐"刚删/正在删"的
    ///       同一个 fid ⇒ 紧接着 file/download 404(21001) file not found。
    ///       真机实锤：14:39:13 的 23018 与 14:39:40 的 404 带同一个 fid。
    /// 改后：响应里带 task_id 就轮询到终态（总预算 [PURGE_DELETE_WAIT_BUDGET]，
    ///       lead 护栏：不许无限挂住 resolve）；超时/形态认不出 ⇒ 如实 warn 后
    ///       继续走 —— 残余竞态由 degrade_attempt 的 21001 自愈兜底。
    /// ```
    pub async fn purge_previous(&self) {
        let kind = self.spec.kind.code().to_string();
        let victims: Vec<String> = {
            let mut guard = temp_saved().lock().unwrap_or_else(|e| e.into_inner());
            let mut keep: Vec<(String, String)> = Vec::new();
            let mut victims = Vec::new();
            for (k, fid) in guard.drain(..) {
                if k == kind {
                    victims.push(fid);
                } else {
                    keep.push((k, fid));
                }
            }
            *guard = keep;
            victims
        };
        if victims.is_empty() {
            return;
        }
        let Some(cookie) = self.cookie() else { return };
        let deadline = std::time::Instant::now() + PURGE_DELETE_WAIT_BUDGET;
        // ★ LIFO（N-23018 v2）：自愈的"一次性子目录"先记目录、后记其文件 ⇒
        //   倒序清理 = 先删文件再删其目录 —— 正序会把非空目录的删除打在前面（必失败）。
        for fid in victims.into_iter().rev() {
            /*
             * ★ 2026-10-29：日志写清"从 sourin-temp 清理"。
             *
             * 为什么强调：这条 fid 是**转存进临时目录**的那份（见 `save_into_temp_dir`），
             * 不是用户自己的文件。日志里不写清目录名，现场排查时就分不清
             * "我们删的是自己扔进去的"还是"误删了用户的东西"。
             *
             * ⚠️ PAN 侧日志必须走 `applog::write_file_log`（`log` 门面在本 crate
             *    无 sink，23018 猎捕二轮实锤的黑洞）。
             */
            match self
                .client
                .post(file_delete_url(&self.spec))
                .header("Content-Type", "application/json")
                .header("Cookie", &cookie)
                .header("Referer", self.spec.share_host)
                .body(file_delete_body(&fid))
                .send()
                .await
            {
                Ok(r) if r.status().is_success() => {
                    // 删除是异步任务 ⇒ 带 task_id 就等到终态；响应形态认不出
                    // （没有 task_id，可能同步删除）⇒ 如实记一笔后当已生效。
                    let body = r.text().await.unwrap_or_default();
                    let task_id = serde_json::from_str::<serde_json::Value>(&body)
                        .ok()
                        .and_then(|v| {
                            v.get("data")
                                .and_then(|d| d.get("task_id"))
                                .and_then(|x| x.as_str())
                                .filter(|x| !x.is_empty())
                                .map(|x| x.to_string())
                        });
                    let confirmed = match task_id {
                        Some(id) => self.wait_delete_task(&cookie, &id, deadline).await,
                        None => {
                            crate::applog::write_file_log(
                                "PAN",
                                &format!(
                                    "清理 {TEMP_DIR_NAME}：删除响应里没有 task_id（形态与预期不符，不猜）kind={kind} fid={fid} ⇒ 视为已生效"
                                ),
                            );
                            true
                        }
                    };
                    if confirmed {
                        crate::applog::write_file_log(
                            "PAN",
                            &format!(
                                "已从 {TEMP_DIR_NAME} 清理临时转存 kind={kind} fid={fid}（已确认删除完成，等价 action_type=2 移入回收站）"
                            ),
                        );
                    } else {
                        crate::applog::write_file_log(
                            "PAN",
                            &format!(
                                "清理 {TEMP_DIR_NAME} 的删除任务未在预算内确认完成 kind={kind} fid={fid} ⇒ 继续解析（残余竞态由 21001 自愈兜底）"
                            ),
                        );
                    }
                }
                Ok(r) => crate::applog::write_file_log(
                    "PAN",
                    &format!(
                        "清理 {TEMP_DIR_NAME} 里的临时转存失败 kind={kind} fid={fid} HTTP {}",
                        r.status()
                    ),
                ),
                Err(e) => crate::applog::write_file_log(
                    "PAN",
                    &format!(
                        "清理 {TEMP_DIR_NAME} 里的临时转存请求失败 kind={kind} fid={fid} err={e}"
                    ),
                ),
            }
        }
    }

    /// 轮询删除任务到终态（`sharepage/save` 同族的 `task?` 读数）
    ///
    /// 返回 true = 确认删除完成；false = 任务失败 / 预算耗尽 / 读数拿不到。
    /// 预算上限由调用方的 `deadline` 控制（[PURGE_DELETE_WAIT_BUDGET] 总预算）。
    async fn wait_delete_task(&self, cookie: &str, task_id: &str, deadline: std::time::Instant) -> bool {
        let referer = self.spec.share_host;
        while std::time::Instant::now() < deadline {
            tokio::time::sleep(PAN_POLL_INTERVAL).await;
            let url = self.api(&format!(
                "task?{}&task_id={task_id}&retry_index=0",
                self.spec.pr_fr
            ));
            let resp = match self
                .client
                .get(&url)
                .header("Accept", "application/json, text/plain, */*")
                .header("Referer", referer)
                .header("Cookie", cookie)
                .send()
                .await
            {
                Ok(r) => r,
                Err(_) => return false,
            };
            let text = match resp.text().await {
                Ok(t) => t,
                Err(_) => return false,
            };
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
                return false;
            };
            if let Some(done) = delete_task_done(&v) {
                return done;
            }
        }
        false
    }

    /// 21001 自愈的前置确认：等"刚删除的 fid"从临时目录清单里**消失**
    /// （回收站/索引最终一致性；预算 [SELFHEAL_LISTING_WAIT]，到点没消失也继续
    /// —— 重转存尽力而为，再 21001 就如实报）。
    async fn wait_fid_gone(&self, cookie: &str, fid: &str) {
        let (dir, fallback) = temp_dir_or_root(self.ensure_temp_dir(cookie).await);
        if fallback.is_some() {
            // 临时目录本来就不可用 ⇒ 没有可确认的清单，直接进重转存
            return;
        }
        let deadline = std::time::Instant::now() + SELFHEAL_LISTING_WAIT;
        while std::time::Instant::now() < deadline {
            if let Ok(entries) = self.list_dir(cookie, &dir).await {
                if !entries.iter().any(|e| e.fid == fid) {
                    return;
                }
            }
            tokio::time::sleep(PAN_POLL_INTERVAL).await;
        }
        crate::applog::write_file_log(
            "PAN",
            &format!(
                "21001 自愈：临时目录清单 {SELFHEAL_LISTING_WAIT:?} 内仍见旧 fid ⇒ 仍按计划重转存（若再 21001 则如实报）"
            ),
        );
    }

    /// 记下这次转存的 fid（下次解析前清理）
    fn remember_temp(&self, fid: &str) {
        temp_saved()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push((self.spec.kind.code().to_string(), fid.to_string()));
    }

    /// ★★★ 把**分享页 URL** 解析成可播直链（给"把分享页当剧集"的那些 csp 源用）
    ///
    /// # 原版行为（Owner 问的"播一次存一次、不复用不删除？"）
    /// ```text
    /// dex 实证：参考实现有 `QuarkTempDelete` / `UCTempDelete` + `file/delete`（action_type:2）
    /// ⇒ **每次播放都转存一份（不复用），播完删掉**（"Temp" 就是这个意思）。
    /// 所以这里：进入解析先清上一次的，转存成功后记住这一次的。
    /// 不在播到一半时删 —— 直链绑 fid，删了会断流。
    /// ```
    pub async fn resolve_share_play(
        &self,
        share_id: &str,
        passcode: &str,
    ) -> Result<CspPlay, String> {
        let share_id = share_id.trim();
        if share_id.is_empty() {
            return Err("分享 id 为空（分享页 URL 解析失败）".to_string());
        }
        let Some(cookie) = self.cookie() else {
            return Err(format!(
                "NEED_LOGIN:{}|{}",
                self.spec.kind.code(),
                login_hint(self.spec.kind)
            ));
        };
        // 先清上一次的临时转存（best-effort）
        self.purge_previous().await;
        /*
         * ★★★ 2026-10-30（现场反馈批次任务 5，Owner 图4：23018「download file size limit」）
         * ```text
         * 改前：pick_share_video 只挑**体积最大**的一个 ⇒ 账号单文件下载上限（23018）
         *       挡住它时就整体失败 —— 分享里明明有能播的小文件。
         * 改后：挑「**可下载**的最大」—— 按体积降序逐个试，遇 23018 降级到次大，
         *       最多试 3 个（SHARE_PICK_MAX_TRIES）；每次降级写日志 + UI 文案。
         * ```
         */
        let candidates = self.pick_share_candidates(&cookie, share_id, passcode).await?;
        // 「夸克网盘」→「夸克」：Owner 指定的文案是「该分享的文件超出夸克下载上限」
        let short_kind = self
            .spec
            .kind
            .display()
            .trim_end_matches("网盘")
            .to_string();
        let cookie2 = cookie.clone();
        let share_id = share_id.to_string();
        let passcode = passcode.to_string();
        let (_idx, mut out, notes) = degrade_pick(
            &candidates,
            SHARE_PICK_MAX_TRIES,
            &short_kind,
            |entry| {
                let cookie = cookie2.clone();
                let share_id = share_id.clone();
                let passcode = passcode.clone();
                async move {
                    self.degrade_attempt(&cookie, &share_id, &passcode, entry)
                        .await
                }
            },
        )
        .await?;
        // UI 文案：降级过要让人看见「跳过了几个超限文件」（否则像没发生一样）
        out.label = Some(if notes.is_empty() {
            format!("分享页 · {}", candidates[_idx].name)
        } else {
            format!(
                "分享页 · {}（已跳过 {} 个超出下载上限的文件）",
                candidates[_idx].name,
                notes.len()
            )
        });
        Ok(out)
    }

    /// 降级重试里的**单次尝试**：转存候选 → 取直链
    ///
    /// ★ 失败的尝试**也** `remember_temp` —— 转存可能已成功（超限发生在取直链一步），
    ///   不记下来下次 purge 就清不掉 ⇒ 用户网盘里堆垃圾（正是上批修掉的问题）。
    ///
    /// ★★★ N-23018 v2（2026-11-01，lead 批复）：下载遇 21001 ⇒ **有界自愈循环**
    /// ```text
    /// v1 的真机缺口（部署版实测）：重转存一次后仍 21001 —— wait_fid_gone 确认
    /// 清单里已无旧 fid，重转存仍回吐同一个死 fid ⇒ 夸克 save 去重的作用域
    /// 不止活跃目录清单（至少含回收站，可能是内容秒传级）。
    /// v2 = 组合升级（每档都验证 save 回吐的 fid ≠ 死 fid）：
    ///   第 2 次转存：同目录等退避（对"删除落地慢/索引收敛"有效）；
    ///   第 3 次转存：一次性子目录（确定性躲开同名去重；对内容级去重无效但无害）。
    /// 预算：重转存 ≤ [SELFHEAL_RESAVE_ATTEMPTS] 次、总预算 [SELFHEAL_TOTAL_BUDGET]、
    ///       退避 = [SELFHEAL_BACKOFF_BASE] × 次数（2s → 4s）。
    /// 穷尽后终态**分两态**（真机缺口的文案修正）：
    ///   · 末次 save 仍回吐死 fid（去重卡住）⇒「临时转存副本被网盘同名去重卡住…
    ///     稍后重试通常可恢复」——可重试语义（分享的文件明明还在）；
    ///   · 末次 save 拿到新 fid 但下载仍 21001 ⇒「文件已不存在…换一条线路」
    ///     （网盘/分享侧真没了，维持上批文案）。
    /// 每一档动作都落 AppLog（自愈了什么、为什么）—— 不静默。
    /// ```
    async fn degrade_attempt(
        &self,
        cookie: &str,
        share_id: &str,
        passcode: &str,
        entry: &DriveEntry,
    ) -> Result<CspPlay, String> {
        let token = entry.fid_token.clone().unwrap_or_default();
        let mut fid = self
            .save_into_temp_dir(cookie, share_id, passcode, &entry.fid, &token)
            .await?;
        self.remember_temp(&fid);
        // 复用 `play`（`share_save` 已把文件放进我自己的网盘 ⇒ 走到裸 fid 那条路）
        let deadline = std::time::Instant::now() + SELFHEAL_TOTAL_BUDGET;
        let mut resaves: u32 = 0;
        // 末次转存是否被网盘去重回吐了死 fid（决定穷尽终态走哪一态）
        let mut dedupe_echo = false;
        let result = loop {
            match self.play("", &fid, "").await {
                Ok(plays) => break Ok(plays),
                Err(e) if is_file_not_found_21001(&e) => {
                    if resaves >= SELFHEAL_RESAVE_ATTEMPTS
                        || std::time::Instant::now() >= deadline
                    {
                        // ★ 穷尽终态分两态（真机缺口的文案修正，lead 批复②）：
                        // 去重回吐型可重试（分享的文件明明还在）；真没了才说"已不存在"。
                        break Err(if dedupe_echo {
                            format!(
                                "{} 临时转存副本被网盘同名去重卡住（下载报 code=21001 file not found）：分享的文件还在，稍后重试通常可恢复，或换一条线路",
                                self.spec.kind.display()
                            )
                        } else {
                            e
                        });
                    }
                    resaves += 1;
                    let dead = fid.clone();
                    let use_subdir = resaves >= 2;
                    crate::applog::write_file_log(
                        "PAN",
                        &format!(
                            "21001 自愈（重转存 {resaves}/{}，{}）：文件 {} 的转存下载报 file not found（purge 删除与 save 去重竞态）",
                            SELFHEAL_RESAVE_ATTEMPTS,
                            if use_subdir { "换一次性子目录" } else { "同目录等退避" },
                            entry.name
                        ),
                    );
                    tokio::time::sleep(SELFHEAL_BACKOFF_BASE * resaves).await;
                    if use_subdir {
                        // ③ 换一次性子目录：确定性躲开"同名目录内去重"
                        //   （对内容级去重无效但无害 —— 两类成因无法静态区分，都兜）。
                        //   目录 fid 也记账（purge LIFO：先删文件再删本目录，别只建不清）。
                        let temp = temp_dir_or_root(self.ensure_temp_dir(cookie).await).0;
                        match self
                            .ensure_dir_under(cookie, &temp, &retry_subdir_name())
                            .await
                        {
                            Ok(sub) => {
                                self.remember_temp(&sub);
                                fid = self
                                    .share_save(
                                        cookie, share_id, passcode, &entry.fid, &token, &sub,
                                    )
                                    .await?;
                            }
                            Err(why) => {
                                crate::applog::write_file_log(
                                    "PAN",
                                    &format!(
                                        "21001 自愈：重试子目录建失败（{why}）⇒ 退回同目录重转存"
                                    ),
                                );
                                self.wait_fid_gone(cookie, &dead).await;
                                fid = self
                                    .save_into_temp_dir(
                                        cookie, share_id, passcode, &entry.fid, &token,
                                    )
                                    .await?;
                            }
                        }
                    } else {
                        // ② 同目录等退避：等删除落地/索引收敛后再转存
                        self.wait_fid_gone(cookie, &dead).await;
                        fid = self
                            .save_into_temp_dir(cookie, share_id, passcode, &entry.fid, &token)
                            .await?;
                    }
                    dedupe_echo = fid == dead;
                    self.remember_temp(&fid);
                    // ★★ 核心判据（真机缺口）：save 回吐的 fid 必须 ≠ 死 fid。
                    //   相同 = 去重回吐（旧文件删除尚未在服务端生效）；已是最后一次
                    //   ⇒ 直接进"卡住"终态，不再空打一次必死的下载。
                    if fid == dead && resaves >= SELFHEAL_RESAVE_ATTEMPTS {
                        break Err(format!(
                            "{} 临时转存副本被网盘同名去重卡住（下载报 code=21001 file not found）：分享的文件还在，稍后重试通常可恢复，或换一条线路",
                            self.spec.kind.display()
                        ));
                    }
                }
                Err(e) => break Err(e),
            }
        };
        let mut plays = result?;
        plays
            .pop()
            .ok_or_else(|| "转存后取直链没有返回地址".to_string())
    }

    /// 在分享里收集**视频文件候选**（BFS ≤ [`SHARE_PICK_MAX_DEPTH`] 层）
    ///
    /// # 与旧 `pick_share_video`（只回最大一个）的差异
    /// ```text
    /// 返回按体积**降序**的候选清单，供 [`degrade_pick`] 逐个试（23018 降级用）。
    /// 层数语义不变：**浅层优先** —— 某层凑够 [`SHARE_PICK_MAX_TRIES`] 个视频就不再下钻；
    /// 一个视频都没有 ⇒ 兜底用"任意文件"清单（.iso/.exe 伪装很常见，真分享里见得到）。
    /// ```
    async fn pick_share_candidates(
        &self,
        cookie: &str,
        share_id: &str,
        passcode: &str,
    ) -> Result<Vec<DriveEntry>, String> {
        let mut frontier: Vec<String> = vec!["0".to_string()];
        let mut scanned = 0usize;
        let mut videos: Vec<DriveEntry> = Vec::new();
        // 兜底：扩展名不认识但确实是文件（真分享里 .iso/.exe 伪装很常见）
        let mut any_files: Vec<DriveEntry> = Vec::new();
        for depth in 0..=SHARE_PICK_MAX_DEPTH {
            let mut next: Vec<String> = Vec::new();
            for folder in &frontier {
                let entries = self
                    .share_list_family(cookie, share_id, passcode, folder)
                    .await?;
                scanned += entries.len();
                for e in entries {
                    if e.is_dir {
                        if depth < SHARE_PICK_MAX_DEPTH {
                            next.push(e.fid);
                        }
                        continue;
                    }
                    if e.size > 0 {
                        if is_video_name(&e.name) {
                            videos.push(e.clone());
                        }
                        any_files.push(e);
                    }
                }
            }
            // 凑够候选就不下钻（浅层优先；也省请求）
            if videos.len() >= SHARE_PICK_MAX_TRIES {
                break;
            }
            if next.is_empty() {
                break;
            }
            frontier = next;
        }
        let mut pool = if !videos.is_empty() { videos } else { any_files };
        pool.sort_by(|a, b| b.size.cmp(&a.size));
        if pool.is_empty() {
            return Err(format!(
                "分享 {share_id} 里没有任何文件（已扫描 {scanned} 个条目）—— 不是\"没登录\"，是这个分享是空的"
            ));
        }
        Ok(pool)
    }
}

/// 账号单文件下载上限的失败（夸克业务码 23018，message「download file size limit」）
///
/// **纯函数**：只看错误文本，不发请求 —— 门禁直接喂样例串
/// （`play` 的错误串形状是 `"…（code=23018）：download file size limit"`，
/// 两个特征都钉进来，任一命中即算超限）。
pub fn is_size_limit_error(text: &str) -> bool {
    text.contains("code=23018")
        || text.to_lowercase().contains("download file size limit")
}

/// 夸克业务码 21001「file not found」——文件在网盘里**已不存在**
///
/// **纯函数**：只看错误/响应文本，不发请求。
/// ```text
/// 真机实测（2026-11-01，sourin-2026-11-01.log）：
///   14:39:13 取下载地址 400 code=23018 file size limit[e2d3230f…]
///   14:39:40 取下载地址 404 {"code":21001,"message":"file not found [e2d3230f…]"}
/// 同一个 fid 27 秒内从"存在但超限"变"不存在" —— 我们上一次解析的
/// purge 把它删了，而 save 对同名文件去重回吐了这个刚删的 fid（竞态）。
/// ```
/// 判据：**双特征确认**（业务码 + message 短语都命中才算）——
/// 裸 "404" / 单独 "21001" 都不许误伤（普通网页 404 不是这回事）。
pub fn is_file_not_found_21001(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("21001") && lower.contains("file not found")
}

/// 删除任务是否已到**终态**（`sharepage/save` 同族的 `task?` 轮询读数）
///
/// **纯函数**：`Some(true)`=删除完成（status=2）/ `Some(false)`=任务失败（status=3）
/// / `None`=还在跑或形态认不出（继续等；等不到由调用方超时放行）。
pub fn delete_task_done(v: &serde_json::Value) -> Option<bool> {
    let status = v.get("data")?.get("status")?.as_i64()?;
    match status {
        2 => Some(true),
        3 => Some(false),
        _ => None,
    }
}

/// purge 等删除任务完成的**总预算**（lead 批复 A 护栏：不许无限挂住 resolve；
/// 超时继续走，残余竞态由 21001 自愈兜底）
pub const PURGE_DELETE_WAIT_BUDGET: std::time::Duration = std::time::Duration::from_secs(5);

/// 21001 自愈里等"旧 fid 从临时目录清单消失"的预算（回收站/索引最终一致性）
pub const SELFHEAL_LISTING_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

/// 21001 自愈的**重转存次数上限**（不含首次转存；lead 批复：有界，如 3 次转存）
///
/// ★ 真机缺口（2026-11-01 部署版实测）：v1 只重转存一次，而夸克 save 的同名
///   去重作用域**不止活跃目录清单**（回收站/内容级）——wait_fid_gone 确认清单
///   里已无旧 fid，重转存仍回吐同一个死 fid ⇒ 下载还是 21001。v2 改为有界循环：
///   每次重转存**验证新 fid ≠ 死 fid**，相同 ⇒ 换下一档手段（等退避 → 一次性子目录）。
pub const SELFHEAL_RESAVE_ATTEMPTS: u32 = 2;

/// 21001 自愈的**总预算**（含重转存的任务轮询、退避、清单等待；超时即终态，
/// 不许把 resolve 无限挂住 —— save 单次本就有 30s 轮询上限，这里兜加总）
pub const SELFHEAL_TOTAL_BUDGET: std::time::Duration = std::time::Duration::from_secs(40);

/// 自愈重转存的退避基数（第 n 次重转存前等 `BASE × n`：2s → 4s）
pub const SELFHEAL_BACKOFF_BASE: std::time::Duration = std::time::Duration::from_secs(2);

/// PAN 侧轮询间隔（删除任务 / 清单确认共用）
pub const PAN_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(500);

/// 降级重试**最多试几个候选**（Owner 指定：遇 23018 回退次大，最多试 3 个）
pub const SHARE_PICK_MAX_TRIES: usize = 3;

/// ★★★ 降级循环（**纯调度，不发网络** —— 网络在 `try_one` 里，门禁用假闭包喂）
///
/// 按候选顺序（体积降序）逐个尝试：
/// ```text
/// · 成功                ⇒ 返回（命中下标, 值, 降级记录）
/// · 超限（23018）        ⇒ 记一条降级日志与记录，试下一个（最多 max_tries 个）
/// · 其它错误            ⇒ **不降级**，原样抛出（降级只针对"文件太大"这一种失败）
/// · 全部超限            ⇒ Err「该分享的文件超出<盘名>下载上限，请换一条线路」
/// ```
pub async fn degrade_pick<'a, T, Fut, F>(
    candidates: &'a [DriveEntry],
    max_tries: usize,
    pan_short_name: &str,
    mut try_one: F,
) -> Result<(usize, T, Vec<String>), String>
where
    F: FnMut(&'a DriveEntry) -> Fut,
    Fut: std::future::Future<Output = Result<T, String>>,
{
    let mut notes: Vec<String> = Vec::new();
    let tried = candidates.len().min(max_tries);
    for (i, entry) in candidates.iter().take(tried).enumerate() {
        match try_one(entry).await {
            Ok(v) => return Ok((i, v, notes)),
            Err(e) => {
                if !is_size_limit_error(&e) {
                    return Err(e);
                }
                // ★ 2026-10-30：降级过程必须落**文件日志**（tag=PAN，对齐既有 [PAN] 惯例）。
                //   `log` 门面在本 crate 无 sink（streamproxy.rs:2179），log::warn 会被
                //   整个丢弃 —— 真机实锤过「整个降级过程零 [PAN] 输出」的黑洞。
                crate::applog::write_file_log(
                    "PAN",
                    &format!(
                        "降级：第 {} 大的文件 {}（{}）超出下载上限 ⇒ 改试次大候选（{e}）",
                        i + 1,
                        entry.name,
                        human_size(entry.size)
                    ),
                );
                notes.push(format!(
                    "已跳过超限文件 {}（{}）",
                    entry.name,
                    human_size(entry.size)
                ));
            }
        }
    }
    Err(format!(
        "该分享的文件超出{pan_short_name}下载上限，请换一条线路（已尝试 {tried} 个候选）"
    ))
}

/// 21001 自愈第 3 档的重试子目录名（**纯函数**：秒级时间戳 + 进程内序号 ⇒ 唯一）
///
/// 唯一性是"确定性躲开同名去重"的前提 —— 名字撞了，子目录里就可能已有同名文件，
/// 去重又会回吐死 fid（真机缺口的同款）。中性命名（t98 铁律），不用具体盘名。
pub fn retry_subdir_name() -> String {
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("retry-{secs}-{n}")
}

/// 分享里找视频时最多下钻几层目录（整季分文件夹是常态）
const SHARE_PICK_MAX_DEPTH: usize = 2;

/// 上一次播放留下的**临时转存文件**（下一次解析前删掉）
///
/// # 原版行为（Owner 问的正是这件事）
/// ```text
/// dex 实证：`QuarkTempDelete` / `UCTempDelete` + `file/delete`（action_type:2）
/// ⇒ **每次播放转存一份（不复用），播完删掉**。
/// 我们此前只做了前半截 ⇒ 用户网盘里会一直堆；这里记下 fid，下次解析开始时清掉。
/// ```
static TEMP_SAVED: std::sync::OnceLock<std::sync::Mutex<Vec<(String, String)>>> =
    std::sync::OnceLock::new();

fn temp_saved() -> &'static std::sync::Mutex<Vec<(String, String)>> {
    TEMP_SAVED.get_or_init(|| std::sync::Mutex::new(Vec::new()))
}

/// 清理用的 URL（**纯函数**，与取证逐字一致）
fn file_delete_url(spec: &PanDriveSpec) -> String {
    format!(
        "{}/1/clouddrive/file/delete?{}",
        api_root(spec),
        spec.pr_fr
    )
}

/// 清理用的请求体（**纯函数**；`action_type:2` = 移入回收站）
fn file_delete_body(fid: &str) -> String {
    format!(
        "{{\"action_type\":2,\"filelist\":[{}],\"exclude_fids\":[]}}",
        serde_json::Value::String(fid.to_string())
    )
}

/// 这个文件名看起来是可播视频吗（**纯函数**）
fn is_video_name(name: &str) -> bool {
    const EXT: [&str; 12] = [
        "mp4", "mkv", "ts", "m3u8", "flv", "avi", "wmv", "mov", "m4v", "rmvb", "mpg", "webm",
    ];
    let lower = name.to_ascii_lowercase();
    let ext = lower.rsplit_once('.').map(|(_, e)| e).unwrap_or("");
    EXT.contains(&ext)
}

/// 清理**所有盘**上一次留下的临时转存（播放结束时调用；失败只记日志）
///
/// # 为什么是"所有盘"而不是"当前这个盘"
/// ```text
/// 播放器 dispose 时只知道自己播完了一条，**不知道它是哪家盘的分享**（那是 resolve 阶段的上下文）。
/// 而临时表里的条目本来就少（每个盘最多 1 条）⇒ 全清最省事，也不会误删自己网盘里的用户文件
/// （只删我们自己转存进去、且还没清的那几个 fid）。
/// ```
pub async fn purge_all_previous() {
    for kind in [PanKind::Quark, PanKind::Uc] {
        let drive = match kind {
            PanKind::Quark => PanDrive::with_spec("PanQuark", quark_spec()),
            PanKind::Uc => PanDrive::with_spec("PanUC", uc_spec()),
            _ => continue,
        };
        drive.purge_previous().await;
    }
}

/// 人读的文件大小
fn human_size(b: u64) -> String {
    const U: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = b as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{b} B")
    } else {
        format!("{v:.1} {}", U[i])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  两个**薄包装**（各 4 行）—— 这是"一个实现 + N 份配置"的落点
// ═══════════════════════════════════════════════════════════════════════
//
// ★ 为什么必须是两个**类型**而不是一个类型两实例：
// ```text
// `register_site!($site)` 用 `<$site>::CLASS` 当注册键、`<$site>::new()` 造实例
//   ⇒ 注册键是**类型级**的常量 ⇒ 两家必须各有一个类型。
// ★ 而每个类型只做两件事：声明 CLASS + 把 spec 传进 `PanDrive`。
//   **逻辑一行都不重复**（全在 `PanDrive` 里）⇒ 这就是"薄派生"。
// ```

/// `csp_PanQuark`（夸克）
pub struct PanQuark;

impl PanQuark {
    pub const CLASS: &'static str = "PanQuark";
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl CspSite for PanQuark {
    fn class(&self) -> &'static str {
        Self::CLASS
    }
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        PanDrive::with_spec(Self::CLASS, quark_spec()).home(ext).await
    }
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        PanDrive::with_spec(Self::CLASS, quark_spec()).list(tid, page, ext).await
    }
    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        PanDrive::with_spec(Self::CLASS, quark_spec()).detail(id, ext).await
    }
    fn supports_search(&self) -> bool {
        false
    }
    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        PanDrive::with_spec(Self::CLASS, quark_spec()).search(kw, page, ext).await
    }
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        PanDrive::with_spec(Self::CLASS, quark_spec()).play(flag, id, ext).await
    }
}

/// `csp_PanUC`（UC 网盘）—— 与夸克**唯一的差别是 `uc_spec()`**
pub struct PanUc;

impl PanUc {
    pub const CLASS: &'static str = "PanUC";
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl CspSite for PanUc {
    fn class(&self) -> &'static str {
        Self::CLASS
    }
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        PanDrive::with_spec(Self::CLASS, uc_spec()).home(ext).await
    }
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        PanDrive::with_spec(Self::CLASS, uc_spec()).list(tid, page, ext).await
    }
    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        PanDrive::with_spec(Self::CLASS, uc_spec()).detail(id, ext).await
    }
    fn supports_search(&self) -> bool {
        false
    }
    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        PanDrive::with_spec(Self::CLASS, uc_spec()).search(kw, page, ext).await
    }
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        PanDrive::with_spec(Self::CLASS, uc_spec()).play(flag, id, ext).await
    }
}

crate::csp::register_site!(PanQuark);
crate::csp::register_site!(PanUc);

// ═══════════════════════════════════════════════════════════════════════
//  ★ 测试缝（2026-11-01，N-23018 v2）：假服务器夹具的 cookie 注入点
// ═══════════════════════════════════════════════════════════════════════
//
// ⚠️ 本块必须位于**全部生产代码之后**：`share_chain_wires_share_referer`
//    门禁按文件里首个 `#[cfg(test)]` 切出"生产段"再数接线，
//    这里的 cfg 标记若落在 share_referer 调用点之前，会把生产段截短（实测踩过）。
#[cfg(test)]
static TEST_COOKIE_OVERRIDES: std::sync::OnceLock<std::sync::Mutex<Vec<(String, String)>>> =
    std::sync::OnceLock::new();

/// ★ 测试缝：假网盘夹具的 API 根，**按 api_host 键控**
///
/// 键控的原因：cargo test 的用例默认并行 —— 若用单一全局覆盖，夹具会把
/// 同进程并行的 URL 字节级门禁（quark_spec 的 drive-pc.quark.cn）一起改道。
/// 夹具把自己的 spec.api_host 设成哨兵 host（127.0.0.1:port）再键入覆盖 ⇒
/// 其它测试查不到 ⇒ 平行安全。
#[cfg(test)]
static TEST_API_BASES: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, String>>> =
    std::sync::OnceLock::new();

/// ★ 测试缝：夹具互斥锁 —— `TEMP_SAVED` 账本是**进程级共享**的，三个夹具
/// 并行会互相 purge 掉对方的记账（LIFO 断言被打乱）⇒ 夹具整体串行。
#[cfg(test)]
static FIXTURE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

impl PanDrive {
    /// ★ 测试缝（仅测试编译存在）：假服务器夹具需要"已登录"态，而真 cookie
    ///   在系统钥匙串里 —— 夹具从这里注入；生产构建本函数不存在（恒 None）。
    #[cfg(test)]
    fn test_cookie_override(&self) -> Option<String> {
        let guard = TEST_COOKIE_OVERRIDES
            .get_or_init(|| std::sync::Mutex::new(Vec::new()))
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        guard
            .iter()
            .find(|(k, _)| k == &self.spec.kind.code().to_string())
            .map(|(_, c)| c.clone())
    }

    /// 仅供测试（见上文）：注入/清除假 cookie。cookie 传空串 ⇒ 清除该盘的注入。
    #[cfg(test)]
    fn debug_set_test_cookie(kind: &str, cookie: &str) {
        let mut guard = TEST_COOKIE_OVERRIDES
            .get_or_init(|| std::sync::Mutex::new(Vec::new()))
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        guard.retain(|(k, _)| k != kind);
        if !cookie.is_empty() {
            guard.push((kind.to_string(), cookie.to_string()));
        }
    }

    /// 仅供测试：见 `api_root`（假网盘夹具的 API 根，按 api_host 键控）。
    #[cfg(test)]
    fn test_api_base_for(host: &str) -> Option<String> {
        TEST_API_BASES
            .get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(host)
            .cloned()
    }

    /// 仅供测试：设置/清除假网盘 API 根（键 = api_host；base 空串 ⇒ 清除）。
    #[cfg(test)]
    fn debug_set_test_api_base(host: &str, base: &str) {
        let mut guard = TEST_API_BASES
            .get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if base.is_empty() {
            guard.remove(host);
        } else {
            guard.insert(host.to_string(), base.to_string());
        }
    }
}

#[cfg(not(test))]
impl PanDrive {
    fn test_api_base_for(_host: &str) -> Option<String> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quark_and_uc_specs_differ_only_in_data() {
        let q = quark_spec();
        let u = uc_spec();
        // ★ 这正是"一份实现 + 两份数据"的**判据**：
        //   两家差异必须**只在数据里**（kind/host/pr/货架），代码只有一份。
        assert_ne!(q.kind, u.kind);
        assert_ne!(q.api_host, u.api_host);
        assert_ne!(q.pr_fr, u.pr_fr);
        assert_ne!(q.shelves, u.shelves, "★ 两家的货架清单必须不同（否则不用两份数据）");
    }

    #[test]
    fn shelves_are_data_not_hardcoded_in_logic() {
        // ★ 反空真：货架必须非空，且**名字**来自数据（改数据就改行为）
        let q = quark_spec();
        assert!(!q.shelves.is_empty(), "货架清单不能为空");
        let mut alt = quark_spec();
        alt.shelves[0].name = "我改的名字".into();
        let d = PanDrive::with_spec("PanQuark", alt);
        assert_eq!(d.spec.shelves[0].name, "我改的名字", "★ 名字必须跟着数据走");
    }

    #[test]
    fn login_hint_matches_reference_wording() {
        // ★ 用户可见文案属**行为层**，与参考实现逐字一致（用户看到的话不该变）
        assert_eq!(login_hint(PanKind::Quark), "还未登录夸克账号,请前往【配置中心】登录");
        assert_eq!(login_hint(PanKind::Uc), "还未登录UC账号,请前往【配置中心】登录");
    }

    #[test]
    fn human_size_is_readable_and_never_panics() {
        assert_eq!(human_size(0), "0 B");
        assert_eq!(human_size(512), "512 B");
        assert_eq!(human_size(1024), "1.0 KB");
        assert_eq!(human_size(1024 * 1024 * 3 / 2), "1.5 MB");
    }

    #[test]
    fn parse_entries_skips_items_without_fid() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"data":{"list":[
                {"fid":"f1","file_name":"a.mp4","dir":false,"size":100},
                {"file_name":"没有 id 的条目"},
                {"fid":"d1","file_name":"目录","dir":true,"size":0}
            ]}}"#,
        )
        .unwrap();
        let e = parse_entries(&v);
        assert_eq!(e.len(), 2, "★ 没 fid 的条目必须丢掉（编一个 id 只会让详情失败）");
        assert_eq!(e[0].fid, "f1");
        assert!(!e[0].is_dir);
        assert!(e[1].is_dir);
    }

    #[test]
    fn parse_entries_on_unexpected_shape_is_empty_not_panic() {
        let v: serde_json::Value = serde_json::from_str(r#"{"data":{}}"#).unwrap();
        assert!(parse_entries(&v).is_empty());
        let v2: serde_json::Value = serde_json::from_str("{}").unwrap();
        assert!(parse_entries(&v2).is_empty());
    }

    #[test]
    fn supports_search_is_false_with_hard_evidence() {
        let d = PanDrive::with_spec("PanQuark", quark_spec());
        assert!(
            !d.supports_search(),
            "★ 订阅里 searchable:0 ⇒ 必须 false（否则会被 registry 拉进搜索，多打注定失败的请求）"
        );
    }

    /// ★★★ 无 cookie 时：home/list/detail/play **都必须如实报登录**，不许返回空
    ///
    /// ```text
    /// 注入验证：把 `login_hint` 那行改成 `return Ok(CspHome::default())`
    ///   ⇒ 本条红（那会让用户看到"这个盘是空的"，而不是"你没登录"）
    /// ```
    #[tokio::test]
    async fn without_cookie_every_path_says_login_not_empty() {
        // ⚠️ 测试环境里钥匙串通常没有夸克凭据 ⇒ 天然就是"无 cookie"路径。
        //    若某台机器**恰好有**（开发者真登录过），本用例会失真 ——
        //    所以先探一下：有凭据就跳过（如实打印原因，不静默）。
        // ⚠️ 还要躲开假网盘夹具的 cookie 注入窗（FIXTURE_LOCK 串行化，
        //    N-23018 v2）：夹具运行期间本用例若并行，会把"假 cookie 在场"
        //    误当成"登录态"⇒ 握手报网络/业务错误而不是"登录"。
        let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        if crate::pan_auth::load(PanKind::Quark).is_some() {
            eprintln!("本机钥匙串已有夸克凭据 ⇒ 跳过『无 cookie』用例（避免假绿/假红）");
            return;
        }
        let d = PanDrive::with_spec("PanQuark", quark_spec());
        for (what, r) in [
            ("home", d.home("").await.err()),
            ("list", d.list("0", 1, "").await.err()),
            ("detail", d.detail("fid1", "").await.err()),
            ("play", d.play("", "fid1", "").await.err()),
        ] {
            let e = r.unwrap_or_else(|| panic!("★ {what} 在无 cookie 时必须 Err（不许返回空）"));
            assert!(
                e.contains("登录"),
                "★★ {what} 的错误必须说『登录』（用户要知道怎么办）—— 实际：{e}"
            );
        }
    }

    /// ★★★ 货架下标越界必须报错（不许静默返回空列表）
    #[tokio::test]
    async fn list_with_out_of_range_shelf_is_error() {
        // 躲开假网盘夹具的 cookie 注入窗（同 without_cookie 用例的说明）
        let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        if crate::pan_auth::load(PanKind::Quark).is_some() {
            eprintln!("有凭据 ⇒ 跳过（本用例需要一个确定的『无凭据』或『有凭据』路径）");
            // 有凭据时也应报错（下标越界与凭据无关），继续测
        }
        let d = PanDrive::with_spec("PanQuark", quark_spec());
        let r = d.list("99", 1, "").await;
        assert!(r.is_err(), "★ 货架下标越界（本盘只有几个）必须报错，实际：{r:?}");
    }

    /// ★ 2026-10-28 重写：这条原先调 `list("abc")` 断言"必须 Err"，
    /// 而它**依赖本机是否登录过网盘**（有凭据 ⇒ 走真网络、返回真列表 ⇒ 用例红）。
    /// 那种"测试读机器状态"的用例不是判据，是运气 ⇒ 改成测**纯函数**。
    #[test]
    fn parse_shelf_and_dir_handles_three_shapes() {
        // ① 裸下标（首页给的货架号）
        assert_eq!(parse_shelf_and_dir("2").unwrap(), (2, None));
        // ② `<下标>:<目录 fid>` —— 点目录进那一层（2026-10-28 的真缺陷）
        assert_eq!(
            parse_shelf_and_dir("0:d8b433aba8804d229371d2de969aa3cf").unwrap(),
            (0, Some("d8b433aba8804d229371d2de969aa3cf".to_string()))
        );
        // ③ 裸 fid（旧数据/外部调用）⇒ 第 0 个货架下的那一层
        assert_eq!(
            parse_shelf_and_dir("abc").unwrap(),
            (0, Some("abc".to_string()))
        );
        // 反面：货架那一段不是数字 ⇒ 仍报错（不许静默当成第 0 个）
        assert!(parse_shelf_and_dir("x:abc").is_err(), "货架段必须是数字");
        assert!(parse_shelf_and_dir("").is_err(), "空串必须报错");
    }

    /// ★★★ 反"猜字段名"门禁：`parse_entries` 用到的键必须**都在取证清单里**
    ///
    /// ```text
    /// 背景：我第一版用 `dir` / `size` 当字段名 —— **两个都没取证**。
    ///   交叉核对参考实现（merge/b/w、merge/b/B 的方法体字符串）：
    ///     取证到：fid / file_name / pdir_fid / dir_path / data
    ///     没取证到：dir / size / file_size / fsize
    ///   ⇒ 全 dex 里 `"dir"` 只在无关的 merge.A0.* 库类里；
    ///     `"size"` 只在 merge/b/m（**123 的**助手）里。
    /// ★ 为什么这条值得做成门禁：
    ///   本项目已有一次同族教训（我把 UC 的 `_size=200` 串到夸克上）——
    ///   **未取证的字段名不会报错**，只会让字段恒为默认值（`is_dir` 恒 false / size 恒 0）
    ///   ⇒ UI 上表现为"目录点不进去"或"大小显示空"，**很难追到根因**。
    /// ⇒ 本门禁：把"允许使用的字段名"写成**清单**，注入一个不在清单里的键 ⇒ 红。
    /// ```
    #[test]
    fn parse_entries_only_uses_forensically_known_keys() {
        // ★ 取证来源：merge/b/w + merge/b/B 的方法体字符串常量（见文件头）
        const FORENSIC_KEYS: [&str; 7] = [
            "fid",       // 条目 id（★ 参考实现直接用）
            "file_name", // 条目名（★ 参考实现直接用）
            "pdir_fid",  // 父目录（★ 请求参数里）
            "dir_path",  // 目录路径（★ 参考实现用；含值 ⇒ 是目录）
            "size",      // ⚠️ 未取证于夸克/UC，但**保留**（见下"为什么允许"）
            "file_size",
            "fsize",
        ];
        // ★ 本门禁的**真实强度**（如实标注，不夸大）：
        //   它**不能**证明"我只用了取证过的键" —— 因为我把 `dir`/`size` 当
        //   **多路尝试**保留了（拿不到就退到 0/false）。所以它测的是两件**较窄**的事：
        //     ① 完全未知的键**不会**被误读（防止"随便哪个键都能当 dir"）
        //     ② 取证到的键**必须**生效（防止门禁退化成"什么都不认"）
        //   ⚠️ 至于 `dir`/`size` 本身未取证这件事，**只能靠注释记录**（本文件已写），
        //      门禁管不到 —— 因为"保留未取证键"是个**有意的取舍**，不是缺陷。
        let v: serde_json::Value = serde_json::from_str(
            r#"{"data":{"list":[
                {"fid":"f1","file_name":"x","is_directory":true,"byte_size":123}
            ]}}"#,
        )
        .unwrap();
        let e = parse_entries(&v);
        assert_eq!(e.len(), 1);
        assert!(
            !e[0].is_dir,
            "★★ `is_dir` 不许由**完全不认识**的键推出 —— 实际被当成目录了"
        );
        assert_eq!(
            e[0].size, 0,
            "★★ `size` 不许由**完全不认识**的键推出（实际取到了值）"
        );
        // ★ 正面：取证到的键**必须**生效（否则门禁退化成"什么都不认"）
        let ok: serde_json::Value = serde_json::from_str(
            r#"{"data":{"list":[{"fid":"f2","file_name":"y","dir_path":"/a/b","size":42}]}}"#,
        )
        .unwrap();
        let e2 = parse_entries(&ok);
        assert_eq!(e2.len(), 1, "取证到的键必须能解析出条目");
        assert_eq!(e2[0].name, "y");
        assert!(e2[0].is_dir, "★ `dir_path` 有值 ⇒ 判为目录（代理判据）");
        assert_eq!(e2[0].size, 42, "★ `size` 若真存在应被取到");
        // 清单本身非空且无重复（反空真：清单为空则本门禁恒真）
        assert_eq!(FORENSIC_KEYS.len(), 7);
        assert!(!FORENSIC_KEYS.is_empty(), "★ 清单不许为空");
    }

    /// ★★ URL 逐字门禁：**对照参考实现的字符串常量**（不只看"能不能构造出来"）
    ///
    /// ```text
    /// 参考实现（dex 方法体字符串，逐字）：
    ///   夸克 merge/b/w：
    ///     https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=
    ///       &pdir_fid=0&_page=1&_size=50&_fetch_total=1&_fetch_sub_dirs=0
    ///       &_sort=file_type:asc,file_name:asc
    ///   UC  merge/b/B：
    ///     https://pc-api.uc.cn/1/clouddrive/file/sort?pr=UCBrowser&fr=pc
    ///       &pdir_fid=0&_page=1&_size=200&_fetch_total=1&_fetch_sub_dirs=0&_sort=…
    /// ⇒ 两家的 **`_size` 不同**（50 vs 200）。
    /// ★ 这条门禁是**交叉核对参考实现时抓到我自己的真缺陷**而加的：
    ///   我第一版把 `_size` 写死 200（那是 UC 的值）⇒ 夸克那边**参数不是逐字**。
    ///   而那种错**不会报错**（接口照样 200）⇒ 只有"断言逐字"能抓。
    /// 注入验证：把 `page_size` 改成同一个值（如都 200）⇒ 本条红。
    /// ```
    #[test]
    fn list_dir_url_matches_reference_byte_for_byte() {
        let q = list_dir_url(&quark_spec(), "0");
        let u = list_dir_url(&uc_spec(), "0");
        // 夸克：host / pr / **size=50** 逐字
        assert!(
            q.starts_with(
                "https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=0&_page=1&_size=50&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,file_name:asc"
            ),
            "★ 夸克 URL 与参考实现不逐字：{q}"
        );
        // UC：host / pr / **size=200** 逐字
        assert!(
            u.starts_with(
                "https://pc-api.uc.cn/1/clouddrive/file/sort?pr=UCBrowser&fr=pc&uc_param_str=&pdir_fid=0&_page=1&_size=200&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,file_name:asc"
            ),
            "★ UC URL 与参考实现不逐字：{u}"
        );
        // ★ 反空真：两家的 URL 必须**不同**（否则"两份数据"没意义）
        assert_ne!(q, u, "★ 两家的 list URL 必须不同（host/pr/size 至少一处）");
        // ★ 且不能只是 host 不同而 size 串了 —— 单独钉住 size
        assert_ne!(
            quark_spec().page_size,
            uc_spec().page_size,
            "★★ 两家的 `_size` 必须不同（夸克 50 / UC 200）—— \
             串了不会报错，只会让结果集不符"
        );
    }

    /// ★★ 目录参数要能替换（不是写死 `pdir_fid=0`）
    #[test]
    fn list_dir_url_takes_dir() {
        let u = list_dir_url(&quark_spec(), "abc123");
        assert!(u.contains("pdir_fid=abc123"), "★ 目录参数必须生效：{u}");
        assert!(!u.contains("pdir_fid=0&"), "★ 不许把目录写死成 0：{u}");
    }

    /// ★★★ 纯函数门禁：货架下标解析（**不依赖 cookie**，所以文案断言能精确）
    ///
    /// ```text
    /// 为什么单独抽出来测：`list()` 前面有"登录闸"⇒ 无凭据时永远先报登录，
    ///   拿不到 tid 那句 ⇒ **判据依赖一个不确定的前置状态**（我第一版就假红了）。
    /// ★ 抽成纯函数后：判"非数字 tid 报什么"**与凭据无关** ⇒ 判据确定。
    /// ```
    #[test]
    fn parse_shelf_index_rejects_non_numeric_with_actionable_text() {
        let e = parse_shelf_index("abc").expect_err("非数字必须 Err");
        assert!(e.contains("数字"), "文案要点明要求：{e}");
        assert!(e.contains("abc"), "文案要带上实际收到的值（便于定位）：{e}");
        let e2 = parse_shelf_index("").expect_err("空 tid 必须 Err");
        assert!(e2.contains("数字") || e2.contains("空"), "{e2}");
        // 正常值
        assert_eq!(parse_shelf_index("0").unwrap(), 0);
        assert_eq!(parse_shelf_index(" 2 ").unwrap(), 2, "★ 两侧空白要能容忍");
    }

    /// ★★★ 纯函数门禁：货架越界（同上，独立于凭据）
    ///
    /// ```text
    /// 注入验证：把 `shelf_of` 的越界检查删掉、改成 `unwrap_or(第一个)`
    ///   ⇒ 本条红（越界会静默列出错误货架 —— 用户看到的是别人的分享）。
    /// ```
    #[test]
    fn shelf_lookup_rejects_out_of_range_with_count() {
        let q = quark_spec();
        let e = shelf_of(&q, 99).expect_err("越界必须 Err");
        assert!(e.contains("99"), "要带上问的哪个：{e}");
        assert!(
            e.contains(&q.shelves.len().to_string()),
            "★ 要说明本盘共几个（用户才知道可用范围）：{e}"
        );
        assert!(shelf_of(&q, 0).is_ok(), "0 号必须有效（至少一个货架）");
    }

    #[tokio::test]
    async fn search_says_unsupported_not_empty_result() {
        let d = PanDrive::with_spec("PanQuark", quark_spec());
        let e = d.search("任意词", 1, "").await.expect_err("★ 必须 Err，不许 Ok(空)");
        assert!(e.contains("不支持搜索"), "{e}");
    }

    /// ★★ 非本族的盘：分享货架必须如实报"未接通"，不许假装能列
    ///
    /// ★ 2026-10-28：夸克/UC 接通后，这条改用 **百度**（结构不同的那类）来守 ——
    ///   否则它会去发真网络请求（假绿：断言靠"网络失败"而不是"这条路没接"）。
    #[tokio::test]
    async fn shared_shelf_says_not_wired_instead_of_pretending() {
        let mut spec = quark_spec();
        spec.kind = PanKind::Baidu;
        let d = PanDrive::with_spec("PanBaidu", spec);
        // 直接调内部函数（绕过 cookie 检查）
        let e = d.list_shared("fake-cookie", "abc123", "0").await.expect_err("必须 Err");
        assert!(
            e.contains("未接通") || e.contains("尚未"),
            "★★ 分享货架未接通时必须如实说（实际：{e}）—— 不许返回空列表冒充"
        );
    }

    // ── ★ 注册契约与"插件化"约束的门禁 ──

    /// ★★★ 两个类名必须**不同**且与订阅 `api` 字段逐字对齐
    #[test]
    fn two_classes_have_distinct_names() {
        assert_ne!(PanQuark::CLASS, PanUc::CLASS);
        assert_eq!(PanQuark::CLASS, "PanQuark");
        assert_eq!(PanUc::CLASS, "PanUC");
        // ★ 与订阅里的 `api`（`csp_PanQuark` / `csp_PanUC`）逐字对齐；
        //   前缀由 `csp::PREFIX` 加 ⇒ 这里只守裸类名
        assert_eq!(PanQuark::new().class(), "PanQuark");
        assert_eq!(PanUc::new().class(), "PanUC");
    }

    /// ★★ 两家的 host / pr 必须不同（若贴错 ⇒ UC 会打夸克接口：
    ///   能"部分成功"但数据是错的 ⇒ **比报错难查**）
    #[test]
    fn uc_spec_differs_from_quark_in_host_and_pr() {
        let q = quark_spec();
        let u = uc_spec();
        assert_eq!(q.kind, PanKind::Quark);
        assert_eq!(u.kind, PanKind::Uc);
        assert_ne!(q.api_host, u.api_host, "★★ UC 的 API host 必须与夸克不同");
        assert_ne!(q.pr_fr, u.pr_fr, "★★ UC 的 pr/fr 参数必须与夸克不同");
    }

    /// ★★ `supports_search()` 门禁钉住**两个类**（薄包装很容易漏改一个）
    ///
    /// ```text
    /// 依据（硬）：订阅 searchable:0 + `registry.rs:287` 用 capabilities.search
    ///   决定"要不要把这个源拉进搜索" ⇒ 返 true 会让用户每次搜索多打一轮注定失败的请求。
    /// 注入验证：把任一类改成 true ⇒ 本条红。
    /// ```
    #[test]
    fn both_wrappers_report_supports_search_false() {
        assert!(!PanQuark::new().supports_search(), "★ PanQuark 必须 false");
        assert!(!PanUc::new().supports_search(), "★ PanUC 必须 false");
        assert!(
            !PanDrive::with_spec("PanQuark", quark_spec()).supports_search(),
            "★ 内部实现也必须 false（薄包装 true 也救不回来）"
        );
    }

    /// ★★ `class()` 必须**跟着数据走**（不是写死常量）
    ///
    /// ```text
    /// 注入验证：把 `PanDrive.class` 改成写死 "PanQuark"
    ///   ⇒ UC 实例报错类名 ⇒ 本条红（注册键与实现不符 = 跨盘错绑）。
    /// ```
    #[test]
    fn pan_drive_class_follows_spec_not_hardcoded() {
        let q = PanDrive::with_spec("PanQuark", quark_spec());
        let u = PanDrive::with_spec("PanUC", uc_spec());
        assert_eq!(q.class(), "PanQuark");
        assert_eq!(u.class(), "PanUC", "★ UC 实例必须报 PanUC，不许写死成 PanQuark");
    }

    // ── 分享链路（2026-10-28 接通）的门禁 ──

    /// ★★★ 换 token 的 body 必须是 **JSON**（表单形态实测 500/15000）
    ///
    /// ```text
    /// 注入验证（已实测真红）：把 `share_token_body` 改成表单拼法
    ///   `format!("pwd_id={share_id}&passcode={passcode}")` ⇒ 本条 FAILED。
    /// 这条就是"为什么它现在能通"的唯一判据 —— 差别只在 body 形状。
    /// ```
    #[test]
    fn share_token_body_is_json_not_form() {
        let b = share_token_body("ba2e2f0417114", "");
        assert_eq!(b, r#"{"pwd_id":"ba2e2f0417114","passcode":""}"#);
        assert!(b.starts_with('{'), "★ 必须是 JSON 对象：{b}");
        // 反面：不许退化成表单
        assert!(
            !b.contains("pwd_id=") || b.contains("\"pwd_id\""),
            "★★ 表单形态（`pwd_id=…&passcode=`）实测恒 500/15000：{b}"
        );
        assert!(!b.contains('&'), "★ 表单才有 `&`：{b}");
    }

    /// ★★ URL 逐字对齐实测（UC 的 host 是 `pc-api`，不是 `drive.uc.cn` —— 后者 403）
    #[test]
    fn share_urls_match_the_verified_probe() {
        let uc = uc_spec();
        assert_eq!(
            share_token_url(&uc),
            "https://pc-api.uc.cn/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc"
        );
        let d = share_detail_url(&uc, "s1", "a+b/c=", "0", 1);
        assert!(d.starts_with(
            "https://pc-api.uc.cn/1/clouddrive/share/sharepage/detail?pr=UCBrowser&fr=pc&pwd_id=s1"
        ), "{d}");
        assert!(d.contains("stoken=a%2Bb%2Fc%3D"), "★★ stoken 必须编码：{d}");
        assert!(d.contains("pdir_fid=0") && d.contains("_size=50"), "{d}");
        assert!(!d.contains("drive.uc.cn"), "★★ 换 token 只认 pc-api 这台：{d}");
    }

    /// ★★★ 同族但**不许串盘**：夸克那两条 URL 必须是夸克自己的 host/pr
    ///
    /// ```text
    /// 注入验证：把 `share_token_url` 写死成 `pc-api.uc.cn` + `pr=UCBrowser&fr=pc`
    ///   ⇒ 本条 FAILED（夸克会把分享 token 请求发到 UC 的机器上）。
    /// 这是"一份实现 + 两份数据"的判据：数据串了不会报错，只会**静默取错**。
    /// ```
    #[test]
    fn quark_share_urls_use_its_own_host_and_pr() {
        let q = quark_spec();
        assert_eq!(
            share_token_url(&q),
            "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc"
        );
        let d = share_detail_url(&q, "6c3812f483a6", "tok", "0", 1);
        assert!(
            d.starts_with(
                "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc"
            ),
            "{d}"
        );
        assert!(
            !d.contains("pc-api.uc.cn") && !d.contains("UCBrowser"),
            "★★ 夸克不许借用 UC 的 host/pr：{d}"
        );
    }

    /// ★★★ T4-C 门禁（2026-10-31）：分享 Referer 构造点拒绝控制字符并带原值
    ///
    /// ```text
    /// 根因实测形态：复合剧集 id 双重拼接后 `\u{1}` 落进 share_id
    /// （`8efcd269e4b7\u{1}https:`）⇒ 旧代码直接 format! 进 Referer ⇒
    /// reqwest send 时 `Error::builder`（一个字节没发出去）。
    /// 注入证红：把三处调用点改回 `format!("{}/s/{share_id}", …)` ⇒
    ///   接线断言红；把 share_referer 的控制字符分支删掉 ⇒ 行为断言红。
    /// ```
    #[test]
    fn share_referer_rejects_control_chars_with_original_value() {
        let spec = quark_spec();
        // 干净 id：逐字拼出（既有行为不许变）
        assert_eq!(
            share_referer(&spec, "8efcd269e4b7").unwrap(),
            "https://pan.quark.cn/s/8efcd269e4b7"
        );
        // 根因实测形态：拒绝，且错误里带原值（Debug 转义让 \u{1} 可见）
        let e = share_referer(&spec, "8efcd269e4b7\u{1}https:").unwrap_err();
        assert!(e.contains("非法控制字符"), "要点明拒绝原因：{e}");
        assert!(e.contains("\\u{1}"), "错误必须带原值（Debug 转义）：{e}");
        // 别的控制字符同样拒（\r/\n 是最常见的注入形态）
        assert!(share_referer(&spec, "abc\r\ndef").is_err());
    }

    /// 接线断言：分享链路三处 Referer 构造（save/token/detail）都必须走校验
    ///
    /// ```text
    /// ★ 只数 `#[cfg(test)]` **之前**的代码段 —— 不然本测试自己的源码字面量
    ///   也算一处（T4-C 实测抓到的假绿：注入掉一个调用点后断言仍绿）。
    /// ```
    #[test]
    fn share_chain_wires_share_referer() {
        let src = include_str!("pan_drive.rs");
        let prod = src.split("#[cfg(test)]").next().unwrap_or("");
        let n = prod.matches("share_referer(&self.spec, share_id)?").count();
        assert!(
            n >= 3,
            "save/token/detail 三处 Referer 都必须走 share_referer 校验，实际 {n} 处"
        );
    }

    /// ★★★ 分享条目的 id 必须能被 `list` / `play` 解回来（**编解码成对**）
    ///
    /// ```text
    /// 这是"分享链接能播"的唯一支点：
    ///   list 把 (shareId, fid, fidToken) 编进 id → play 解出来 → sharepage/save
    /// 任何一端改了形状 ⇒ 静默退化成"格式解不了"。
    /// 注入验证（已实测真红）：
    ///   ① 把 `item_id_of` 的分享分支改回 `e.fid.clone()` ⇒ 本条 FAILED（token 丢了）
    ///   ② 把 `parse_share_item` 的 `splitn(3, ':')` 改成 `splitn(2, ':')` ⇒ 本条 FAILED
    /// ```
    /// ★★★ "播完即删"必须**真的接上**：FFI 有命令、实现有入口
    ///
    /// ```text
    /// 只写一个 pub fn 没人调 = 没做。这里读 `ffi.rs` 源码断言命令名与调用点都在
    /// （本仓既有先例：`tvbox_aggregate.rs` 用 include_str! 守"注释里的判据"）。
    /// 注入验证：删掉 ffi.rs 里那条 arm ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn cleanup_command_is_wired_for_playback_end() {
        let ffi = include_str!("../ffi.rs");
        assert!(
            ffi.contains("\"pan_cleanup_temp\""),
            "★★ Dart 在播放器 dispose 时调的命令必须在 FFI 里有分支"
        );
        assert!(
            ffi.contains("purge_all_previous"),
            "★ 命令要真的调到清理实现，不许是空分支"
        );
    }

    /// ★★★ 清理 URL/体（与 dex 取证逐字一致）
    ///
    /// ```text
    /// 注入验证：把 `action_type` 从 2 改成 1 ⇒ 本条 FAILED
    ///   （1 = 真删、2 = 移入回收站；原版用 2，删错了用户找不回）。
    /// ```
    #[test]
    fn temp_cleanup_matches_the_reference() {
        let q = quark_spec();
        assert_eq!(
            file_delete_url(&q),
            "https://drive-pc.quark.cn/1/clouddrive/file/delete?pr=ucpro&fr=pc"
        );
        assert_eq!(
            file_delete_body("f1"),
            r#"{"action_type":2,"filelist":["f1"],"exclude_fids":[]}"#
        );
        assert_eq!(
            file_delete_url(&uc_spec()),
            "https://pc-api.uc.cn/1/clouddrive/file/delete?pr=UCBrowser&fr=pc"
        );
    }

    /// ★★ 挑视频的判据（纯函数）
    #[test]
    fn video_name_detection_is_narrow() {
        assert!(is_video_name("第01集.mp4"));
        assert!(is_video_name("MOVIE.MKV"), "大小写不敏感");
        assert!(!is_video_name("字幕.ass"));
        assert!(!is_video_name("封面.jpg"));
        assert!(!is_video_name("没有扩展名"));
    }

    /// ★★★ 真网络：用**本机钥匙串里的夸克登录态**解析一个真分享页（默认 ignored）
    ///
    /// ```text
    /// cargo test --lib quark_share_live_resolves --release -- --ignored --nocapture
    /// 判据：打印直链前缀；`__puus` 必须已在 Cookie 里（缺它 CDN 403）。
    /// 大小超限 / 分享失效都是**真实边界**，打印出来让人判读，不伪造成功。
    /// ```
    #[tokio::test]
    #[ignore = "真网络：需要本机钥匙串里的夸克登录态"]
    async fn quark_share_live_resolves() {
        let share = std::env::var("SHARE_ID").unwrap_or_else(|_| "6c3812f483a6".to_string());
        let d = PanDrive::with_spec("PanQuark", quark_spec());
        match d.resolve_share_play(&share, "").await {
            Ok(p) => {
                eprintln!("[LIVE] 分享 {share} ⇒ 直链 {}", p.url.chars().take(110).collect::<String>());
                assert!(p.url.starts_with("http"));
                assert!(p
                    .headers
                    .iter()
                    .any(|(k, v)| k == "Cookie" && v.contains("__puus")));
            }
            Err(e) => {
                eprintln!("[LIVE] 分享 {share} 解析失败：{e}");
            }
        }
    }

    /// ★★ 真网络：把分享根目录逐条打出来（诊断"转存 token 校验异常"用）
    #[tokio::test]
    #[ignore = "真网络：需要本机钥匙串里的夸克登录态"]
    async fn quark_share_live_list() {
        let share = std::env::var("SHARE_ID").unwrap_or_else(|_| "6c3812f483a6".to_string());
        let d = PanDrive::with_spec("PanQuark", quark_spec());
        let Some(cookie) = d.cookie() else {
            eprintln!("[LIVE] 没有夸克登录态 ⇒ 跳过");
            return;
        };
        match d.share_list_family(&cookie, &share, "", "0").await {
            Ok(list) => {
                eprintln!("[LIVE] 分享 {share} 根目录 {} 条：", list.len());
                for e in &list {
                    eprintln!(
                        "  name={:?} dir={} size={} token_len={}",
                        e.name,
                        e.is_dir,
                        e.size,
                        e.fid_token.as_deref().map(|t| t.len()).unwrap_or(0)
                    );
                }
            }
            Err(e) => eprintln!("[LIVE] 列目录失败：{e}"),
        }
    }

    #[test]
    fn share_item_id_roundtrip() {
        let share_shelf = Shelf {
            name: "别人的分享".into(),
            share_id: "6c3812f483a6".into(),
            folder: "0".into(),
        };
        let file = DriveEntry {
            fid: "d8b433aba8804d229371d2de969aa3cf".into(),
            name: "第01集.mp4".into(),
            is_dir: false,
            size: 1024,
            fid_token: Some("9f2c1a".into()),
        };
        let id = item_id_of(&share_shelf, 1, &file);
        assert_eq!(id, "share:6c3812f483a6:d8b433aba8804d229371d2de969aa3cf:9f2c1a");

        // play 端：解回三要素
        let (sid, fid, tok) = parse_share_item(&id).expect("分享条目必须能解回来");
        assert_eq!(sid, "6c3812f483a6");
        assert_eq!(fid, "d8b433aba8804d229371d2de969aa3cf");
        assert_eq!(tok, "9f2c1a", "★★ fid_token 丢了 ⇒ 转存必然失败");

        // list 端：分享内的**目录**同样能下钻（fid 就是分享里的 pdir_fid）
        let dir = DriveEntry {
            fid: "5a84777138e14ceb90289aec0068d1dc".into(),
            name: "战邮1942".into(),
            is_dir: true,
            size: 0,
            fid_token: Some("401a4dc47a1f0da3a8c92ecc05759a6d".into()),
        };
        let spec = PanDriveSpec {
            shelves: vec![uc_spec().shelves[0].clone(), share_shelf.clone()],
            ..uc_spec()
        };
        let dir_id = item_id_of(&share_shelf, 1, &dir);
        let (idx, folder) = list_target(&spec, &dir_id).expect("分享目录必须能下钻");
        assert_eq!(idx, 1, "必须回到**这个分享**所在的货架");
        assert_eq!(folder, dir.fid, "目录 fid 就是 pdir_fid");

        // 反面：自己网盘形状保持不变（裸 fid 不许被当成分享）
        let own = DriveEntry {
            fid: "abc123".into(),
            name: "a.mp4".into(),
            is_dir: false,
            size: 1,
            fid_token: None,
        };
        let own_shelf = uc_spec().shelves[0].clone();
        assert_eq!(item_id_of(&own_shelf, 0, &own), "abc123");
        assert!(parse_share_item("abc123").is_none());
    }

    /// ★★ 货架被改过（分享 id 不在 spec 里）⇒ 可读 Err，不许静默列第 0 个货架
    #[test]
    fn list_target_rejects_unknown_share() {
        let e = list_target(&uc_spec(), "share:not-in-spec:fid:tok")
            .expect_err("未知分享必须报错");
        assert!(e.contains("not-in-spec"), "要点明是哪个分享：{e}");
        assert!(e.contains("货架"), "要给出下一步（回首页重开）：{e}");
    }

    /// ★★★ 真实分享响应片段（2026-10-28 实测 capture，裁剪到关键字段）
    #[test]
    fn uc_share_detail_parses_real_fragment() {
        let body = r#"{"status":200,"code":0,"message":"ok","data":{"is_owner":0,"list":[
            {"fid":"5a84777138e14ceb90289aec0068d1dc","file_name":"战邮1942",
             "file_type":0,"size":0,"dir":true,"file":false,
             "share_fid_token":"401a4dc47a1f0da3a8c92ecc05759a6d"}]}}"#;
        let v = share_envelope("UC", body, "列分享目录").expect("实测响应必须过信封");
        let e = parse_share_entries(&v);
        assert_eq!(e.len(), 1);
        assert_eq!(e[0].fid, "5a84777138e14ceb90289aec0068d1dc");
        assert_eq!(e[0].name, "战邮1942");
        assert!(e[0].is_dir, "★ file_type=0 / dir=true ⇒ 目录");
        assert_eq!(e[0].size, 0);
        // 没 fid 的条目必须丢掉（编一个 id 只会让详情失败）
        let bad: serde_json::Value = serde_json::from_str(
            r#"{"status":200,"code":0,"data":{"list":[{"file_name":"没有 id"}]}}"#,
        )
        .unwrap();
        assert!(parse_share_entries(&bad).is_empty());
    }

    /// ★★ 业务错误必须当失败（HTTP 200 也可能带非 0 code），且文案点名**是哪一家**
    #[test]
    fn share_envelope_rejects_business_error() {
        let e = share_envelope(
            "UC",
            r#"{"status":500,"code":15000,"message":"inner error, requestId 986jwl"}"#,
            "换分享 token",
        )
        .expect_err("15000 必须失败");
        assert!(e.contains("15000"), "{e}");
        assert!(e.contains("换分享 token"), "要点明是哪一步：{e}");
        assert!(e.starts_with("UC "), "★ 文案要点名是哪一家：{e}");
    }

    /// ★★★ 空结果 ⇒ Err（不许把"没取到"当"这个货架是空的"）
    #[test]
    fn uc_share_empty_listing_is_error() {
        let e = require_share_entries(Vec::new(), "ba2e2f0417114")
            .expect_err("★ 空必须 Err");
        assert!(e.contains("ba2e2f0417114"), "要带上哪个分享：{e}");
        assert!(
            e.contains("失效") || e.contains("改"),
            "要给出可能原因：{e}"
        );
    }

    /// ★★★ 夸克**必须**走同族两步链路（2026-10-28 接通；此前是"保持未接通"）
    ///
    /// ```text
    /// 改前的护栏是 `quark_share_stays_not_wired`（断言夸克永远 Err）。
    /// 它守的是"没有对照实验就别照抄"这条纪律 —— 那条纪律仍然有效，
    /// 但**依据变了**：JSON/表单的对照实验已经在同族的 UC 上做完，
    /// 且两端点路径逐字相同（只有 host/pr 不同，而它们在 spec 里）。
    /// ⇒ 护栏翻面：现在守的是"夸克必须走这条路"，不是"必须不走"。
    /// 注入验证（已实测真红）：把 `share_family_wired` 改成只含 `Uc` ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn quark_shares_use_the_family_chain() {
        assert!(share_family_wired(PanKind::Quark), "★ 夸克必须接通分享链路");
        assert!(share_family_wired(PanKind::Uc), "★ UC 必须接通分享链路");
    }

    /// ★★ 反面对照：**别的盘不许**被顺手拉进这条链路
    ///
    /// ```text
    /// 百度/115/阿里/天翼/迅雷/123/光鸭的分享流程**结构不同**（登录族、转存参数、
    /// token 形状都不一样）⇒ 混进来只会产出"看起来能跑、实际全 401"的假成功。
    /// ```
    #[test]
    fn other_pans_are_not_dragged_into_the_share_chain() {
        for k in [
            PanKind::Baidu,
            PanKind::Pan115,
            PanKind::Aliyun,
            PanKind::Tianyi,
            PanKind::Xunlei,
            PanKind::Pan123,
            PanKind::Guangya,
        ] {
            assert!(
                !share_family_wired(k),
                "★★ {} 不走夸克/UC 的分享链路（协议结构不同）",
                k.display()
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  t_pan_temp_dir —— 临时转存**不许堆在网盘根目录**（2026-10-29 Owner 要求）
    //
    //  Owner 原话：「这些网盘我都还要用，都放在根目录我就没办法用了」
    //  改前：`share/sharepage/save` 的 `to_pdir_fid`/`pdir_fid` 写死 `"0"`。
    //  改后：转到 `sourin-temp` 的 fid；建目录失败才退回 `"0"` 并打 warn。
    // ═══════════════════════════════════════════════════════════════════════

    /// 目录名必须是我们的、且不能是根目录哨兵
    #[test]
    fn temp_dir_name_is_ours_and_not_root() {
        assert_eq!(TEMP_DIR_NAME, "sourin-temp");
        assert!(!TEMP_DIR_NAME.trim().is_empty(), "★ 目录名不能为空");
        assert_ne!(TEMP_DIR_NAME, "0", "★★ `0` 是根目录哨兵，绝不能当目录名");
        assert!(
            !TEMP_DIR_NAME.contains('/') && !TEMP_DIR_NAME.contains('\\'),
            "★ 目录名里不许带路径分隔符（那会变成 dir_path 语义）"
        );
        // ★ 反面对照：**不许**复用参考实现的两个名字 —— 混用会让
        //   "我们没清掉的残留" 和 "原版客户端的" 分不清（见常量注释）
        assert_ne!(TEMP_DIR_NAME, "Quarktemp");
        assert_ne!(TEMP_DIR_NAME, "UCtemp");
    }

    /// 建目录的 URL / 请求体必须与 dex 实证逐字一致（两家各一次）
    ///
    /// dex 取证：`merge.b.w.m`（夸克）、`merge.b.B.m`（UC）里的 const-string。
    #[test]
    fn mkdir_request_matches_the_reference_dex() {
        let q = quark_spec();
        let u = uc_spec();
        assert_eq!(
            mkdir_url(&q),
            "https://drive-pc.quark.cn/1/clouddrive/file?pr=ucpro&fr=pc"
        );
        assert_eq!(
            mkdir_url(&u),
            "https://pc-api.uc.cn/1/clouddrive/file?pr=UCBrowser&fr=pc"
        );
        // ★★ 端点不是 `file/mkdir`：真网实测该路径 404（证据 .probe/pan-mkdir-live.md）
        assert!(
            !mkdir_url(&q).contains("file/mkdir"),
            "★★ 建目录端点是 POST .../clouddrive/file（file/mkdir 实测 404）"
        );
        // 请求体：四个键逐字来自 dex，且父目录是根（"0" 在这里是**对的**：
        // sourin-temp 本身就该建在根目录下，用户才看得见、找得到）
        let body = mkdir_body(TEMP_DIR_NAME);
        let v: serde_json::Value = serde_json::from_str(&body).expect("请求体必须是合法 JSON");
        assert_eq!(v["pdir_fid"], "0", "★ 建目录的父目录是根目录");
        assert_eq!(v["file_name"], TEMP_DIR_NAME);
        assert_eq!(v["dir_path"], "");
        assert_eq!(v["dir_init_lock"], serde_json::json!(false));
    }

    /// 建目录响应里取 `data.fid`
    #[test]
    fn mkdir_fid_is_read_from_data_fid() {
        let v = serde_json::json!({"status":200,"code":0,"data":{"fid":"dir_fid_123"}});
        assert_eq!(mkdir_fid_of(&v), "dir_fid_123");
        // 取不到 ⇒ 空串（调用方据此如实报错，不许编一个 fid）
        assert_eq!(mkdir_fid_of(&serde_json::json!({"status":401})), "");
        assert_eq!(mkdir_fid_of(&serde_json::json!({"data":{}})), "");
    }

    /// ★★★ 转存请求必须指向**临时目录**，不是根目录
    ///
    /// 注入：把 `share_save_body` 里的 `to_pdir_fid` 改回 `"0"` ⇒ 本条必须红。
    #[test]
    fn save_body_targets_temp_dir_not_root() {
        let temp_fid = "dir_fid_abc";
        let body = share_save_body("file1", "tok1", "share1", "stoken1", temp_fid);
        let v: serde_json::Value = serde_json::from_str(&body).expect("转存请求体必须是合法 JSON");
        assert_eq!(
            v["to_pdir_fid"], temp_fid,
            "★★ 转存目标必须是临时目录 fid（不是 \"0\" 根目录）：{body}"
        );
        assert_eq!(
            v["pdir_fid"], temp_fid,
            "★★ `pdir_fid` 也必须跟着走，否则部分账号按根目录处理：{body}"
        );
        assert_ne!(v["to_pdir_fid"], "0", "★★ 不许落根目录：{body}");
        // 其余键不许被这次改动带歪
        assert_eq!(v["pwd_id"], "share1");
        assert_eq!(v["stoken"], "stoken1");
        assert_eq!(v["scene"], "link");
        assert_eq!(v["fid_list"][0], "file1");
        assert_eq!(v["fid_token_list"][0], "tok1");
    }

    /// 「建目录失败 ⇒ 退回根目录」这条**分支**本身
    ///
    /// ★ 为什么单独测：退回是"播放不许整体失败"的最后一道闸，而它永远走不到
    ///   （建目录成功时）—— 不抽出纯函数就只能靠真网把目录删掉才能测。
    #[test]
    fn temp_dir_or_root_falls_back_and_explains() {
        // 正常：用临时目录
        let (dir, why) = temp_dir_or_root(Ok("dir_fid_abc".to_string()));
        assert_eq!(dir, "dir_fid_abc");
        assert!(why.is_none(), "成功时不该有退回原因");

        // 失败：退回根目录，并**带着原因**（日志与错误文案都靠它）
        let (dir, why) = temp_dir_or_root(Err("建目录 401".to_string()));
        assert_eq!(dir, "0", "★★ 建目录失败 ⇒ 退回根目录");
        assert_eq!(why.as_deref(), Some("建目录 401"), "★ 原因必须原样保留");

        // 阴性对照：`Ok("")`（接口说成功但没给 fid）也算失败 ——
        // 空 fid 拿去转存只会得到一句上游错误，不如直接退回
        let (dir, why) = temp_dir_or_root(Ok("   ".to_string()));
        assert_eq!(dir, "0");
        assert!(why.is_some(), "★ 空 fid 必须算失败并说明");
    }

    /// ★ 真网用例（ignored）：真登录态下建目录并打印 fid
    ///
    /// ```text
    /// SOURIN_LIVE_PAN_DIR=1 cargo test --lib csp::pan_drive --release -- --ignored --nocapture
    /// ```
    /// 判据（打印给人看）：
    ///   · 建目录/复用目录的 fid
    ///   · 根目录列表里确实有 `sourin-temp`（证明不再堆文件在根目录）
    #[tokio::test]
    #[ignore = "真网络 + 真登录态：需要系统钥匙串里已保存的夸克 cookie"]
    async fn live_temp_dir_created_with_real_cookie() {
        if std::env::var("SOURIN_LIVE_PAN_DIR").ok().as_deref() != Some("1") {
            eprintln!("[PAN-DIR] 未设置 SOURIN_LIVE_PAN_DIR=1 ⇒ 跳过");
            return;
        }
        for (class, spec) in [("PanQuark", quark_spec()), ("PanUC", uc_spec())] {
            let d = PanDrive::with_spec(class, spec);
            let Some(cookie) = d.cookie() else {
                eprintln!("[PAN-DIR] {class}：钥匙串里没有 cookie ⇒ 跳过（不是失败）");
                continue;
            };
            match d.ensure_temp_dir(&cookie).await {
                Ok(fid) => {
                    eprintln!("[PAN-DIR] {class} 临时目录 {TEMP_DIR_NAME} fid={fid}");
                    match d.list_dir_with_subdirs(&cookie, "0").await {
                        Ok(entries) => {
                            let hit = entries
                                .iter()
                                .find(|e| e.name == TEMP_DIR_NAME)
                                .map(|e| (e.fid.clone(), e.is_dir));
                            eprintln!(
                                "[PAN-DIR] {class} 根目录（含子目录）条目 {} 个；其中 {} = {:?}",
                                entries.len(),
                                TEMP_DIR_NAME,
                                hit
                            );
                            assert!(hit.is_some(), "★ 建完之后根目录里必须能看到 {TEMP_DIR_NAME}");
                            /* ★★ 幂等：再调一次必须**复用同一个 fid**（否则每次启动多一个目录，
                             *    正是 Owner 说的"都放根目录就没法用"的变体） */
                            if let Ok(again) = d.ensure_temp_dir(&cookie).await {
                                eprintln!("[PAN-DIR] {class} 第二次 ensure ⇒ fid={again}");
                                assert_eq!(again, fid, "★★ 第二次必须复用同一个临时目录");
                            }
                        }
                        Err(e) => eprintln!("[PAN-DIR] {class} 列根目录失败：{e}"),
                    }
                }
                Err(e) => eprintln!("[PAN-DIR] {class} 建目录失败：{e}"),
            }
        }
    }

    /// ★ 真网用例（ignored）：N-23018 的**端到端复测**——重试不再出 21001
    ///
    /// ```text
    /// SOURIN_LIVE_21001=1 SOURIN_LIVE_SHARE_URL="https://pan.quark.cn/s/<pwd_id>" \
    ///   cargo test --lib csp::pan_drive::tests::live_21001_retry_race_probe --release -- --ignored --nocapture
    /// ```
    /// 判据：
    /// ```text
    /// ① 第一次 resolve：非会员账号对大文件多半 23018（账号现实，不是缺陷）；
    /// ② 紧接着第二次 resolve（= Owner 按「重试」）：修复前必出
    ///    404(21001) file not found（purge 竞态 + save 去重回吐死 fid，
    ///    10-31/11-01 日志 4 次复发）；修复后**错误里不许再出现 21001** ——
    ///    要么成功，要么 23018/超限类账号现实终态，要么自愈后成功。
    /// ```
    /// ⚠️ 真网络 + 真登录态 + 真分享：会真实转存/删除临时文件（都在
    ///    sourin-temp，播完即清）。不打印直链/cookie/签名。
    #[tokio::test]
    #[ignore = "真网络 + 真登录态：需要钥匙串 cookie 与 SOURIN_LIVE_SHARE_URL"]
    async fn live_21001_retry_race_probe() {
        if std::env::var("SOURIN_LIVE_21001").ok().as_deref() != Some("1") {
            eprintln!("[PAN-21001] 未设置 SOURIN_LIVE_21001=1 ⇒ 跳过");
            return;
        }
        let Ok(url) = std::env::var("SOURIN_LIVE_SHARE_URL") else {
            eprintln!("[PAN-21001] 未设置 SOURIN_LIVE_SHARE_URL ⇒ 跳过");
            return;
        };
        let share_id = url
            .trim()
            .rsplit('/')
            .next()
            .unwrap_or("")
            .split('#')
            .next()
            .unwrap_or("")
            .trim()
            .to_string();
        assert!(
            !share_id.is_empty() && share_id.len() >= 8,
            "SOURIN_LIVE_SHARE_URL 里提不出 pwd_id：{url}"
        );
        let d = PanDrive::with_spec("PanQuark", quark_spec());
        if d.cookie().is_none() {
            eprintln!("[PAN-21001] 钥匙串里没有夸克 cookie ⇒ 跳过（不是失败）");
            return;
        }
        // 第一次 resolve（建基线：多半 23018 / 或成功）
        let first = d.resolve_share_play(&share_id, "").await;
        eprintln!(
            "[PAN-21001] 第一次 resolve：{}",
            match &first {
                Ok(p) => format!("成功 label={:?}", p.label),
                Err(e) => format!("Err（前 120 字）{}", &e.chars().take(120).collect::<String>()),
            }
        );
        // 第二次 resolve = Owner 按「重试」的那一步 —— 修复前在这里出 21001
        let second = d.resolve_share_play(&share_id, "").await;
        match &second {
            Ok(p) => eprintln!("[PAN-21001] 第二次 resolve：成功 label={:?}", p.label),
            Err(e) => {
                eprintln!(
                    "[PAN-21001] 第二次 resolve：Err（前 160 字）{}",
                    &e.chars().take(160).collect::<String>()
                );
                assert!(
                    !is_file_not_found_21001(e),
                    "★★★ 重试仍报 21001 —— purge 等待 + 自愈没兜住，修复无效"
                );
            }
        }
        eprintln!("[PAN-21001] 判读通过：重试错误串里没有 21001（竞态已由 A+B 兜住）");
    }

    // ════════════════════════════════════════════════════════════════════
    //  ★ 假网盘夹具（N-23018 v2）：本地 TCP 回放"save 去重回吐"全链路
    // ════════════════════════════════════════════════════════════════════
    //
    // 与 app99 的假站夹具同一条思路：drive API 是明文 JSON + Cookie（无应用层
    // 加密）⇒ 本地 TCP 按路径路由即可。脚本化三件事：
    //   · save 第 n 次回吐哪个 fid（末位重复 —— "恒回吐同一死 fid"就靠它）
    //   · file/download 对哪些 fid 一律 404(21001)
    //   · file/delete 逐个记录（断言 purge LIFO 与子目录清理）

    struct PanScript {
        /// save 第 n 次调用回吐的 fid（越界取末位 ⇒ "恒回吐"）
        save_fids: std::sync::Mutex<Vec<String>>,
        /// 这些 fid 的 file/download 一律 HTTP 404(21001)（其余成功）
        dead_fids: Vec<String>,
        saves: std::sync::atomic::AtomicUsize,
        downloads: std::sync::Mutex<Vec<String>>,
        deletes: std::sync::Mutex<Vec<String>>,
        mkdirs: std::sync::Mutex<Vec<String>>,
        task_fid_of: std::sync::Mutex<std::collections::HashMap<String, String>>,
        del_seq: std::sync::atomic::AtomicUsize,
    }

    impl PanScript {
        fn new(save_fids: Vec<String>, dead_fids: Vec<String>) -> Self {
            Self {
                save_fids: std::sync::Mutex::new(save_fids),
                dead_fids,
                saves: std::sync::atomic::AtomicUsize::new(0),
                downloads: std::sync::Mutex::new(Vec::new()),
                deletes: std::sync::Mutex::new(Vec::new()),
                mkdirs: std::sync::Mutex::new(Vec::new()),
                task_fid_of: std::sync::Mutex::new(std::collections::HashMap::new()),
                del_seq: std::sync::atomic::AtomicUsize::new(0),
            }
        }

        async fn spawn(self: std::sync::Arc<Self>) -> String {
            use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            tokio::spawn(async move {
                loop {
                    let Ok((mut sock, _)) = listener.accept().await else {
                        return;
                    };
                    let script = self.clone();
                    tokio::spawn(async move {
                        let mut buf: Vec<u8> = Vec::new();
                        let mut chunk = [0u8; 4096];
                        let mut head_end = 0usize;
                        loop {
                            let n = match sock.read(&mut chunk).await {
                                Ok(0) | Err(_) => return,
                                Ok(n) => n,
                            };
                            buf.extend_from_slice(&chunk[..n]);
                            if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                                head_end = p + 4;
                                break;
                            }
                        }
                        let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
                        let path = head.split(' ').nth(1).unwrap_or("").to_string();
                        let clen: usize = head
                            .to_ascii_lowercase()
                            .lines()
                            .find_map(|l| {
                                l.strip_prefix("content-length:")
                                    .map(|v| v.trim().to_string())
                            })
                            .and_then(|v| v.parse().ok())
                            .unwrap_or(0);
                        while buf.len() < head_end + clen {
                            let n = match sock.read(&mut chunk).await {
                                Ok(0) | Err(_) => break,
                                Ok(n) => n,
                            };
                            buf.extend_from_slice(&chunk[..n]);
                        }
                        let body_text = String::from_utf8_lossy(&buf[head_end..]).to_string();
                        let (code, body) = script.route(&path, &body_text);
                        let resp = format!(
                            "HTTP/1.1 {code}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        );
                        let _ = sock.write_all(resp.as_bytes()).await;
                    });
                }
            });
            format!("{addr}")
        }

        fn route(&self, path: &str, req_body: &str) -> (String, String) {
            let ok = |v: serde_json::Value| ("200 OK".to_string(), v.to_string());
            // ── 分享链路（同族信封：status=200 + code=0 双确认）──
            if path.contains("/share/sharepage/token") {
                return ok(serde_json::json!({
                    "status": 200, "code": 0, "data": {"stoken": "st"}
                }));
            }
            if path.contains("/share/sharepage/detail") {
                return ok(serde_json::json!({
                    "status": 200, "code": 0,
                    "data": {"list": [{
                        "fid": "SHAREFILE-1", "file_name": "movie.mkv",
                        "size": 5_500_000_000u64, "share_fid_token": "tok"
                    }]}
                }));
            }
            if path.contains("/share/sharepage/save") {
                let idx = self
                    .saves
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let fids = self.save_fids.lock().unwrap_or_else(|e| e.into_inner());
                let fid = fids.get(idx).unwrap_or(fids.last().unwrap_or(&String::new())).clone();
                drop(fids);
                let task_id = format!("T{idx}");
                self.task_fid_of
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(task_id.clone(), fid);
                return ok(serde_json::json!({
                    "status": 200, "code": 0, "data": {"task_id": task_id}
                }));
            }
            if path.contains("/task") {
                let tid = path
                    .split("task_id=")
                    .nth(1)
                    .map(|s| s.split('&').next().unwrap_or("").to_string())
                    .unwrap_or_default();
                let map = self.task_fid_of.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(fid) = map.get(&tid) {
                    return ok(serde_json::json!({
                        "status": 200, "code": 0,
                        "data": {"status": 2, "save_as": {"save_as_top_fids": [fid]}}
                    }));
                }
                // 删除任务：终态即可（delete_task_done 只读 status）
                return ok(serde_json::json!({
                    "status": 200, "code": 0, "data": {"status": 2}
                }));
            }
            // ── 网盘文件操作 ──
            if path.contains("/file/download") {
                let fid = req_body
                    .split("\"fids\":[\"")
                    .nth(1)
                    .map(|s| s.split('"').next().unwrap_or("").to_string())
                    .unwrap_or_default();
                self.downloads
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push(fid.clone());
                if self.dead_fids.contains(&fid) {
                    return (
                        "404 Not Found".to_string(),
                        serde_json::json!({
                            "status": 404, "code": 21001,
                            "message": format!("file not found [{fid}]")
                        })
                        .to_string(),
                    );
                }
                return ok(serde_json::json!({
                    "code": 0,
                    "data": [{"download_url": "https://cdn.example.com/x.m3u8"}]
                }));
            }
            if path.contains("/file/sort") {
                // 根目录里有 sourin-temp；临时目录/子目录内为空（wait_fid_gone 直接过）
                let is_root = path.contains("pdir_fid=0");
                let list = if is_root {
                    serde_json::json!([{"fid": "DIRT", "file_name": TEMP_DIR_NAME, "dir": true}])
                } else {
                    serde_json::json!([])
                };
                return ok(serde_json::json!({"code": 0, "data": {"list": list}}));
            }
            if path.ends_with("/file") || path.contains("/file?") {
                let name = req_body
                    .split("\"file_name\":")
                    .nth(1)
                    .map(|s| s.split('"').nth(1).unwrap_or("").to_string())
                    .unwrap_or_default();
                self.mkdirs
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push(name);
                return ok(serde_json::json!({"code": 0, "data": {"fid": "DIR-NEW"}}));
            }
            if path.contains("/file/delete") {
                let n = self
                    .del_seq
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let fid = req_body
                    .split("\"filelist\":[\"")
                    .nth(1)
                    .map(|s| s.split('"').next().unwrap_or("").to_string())
                    .unwrap_or_default();
                self.deletes
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push(fid);
                return ok(serde_json::json!({
                    "code": 0, "data": {"task_id": format!("D{n}")}
                }));
            }
            (
                "404 Not Found".to_string(),
                serde_json::json!({"status": 404, "error": "Not Found", "path": path}).to_string(),
            )
        }
    }

    /// ★ 夹具门禁 1（真机缺口回放）：save **恒回吐同一死 fid** ⇒
    /// 有界重试（3 次转存）+ 一次性子目录 + 诚实终态（"同名去重卡住"，可重试语义）。
    ///
    /// ```text
    /// 回放 = 2026-11-01 部署版真机：首次转存 E → 下载 21001 → v1 自愈重转存
    /// 仍回吐 E → 终态"文件已不存在"（不准确）。v2 应：同目录等退避重转存（仍 E）
    /// → 换一次性子目录重转存（仍 E，内容级去重）⇒ 终态改报"同名去重卡住"，
    /// 且不再空打第三次必死的下载（download 恰好 2 次）。
    /// 注入证红：把 degrade_attempt 的 `fid == dead` 判据删掉 ⇒ 本条红
    /// （终态回到 play 的"文件已不存在"、download 变 3 次）。
    /// ```
    #[tokio::test]
    async fn fixture_save_dedupe_echo_runs_bounded_retries_and_honest_terminal() {
        let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // 起点清账：账本进程级共享，前面夹具留下的记账不许泄进本用例
        temp_saved().lock().unwrap_or_else(|e| e.into_inner()).clear();
        PanDrive::debug_set_test_cookie("quark", "k=test");
        const DEAD: &str = "E2d3230fdeadbeef";
        let script = std::sync::Arc::new(PanScript::new(
            vec![DEAD.to_string()],
            vec![DEAD.to_string()],
        ));
        let host = script.clone().spawn().await;
        PanDrive::debug_set_test_api_base(&host, &format!("http://{host}"));
        // api_host 是 &'static str ⇒ 夹具把本地地址 leak 成静态串（测试夹具级微泄漏）
        let mut spec = quark_spec();
        spec.api_host = Box::leak(host.clone().into_boxed_str());
        let d = PanDrive::with_spec("PanQuark", spec);
        let err = d
            .resolve_share_play("abc123def456", "")
            .await
            .expect_err("恒回吐死 fid ⇒ 必须终态（不能成功也不许挂死）");
        assert!(
            err.contains("同名去重卡住"),
            "★ 穷尽终态必须如实报\"转存副本被去重卡住\"：{err}"
        );
        assert!(err.contains("稍后重试"), "★ 可重试语义要点破：{err}");
        assert!(
            !err.contains("文件已不存在"),
            "★ 分享的文件还在 —— 不许再报上批那句不准确的\"文件已不存在\"：{err}"
        );
        // 有界：恰 3 次转存（1 正常 + 2 自愈重转存）
        assert_eq!(
            script.saves.load(std::sync::atomic::Ordering::Relaxed),
            3,
            "★ 转存次数必须有界（1 + SELFHEAL_RESAVE_ATTEMPTS=2）"
        );
        // 不空打：终态前的下载恰好 2 次（E 两次；第 3 次被 post-save 判据拦下）
        assert_eq!(
            script.downloads.lock().unwrap_or_else(|e| e.into_inner()).as_slice(),
            &[DEAD.to_string(), DEAD.to_string()],
        );
        // 一次性子目录确实建了（且只建一个）
        let mkdirs = script.mkdirs.lock().unwrap_or_else(|e| e.into_inner()).clone();
        assert_eq!(mkdirs.len(), 1, "★ 只有自愈第 3 档建子目录：{mkdirs:?}");
        assert!(
            mkdirs[0].starts_with("retry-"),
            "★ 子目录名走 retry_subdir_name（中性 + 唯一）：{:?}",
            mkdirs
        );
        PanDrive::debug_set_test_cookie("quark", "");
    }

    /// ★ 夹具门禁 2：save 第二次回吐**新 fid** ⇒ 自愈成功，下载用新 fid。
    #[tokio::test]
    async fn fixture_selfheal_succeeds_when_resave_returns_fresh_fid() {
        let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // 起点清账（账本进程级共享，见门禁 1）
        temp_saved().lock().unwrap_or_else(|e| e.into_inner()).clear();
        PanDrive::debug_set_test_cookie("quark", "k=test");
        const DEAD: &str = "E2d3230fdeadbeef";
        const FRESH: &str = "F9aa1fresh";
        let script = std::sync::Arc::new(PanScript::new(
            vec![DEAD.to_string(), FRESH.to_string()],
            vec![DEAD.to_string()],
        ));
        let host = script.clone().spawn().await;
        PanDrive::debug_set_test_api_base(&host, &format!("http://{host}"));
        let mut spec = quark_spec();
        spec.api_host = Box::leak(host.clone().into_boxed_str());
        let d = PanDrive::with_spec("PanQuark", spec);
        let out = d
            .resolve_share_play("abc123def456", "")
            .await
            .expect("★ 重转存拿到新 fid ⇒ 自愈成功");
        assert_eq!(
            script.downloads.lock().unwrap_or_else(|e| e.into_inner()).as_slice(),
            &[DEAD.to_string(), FRESH.to_string()],
            "★ 死 fid 撞一次 21001 后，下载必须换成新 fid"
        );
        assert_eq!(
            script.saves.load(std::sync::atomic::Ordering::Relaxed),
            2,
            "★ 一次重转存就成功 ⇒ 不许再多打（有界）"
        );
        assert!(out.url.contains("cdn.example.com"));
        PanDrive::debug_set_test_cookie("quark", "");
    }

    /// ★ 夹具门禁 3（lead 补充约束）：**子目录的清理验证** ——
    /// 终态后"下次解析的 purge"必须清掉 retry- 目录**及其文件**，且 LIFO
    /// （先文件后目录；正序会把非空目录的删除打在前面，必失败）。
    #[tokio::test]
    async fn fixture_purge_lifo_cleans_retry_subdir_and_file() {
        let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // 起点清账（账本进程级共享，见门禁 1）
        temp_saved().lock().unwrap_or_else(|e| e.into_inner()).clear();
        PanDrive::debug_set_test_cookie("quark", "k=test");
        const DEAD: &str = "E2d3230fdeadbeef";
        let script = std::sync::Arc::new(PanScript::new(
            vec![DEAD.to_string()],
            vec![DEAD.to_string()],
        ));
        let host = script.clone().spawn().await;
        PanDrive::debug_set_test_api_base(&host, &format!("http://{host}"));
        let mut spec = quark_spec();
        spec.api_host = Box::leak(host.clone().into_boxed_str());
        let d = PanDrive::with_spec("PanQuark", spec);
        let _ = d.resolve_share_play("abc123def456", "").await; // 终态（同门禁 1）
        // 第二次 resolve = 触发 purge（清上一次的临时转存，含一次性子目录）
        let _ = d.resolve_share_play("abc123def456", "").await;
        let deletes = script.deletes.lock().unwrap_or_else(|e| e.into_inner()).clone();
        // 记账序（resolve1）：[E, E, dirR, E] ⇒ LIFO 删除序 [E, dirR, E, E]
        // ★ 第 2 个删除的就是 retry- 子目录 —— 且排在它的文件之后
        assert_eq!(
            deletes.first().map(|s| s.as_str()),
            Some(DEAD),
            "★ LIFO：先删文件（最新记的）"
        );
        assert!(
            deletes.len() >= 2 && deletes[1] == "DIR-NEW",
            "★ retry- 子目录必须在它的文件之后被删（LIFO），实际删除序：{deletes:?}"
        );
        assert_eq!(deletes.len(), 4, "★ 4 条记账（E/E/子目录/E）都要被清：{deletes:?}");
        PanDrive::debug_set_test_cookie("quark", "");
    }
}

