// ═══════════════════════════════════════════════════════════════════════
//  csp_LocalFile —— 「本地目录当片源」的 Rust 实现（**本批不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（DEX 常量逐字，`.probe/csp-parity/LocalFile.txt` + `dex_const_strings.py`）
// ```text
// parent = Lcom/github/catvod/crawler/Spider;
// 方法    <init> checkstring categoryContent detailContent homeContent init playerContent searchContent
// 字段    a（= init 收到的 ext，本类没有第二个字段）
//
// checkstring（逐字 18 项，注意其中有被上游截断的 `.mp` / `.m4`）：
//   .flac .ape .avi .wmv .rm .3gp .mov .mp .m4 .vob .ts .webm .dat .m3u .mkv .flv .aac .wma
// <init>  homeContent 的分类（逐字）：
//   type_id / type_name = 「本地文件」 / type_flag = 1 / class / filters = {}
// d       列表项字段：vod_id / vod_name / vod_pic / vod_tag(folder|file) / vod_remarks；
//         分页：page / pagecount / limit / total / list
// f       详情字段：vod_id / vod_name / vod_pic / type_name / vod_play_from = 「本地」/
//         vod_play_url（用 `$` 与 `#` 拼集）
// b       playerContent 的返回键：parse / playUrl / url
// ```
//
// # ★ 为什么**没有** `register_site!`（三条判据逐条对照）
// ```text
// ① 订阅（100 站）里 `csp_LocalFile` = **0 站**（本地目录不可能写进公共订阅）❌
// ② host/path：**只能来自 ext** —— DEX 的 `init` 把 ext 原样存进字段 `a`，
//    全类没有任何默认目录常量；ext 为空时无处可读 ❌
// ③ 真文件读数：无 ext ⇒ 没有可列出的目录 ❌
// ⇒ **做实现、不注册**（注册会变成 state.rs 里「类即源」的一条空源：
//    用户点进去只会看到「请填目录」，那正是本仓最忌讳的「看起来有、其实没有」）
// ```
// ★ 一旦某份配置给了 `ext = {"path":"D:/影视"}`（或直接给目录路径），本实现即可用。
//
// # ext 的两种形态（都支持，顺序固定）
// ```text
// ① 裸路径：            D:/影视            /sdcard/Movies         （DEX 就是原样存 ext）
// ② 对象：              {"path":"D:/影视"}  {"dir":"…"}  {"folder":"…"}  {"site":["D:/影视"]}
// ```
//
// # 与 DEX 的三处**有据**差异（都写在下面，不静默）
// ```text
// ① 列表只收「文件夹 + 媒体文件」：DEX 的 checkstring 决定什么是媒体；
//    非媒体（.srt/.jpg/.nfo）不列出来 —— 列出来点了也放不了。
// ② 不引用 DEX 里那两个**远程默认图标**（folder.png / video.png，第三方 CDN）：
//    本地源不该依赖外网才能显示封面；`cover` 一律 None。
// ③ 不展示 DEX 的 `yyyy/MM/dd aHH:mm:ss` 备注：本仓没有时间库，且那只是装饰；
//    副标题改为**文件大小**（真实且无需新依赖）。
// ```
//
// # 为什么本文件**没有** `reqwest::Client`（因此也没有 `.no_proxy()`）
// ```text
// 本类只读 `std::fs`，一个字节都不发 HTTP。
// 全仓判据 `zz_r3i_no_proxy_consistency` 的口径是「**造了** Client::builder() 的类必须关代理」
// —— 本文件不造 client，不在该判据的候选集里（不是绕过判据，是判据的适用条件不成立）。
// ```

use async_trait::async_trait;
use std::path::{Path, PathBuf};

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 分类 id（DEX 的 homeContent 只给一个分类；本地根目录）
const ROOT_ID: &str = "0";

/// 分类名（DEX 逐字）
const ROOT_NAME: &str = "本地文件";

/// 一页多少条（DEX 有 limit/total 分页；本地目录用固定页长）
const PAGE_SIZE: usize = 100;

/// DEX `checkstring` 的扩展名（逐字 18 项）
///
/// ★ 其中 `.mp` / `.m4` 是被上游**截断**的（原意显然是 `.mp4` / `.m4v`）——
///   所以下面 `is_media` 额外认 `.mp4` / `.m4v`（否则最常见的 mp4 反而放不出来）。
const MEDIA_EXTS: &[&str] = &[
    ".flac", ".ape", ".avi", ".wmv", ".rm", ".3gp", ".mov", ".mp", ".m4", ".vob", ".ts", ".webm",
    ".dat", ".m3u", ".mkv", ".flv", ".aac", ".wma",
];

pub struct LocalFile;

impl LocalFile {
    pub const CLASS: &'static str = "LocalFile";

    pub fn new() -> Self {
        Self
    }

    /// 从 ext 取根目录
    ///
    /// ★ 三种失败必须能分开（用户看到的修法完全不同）：
    /// ```text
    /// · 没写 ext            ⇒ 「请填目录」
    /// · 写了但路径不存在      ⇒ 「目录不存在：<路径>」
    /// · 存在但不是目录        ⇒ 「不是目录：<路径>」
    /// ```
    pub fn root_of(ext: &str) -> Result<PathBuf, String> {
        let raw = ext.trim();
        if raw.is_empty() || raw == "null" {
            return Err("LocalFile 需要 ext 里的本地目录路径（例如 \
                        {\"path\":\"D:/影视\"}，或直接写 D:/影视）——当前配置没给，无法列出文件"
                .to_string());
        }
        let mut cand = String::new();
        if raw.starts_with('{') {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) {
                for k in ["path", "dir", "folder"] {
                    if let Some(s) = v.get(k).and_then(|x| x.as_str()) {
                        let s = s.trim();
                        if !s.is_empty() {
                            cand = s.to_string();
                            break;
                        }
                    }
                }
                if cand.is_empty() {
                    if let Some(arr) = v.get("site").and_then(|x| x.as_array()) {
                        if let Some(s) = arr.iter().filter_map(|x| x.as_str()).next() {
                            cand = s.trim().to_string();
                        }
                    }
                }
            }
        }
        if cand.is_empty() {
            cand = raw.trim_matches('"').trim().to_string();
        }
        let p = PathBuf::from(&cand);
        let p = if p.is_absolute() {
            p
        } else {
            std::env::current_dir()
                .map_err(|e| format!("取当前工作目录失败（无法解析相对路径 {cand}）：{e}"))?
                .join(p)
        };
        if !p.exists() {
            return Err(format!("目录不存在：{}", p.display()));
        }
        if !p.is_dir() {
            return Err(format!("不是目录：{}（ext 要给目录，不是单个文件）", p.display()));
        }
        Ok(p)
    }

    /// 列目录：**文件夹在前**，然后按名字排序的媒体文件
    ///
    /// ★ 纯函数式（`fn(dir) -> Vec`）：单测直接用真目录，不需要网络。
    pub fn entries(dir: &Path) -> Result<Vec<CspItem>, String> {
        let rd = std::fs::read_dir(dir)
            .map_err(|e| format!("读目录失败：{}（{e}）", dir.display()))?;
        let mut items: Vec<CspItem> = Vec::new();
        for ent in rd.flatten() {
            let p = ent.path();
            let name = p
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_default();
            if name.is_empty() || name.starts_with('.') {
                continue;
            }
            let Ok(meta) = ent.metadata() else { continue };
            if meta.is_dir() {
                items.push(CspItem {
                    id: p.to_string_lossy().to_string(),
                    title: name,
                    cover: None,
                    subtitle: Some("文件夹".to_string()),
                });
            } else if is_media(&name) {
                items.push(CspItem {
                    id: p.to_string_lossy().to_string(),
                    title: name,
                    cover: None,
                    subtitle: Some(human_size(meta.len())),
                });
            }
        }
        // 文件夹在前，同类按名字（不区分大小写）排序 —— 结果稳定，门禁可复现
        items.sort_by(|a, b| {
            let af = a.subtitle.as_deref() == Some("文件夹");
            let bf = b.subtitle.as_deref() == Some("文件夹");
            bf.cmp(&af)
                .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
        });
        Ok(items)
    }

    /// 目录里的**媒体文件**（详情页的剧集来源；非递归）
    fn media_files(dir: &Path) -> Vec<PathBuf> {
        let mut out: Vec<PathBuf> = Vec::new();
        if let Ok(rd) = std::fs::read_dir(dir) {
            for ent in rd.flatten() {
                let p = ent.path();
                if p.is_file()
                    && p.file_name()
                        .map(|n| is_media(&n.to_string_lossy()))
                        .unwrap_or(false)
                {
                    out.push(p);
                }
            }
        }
        out.sort();
        out
    }
}

impl Default for LocalFile {
    fn default() -> Self {
        Self::new()
    }
}

/// 是不是媒体文件（DEX `checkstring` 的后缀判定 + 两个被截断的补全）
pub fn is_media(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    MEDIA_EXTS.iter().any(|e| lower.ends_with(e))
        || lower.ends_with(".mp4")
        || lower.ends_with(".m4v")
}

/// 字节数 → 人类可读（副标题用；不引依赖）
fn human_size(n: u64) -> String {
    const KB: f64 = 1024.0;
    let f = n as f64;
    if f >= KB * KB * KB {
        format!("{:.1} GB", f / (KB * KB * KB))
    } else if f >= KB * KB {
        format!("{:.1} MB", f / (KB * KB))
    } else if f >= KB {
        format!("{:.0} KB", f / KB)
    } else {
        format!("{n} B")
    }
}

/// 本地路径 → `file://`（播放器认这个 scheme，见 `lib/main.dart` 的本地起播）
///
/// ```text
/// D:\影视\a.mp4  ⇒ file:///D:/影视/a.mp4
/// /sdcard/a.mp4  ⇒ file:///sdcard/a.mp4
/// ```
/// ★ 不做百分号编码：与 App 自己的本地起播逐字同形（`file:///$p`，`p` 只把反斜杠换正斜杠）。
pub fn file_url(path: &Path) -> String {
    let s = path.to_string_lossy().replace('\\', "/");
    if s.starts_with("file://") {
        return s;
    }
    if s.starts_with('/') {
        format!("file://{s}")
    } else {
        format!("file:///{s}")
    }
}

// ══ ⚠️ **没有 `register_site!`**（原因见文件头：缺 ①②③）══

#[async_trait]
impl CspSite for LocalFile {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let root = Self::root_of(ext)?;
        let items = Self::entries(&root)?;
        if items.is_empty() {
            return Err(format!(
                "目录 {} 里没有可列出的条目（空目录，或只有非媒体文件）——\
                 本类不把「空目录」说成「这个源没内容」",
                root.display()
            ));
        }
        Ok(CspHome {
            categories: vec![CspCategory {
                id: ROOT_ID.to_string(),
                name: ROOT_NAME.to_string(),
            }],
            items,
        })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let root = Self::root_of(ext)?;
        let tid = tid.trim();
        let dir = if tid.is_empty() || tid == ROOT_ID {
            root
        } else {
            let p = PathBuf::from(tid);
            if p.is_absolute() {
                p
            } else {
                root.join(p)
            }
        };
        if !dir.is_dir() {
            return Err(format!("分类 {tid} 不是可读目录：{}", dir.display()));
        }
        let all = Self::entries(&dir)?;
        let page = if page == 0 { 1 } else { page };
        let start = ((page as usize) - 1) * PAGE_SIZE;
        if start >= all.len() {
            if page > 1 {
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total: Some(all.len() as u64),
                });
            }
            return Err(format!("目录 {} 里没有可列出的条目", dir.display()));
        }
        let items: Vec<CspItem> = all
            .iter()
            .skip(start)
            .take(PAGE_SIZE)
            .cloned()
            .collect();
        let page_count = ((all.len() + PAGE_SIZE - 1) / PAGE_SIZE).max(1) as u32;
        Ok(CspList {
            items,
            page,
            page_count: Some(page_count),
            total: Some(all.len() as u64),
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空（本地条目 id 就是文件/文件夹路径）".to_string());
        }
        let p = PathBuf::from(id);
        if !p.exists() {
            return Err(format!("路径不存在：{id}"));
        }
        let title = p
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| id.to_string());

        if p.is_dir() {
            let files = Self::media_files(&p);
            if files.is_empty() {
                return Err(format!("文件夹「{title}」里没有可播放的媒体文件"));
            }
            let episodes: Vec<CspEpisode> = files
                .iter()
                .map(|f| CspEpisode {
                    id: f.to_string_lossy().to_string(),
                    title: f
                        .file_name()
                        .map(|s| s.to_string_lossy().to_string())
                        .unwrap_or_default(),
                    flag: "本地".to_string(),
                })
                .collect();
            return Ok(CspDetail {
                id: id.to_string(),
                title,
                cover: None,
                description: Some(format!("本地文件夹，共 {} 个媒体文件", episodes.len())),
                episodes,
            });
        }

        if p.is_file() && is_media(&title) {
            return Ok(CspDetail {
                id: id.to_string(),
                title: title.clone(),
                cover: None,
                description: None,
                episodes: vec![CspEpisode {
                    id: id.to_string(),
                    title,
                    flag: "本地".to_string(),
                }],
            });
        }
        Err(format!("「{title}」不是可播放的本地媒体文件"))
    }

    /// 搜索：本地目录没有索引 ⇒ 明确不支持（不给"空结果"的假成功）
    fn supports_search(&self) -> bool {
        false
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("LocalFile 不支持搜索：本地目录没有索引，请在分类里逐级浏览".to_string())
    }

    /// 取流：本地文件 ⇒ `file://` 直链（播放器原生支持，零网络）
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id 为空（本地条目 id 就是文件路径）".to_string());
        }
        let p = PathBuf::from(id);
        if !p.exists() {
            return Err(format!("文件不存在：{id}"));
        }
        if p.is_dir() {
            return Err(format!(
                "「{}」是文件夹，不是可播放文件（请先进入文件夹选一集）",
                p.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default()
            ));
        }
        if !is_media(&p.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default()) {
            return Err(format!("「{id}」不是可识别的媒体文件（按扩展名判断）"));
        }
        Ok(vec![CspPlay {
            url: file_url(&p),
            headers: Vec::new(),
            label: Some("本地".to_string()),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试（真文件系统：临时目录 + 真文件）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir(tag: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "sourin-local-file-{tag}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).expect("建临时目录");
        p
    }

    fn touch(dir: &Path, name: &str, bytes: usize) -> PathBuf {
        let p = dir.join(name);
        std::fs::write(&p, vec![0u8; bytes]).expect("写临时文件");
        p
    }

    #[test]
    fn class_name_is_exact() {
        assert_eq!(LocalFile::CLASS, "LocalFile");
    }

    #[test]
    fn media_extensions_follow_the_dex_list_plus_the_truncated_mp4_m4v() {
        for n in ["a.mkv", "b.FLV", "c.mp4", "d.m4v", "e.ts", "f.m3u"] {
            assert!(is_media(n), "{n} 应算媒体");
        }
        for n in ["a.srt", "b.jpg", "c.nfo", "d.txt", "noext"] {
            assert!(!is_media(n), "{n} 不该算媒体");
        }
    }

    #[test]
    fn root_of_accepts_raw_path_and_object() {
        let d = tmp_dir("root");
        let raw = d.to_string_lossy().to_string();
        assert_eq!(LocalFile::root_of(&raw).unwrap(), d);
        let obj = format!(r#"{{"path":{:?}}}"#, raw);
        assert_eq!(LocalFile::root_of(&obj).unwrap(), d);
        let site = format!(r#"{{"site":[{:?}]}}"#, raw);
        assert_eq!(LocalFile::root_of(&site).unwrap(), d);
        // 没写 ext ⇒ 可读 Err（文案里必须有「目录」）
        let e = LocalFile::root_of("").expect_err("空 ext 必须 Err");
        assert!(e.contains("目录"), "{e}");
        // 不存在 / 不是目录
        let miss = d.join("nope");
        let e2 = LocalFile::root_of(&miss.to_string_lossy()).expect_err("不存在必须 Err");
        assert!(e2.contains("目录不存在"), "{e2}");
        let f = touch(&d, "a.mp4", 8);
        let e3 = LocalFile::root_of(&f.to_string_lossy()).expect_err("文件不是目录");
        assert!(e3.contains("不是目录"), "{e3}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn home_lists_real_directory_folders_first_and_skips_non_media() {
        let d = tmp_dir("home");
        touch(&d, "b.mp4", 2048);
        touch(&d, "a.mkv", 1024);
        touch(&d, "c.srt", 10);
        std::fs::create_dir(d.join("子目录")).unwrap();
        let ext = d.to_string_lossy().to_string();

        let h = LocalFile::new().home(&ext).await.expect("首页应成功");
        assert_eq!(h.categories.len(), 1);
        assert_eq!(h.categories[0].name, "本地文件");
        assert_eq!(h.items.len(), 3, "文件夹 + 2 个媒体（.srt 被跳过）：{:?}", h.items);
        assert_eq!(h.items[0].subtitle.as_deref(), Some("文件夹"));
        assert_eq!(h.items[0].title, "子目录");
        assert_eq!(h.items[1].title, "a.mkv");
        assert!(h.items[1].subtitle.as_deref().unwrap_or("").contains("KB"));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn empty_directory_is_error_not_empty_home() {
        let d = tmp_dir("empty");
        let ext = d.to_string_lossy().to_string();
        let e = LocalFile::new().home(&ext).await.expect_err("空目录必须 Err");
        assert!(e.contains("没有可列出的条目"), "{e}");
        let l = LocalFile::new().list("0", 1, &ext).await.expect_err("空目录列表必须 Err");
        assert!(l.contains("没有可列出的条目"), "{l}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn list_reads_subfolder_and_sets_page_count() {
        let d = tmp_dir("list");
        let sub = d.join("剧集");
        std::fs::create_dir(&sub).unwrap();
        touch(&sub, "01.mp4", 16);
        touch(&sub, "02.mp4", 16);
        let ext = d.to_string_lossy().to_string();

        let l = LocalFile::new()
            .list(&sub.to_string_lossy(), 1, &ext)
            .await
            .expect("子目录列表应成功");
        assert_eq!(l.items.len(), 2);
        assert_eq!(l.page, 1);
        assert_eq!(l.total, Some(2));
        assert_eq!(l.page_count, Some(1));
        // 越界页：如实回"没有更多"（不是解析失败）
        let p2 = LocalFile::new()
            .list(&sub.to_string_lossy(), 2, &ext)
            .await
            .expect("越界页应 Ok 空");
        assert!(p2.items.is_empty());
        assert_eq!(p2.page_count, Some(1));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn detail_file_and_folder_build_episodes() {
        let d = tmp_dir("detail");
        let sub = d.join("电影");
        std::fs::create_dir(&sub).unwrap();
        let f1 = touch(&sub, "上集.mp4", 16);
        touch(&sub, "下集.mkv", 16);
        let ext = d.to_string_lossy().to_string();

        let one = LocalFile::new()
            .detail(&f1.to_string_lossy(), &ext)
            .await
            .expect("单文件详情应成功");
        assert_eq!(one.episodes.len(), 1);
        assert_eq!(one.episodes[0].title, "上集.mp4");
        assert_eq!(one.episodes[0].flag, "本地");

        let folder = LocalFile::new()
            .detail(&sub.to_string_lossy(), &ext)
            .await
            .expect("文件夹详情应成功");
        assert_eq!(folder.episodes.len(), 2);
        assert!(folder.description.as_deref().unwrap_or("").contains("2 个媒体文件"));

        // 空文件夹 ⇒ Err（不是"0 集"）
        let empty = d.join("空");
        std::fs::create_dir(&empty).unwrap();
        let e = LocalFile::new()
            .detail(&empty.to_string_lossy(), &ext)
            .await
            .expect_err("空文件夹必须 Err");
        assert!(e.contains("没有可播放的媒体文件"), "{e}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn play_returns_file_url_and_rejects_directories() {
        let d = tmp_dir("play");
        let f = touch(&d, "a.mp4", 16);
        let ext = d.to_string_lossy().to_string();
        let got = LocalFile::new()
            .play("本地", &f.to_string_lossy(), &ext)
            .await
            .expect("取流应成功");
        assert_eq!(got.len(), 1);
        assert!(got[0].url.starts_with("file://"), "{}", got[0].url);
        assert!(got[0].url.ends_with("/a.mp4"), "{}", got[0].url);
        assert!(got[0].headers.is_empty(), "本地文件不需要任何请求头");
        assert_eq!(got[0].label.as_deref(), Some("本地"));

        let e = LocalFile::new()
            .play("本地", &d.to_string_lossy(), &ext)
            .await
            .expect_err("文件夹不可播");
        assert!(e.contains("文件夹"), "{e}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn file_url_forms_match_the_app_local_playback_shape() {
        assert_eq!(file_url(Path::new(r"D:\影视\a.mp4")), "file:///D:/影视/a.mp4");
        assert_eq!(file_url(Path::new("/sdcard/a.mp4")), "file:///sdcard/a.mp4");
        assert_eq!(file_url(Path::new("relative/a.mp4")), "file:///relative/a.mp4");
        assert_eq!(file_url(Path::new("file:///x.mp4")), "file:///x.mp4");
    }

    /// ★ 判据三条缺 ①②③ ⇒ 必须**不注册**
    #[test]
    fn local_file_must_not_be_registered_without_ext() {
        let flat = crate::csp::shared::impl_src_only(include_str!("local_file.rs"));
        assert!(!flat.contains("register_site!(LocalFile)"), "★ 无 ext 不许注册");
        assert!(
            !crate::csp::is_implemented("csp_LocalFile"),
            "★ 不许进注册表（否则 state.rs 会暴露一条空源）"
        );
    }

    /// 本类不发 HTTP ⇒ 不该出现在 no_proxy 判据的候选集里
    #[test]
    fn this_class_builds_no_http_client_so_the_proxy_rule_does_not_apply() {
        let flat = crate::csp::shared::impl_src_only(include_str!("local_file.rs"));
        assert!(!flat.contains("Client::builder()"), "★ 本地类不许造 HTTP client");
        assert!(!flat.contains("reqwest::"), "★ 本地类不许发网络请求");
    }

    /// 真读数（真文件系统；`#[ignore]`，必须显式点名 + `CSP_LIVE=1`）
    ///
    /// ```text
    /// CSP_LIVE=1 cargo test --lib csp::local_file:: -- --ignored --nocapture
    /// ```
    /// ★ 目录建在**仓库内**的 `target/parity-local-live`（gitignored），
    ///   不是"凭空造一条假读数目录"，而是让实现真的去 `read_dir`/`metadata`。
    #[tokio::test]
    #[ignore = "真文件：CSP_LIVE=1 cargo test --lib csp::local_file:: -- --ignored --nocapture"]
    async fn csp_live_local_file_reads_repo_temp_dir() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真读数用例：显式跑就必须给 CSP_LIVE=1（不给就失败，不许记成 ok）"
        );
        let root = PathBuf::from("target/parity-local-live");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("剧集")).expect("建目录");
        std::fs::create_dir_all(root.join("空目录")).expect("建空目录");
        std::fs::write(root.join("剧集/01.mp4"), vec![0u8; 4096]).unwrap();
        std::fs::write(root.join("剧集/02.mkv"), vec![0u8; 8192]).unwrap();
        std::fs::write(root.join("单集.flac"), vec![0u8; 1024]).unwrap();
        std::fs::write(root.join("说明.srt"), b"1
00:00:01 --> 00:00:02
").unwrap();
        let ext = root.to_string_lossy().to_string();

        let site = LocalFile::new();
        let home = site.home(&ext).await.expect("home 应成功");
        eprintln!(
            "[LIVE] LocalFile home({ext}) ⇒ {} 分类 / {} 条目: {:?}",
            home.categories.len(),
            home.items.len(),
            home.items.iter().map(|i| i.title.clone()).collect::<Vec<_>>()
        );
        assert_eq!(home.items.len(), 3, "2 个文件夹 + 1 个媒体（.srt 不列）");

        let folder_id = home.items[0].id.clone();
        let list = site.list(&folder_id, 1, &ext).await.expect("list 应成功");
        eprintln!("[LIVE] LocalFile list({folder_id}) ⇒ {} 条", list.items.len());
        assert_eq!(list.items.len(), 2);

        let d = site.detail(&folder_id, &ext).await.expect("detail 应成功");
        eprintln!(
            "[LIVE] LocalFile detail(文件夹) ⇒ 标题={:?} 集数={} 首集={:?}",
            d.title,
            d.episodes.len(),
            d.episodes.first().map(|e| e.title.clone())
        );
        assert_eq!(d.episodes.len(), 2);

        let got = site.play("本地", &d.episodes[0].id, &ext).await.expect("play 应成功");
        eprintln!("[LIVE] LocalFile play ⇒ url={:?} headers={:?}", got[0].url, got[0].headers);
        assert!(got[0].url.starts_with("file://"));
        let _ = std::fs::remove_dir_all(&root);
    }
}
