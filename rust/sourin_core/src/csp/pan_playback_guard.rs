// 播放解析代次与临时文件归属。异步子任务不会自动继承 task-local，需显式 scope。

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaybackOwner {
    pub consumer: String,
    pub generation: u64,
}

#[derive(Default)]
struct Latest {
    generation: u64,
    closed: bool,
}

fn latest() -> &'static Mutex<HashMap<String, Latest>> {
    static LATEST: OnceLock<Mutex<HashMap<String, Latest>>> = OnceLock::new();
    LATEST.get_or_init(|| Mutex::new(HashMap::new()))
}

tokio::task_local! {
    static OWNER: Option<PlaybackOwner>;
}

pub fn owner_from_payload(value: &serde_json::Value) -> Result<Option<PlaybackOwner>, String> {
    let consumer = value.get("play_consumer");
    let generation = value.get("play_generation");
    if consumer.is_none() && generation.is_none() { return Ok(None); }
    let consumer = consumer.and_then(|c| c.as_str()).filter(|c| {
        !c.is_empty() && c.len() <= 160 && !c.chars().any(char::is_control)
    }).ok_or("播放解析请求缺少有效的会话标识")?;
    let generation = generation.and_then(|g| g.as_u64()).filter(|g| *g > 0)
        .ok_or("播放解析请求缺少有效的请求代次")?;
    Ok(Some(PlaybackOwner { consumer: consumer.into(), generation }))
}

/// 在首个网络 await 前注册；晚抵达的旧请求不能重置较新的代次或关闭状态。
pub fn register(owner: Option<PlaybackOwner>) -> Result<Option<PlaybackOwner>, String> {
    if let Some(owner) = &owner {
        let mut all = latest().lock().unwrap_or_else(|e| e.into_inner());
        let last = all.entry(owner.consumer.clone()).or_default();
        if owner.generation < last.generation || last.closed {
            return Err("播放解析请求已过期".into());
        }
        if owner.generation > last.generation {
            last.generation = owner.generation;
            last.closed = false;
        }
    }
    Ok(owner)
}

pub async fn with_scope<T>(owner: Option<PlaybackOwner>, future: impl Future<Output = T>) -> T {
    OWNER.scope(owner, future).await
}

pub fn current_owner() -> Option<PlaybackOwner> {
    OWNER.try_with(Clone::clone).ok().flatten()
}

pub fn check_current() -> Result<(), String> {
    let Some(owner) = current_owner() else { return Ok(()); };
    let all = latest().lock().unwrap_or_else(|e| e.into_inner());
    match all.get(&owner.consumer) {
        Some(last) if last.generation == owner.generation && !last.closed => Ok(()),
        _ => Err("播放解析请求已过期".into()),
    }
}

pub fn invalidate(owner: &PlaybackOwner) {
    let mut all = latest().lock().unwrap_or_else(|e| e.into_inner());
    let last = all.entry(owner.consumer.clone()).or_default();
    if owner.generation >= last.generation {
        last.generation = owner.generation;
        last.closed = true;
    }
}

/// 清理自己的旧代次；无上下文的旧调用方只能清理无归属的旧副本。
pub fn cleanup_matches(saved: &Option<PlaybackOwner>, target: &Option<PlaybackOwner>) -> bool {
    match (saved, target) {
        (Some(saved), Some(target)) => saved.consumer == target.consumer && saved.generation <= target.generation,
        (None, None) => true,
        _ => false,
    }
}

/// 只在真实网盘修改阶段持锁；解析和匿名列文件无需堵住新请求。
pub async fn mutation_lock(kind: &str) -> tokio::sync::OwnedMutexGuard<()> {
    static LOCKS: OnceLock<Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>> = OnceLock::new();
    let lock = LOCKS.get_or_init(|| Mutex::new(HashMap::new())).lock()
        .unwrap_or_else(|e| e.into_inner()).entry(kind.to_string())
        .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(()))).clone();
    lock.lock_owned().await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owner(consumer: &str, generation: u64) -> PlaybackOwner {
        PlaybackOwner { consumer: consumer.into(), generation }
    }

    #[tokio::test]
    async fn latest_request_rejects_slow_old_parser_before_mutation() {
        let old = owner("guard-slow-parser", 1);
        let new = owner("guard-slow-parser", 2);
        register(Some(old.clone())).unwrap();
        register(Some(new.clone())).unwrap();
        with_scope(Some(new), async {
            let _lock = mutation_lock("guard-fixture").await;
            assert!(check_current().is_ok());
        }).await;
        with_scope(Some(old.clone()), async {
            let _lock = mutation_lock("guard-fixture").await;
            assert!(check_current().is_err(), "旧解析不能进入会删除新副本的修改阶段");
        }).await;
        assert!(register(Some(old)).is_err(), "旧请求不能反过来登记为最新请求");
    }

    #[tokio::test]
    async fn disposal_closes_only_its_consumer_and_cannot_reopen_old_epoch() {
        let old_page = owner("guard-disposed-page", 5);
        let new_page = owner("guard-new-page", 6);
        register(Some(old_page.clone())).unwrap();
        register(Some(new_page.clone())).unwrap();
        invalidate(&old_page);
        assert!(register(Some(old_page.clone())).is_err());
        assert!(register(Some(owner("guard-disposed-page", 7))).is_err(), "已退出页面不能用更高代次复活");
        with_scope(Some(old_page), async { assert!(check_current().is_err()); }).await;
        with_scope(Some(new_page), async { assert!(check_current().is_ok()); }).await;
    }

    #[test]
    fn cleanup_is_owner_and_generation_scoped_including_legacy() {
        let target = Some(owner("cleanup-page", 7));
        assert!(cleanup_matches(&Some(owner("cleanup-page", 6)), &target));
        assert!(!cleanup_matches(&Some(owner("cleanup-page", 8)), &target));
        assert!(!cleanup_matches(&Some(owner("new-page", 1)), &target));
        assert!(!cleanup_matches(&target, &None));
        assert!(!cleanup_matches(&None, &target));
        assert!(cleanup_matches(&None, &None));
    }

    #[test]
    fn payload_is_optional_but_half_context_and_zero_generation_are_rejected() {
        assert_eq!(owner_from_payload(&serde_json::json!({"other":true})).unwrap(), None);
        assert!(owner_from_payload(&serde_json::json!({"play_consumer":"p"})).is_err());
        assert!(owner_from_payload(&serde_json::json!({"play_consumer":"p","play_generation":0})).is_err());
        assert_eq!(owner_from_payload(&serde_json::json!({
            "play_consumer":"p","play_generation":3
        })).unwrap(), Some(owner("p", 3)));
    }
}
