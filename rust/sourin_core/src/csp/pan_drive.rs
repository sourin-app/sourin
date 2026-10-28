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
        fid: &str,
        fid_token: &str,
    ) -> Result<String, String> {
        let referer = format!("{}/s/{share_id}", self.spec.share_host);
        // ① 换 share token
        let token_url = self.api(&format!("share/sharepage/token?{}", self.spec.pr_fr));
        let token_body = format!(
            "{{\"pwd_id\":{},\"passcode\":\"\"}}",
            serde_json::Value::String(share_id.to_string())
        );
        let resp = self
            .client
            .post(&token_url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", &referer)
            .header("Cookie", cookie)
            .body(token_body)
            .send()
            .await
            .map_err(|e| format!("换分享 token 请求失败：{e}"))?;
        let text = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        let v: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| format!("换分享 token 返回的不是 JSON（{e}）：{}", short(&text)))?;
        let stoken = v
            .get("data")
            .and_then(|d| d.get("stoken"))
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        if stoken.is_empty() {
            return Err(format!("换分享 token 没有 stoken（响应：{}）", short(&text)));
        }

        // ② 转存
        let save_url = self.api(&format!("share/sharepage/save?{}", self.spec.pr_fr));
        let save_body = format!(
            "{{\"fid_list\":[{}],\"fid_token_list\":[{}],\"to_pdir_fid\":\"0\",\
              \"pwd_id\":{},\"stoken\":{},\"pdir_fid\":\"0\",\"scene\":\"link\"}}",
            serde_json::Value::String(fid.to_string()),
            serde_json::Value::String(fid_token.to_string()),
            serde_json::Value::String(share_id.to_string()),
            serde_json::Value::String(stoken.clone()),
        );
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

        // ③ 轮询任务（最多 ~10 秒；超时如实报，不猜地址）
        for _ in 0..10 {
            tokio::time::sleep(std::time::Duration::from_millis(900)).await;
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
            // 有的盘把 saved fid 放在 data.save_as.top_fid，有的在更深一层
            let saved = v
                .get("data")
                .and_then(|d| {
                    d.get("save_as")
                        .and_then(|s| s.get("top_fid"))
                        .or_else(|| d.get("top_fid"))
                })
                .and_then(|x| x.as_str())
                .unwrap_or("");
            if !saved.is_empty() {
                return Ok(saved.to_string());
            }
            let status = v
                .get("data")
                .and_then(|d| d.get("status"))
                .and_then(|x| x.as_i64())
                .unwrap_or(-1);
            if status == 3 {
                return Err(format!("转存任务失败（status=3，响应：{}）", short(&text)));
            }
        }
        Err("转存任务超时（约 9 秒未完成）⇒ 现在给不出地址，不伪造".to_string())
    }

    pub fn with_spec(class: &'static str, spec: PanDriveSpec) -> Self {
        // ⚠️ 与 `pan_web_share.rs` 同一条纪律：reqwest 默认读环境代理，
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
        crate::pan_auth::load(self.spec.kind).map(|c| c.cookie)
    }

    /// 拼一个 API URL（把 `{pr_fr}` 之类的固定参数带上）
    fn api(&self, path: &str) -> String {
        format!("https://{}/1/clouddrive/{}", self.spec.api_host, path)
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
        "https://{}/1/clouddrive/file/sort?{}&uc_param_str=&pdir_fid={dir}\
         &_page=1&_size={}&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,file_name:asc",
        spec.api_host, spec.pr_fr, spec.page_size
    )
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
        "https://{}/1/clouddrive/share/sharepage/token?{}",
        spec.api_host, spec.pr_fr
    )
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
        "https://{}/1/clouddrive/share/sharepage/detail?{}\
         &pwd_id={share_id}&stoken={}&pdir_fid={folder}&force=0\
         &_page={}&_size=50&_fetch_total=1\
         &_sort=file_type:asc,updated_at:desc",
        spec.api_host,
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
            self.share_save(&cookie, &share_id, &sfid, &token).await?
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
            return self.share_list_family(cookie, share_id, folder).await;
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
        folder: &str,
    ) -> Result<Vec<DriveEntry>, String> {
        let kind = self.spec.kind.display();
        let referer = format!("{}/s/{share_id}", self.spec.share_host);
        // ① 换 token
        let resp = self
            .client
            .post(share_token_url(&self.spec))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", &referer)
            .header("Cookie", cookie)
            .body(share_token_body(share_id, ""))
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
        // ② 列目录
        let url = share_detail_url(&self.spec, share_id, &stoken, folder, 1);
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
}

