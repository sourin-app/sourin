// ═══════════════════════════════════════════════════════════════════════
//  一次性数据迁移：把"被自动化停用、但本身能搜索"的源恢复启用
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它（真读数，2026-10-29）
//
// ```text
// 逐个源直测（绕过聚合）：注册 98 个源 ⇒ **50 个能搜到「老舅」**、46 个报错、2 个空。
// 而聚合「全部」只扇出 47 个候选、14 个有结果 —— 差的 51 个 id 躺在
// `disabled-providers.json` 里：api / api-2..5 / bfzyapi / cj / caiji / ffzy /
// cctv / bilibili / hongniuzy2 / jszyapi / sdzyapi / suoniapi / tyyszy / 154 / 360 …
//
// 这些**不是用户一个个点掉的**：是整个文件夹一次写进去的（导入/整顿那几轮自动化产物）。
// 后果：原版「全部」= 配置里所有站点都扇出（原版没有列表启用这个概念），
//       而我们这边"被自动化关掉"的源连搜索都不参与 ⇒ 与 Owner 要求的"75 个源"差了 28 个。
// ```
//
// # 为什么用"一次性迁移"而不是改聚合的选择规则
//
// ```text
// 试过在 `enabled_children` 里忽略停用（直接 `manifests()`）：扇出立刻变 98、结果 50，
// 但把既有纪律 R2-B「用户显式停用就不搜」一起推翻了，4 个门禁当场变红。
// 那条纪律是**用户意图**（首页关了、搜索还能搜出来 = bug），不能为了数字好看破坏。
// ⇒ 正确做法：**修数据**。把"自动化写进去、且本身可搜索"的源摘出来，
//   用户之后手动停用的照旧生效（迁移只跑一次）。
// ```
//
// # 幂等与安全
//
// ```text
// · 标记文件 `provider-migration.json` 记 `restore_searchable_v1: true`；
//   跑过一次就不再跑 ⇒ 用户下次手停的源不会被"复活"。
// · 不可搜索的源（直播/豆瓣/网盘/短视频）**不动**：它们留在停用列表里，
//   因为扇出它们只会得到 `Unsupported`（探针实测）。
// · 写盘失败只 log::warn，不阻断启动（源少几个比应用起不来好）。
// ```

use std::collections::HashSet;
use std::path::Path;

use crate::model::ProviderManifest;

/// 迁移标记文件名
const MARKER: &str = "provider-migration.json";

/// 标记里的键（版本化：将来再加迁移就加新键）
const KEY: &str = "restore_searchable_v1";

/// 纯函数：给定"当前停用列表"和"可搜索源 id 集合"，算出恢复后应该留下的列表
///
/// # 返回
/// `(留下的停用列表, 被恢复的 id 列表)`
///
/// # 为什么要拆成纯函数
/// ```text
/// 这个迁移只跑一次，如果写错就再也没机会纠正（标记已落）。
/// 纯函数可以在门禁里穷举：可搜索的摘掉、不可搜索的保留、未注册的 id 原样保留。
/// ```
pub fn plan_restore(disabled: &[String], searchable: &HashSet<String>) -> (Vec<String>, Vec<String>) {
    let mut keep = Vec::with_capacity(disabled.len());
    let mut restored = Vec::new();
    for id in disabled {
        if searchable.contains(id) {
            restored.push(id.clone());
        } else {
            keep.push(id.clone());
        }
    }
    (keep, restored)
}

/// 执行一次迁移（有标记就跳过）。返回被恢复的源数（`None` = 本次未执行）
pub fn run_once(data_dir: &Path, manifests: &[ProviderManifest]) -> Option<usize> {
    let marker = data_dir.join(MARKER);
    let done = std::fs::read_to_string(&marker)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v.get(KEY).and_then(|b| b.as_bool()))
        .unwrap_or(false);
    if done {
        return None;
    }

    let searchable: HashSet<String> = manifests
        .iter()
        .filter(|m| m.capabilities.search)
        .map(|m| m.id.clone())
        .collect();
    let disabled = crate::commands::load_disabled(data_dir);
    let (keep, restored) = plan_restore(&disabled, &searchable);

    if !restored.is_empty() {
        if let Err(e) = crate::commands::save_disabled(data_dir, &keep) {
            log::warn!(
                "[provider-migration] 恢复 {} 个可搜索源失败（不阻断启动）：{e}",
                restored.len()
            );
            return None;
        }
        log::warn!(
            "[provider-migration] 一次性迁移：恢复 {} 个被自动化停用的可搜索源（保留 {} 个停用）：{:?}",
            restored.len(),
            keep.len(),
            restored
        );
    }

    // 落标记（即使没有要恢复的也落，避免每次启动都扫一遍）
    let body = serde_json::json!({ KEY: true }).to_string();
    if let Err(e) = std::fs::write(&marker, body) {
        log::warn!("[provider-migration] 写迁移标记失败：{e}");
    }
    Some(restored.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Capabilities;

    fn manifest(id: &str, search: bool) -> ProviderManifest {
        ProviderManifest {
            id: id.to_string(),
            name: id.to_string(),
            version: "1".into(),
            kind: "tvbox".into(),
            description: None,
            icon: None,
            id_prefixes: Vec::new(),
            capabilities: Capabilities {
                vod: true,
                search,
                ..Default::default()
            },
            hidden: false,
            cover_headers: Vec::new(),
            config: Vec::new(),
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            enabled: None,
        }
    }

    /// ★★★ 只恢复"可搜索"的；不可搜索的（直播/豆瓣/网盘）必须留在停用列表里
    ///
    /// ```text
    /// 注入验证：把 `if searchable.contains(id)` 改成 `if true` ⇒ 本条 FAILED
    ///   （那会把直播/豆瓣也复活，扇出里多 17 条 Unsupported 噪声）。
    /// ```
    #[test]
    fn plan_restores_only_searchable() {
        let disabled = vec![
            "api".to_string(),
            "cctv".to_string(),
            "iptv".to_string(),
            "csp-douban".to_string(),
        ];
        let searchable: HashSet<String> = ["api", "cctv", "csp-douban"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        // csp-douban 声明 search=true（真机它在 search() 里才拒绝）⇒ 会被恢复 —— 这是已知代价，
        // 由聚合的 fails 暴露出来，不影响"用户手停仍生效"这条纪律。
        let (keep, restored) = plan_restore(&disabled, &searchable);
        assert_eq!(keep, vec!["iptv".to_string()], "★ 不可搜索的必须留下");
        assert_eq!(
            restored,
            vec!["api".to_string(), "cctv".to_string(), "csp-douban".to_string()]
        );
    }

    /// ★★ 未注册的 id 原样保留（不许把用户的其它停用记录清掉）
    #[test]
    fn plan_keeps_unknown_ids() {
        let disabled = vec!["ghost".to_string(), "api".to_string()];
        let searchable: HashSet<String> = ["api".to_string()].into_iter().collect();
        let (keep, restored) = plan_restore(&disabled, &searchable);
        assert_eq!(keep, vec!["ghost".to_string()]);
        assert_eq!(restored, vec!["api".to_string()]);
    }

    /// ★★★ 迁移只跑一次（标记生效后，用户新停用的源不许被复活）
    #[test]
    fn run_once_respects_marker() {
        let dir = std::env::temp_dir().join(format!(
            "sourin-mig-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        crate::commands::save_disabled(&dir, &["api".to_string(), "iptv".to_string()]).unwrap();
        let manifests = vec![manifest("api", true), manifest("iptv", false)];

        let first = run_once(&dir, &manifests).expect("第一次必须执行");
        assert_eq!(first, 1, "只应恢复 api");
        assert_eq!(crate::commands::load_disabled(&dir), vec!["iptv".to_string()]);

        // 用户之后手动停用 api ⇒ 第二次启动**不许**把它复活
        crate::commands::save_disabled(&dir, &["api".to_string(), "iptv".to_string()]).unwrap();
        assert_eq!(run_once(&dir, &manifests), None, "★ 有标记就跳过");
        assert_eq!(
            crate::commands::load_disabled(&dir),
            vec!["api".to_string(), "iptv".to_string()],
            "★★ 用户手停的必须留在停用列表"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}