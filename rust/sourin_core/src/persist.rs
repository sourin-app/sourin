// ═══════════════════════════════════════════════════════════════════════
//  第三方源清单的持久化 —— 从 Tauri lib.rs 搬过来的（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件
//
// 这组函数原来散在 Tauri 的 `lib.rs` 里（`load_persisted` /
// `save_persisted` / `providers_file` / `persist_from_registry`），
// 而 `AppState::bootstrap` 需要它们。
//
// 它们本质是**存储层**的东西，跟 UI 框架无关，所以搬到核心层。
//
// # 原注释里记录的设计意图（保留）
//
// ## 为什么用「内存状态反推」而不是维护一份并行清单
//
// `persist_from_registry` 从 `state.third_party` 反推要写什么，
// 而不是另外维护一份列表 —— 避免两处状态不一致
// （用户移除源后忘了同步清单 = 幽灵源复活）。

use std::path::{Path, PathBuf};

use crate::model::PersistedProvider;
use crate::state::AppState;

/// 清单文件路径
pub fn providers_file(dir: &Path) -> PathBuf {
    dir.join("third-party-providers.json")
}

/// 读取持久化的第三方源清单
///
/// # 容错
///
/// 文件不存在 → 空列表（首次启动的正常情况）
/// 文件损坏   → 记 warn + 空列表（**不能崩** —— 一份坏 JSON
///              不该让整个应用起不来）
pub fn load_persisted(dir: &Path) -> Vec<PersistedProvider> {
    let p = providers_file(dir);
    match std::fs::read_to_string(&p) {
        Ok(s) => serde_json::from_str(&s).unwrap_or_else(|e| {
            log::warn!("第三方源清单解析失败（将忽略）: {e}");
            Vec::new()
        }),
        Err(_) => Vec::new(),
    }
}

/// 原子写入清单
///
/// # 为什么要「先写临时文件再 rename」
///
/// 直接 `fs::write` 到目标文件，如果写到一半断电/崩溃，
/// 文件就是**半截 JSON** —— 下次启动读不出来，用户的源全丢。
///
/// `rename` 在同一个文件系统内是**原子操作**：
/// 要么还是旧文件，要么已经完整是新文件，不存在中间态。
pub fn save_persisted(dir: &Path, list: &[PersistedProvider]) -> Result<(), String> {
    let p = providers_file(dir);
    let tmp = p.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(list).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, body).map_err(|e| format!("写入临时清单失败: {e}"))?;
    std::fs::rename(&tmp, &p).map_err(|e| format!("替换清单失败: {e}"))?;
    Ok(())
}

/// 把「当前内存里的第三方源」写回清单
///
/// ⚠️ 从**内存状态反推**而不是维护一份并行列表：
/// 避免两处状态不一致（用户移除源后忘了同步清单 = 幽灵源复活）。
pub fn persist_from_registry(state: &AppState) -> Result<(), String> {
    let list: Vec<PersistedProvider> = state
        .third_party
        .read()
        .map_err(|_| "第三方源列表被污染（锁中毒）".to_string())?
        .clone();
    save_persisted(&state.data_dir, &list)
}

// ═══════════════════════════════════════════════════════════════════════
//  恢复失败报告（第19项收口）
// ═══════════════════════════════════════════════════════════════════════

/// 一条「重启后没能恢复的源」
///
/// # 为什么要有这个（而不只是 `log::warn`）
///
/// 用户视角的故障是「我明明导入过这个源，重启后没了」。
/// 日志他在界面里看不到，所以必须有一份**可查询**的记录：
/// ```text
/// data_dir/restore-failures.json
/// [{"id":"tvbox3","api":"csp_PanWebShare","reason":"csp_PanWebShare 尚未实现"}]
/// ```
/// `reason` 直接用**实现层给的原文**（不二次改写）——
/// 「尚未实现」和「网络失败」是两件事，用户/我们据此决定该等下一个版本还是重试。
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct RestoreFailure {
    pub id: String,
    pub api: String,
    pub reason: String,
}

/// 恢复失败报告的文件名
pub fn restore_failures_file(dir: &Path) -> PathBuf {
    dir.join("restore-failures.json")
}

/// 写恢复失败报告（覆盖写；空列表时**删掉旧报告**）
///
/// 为什么空列表要删：上一次的失败报告如果留着，用户会一直看到
/// 一个早就修好的告警 —— 陈旧数据比没有数据更误导。
pub fn write_restore_failures(dir: &Path, rows: &[RestoreFailure]) -> Result<(), String> {
    let p = restore_failures_file(dir);
    if rows.is_empty() {
        let _ = std::fs::remove_file(&p);
        return Ok(());
    }
    let tmp = p.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(rows).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, body).map_err(|e| format!("写临时报告失败: {e}"))?;
    std::fs::rename(&tmp, &p).map_err(|e| format!("替换报告失败: {e}"))?;
    Ok(())
}

/// 读恢复失败报告（不存在 / 损坏 ⇒ 空列表，**绝不 panic**）
pub fn load_restore_failures(dir: &Path) -> Vec<RestoreFailure> {
    match std::fs::read_to_string(restore_failures_file(dir)) {
        Ok(s) => serde_json::from_str(&s).unwrap_or_else(|e| {
            log::warn!("restore-failures.json 解析失败（将忽略）: {e}");
            Vec::new()
        }),
        Err(_) => Vec::new(),
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 临时目录（用时间戳保证唯一）
    fn tmp_dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "sourin-core-test-{tag}-{}",
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// ★ 损坏的清单必须降级为空列表，**不能崩**
    ///
    /// 为什么重要：一份坏 JSON 如果让整个应用起不来，
    /// 用户没有任何自救手段（他不知道该删哪个文件）。
    #[test]
    fn corrupt_file_degrades_to_empty() {
        let dir = tmp_dir("corrupt");
        std::fs::write(providers_file(&dir), "{ this is not json").unwrap();
        let got = load_persisted(&dir);
        assert!(got.is_empty(), "损坏清单应降级为空而不是崩溃");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 不存在的文件 → 空列表（首次启动的正常路径）
    #[test]
    fn missing_file_is_empty_not_error() {
        let dir = tmp_dir("missing");
        assert!(load_persisted(&dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 写入再读出必须一致（含两种变体）
    #[test]
    fn save_load_roundtrip() {
        let dir = tmp_dir("roundtrip");
        let list = vec![
            PersistedProvider::Declarative {
                id: "d1".into(),
                json: r#"{"id":"d1"}"#.into(),
            },
            PersistedProvider::Http {
                id: "h1".into(),
                base_url: "http://127.0.0.1:9999".into(),
                headers: [("X-Test".to_string(), "1".to_string())]
                    .into_iter()
                    .collect(),
            },
        ];
        save_persisted(&dir, &list).unwrap();
        let back = load_persisted(&dir);
        assert_eq!(back.len(), 2, "读回来的条数不对");
        assert_eq!(back[0].id(), "d1");
        assert_eq!(back[1].id(), "h1");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ 原子写：写完不能留下 .tmp 残file
    ///
    /// rename 成功后临时文件应该已经不存在了。
    /// 如果留了，说明 rename 没生效（如跨文件系统），
    /// 那种情况下原子性也是不成立的 —— 必须测。
    #[test]
    fn atomic_write_leaves_no_tmp_file() {
        let dir = tmp_dir("atomic");
        save_persisted(&dir, &[]).unwrap();
        let tmp = providers_file(&dir).with_extension("json.tmp");
        assert!(!tmp.exists(), "原子写不该留下临时文件: {}", tmp.display());
        assert!(providers_file(&dir).exists(), "目标文件应该存在");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 失败报告：写→读一致；空列表 ⇒ 删文件（陈旧告警比没有更糟）
    #[test]
    fn restore_failures_roundtrip_and_cleared_when_empty() {
        let dir = tmp_dir("rf");
        assert!(load_restore_failures(&dir).is_empty(), "没有报告时读出来必须是空");
        let rows = vec![RestoreFailure {
            id: "tvbox3".to_string(),
            api: "csp_PanWebShare".to_string(),
            reason: "csp_PanWebShare 尚未实现".to_string(),
        }];
        write_restore_failures(&dir, &rows).expect("写报告");
        let got = load_restore_failures(&dir);
        assert_eq!(got, rows, "写进去的必须原样读回来（reason 不许被改写）");
        assert!(restore_failures_file(&dir).exists());
        // 空列表 ⇒ 删掉旧报告
        write_restore_failures(&dir, &[]).expect("清空报告");
        assert!(!restore_failures_file(&dir).exists(), "空报告应删文件，避免陈旧告警");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 旧清单（`Tvbox` 没有 `ext` 字段）必须照常能读 —— 阴性对照
    #[test]
    fn old_tvbox_json_without_ext_still_loads() {
        let dir = tmp_dir("oldext");
        let body = r#"[{"kind":"tvbox","id":"a","name":"n","api":"csp_Bili","categories":[]}]"#;
        std::fs::write(providers_file(&dir), body).unwrap();
        let got = load_persisted(&dir);
        assert_eq!(got.len(), 1, "旧清单不许整份被丢");
        match &got[0] {
            PersistedProvider::Tvbox { ext, api, .. } => {
                assert_eq!(api, "csp_Bili");
                assert!(ext.is_none(), "缺字段 ⇒ None（不是空串、更不是解析失败）");
            }
            _ => panic!("应识别为 tvbox"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

}
