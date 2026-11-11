//! Persistent subscription origins. Old provider ids and user history are unchanged.
use crate::{model::PersistedProvider, state::AppState};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

const FILE: &str = "source-catalog.json";
static WRITE: Mutex<()> = Mutex::new(());
pub const FETCH_BUDGET: Duration = Duration::from_secs(24);

#[cfg(test)]
#[path = "source_catalog_selection_tests.rs"]
mod selection_tests;

#[cfg(test)]
#[path = "source_catalog_identity_tests.rs"]
mod identity_tests;

#[cfg(test)]
#[path = "source_catalog_lifecycle_tests.rs"]
mod lifecycle_tests;

#[cfg(test)]
#[path = "source_catalog_live_parent_tests.rs"]
mod live_parent_tests;

#[cfg(test)]
#[path = "source_catalog_live_refresh_tests.rs"]
mod live_refresh_tests;

#[cfg(test)]
#[path = "source_catalog_live_refresh_persistence_tests.rs"]
mod live_refresh_persistence_tests;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SourceOrigin {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub primary_url: String,
    pub backup_urls: Vec<String>,
    pub last_successful_url: Option<String>,
    pub last_successful_endpoint: Option<String>,
    pub last_success_at: i64,
    pub provider_ids: Vec<String>,
    /// TVBox live descendants have their own playlist/address origin.
    pub related_provider_ids: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SourceCatalog {
    pub version: u32,
    pub origins: Vec<SourceOrigin>,
    #[serde(skip_deserializing)]
    pub groups: Vec<SourceOriginGroup>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SourceOriginGroup {
    pub id: String,
    pub name: String,
    pub provider_ids: Vec<String>,
    pub selected_provider_ids: Vec<String>,
}

pub fn load(dir: &Path) -> SourceCatalog {
    std::fs::read_to_string(dir.join(FILE))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save(dir: &Path, catalog: &SourceCatalog) -> Result<(), String> {
    let path = dir.join(FILE);
    let tmp = dir.join("source-catalog.json.tmp");
    let mut stored = catalog.clone();
    stored.version = 1;
    stored.groups.clear();
    std::fs::write(
        &tmp,
        serde_json::to_vec_pretty(&stored).map_err(|e| e.to_string())?,
    )
    .map_err(|e| format!("保存源配置失败：{e}"))?;
    std::fs::rename(tmp, path).map_err(|e| format!("替换源配置失败：{e}"))
}

pub fn origin_id(kind: &str, url: &str) -> String {
    format!("{kind}-{}", crate::m3u::stable_key(url.trim()))
}

fn has_url(origin: &SourceOrigin, url: &str) -> bool {
    let url = url.trim();
    !url.is_empty()
        && (origin.primary_url.trim() == url
            || origin.backup_urls.iter().any(|u| u.trim() == url)
            || origin.id == origin_id(&origin.kind, url)
            || origin.last_successful_url.as_deref().map(str::trim) == Some(url))
}

fn legacy_origin(kind: &str, name: &str, url: &str, pid: &str) -> SourceOrigin {
    let url = url.trim();
    SourceOrigin {
        id: if kind == "js" {
            format!("js-{pid}")
        } else if url.is_empty() {
            format!("{kind}-local-{pid}")
        } else {
            origin_id(kind, url)
        },
        name: name.to_owned(),
        kind: kind.to_owned(),
        primary_url: url.to_owned(),
        provider_ids: vec![pid.to_owned()],
        ..Default::default()
    }
}

fn add_legacy(catalog: &mut SourceCatalog, source: &SourceOrigin) {
    let pid = &source.provider_ids[0];
    if catalog
        .origins
        .iter()
        .any(|o| o.kind == source.kind && o.provider_ids.contains(pid))
    {
        return;
    }
    if let Some(origin) = catalog
        .origins
        .iter_mut()
        .find(|o| source.kind != "js" && !source.primary_url.is_empty()
            && o.kind == source.kind && o.primary_url.trim() == source.primary_url)
    {
        origin.provider_ids.push(pid.to_owned());
    } else {
        catalog.origins.push(source.clone());
    }
}

/// Older catalogs merged every missing URL, and also merged distinct JS ids
/// downloaded from one URL. Only sidecar download/subscription URLs establish
/// provenance; a provider's API URL or display name never does.
fn reconcile_origins(catalog: &mut SourceCatalog, sources: &[SourceOrigin]) {
    let mut repaired = Vec::new();
    for mut origin in std::mem::take(&mut catalog.origins) {
        let mut seen = HashSet::new();
        origin.provider_ids.retain(|id| seen.insert(id.clone()));
        if !matches!(origin.kind.as_str(), "js" | "tvbox") {
            repaired.push(origin);
            continue;
        }
        let members: Vec<_> = origin.provider_ids.iter().filter_map(|id| {
            sources.iter().find(|s| s.kind == origin.kind && s.provider_ids.contains(id))
        }).collect();
        if members.is_empty() {
            // Multi-repository TVBox subscriptions legitimately have no child
            // providers yet. Empty local/JS remnants have no editable owner.
            if origin.kind == "tvbox" && !origin.primary_url.trim().is_empty() {
                origin.provider_ids.clear();
                repaired.push(origin);
            }
            continue;
        }
        if members.len() == 1 && origin.provider_ids.len() == 1 {
            // A singleton's manual name/addresses are unambiguous, including
            // a local plugin to which the user explicitly added a URL.
            if origin.kind == "js" {
                origin.id = members[0].id.clone();
            }
            repaired.push(origin);
            continue;
        }
        let mut parts: Vec<SourceOrigin> = Vec::new();
        for source in members {
            if let Some(part) = parts.iter_mut().find(|part| {
                source.kind == "tvbox" && !source.primary_url.is_empty()
                    && part.primary_url == source.primary_url
            }) {
                part.provider_ids.extend(source.provider_ids.clone());
            } else {
                parts.push(source.clone());
            }
        }
        if parts.len() == 1 && origin.kind == "tvbox" && !parts[0].primary_url.is_empty() {
            origin.provider_ids = parts[0].provider_ids.clone();
            repaired.push(origin);
            continue;
        }
        // Keep saved edits only when the old identity identifies exactly one
        // part. A shared URL cannot attribute JS backups/cooldown to a plugin.
        let owners: Vec<_> = parts.iter().enumerate().filter(|(_, part)| {
            origin.id == part.id || (part.provider_ids.len() == 1
                && origin.id == format!("{}-local-{}", part.kind, part.provider_ids[0]))
        }).map(|(index, _)| index).collect();
        for (index, mut part) in parts.into_iter().enumerate() {
            if owners.len() == 1 && owners[0] == index {
                let ids = part.provider_ids;
                let id = part.id;
                part = origin.clone();
                part.id = id;
                part.provider_ids = ids;
            }
            repaired.push(part);
        }
    }
    catalog.origins = repaired;
    for source in sources {
        add_legacy(catalog, source);
    }
}

pub fn catalog(state: &AppState) -> Result<SourceCatalog, String> {
    let _guard = WRITE.lock().map_err(|_| "源配置写入锁不可用")?;
    catalog_locked(state)
}

// Callers already holding WRITE use this entry point, so reconciliation and
// user edits are serialized without recursively locking the same mutex.
fn catalog_locked(state: &AppState) -> Result<SourceCatalog, String> {
    let mut out = load(&state.data_dir);
    let previous = out.origins.clone();
    let mut sources = Vec::new();
    let metas = crate::tvbox::load_tvbox_metas(&state.data_dir);
    let persisted = state.third_party.read().map_err(|_| "源配置不可读")?;
    let known: HashSet<_> = state
        .registry
        .manifests()
        .into_iter()
        .map(|m| m.id)
        .collect();
    let disabled = crate::commands::load_disabled(&state.data_dir);
    let aggregate = crate::tvbox_aggregate::load(&state.data_dir);
    let explicit = aggregate.site_selection_explicit || !aggregate.enabled_site_ids.is_empty();
    let mut groups: BTreeMap<String, SourceOriginGroup> = BTreeMap::new();
    for row in persisted.iter() {
        match row {
            PersistedProvider::Tvbox { id, name, api, ext, .. } if known.contains(id) => {
                let meta = metas.get(id);
                let url = meta.and_then(|m| m.source_url.as_deref()).unwrap_or("").trim();
                let label = if url.is_empty() {
                    "本地 TVBox 配置".to_string()
                } else {
                    reqwest::Url::parse(url)
                        .ok()
                        .and_then(|u| u.host_str().map(str::to_owned))
                        .unwrap_or_else(|| "TVBox 订阅".into())
                };
                sources.push(legacy_origin("tvbox", &label, url, id));
                // A CSP API identifies an implementation; different ext values
                // can select unrelated upstreams despite a shared site key.
                let key = meta
                    .map(|m| m.site_key.as_str())
                    .filter(|s| !s.is_empty())
                    .unwrap_or(name);
                let base_identity = format!("{key}\n{}", crate::tvbox::normalize_api_url(api));
                // Keep the existing group identity when no ext is configured.
                let identity = match ext.as_deref().map(str::trim).filter(|ext| !ext.is_empty()) {
                    Some(ext) => format!("{base_identity}\n{ext}"),
                    None => base_identity,
                };
                let gid = format!("site-{}", crate::m3u::stable_key(&identity));
                let group = groups
                    .entry(gid.clone())
                    .or_insert_with(|| SourceOriginGroup {
                        id: gid,
                        name: name.clone(),
                        ..Default::default()
                    });
                group.provider_ids.push(id.clone());
                if !disabled.contains(id) && (!explicit || aggregate.enabled_site_ids.contains(id))
                {
                    group.selected_provider_ids.push(id.clone());
                }
            }
            PersistedProvider::M3uLive { id, name, url } if known.contains(id) => {
                sources.push(legacy_origin("live", name, url, id))
            }
            _ => {}
        }
    }
    drop(persisted);
    let dir = crate::state::plugins_dir(&state.data_dir);
    for manifest in state.registry.manifests().iter().filter(|m| m.kind == "js") {
        let url = crate::plugins::read_plugin_meta(&dir, &manifest.id)
            .and_then(|m| m.source_url)
            .unwrap_or_default();
        sources.push(legacy_origin("js", &manifest.name, &url, &manifest.id));
    }
    reconcile_origins(&mut out, &sources);
    for origin in &mut out.origins {
        origin.provider_ids.retain(|id| known.contains(id));
        let mut seen = HashSet::new();
        origin.related_provider_ids.retain(|id| origin.kind == "tvbox"
            && seen.insert(id.clone())
            && sources.iter().any(|source| source.kind == "live"
                && source.provider_ids.contains(id)));
    }
    out.version = 1;
    out.groups = groups.into_values().collect();
    if out.origins != previous {
        save(&state.data_dir, &out)?;
    }
    Ok(out)
}

pub fn command_get(state: &AppState) -> Result<serde_json::Value, String> {
    serde_json::to_value(catalog(state)?).map_err(|e| e.to_string())
}

pub fn validated_urls(primary: &str, backups: &[String]) -> Result<Vec<String>, String> {
    if primary.trim().is_empty() {
        return Err("请填写主地址".into());
    }
    if backups.len() > 8 {
        return Err("备用地址最多 8 个".into());
    }
    let mut urls = Vec::new();
    for raw in std::iter::once(primary).chain(backups.iter().map(String::as_str)) {
        let value = raw.trim();
        if value.is_empty() {
            continue;
        }
        let url = reqwest::Url::parse(value).map_err(|_| "源地址必须是完整的 HTTP(S) 地址")?;
        if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
            return Err("源地址必须是完整的 HTTP(S) 地址".into());
        }
        if !urls.iter().any(|u| u == value) {
            urls.push(value.to_owned());
        }
    }
    if urls.is_empty() {
        return Err("请填写主地址".into());
    }
    Ok(urls)
}

pub fn command_set_origin(
    state: &AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    let _guard = WRITE.lock().map_err(|_| "源配置写入锁不可用")?;
    let mut out = catalog_locked(state)?;
    let id = args.get("id").and_then(|v| v.as_str()).unwrap_or("");
    let origin = out
        .origins
        .iter_mut()
        .find(|o| o.id == id)
        .ok_or("源订阅已不存在")?;
    let primary = args
        .get("primaryUrl")
        .and_then(|v| v.as_str())
        .unwrap_or(&origin.primary_url)
        .to_owned();
    let backups = match args.get("backupUrls") {
        Some(v) => {
            serde_json::from_value::<Vec<String>>(v.clone()).map_err(|_| "备用地址格式错误")?
        }
        None => origin.backup_urls.clone(),
    };
    let urls = validated_urls(&primary, &backups)?;
    if origin.primary_url != urls[0] || origin.backup_urls != urls[1..] {
        origin.last_successful_endpoint = None;
        origin.last_successful_url = None;
        origin.last_success_at = 0;
    }
    origin.primary_url = urls[0].clone();
    origin.backup_urls = urls[1..].to_vec();
    if let Some(name) = args.get("name").and_then(|v| v.as_str()) {
        origin.name = name.trim().chars().take(60).collect();
    }
    let binding = origin.clone();
    save(&state.data_dir, &out)?;
    if binding.kind == "tvbox" {
        for id in &binding.provider_ids {
            let mut meta = crate::tvbox::read_tvbox_meta(&state.data_dir, id).unwrap_or_default();
            meta.source_url = Some(binding.primary_url.clone());
            crate::tvbox::write_tvbox_meta(&state.data_dir, id, &meta)?;
        }
    }
    drop(_guard);
    command_get(state)
}

pub fn command_select(
    state: &AppState,
    group_id: &str,
    selected: &[String],
) -> Result<serde_json::Value, String> {
    let _guard = WRITE.lock().map_err(|_| "源配置写入锁不可用")?;
    let out = catalog_locked(state)?;
    let group = out
        .groups
        .iter()
        .find(|g| g.id == group_id)
        .ok_or("子源已不存在")?;
    if selected.iter().any(|id| !group.provider_ids.contains(id)) {
        return Err("选择中包含不属于此子源的提供方".into());
    }
    let mut disabled = crate::commands::load_disabled(&state.data_dir);
    let previous_disabled = disabled.clone();
    let mut agg = crate::tvbox_aggregate::load(&state.data_dir);
    let explicit = agg.site_selection_explicit || !agg.enabled_site_ids.is_empty();
    if !explicit {
        agg.enabled_site_ids = state
            .registry
            .manifests()
            .iter()
            .filter(|m| m.kind == "tvbox")
            .map(|m| m.id.clone())
            .collect();
    }
    for id in &group.provider_ids {
        disabled.retain(|p| p != id);
        agg.enabled_site_ids.retain(|p| p != id);
        if selected.contains(id) {
            agg.enabled_site_ids.push(id.clone());
        } else {
            disabled.push(id.clone());
        }
    }
    agg.site_selection_explicit = true;
    crate::commands::save_disabled(&state.data_dir, &disabled)?;
    if let Err(error) = crate::tvbox_aggregate::save(&state.data_dir, &agg) {
        crate::commands::save_disabled(&state.data_dir, &previous_disabled)?;
        return Err(error);
    }
    sync_enabled(&state.registry, &state.data_dir);
    drop(_guard);
    command_get(state)
}

/// Turn the legacy temporary TVBox-only view into ordinary saved source switches.
/// Hidden children were aggregate presentation, never an instruction to disable.
pub fn migrate_legacy_solo(
    registry: &crate::registry::Registry,
    dir: &Path,
    persisted: &[PersistedProvider],
) -> Result<bool, String> {
    let _guard = WRITE.lock().map_err(|_| "源配置写入锁不可用")?;
    let mut aggregate = crate::tvbox_aggregate::load(dir);
    if !aggregate.solo {
        return Ok(false);
    }
    let previous_disabled = crate::commands::load_disabled(dir);
    let metas = crate::tvbox::load_tvbox_metas(dir);
    let explicit = aggregate.site_selection_explicit || !aggregate.enabled_site_ids.is_empty();
    let mut candidates = if explicit {
        aggregate.enabled_site_ids.clone()
    } else {
        let mut ids: Vec<_> = metas.keys().cloned().collect();
        ids.sort();
        ids
    };
    let aggregate_enabled = !previous_disabled.iter()
        .any(|id| id == crate::tvbox_aggregate::AGGREGATE_ID);
    let mut selected = HashSet::new();
    candidates.retain(|id| {
        aggregate_enabled && metas.contains_key(id)
            && !previous_disabled.contains(id) && selected.insert(id.clone())
    });
    let known: std::collections::BTreeSet<String> = registry.manifests().into_iter()
        .map(|manifest| manifest.id)
        .chain(persisted.iter().map(|provider| provider.id().to_owned()))
        .chain(metas.keys().cloned())
        .collect();
    let mut disabled = previous_disabled.clone();
    for id in known {
        if id != crate::tvbox_aggregate::AGGREGATE_ID
            && !selected.contains(&id) && !disabled.contains(&id)
        {
            disabled.push(id);
        }
    }
    // The older automatic restore must never undo this newer explicit choice.
    crate::provider_migration::preserve_current_selection(dir)?;
    crate::commands::save_disabled(dir, &disabled)?;
    aggregate.enabled_site_ids = candidates;
    aggregate.site_selection_explicit = true;
    aggregate.solo = false;
    if let Err(error) = crate::tvbox_aggregate::save(dir, &aggregate) {
        return match crate::commands::save_disabled(dir, &previous_disabled) {
            Ok(()) => Err(error),
            Err(rollback) => Err(format!("{error}；恢复源启用状态失败：{rollback}")),
        };
    }
    log::info!("已迁移 TVBox 测试选择：保留 {} 个子源，其余源保持停用，可手动重新启用", selected.len());
    Ok(true)
}

pub fn provider_enabled(
    manifest: &crate::model::ProviderManifest,
    disabled: &[String],
    aggregate: &crate::tvbox_aggregate::AggregateConfig,
) -> bool {
    let explicit = aggregate.site_selection_explicit || !aggregate.enabled_site_ids.is_empty();
    !disabled.contains(&manifest.id)
        && (manifest.kind != "tvbox"
            || manifest.id == crate::tvbox_aggregate::AGGREGATE_ID
            || !explicit || aggregate.enabled_site_ids.contains(&manifest.id))
}

pub fn sync_enabled(registry: &crate::registry::Registry, dir: &Path) {
    let disabled = crate::commands::load_disabled(dir);
    let agg = crate::tvbox_aggregate::load(dir);
    for manifest in registry.manifests() {
        registry.set_enabled(&manifest.id, provider_enabled(&manifest, &disabled, &agg));
    }
}

pub fn record_import(
    state: &AppState,
    primary: &str,
    actual: &str,
    endpoint: &str,
    ids: &[String],
    live_ids: &[String],
    name: Option<&str>,
    backups: &[String],
) -> Result<String, String> {
    let _guard = WRITE.lock().map_err(|_| "源配置写入锁不可用")?;
    let mut out = catalog_locked(state)?;
    let idx = out.origins.iter().position(|o| {
        o.kind == "tvbox" && o.provider_ids.iter().any(|id| ids.contains(id))
    }).or_else(|| matching_origin(&out, "tvbox", None, primary));
    let index = idx.unwrap_or_else(|| {
        out.origins.push(SourceOrigin {
            id: origin_id("tvbox", primary),
            name: "TVBox 订阅".into(),
            kind: "tvbox".into(),
            primary_url: primary.into(),
            ..Default::default()
        });
        out.origins.len() - 1
    });
    let origin = &mut out.origins[index];
    if let Some(name) = name.filter(|n| !n.trim().is_empty()) {
        origin.name = name.trim().chars().take(60).collect();
    }
    if !backups.is_empty() {
        origin.backup_urls = validated_urls(primary, backups)?[1..].to_vec();
    }
    for id in ids {
        if !origin.provider_ids.contains(id) {
            origin.provider_ids.push(id.clone());
        }
    }
    // Replace this import's descendant set. A shared playlist can belong to
    // several parents, while its address settings keep a single live owner.
    let mut seen = HashSet::new();
    origin.related_provider_ids = live_ids.iter()
        .filter(|id| seen.insert((*id).clone())).cloned().collect();
    origin.last_successful_url = Some(actual.to_owned());
    origin.last_successful_endpoint = Some(endpoint.to_owned());
    origin.last_success_at = now_secs();
    let id = origin.id.clone();
    save(&state.data_dir, &out)?;
    Ok(id)
}

/// Refresh only the live attribution of a known TVBox VOD representative.
/// Playlist addresses and successful endpoint state remain with live owners.
pub fn record_live_membership(
    state: &AppState,
    tvbox_provider_id: &str,
    live_ids: &[String],
) -> Result<bool, String> {
    let _guard = WRITE.lock().map_err(|_| "源配置写入锁不可用")?;
    let mut out = catalog_locked(state)?;
    let known_live: HashSet<String> = out.origins.iter()
        .filter(|origin| origin.kind == "live")
        .flat_map(|origin| origin.provider_ids.iter().cloned()).collect();
    if live_ids.iter().any(|id| !known_live.contains(id)) {
        return Err("直播归属包含尚未登记的直播来源".into());
    }
    let origin = out.origins.iter_mut()
        .find(|origin| origin.kind == "tvbox"
            && origin.provider_ids.iter().any(|id| id == tvbox_provider_id))
        .ok_or("没有找到此 TVBox 源的父订阅")?;
    let mut seen = HashSet::new();
    let ids: Vec<String> = live_ids.iter()
        .filter(|id| seen.insert((*id).clone())).cloned().collect();
    let changed = origin.related_provider_ids != ids;
    if changed {
        origin.related_provider_ids = ids;
        save(&state.data_dir, &out)?;
    }
    Ok(changed)
}

pub fn urls_for(dir: &Path, kind: &str, provider_id: Option<&str>, primary: &str) -> Vec<String> {
    let catalog = load(dir);
    match matching_origin(&catalog, kind, provider_id, primary).map(|i| &catalog.origins[i]) {
        Some(o) => ordered_urls(o, now_secs()).unwrap_or_else(|_| vec![primary.to_owned()]),
        None => vec![primary.to_owned()],
    }
}

fn matching_origin(catalog: &SourceCatalog, kind: &str, provider_id: Option<&str>, primary: &str) -> Option<usize> {
    if let Some(id) = provider_id {
        // A URL may serve multiple plugin ids over time. An explicit provider
        // must never inherit another provider's endpoints or success state.
        return catalog.origins.iter().position(|o| o.kind == kind
            && o.provider_ids.iter().any(|p| p == id));
    }
    let primary = primary.trim();
    if primary.is_empty() {
        return None;
    }
    catalog.origins.iter().position(|o| o.kind == kind && o.primary_url.trim() == primary)
        .or_else(|| catalog.origins.iter().position(|o| o.kind == kind && has_url(o, primary)))
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn ordered_urls(origin: &SourceOrigin, now: i64) -> Result<Vec<String>, String> {
    let mut urls = validated_urls(&origin.primary_url, &origin.backup_urls)?;
    // Recheck the primary after a bounded cooldown. Never invent an endpoint
    // from a redirect destination or retain one the user removed.
    if origin.last_success_at > 0 && (0..300).contains(&(now - origin.last_success_at)) {
        if let Some(index) = origin
            .last_successful_endpoint
            .as_ref()
            .and_then(|entry| urls.iter().position(|url| url == entry))
        {
            let preferred = urls.remove(index);
            urls.insert(0, preferred);
        }
    }
    Ok(urls)
}

pub fn primary_for(dir: &Path, kind: &str, provider_id: &str) -> Option<String> {
    load(dir)
        .origins
        .into_iter()
        .find(|o| o.kind == kind && o.provider_ids.iter().any(|id| id == provider_id))
        .map(|o| o.primary_url)
        .filter(|url| !url.trim().is_empty())
}

fn record_success(
    dir: &Path,
    kind: &str,
    provider_id: Option<&str>,
    primary: &str,
    actual: &str,
    endpoint: &str,
) {
    let Ok(_guard) = WRITE.lock() else {
        return;
    };
    let mut catalog = load(dir);
    if let Some(index) = matching_origin(&catalog, kind, provider_id, primary) {
        let origin = &mut catalog.origins[index];
        origin.last_successful_url = Some(actual.to_owned());
        origin.last_successful_endpoint = Some(endpoint.to_owned());
        // Preserve the start of the cooldown when repeatedly using the same
        // backup, so frequent requests cannot postpone primary recovery forever.
        if origin.last_success_at == 0 || now_secs() - origin.last_success_at >= 300 {
            origin.last_success_at = now_secs();
        }
        if let Err(error) = save(dir, &catalog) {
            log::warn!("记录成功源地址失败：{error}");
        }
    }
}

/// Endpoint failures can try another configured address. Identity failures stop the chain.
pub enum Validation {
    Invalid(String),
    Terminal(String),
}

pub async fn fetch_validated<F>(
    proxy: &Arc<crate::proxy::ProxyStore>,
    provider: &str,
    urls: &[String],
    ua: Option<&str>,
    validate: F,
) -> Result<(String, String, String), String>
where
    F: Fn(&str) -> Result<String, Validation>,
{
    fetch_with_budget(proxy, provider, urls, ua, validate, FETCH_BUDGET).await
}

async fn fetch_with_budget<F>(
    proxy: &Arc<crate::proxy::ProxyStore>,
    provider: &str,
    urls: &[String],
    ua: Option<&str>,
    validate: F,
    budget: Duration,
) -> Result<(String, String, String), String>
where
    F: Fn(&str) -> Result<String, Validation>,
{
    let client = proxy
        .client_for(provider, None)
        .map_err(|e| format!("代理配置不可用: {}", e.message))?;
    let deadline = tokio::time::Instant::now() + budget;
    let mut errors = Vec::new();
    for (index, url) in urls.iter().enumerate() {
        let attempt = async {
            let mut req = client.get(url);
            if let Some(ua) = ua {
                req = req.header(reqwest::header::USER_AGENT, ua);
            }
            let mut response = req
                .send()
                .await
                .map_err(|_| Validation::Invalid("网络请求失败".into()))?;
            let status = response.status();
            // These subscription downloads carry no account authentication.
            // A rejected mirror must not prevent trying another user-supplied
            // address through the same proxy. Content identity checks below
            // still terminate updates that would replace a different plugin.
            if !status.is_success() {
                return Err(Validation::Invalid(format!("HTTP {}", status.as_u16())));
            }
            if response
                .content_length()
                .is_some_and(|n| n > 4 * 1024 * 1024)
            {
                return Err(Validation::Invalid("配置超过 4 MiB".into()));
            }
            let actual = response.url().to_string();
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| Validation::Invalid("读取响应失败".into()))?
            {
                if bytes.len() + chunk.len() > 4 * 1024 * 1024 {
                    return Err(Validation::Invalid("配置超过 4 MiB".into()));
                }
                bytes.extend_from_slice(&chunk);
            }
            let text = String::from_utf8(bytes)
                .map_err(|_| Validation::Invalid("配置不是 UTF-8 文本".into()))?;
            validate(&text).map(|text| (text, actual, url.clone()))
        };
        let now = tokio::time::Instant::now();
        let share = deadline.saturating_duration_since(now) / (urls.len() - index) as u32;
        let attempt_end = (now + share.min(Duration::from_secs(8))).min(deadline);
        match tokio::time::timeout_at(attempt_end, attempt).await {
            Ok(Ok(result)) => return Ok(result),
            Ok(Err(Validation::Terminal(error))) => return Err(error),
            Ok(Err(Validation::Invalid(error))) => {
                errors.push(format!("地址 {}：{error}", index + 1))
            }
            Err(_) => errors.push(format!("地址 {}：请求超时", index + 1)),
        }
        if tokio::time::Instant::now() >= deadline {
            break;
        }
    }
    Err(format!(
        "所有可尝试地址均失败（总预算 {} 秒）：{}",
        budget.as_secs_f32(),
        errors.join("；")
    ))
}

pub async fn fetch_tvbox(state: &AppState, url: &str) -> Result<(String, String), String> {
    let urls = urls_for(&state.data_dir, "tvbox", None, url);
    let result = fetch_validated(
        &state.proxy,
        "tvbox",
        &urls,
        Some(crate::tvbox::TVBOX_CONFIG_UA),
        validate_tvbox,
    )
    .await
    .map_err(|error| format!("下载配置失败：{error}"))?;
    record_success(&state.data_dir, "tvbox", None, url, &result.1, &result.2);
    Ok((result.0, result.1))
}

pub fn validate_tvbox(text: &str) -> Result<String, Validation> {
    let text = crate::tvbox::unwrap_tvbox_config_text(text).map_err(Validation::Invalid)?;
    let cfg = crate::tvbox::parse_loose_json(&text)
        .map_err(|_| Validation::Invalid("返回内容不是 TVBox JSON 配置（可能是网页）".into()))?;
    if cfg.get("sites").and_then(|v| v.as_array()).is_none()
        && cfg.get("urls").and_then(|v| v.as_array()).is_none()
    {
        return Err(Validation::Invalid("配置缺少 sites / urls".into()));
    }
    Ok(text)
}

pub async fn fetch_plugin(
    state: &AppState,
    id: &str,
    url: &str,
) -> Result<(String, String), String> {
    let urls = urls_for(&state.data_dir, "js", Some(id), url);
    let result = fetch_validated(&state.proxy, id, &urls, None, |text| {
        let meta = crate::plugins::parse_meta(text);
        if meta.id.is_empty() || meta.name.is_empty() {
            return Err(Validation::Invalid("不是有效的 JS 插件".into()));
        }
        if meta.id != id {
            return Err(Validation::Terminal(
                "备用地址的插件身份不匹配，已停止更新".into(),
            ));
        }
        crate::plugins::validate_source_syntax(text).map_err(Validation::Invalid)?;
        Ok(text.into())
    })
    .await?;
    record_success(&state.data_dir, "js", Some(id), url, &result.1, &result.2);
    Ok((result.0, result.1))
}

pub fn record_live_success(dir: &Path, id: &str, primary: &str, actual: &str, endpoint: &str) {
    record_success(dir, "live", Some(id), primary, actual, endpoint);
}

pub fn record_plugin(
    state: &AppState,
    id: &str,
    name: &str,
    primary: &str,
    backups: &[String],
    actual: &str,
    endpoint: &str,
) -> Result<(), String> {
    let _guard = WRITE.lock().map_err(|_| "源配置写入锁不可用")?;
    let mut out = catalog_locked(state)?;
    let urls = validated_urls(primary, backups)?;
    let index = out
        .origins
        .iter()
        .position(|o| o.kind == "js" && o.provider_ids.iter().any(|p| p == id));
    let index = index.unwrap_or_else(|| {
        out.origins.push(SourceOrigin {
            id: format!("js-{id}"),
            ..Default::default()
        });
        out.origins.len() - 1
    });
    out.origins[index] = SourceOrigin {
        id: out.origins[index].id.clone(),
        kind: "js".into(),
        name: name.into(),
        primary_url: urls[0].clone(),
        backup_urls: urls[1..].to_vec(),
        last_successful_url: Some(actual.into()),
        last_successful_endpoint: Some(endpoint.into()),
        last_success_at: now_secs(),
        provider_ids: vec![id.into()],
        related_provider_ids: Vec::new(),
    };
    save(&state.data_dir, &out)
}

pub async fn import_live(
    state: &AppState,
    url: &str,
    name: &str,
    backups: &[String],
) -> Result<serde_json::Value, String> {
    use crate::provider::MediaProvider;
    let urls = validated_urls(url, backups)?;
    let provider = crate::providers::m3u_live::M3uLiveProvider::new(name, &urls[0])
        .with_context(state.proxy.clone(), state.data_dir.clone());
    let manifest = provider.manifest().clone();
    let (_, actual, endpoint) = fetch_validated(&state.proxy, &manifest.id, &urls, None, |text| {
        if !crate::providers::m3u_live::valid_playlist(text, &manifest.id) {
            return Err(Validation::Invalid("直播配置没有可用频道".into()));
        }
        Ok(text.to_owned())
    })
    .await?;
    {
        let mut rows = state.third_party.write().map_err(|_| "源配置不可写")?;
        rows.retain(|row| row.id() != manifest.id);
        rows.push(PersistedProvider::M3uLive {
            id: manifest.id.clone(),
            name: manifest.name.clone(),
            url: urls[0].clone(),
        });
    }
    crate::commands_provider::persist_from_registry(state)?;
    state.registry.register(Arc::new(provider));
    let _guard = WRITE.lock().map_err(|_| "源配置写入锁不可用")?;
    let mut out = catalog_locked(state)?;
    let origin = out
        .origins
        .iter_mut()
        .find(|o| o.kind == "live" && o.provider_ids.contains(&manifest.id))
        .ok_or("直播来源登记失败")?;
    origin.primary_url = urls[0].clone();
    origin.backup_urls = urls[1..].to_vec();
    origin.last_successful_url = Some(actual);
    origin.last_successful_endpoint = Some(endpoint);
    origin.last_success_at = now_secs();
    save(&state.data_dir, &out)?;
    crate::commands_provider::touch_providers(state);
    serde_json::to_value(manifest).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn endpoint_order_deduplicates_and_rejects_non_http() {
        assert_eq!(
            validated_urls(
                " https://a.test/config ",
                &[
                    "https://a.test/config".into(),
                    "https://b.test/config".into()
                ]
            )
            .unwrap(),
            vec!["https://a.test/config", "https://b.test/config"]
        );
        assert!(validated_urls("file:///secret", &[]).is_err());
        assert!(validated_urls("", &[]).is_err());
    }
    #[test]
    fn distribution_html_is_not_a_configuration() {
        assert!(validate_tvbox("<html><script>download()</script></html>").is_err());
        assert!(validate_tvbox(r#"{"sites":[]}"#).is_ok());
        assert!(validate_tvbox(r#"{"hello":"world"}"#).is_err());
    }

    #[test]
    fn plugin_syntax_validation_does_not_execute_downloaded_code() {
        assert!(
            crate::plugins::validate_source_syntax("throw new Error('must never execute');")
                .is_ok()
        );
        assert!(crate::plugins::validate_source_syntax("function broken( {").is_err());
    }
    #[test]
    fn catalog_roundtrip_preserves_real_origins_and_backups() {
        let c = SourceCatalog {
            version: 1,
            origins: vec![SourceOrigin {
                id: "subscription-a".into(),
                kind: "tvbox".into(),
                primary_url: "https://a.test/tv".into(),
                backup_urls: vec!["https://b.test/tv".into()],
                provider_ids: vec!["legacy-id".into()],
                ..Default::default()
            }],
            ..Default::default()
        };
        let restored: SourceCatalog =
            serde_json::from_str(&serde_json::to_string(&c).unwrap()).unwrap();
        assert_eq!(restored.origins[0].provider_ids, vec!["legacy-id"]);
        assert_eq!(restored.origins[0].backup_urls, vec!["https://b.test/tv"]);
    }

    #[test]
    fn recent_success_reorders_configured_endpoints_but_expires() {
        let mut origin = SourceOrigin {
            primary_url: "https://primary.test/config".into(),
            backup_urls: vec!["https://backup.test/config".into()],
            last_successful_url: Some("https://redirect.test/final".into()),
            last_successful_endpoint: Some("https://backup.test/config".into()),
            last_success_at: 1000,
            ..Default::default()
        };
        assert_eq!(
            ordered_urls(&origin, 1100).unwrap()[0],
            "https://backup.test/config"
        );
        assert_eq!(
            ordered_urls(&origin, 1300).unwrap()[0],
            "https://primary.test/config"
        );
        origin.backup_urls.clear();
        assert_eq!(
            ordered_urls(&origin, 1100).unwrap(),
            vec!["https://primary.test/config"]
        );
    }

    #[tokio::test]
    async fn total_budget_reserves_time_for_fourth_configured_endpoint() {
        use axum::routing::get;
        let app = axum::Router::new()
            .route(
                "/slow",
                get(|| async {
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    "unused"
                }),
            )
            .route("/fourth", get(|| async { "fourth succeeded" }));
        let (base, server) = serve(app).await;
        let urls = vec![
            format!("{base}/slow?a"),
            format!("{base}/slow?b"),
            format!("{base}/slow?c"),
            format!("{base}/fourth"),
        ];
        let proxy = Arc::new(crate::proxy::ProxyStore::new());
        let started = tokio::time::Instant::now();
        let (body, _, endpoint) = fetch_with_budget(
            &proxy,
            "p",
            &urls,
            None,
            |s| Ok(s.into()),
            Duration::from_millis(400),
        )
        .await
        .unwrap();
        assert_eq!(body, "fourth succeeded");
        assert_eq!(endpoint, urls[3]);
        assert!(started.elapsed() < Duration::from_millis(600));
        server.abort();
    }

    fn scratch(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "sourin-catalog-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    async fn serve(app: axum::Router) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        (base, task)
    }

    #[tokio::test]
    async fn fails_over_only_to_declared_endpoint_and_keeps_redirect_base() {
        use axum::{response::Redirect, routing::get};
        let app = axum::Router::new()
            .route("/bad", get(|| async { "<html>distribution page</html>" }))
            .route("/backup", get(|| async { Redirect::temporary("/actual/config.json") }))
            .route("/actual/config.json", get(|| async { r#"{"sites":[{"key":"one","name":"One","type":1,"api":"./vod"}],"lives":[{"name":"Live","url":"./list.m3u"}]}"# }));
        let (base, server) = serve(app).await;
        let proxy = Arc::new(crate::proxy::ProxyStore::new());
        let (text, actual, endpoint) = fetch_validated(
            &proxy,
            "tvbox",
            &[format!("{base}/bad"), format!("{base}/backup")],
            None,
            validate_tvbox,
        )
        .await
        .unwrap();
        assert_eq!(actual, format!("{base}/actual/config.json"));
        assert_eq!(endpoint, format!("{base}/backup"));
        let cfg = crate::tvbox::parse_loose_json(&text).unwrap();
        let (jobs, _, lives) = crate::tvbox::collect_sites(&cfg, &actual);
        assert_eq!(jobs[0].api, format!("{base}/actual/vod"));
        assert_eq!(lives[0]["url"], format!("{base}/actual/list.m3u"));
        server.abort();
    }

    #[tokio::test]
    async fn identity_errors_do_not_try_backup() {
        use axum::routing::get;
        use std::sync::atomic::{AtomicUsize, Ordering};
        let hits = Arc::new(AtomicUsize::new(0));
        let counted = hits.clone();
        let app = axum::Router::new()
            .route("/wrong", get(|| async { "wrong identity" }))
            .route(
                "/backup",
                get(move || {
                    let hits = counted.clone();
                    async move {
                        hits.fetch_add(1, Ordering::SeqCst);
                        "valid"
                    }
                }),
            );
        let (base, server) = serve(app).await;
        let proxy = Arc::new(crate::proxy::ProxyStore::new());
        assert!(fetch_validated(
            &proxy,
            "p",
            &[format!("{base}/wrong"), format!("{base}/backup")],
            None,
            |_| Err(Validation::Terminal("identity mismatch".into()))
        )
        .await
        .unwrap_err()
        .contains("identity"));
        assert_eq!(hits.load(Ordering::SeqCst), 0);
        server.abort();
    }

    #[tokio::test]
    async fn rejected_subscription_endpoints_try_declared_backups_through_same_proxy() {
        use crate::csp::http_context::test_support::{custom, serve as serve_proxy};
        use axum::{http::StatusCode, response::IntoResponse};
        let origin = serve_proxy(|_| "unexpected direct request".into_response()).await;
        let http_proxy = serve_proxy(|request| {
            assert_eq!(request.headers["user-agent"], "Subscription fixture");
            assert!(!request.headers.contains_key("authorization"));
            match request.uri.path() {
                "/blocked-401" => StatusCode::UNAUTHORIZED.into_response(),
                "/blocked-403" => StatusCode::FORBIDDEN.into_response(),
                "/backup" => r#"{"sites":[{"key":"fixture","name":"Fixture","type":1,"api":"./api"}]}"#.into_response(),
                _ => panic!("undeclared endpoint requested: {}", request.uri),
            }
        }).await;
        let proxy = Arc::new(crate::proxy::ProxyStore::new());
        custom(&proxy, &http_proxy.url);
        for status in [401, 403] {
            let primary = format!("{}/blocked-{status}", origin.url);
            let backup = format!("{}/backup", origin.url);
            let (text, actual, endpoint) = fetch_validated(
                &proxy, "tvbox", &[primary.clone(), backup.clone()],
                Some("Subscription fixture"), validate_tvbox,
            ).await.unwrap();
            assert!(text.contains("\"key\":\"fixture\""));
            assert_eq!(actual, backup);
            assert_eq!(endpoint, backup);
            let requests = http_proxy.hits.lock().unwrap();
            let last = &requests[requests.len() - 2..];
            assert_eq!(last[0].uri.to_string(), primary);
            assert_eq!(last[1].uri.to_string(), backup);
            assert!(origin.hits.lock().unwrap().is_empty(), "fallback must retain the configured proxy");
        }
        assert_eq!(http_proxy.hits.lock().unwrap().len(), 4);
        let error = fetch_validated(
            &proxy, "tvbox", &[format!("{}/blocked-401", origin.url), format!("{}/blocked-403", origin.url)],
            Some("Subscription fixture"), validate_tvbox,
        ).await.unwrap_err();
        assert!(error.contains("HTTP 401") && error.contains("HTTP 403"), "all failures remain visible: {error}");
        assert_eq!(http_proxy.hits.lock().unwrap().len(), 6);
        assert!(origin.hits.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn cancelled_request_does_not_start_backup() {
        use axum::routing::get;
        use std::sync::atomic::{AtomicUsize, Ordering};
        let hits = Arc::new(AtomicUsize::new(0));
        let counted = hits.clone();
        let app = axum::Router::new()
            .route(
                "/pending",
                get(|| async {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    "unused"
                }),
            )
            .route(
                "/backup",
                get(move || {
                    let hits = counted.clone();
                    async move {
                        hits.fetch_add(1, Ordering::SeqCst);
                        "valid"
                    }
                }),
            );
        let (base, server) = serve(app).await;
        let proxy = Arc::new(crate::proxy::ProxyStore::new());
        let urls = vec![format!("{base}/pending"), format!("{base}/backup")];
        let request = tokio::spawn(async move {
            fetch_validated(&proxy, "p", &urls, None, |s| Ok(s.into())).await
        });
        tokio::time::sleep(Duration::from_millis(30)).await;
        request.abort();
        assert!(request.await.unwrap_err().is_cancelled());
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert_eq!(hits.load(Ordering::SeqCst), 0);
        server.abort();
    }

    #[test]
    fn explicit_empty_selection_and_manual_disable_survive_registry_rebuild() {
        let dir = scratch("disabled");
        let mut aggregate = crate::tvbox_aggregate::AggregateConfig::default();
        aggregate.site_selection_explicit = true;
        aggregate.enabled_site_ids = vec!["first".into()];
        crate::tvbox_aggregate::save(&dir, &aggregate).unwrap();
        crate::commands::save_disabled(&dir, &["first".into()]).unwrap();
        for _ in 0..2 {
            let registry = crate::registry::Registry::new();
            for id in ["first", "second"] {
                registry.register(Arc::new(
                    crate::tvbox::TvboxAppleCmsProvider::new(
                        id,
                        id,
                        "https://example.invalid/api",
                        vec![],
                    )
                    .unwrap(),
                ));
            }
            sync_enabled(&registry, &dir);
            assert!(registry.enabled_manifests().is_empty());
        }
        aggregate.enabled_site_ids.clear();
        crate::tvbox_aggregate::save(&dir, &aggregate).unwrap();
        assert!(crate::tvbox_aggregate::load(&dir).site_selection_explicit);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn two_subscriptions_keep_separate_providers_and_restart_selection() {
        use axum::routing::get;
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let app = axum::Router::new()
            .route(
                "/a.json",
                get(|| async {
                    r#"{"sites":[{"key":"shared","name":"Shared","type":1,"api":"./vod"}]}"#
                }),
            )
            .route(
                "/b.json",
                get(|| async {
                    r#"{"sites":[{"key":"shared","name":"Shared","type":1,"api":"./vod"}]}"#
                }),
            )
            .route(
                "/vod",
                get(|| async {
                    r#"{"class":[{"type_id":"1","type_name":"Movies"}],"list":[{"vod_id":"1","vod_name":"Fixture"}],"total":1}"#
                }),
            );
        let (base, server) = serve(app).await;
        let dir = scratch("origins");
        let state = AppState::bootstrap(dir.clone()).await.unwrap();
        let a = crate::tvbox::import_tvbox_config(&state, &format!("{base}/a.json"))
            .await
            .unwrap();
        let b = crate::tvbox::import_tvbox_config(&state, &format!("{base}/b.json"))
            .await
            .unwrap();
        let first = a["imported"][0]["id"].as_str().unwrap().to_owned();
        let second = b["imported"][0]["id"].as_str().unwrap().to_owned();
        assert_ne!(
            first, second,
            "A second real subscription must never overwrite the first"
        );
        let snapshot = catalog(&state).unwrap();
        assert_eq!(
            snapshot
                .origins
                .iter()
                .filter(|o| o.kind == "tvbox")
                .count(),
            2
        );
        let group = snapshot
            .groups
            .iter()
            .find(|g| g.provider_ids.contains(&first))
            .unwrap();
        assert!(group.provider_ids.contains(&second));
        command_select(&state, &group.id, &[second.clone()]).unwrap();
        let checked = crate::tvbox::update_tvbox_source(&state, &second, true, false)
            .await
            .unwrap();
        assert_eq!(checked["unchanged"], 1);
        assert_eq!(
            checked["unchangedForeign"], 0,
            "Another subscription must not consume this origin's site identity"
        );
        let reimported = crate::tvbox::import_tvbox_config(&state, &format!("{base}/a.json"))
            .await
            .unwrap();
        assert_eq!(reimported["imported"][0]["id"], first);
        assert!(
            !state
                .registry
                .enabled_manifests()
                .iter()
                .any(|m| m.id == first),
            "Refreshing a disabled source must not enable it"
        );
        let displayed = crate::commands::list_providers(&state).unwrap();
        assert!(displayed
            .iter()
            .all(|m| m.id != crate::tvbox_aggregate::AGGREGATE_ID));
        assert!(displayed
            .iter()
            .filter(|m| m.kind == "tvbox")
            .all(|m| !m.hidden));
        let id = snapshot
            .origins
            .iter()
            .find(|o| o.provider_ids.contains(&first))
            .unwrap()
            .id
            .clone();
        command_set_origin(
            &state,
            &serde_json::json!({"id":id,"backupUrls":[format!("{base}/b.json")]}),
        )
        .unwrap();
        drop(state);
        let restarted = AppState::bootstrap(dir.clone()).await.unwrap();
        let snapshot = catalog(&restarted).unwrap();
        let group = snapshot
            .groups
            .iter()
            .find(|g| g.provider_ids.contains(&first))
            .unwrap();
        assert_eq!(group.selected_provider_ids, vec![second]);
        assert_eq!(
            snapshot
                .origins
                .iter()
                .find(|o| o.id == id)
                .unwrap()
                .backup_urls
                .len(),
            1
        );
        assert!(!restarted
            .registry
            .enabled_manifests()
            .iter()
            .any(|m| m.id == first));
        drop(restarted);
        server.abort();
    }
    #[tokio::test]
    async fn reimport_primary_does_not_borrow_another_subscriptions_backup_identity() {
        use axum::routing::get;
        use std::sync::atomic::{AtomicBool, Ordering};

        let updated = Arc::new(AtomicBool::new(false));
        let b_updated = updated.clone();
        let app = axum::Router::new()
            .route("/a.json", get(|| async {
                r#"{"sites":[{"key":"shared","name":"Shared","type":1,"api":"./vod"},{"key":"added","name":"Additional","type":1,"api":"./vod"}]}"#
            }))
            .route("/b.json", get(move || {
                let updated = b_updated.clone();
                async move {
                    if updated.load(Ordering::SeqCst) {
                        r#"{"sites":[{"key":"shared","name":"Shared refreshed","type":1,"api":"./vod"},{"key":"added","name":"Additional refreshed","type":1,"api":"./vod"}]}"#
                    } else {
                        r#"{"sites":[{"key":"shared","name":"Shared","type":1,"api":"./vod"}]}"#
                    }
                }
            }))
            .route("/vod", get(|| async {
                r#"{"class":[{"type_id":"1","type_name":"Movies"}],"list":[{"vod_id":"1","vod_name":"Fixture"}],"total":1}"#
            }));
        let (base, server) = serve(app).await;
        let dir = scratch("overlapping-subscription-addresses");
        let state = AppState::bootstrap(dir.clone()).await.unwrap();
        let a_url = format!("{base}/a.json");
        let b_url = format!("{base}/b.json");
        let a = crate::tvbox::import_tvbox_config_with_options(&state, &a_url, &[], Some("A"))
            .await.unwrap();
        let b = crate::tvbox::import_tvbox_config_with_options(&state, &b_url, &[], Some("B"))
            .await.unwrap();
        assert_eq!(a["imported"].as_array().unwrap().len(), 2);
        assert_eq!(b["imported"].as_array().unwrap().len(), 1);
        let a_shared = a["imported"][0]["id"].as_str().unwrap().to_owned();
        let a_added = a["imported"][1]["id"].as_str().unwrap().to_owned();
        let b_shared = b["imported"][0]["id"].as_str().unwrap().to_owned();
        assert_ne!(a_shared, b_shared, "independent subscriptions must retain independent ids");
        let before = catalog(&state).unwrap();
        let a_origin_id = before.origins.iter().find(|o| o.provider_ids.contains(&a_shared)).unwrap().id.clone();
        let b_origin_id = before.origins.iter().find(|o| o.provider_ids.contains(&b_shared)).unwrap().id.clone();
        assert_ne!(a_origin_id, b_origin_id);
        command_set_origin(&state, &serde_json::json!({
            "id": a_origin_id, "backupUrls": [b_url.clone()]
        })).unwrap();
        let before = catalog(&state).unwrap();
        let group_id = before.groups.iter().find(|g| g.provider_ids.contains(&b_shared)).unwrap().id.clone();
        command_select(&state, &group_id, &[b_shared.clone()]).unwrap();
        assert!(crate::commands_provider::set_enabled_persisted(&state, &a_added, false).unwrap());
        let before = catalog(&state).unwrap();
        let original_a = before.origins.iter().find(|o| o.id == a_origin_id).unwrap().clone();
        let original_a_shared = serde_json::to_value(
            crate::commands_provider::get_provider_config(&state, &a_shared).unwrap().unwrap()).unwrap();
        let original_a_added = serde_json::to_value(
            crate::commands_provider::get_provider_config(&state, &a_added).unwrap().unwrap()).unwrap();

        // The extra site exists only in A before this update. Borrowing its id
        // makes the regression deterministic even when the shared site's two
        // sidecars happen to iterate in B-first order.
        updated.store(true, Ordering::SeqCst);
        let reimported = crate::tvbox::import_tvbox_config(&state, &b_url).await.unwrap();
        assert_eq!(reimported["imported"].as_array().unwrap().len(), 2);
        assert_eq!(reimported["imported"][0]["id"], b_shared,
            "reimporting the exact B primary must update B's existing site only");
        let b_added = reimported["imported"][1]["id"].as_str().unwrap().to_owned();
        assert_ne!(b_added, a_added, "B's newly added site must not steal A's matching site id");
        assert_ne!(b_added, a_shared);
        assert_ne!(b_added, b_shared);
        assert_eq!(reimported["originId"], b_origin_id);

        let verify = |st: &AppState| {
            let current = catalog(st).unwrap();
            assert_eq!(current.origins.iter().find(|o| o.id == a_origin_id).unwrap(), &original_a);
            let current_b = current.origins.iter().find(|o| o.id == b_origin_id).unwrap();
            assert_eq!(current_b.primary_url, b_url);
            let mut actual_ids = current_b.provider_ids.clone();
            actual_ids.sort();
            let mut expected_ids = vec![b_shared.clone(), b_added.clone()];
            expected_ids.sort();
            assert_eq!(actual_ids, expected_ids);
            for (id, original) in [(&a_shared, &original_a_shared), (&a_added, &original_a_added)] {
                assert_eq!(serde_json::to_value(
                    crate::commands_provider::get_provider_config(st, id).unwrap().unwrap()).unwrap(), *original);
                assert!(!crate::commands::get_provider_enabled(st, id).unwrap());
                assert_eq!(crate::tvbox::read_tvbox_meta(&dir, id).unwrap().source_url.as_deref(), Some(a_url.as_str()));
            }
            for id in [&b_shared, &b_added] {
                assert!(crate::commands::get_provider_enabled(st, id).unwrap());
                assert_eq!(crate::tvbox::read_tvbox_meta(&dir, id).unwrap().source_url.as_deref(), Some(b_url.as_str()));
            }
            assert_eq!(st.registry.get(&b_shared).unwrap().manifest().name, "Shared refreshed");
            assert_eq!(st.registry.get(&b_added).unwrap().manifest().name, "Additional refreshed");
            let group = current.groups.iter().find(|g| g.id == group_id).unwrap();
            let mut selected = group.selected_provider_ids.clone();
            selected.sort();
            assert_eq!(selected, vec![b_shared.clone()]);
            let added_group = current.groups.iter().find(|g| g.provider_ids.contains(&b_added)).unwrap();
            assert_eq!(added_group.selected_provider_ids, vec![b_added.clone()]);
        };
        verify(&state);
        drop(state);
        let restarted = AppState::bootstrap(dir.clone()).await.unwrap();
        verify(&restarted);
        drop(restarted);
        server.abort();
        let _ = std::fs::remove_dir_all(dir);
    }
    #[tokio::test]
    async fn all_http_endpoints_fail_with_bounded_redacted_error() {
        use axum::{http::StatusCode, routing::get};
        let attempts = Arc::new(Mutex::new(Vec::new()));
        let mut app = axum::Router::new();
        for (path, status) in [
            ("/primary", StatusCode::INTERNAL_SERVER_ERROR),
            ("/backup-one", StatusCode::BAD_GATEWAY),
            ("/backup-two", StatusCode::SERVICE_UNAVAILABLE),
        ] {
            let attempts = attempts.clone();
            app = app.route(path, get(move || {
                let attempts = attempts.clone();
                async move {
                    attempts.lock().unwrap().push(path);
                    status
                }
            }));
        }
        let (base, server) = serve(app).await;
        let urls: Vec<_> = ["/primary", "/backup-one", "/backup-two"].iter()
            .map(|path| format!("{base}{path}?token=must-not-appear")).collect();
        let proxy = Arc::new(crate::proxy::ProxyStore::new());
        let error = tokio::time::timeout(Duration::from_secs(2), fetch_with_budget(
            &proxy, "tvbox", &urls, None, validate_tvbox, Duration::from_millis(500),
        )).await.expect("all failed endpoints must terminate within a bounded budget").unwrap_err();
        assert_eq!(*attempts.lock().unwrap(), vec!["/primary", "/backup-one", "/backup-two"]);
        assert!(error.contains("所有可尝试地址均失败"));
        for (index, status) in [(1, 500), (2, 502), (3, 503)] {
            assert!(error.contains(&format!("地址 {index}：HTTP {status}")), "{error}");
        }
        assert!(!error.contains(&base) && !error.contains("must-not-appear"),
            "error summaries must not expose source addresses or tokens: {error}");
        server.abort();
    }

    #[tokio::test]
    async fn fetch_tvbox_persists_backup_without_postponing_primary_recovery() {
        use axum::{http::StatusCode, response::{IntoResponse, Redirect}, routing::get};
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

        let primary_ready = Arc::new(AtomicBool::new(false));
        let primary_hits = Arc::new(AtomicUsize::new(0));
        let backup_hits = Arc::new(AtomicUsize::new(0));
        let ready = primary_ready.clone();
        let main_hits = primary_hits.clone();
        let fallback_hits = backup_hits.clone();
        let app = axum::Router::new()
            .route("/primary.json", get(move || {
                let ready = ready.clone();
                let hits = main_hits.clone();
                async move {
                    hits.fetch_add(1, Ordering::SeqCst);
                    if ready.load(Ordering::SeqCst) {
                        r#"{"sites":[{"key":"one","name":"One","type":1,"api":"./actual/vod"}]}"#.into_response()
                    } else {
                        StatusCode::SERVICE_UNAVAILABLE.into_response()
                    }
                }
            }))
            .route("/backup.json", get(move || {
                let hits = fallback_hits.clone();
                async move {
                    hits.fetch_add(1, Ordering::SeqCst);
                    Redirect::temporary("/actual/config.json")
                }
            }))
            .route("/actual/config.json", get(|| async {
                r#"{"sites":[{"key":"one","name":"One","type":1,"api":"./vod"}]}"#
            }))
            .route("/actual/vod", get(|| async {
                r#"{"class":[{"type_id":"1","type_name":"Movies"}],"list":[{"vod_id":"1","vod_name":"Fixture"}],"total":1}"#
            }));
        let (base, server) = serve(app).await;
        let dir = scratch("persisted-failover-recovery");
        let state = AppState::bootstrap(dir.clone()).await.unwrap();
        let primary = format!("{base}/primary.json");
        let backup = format!("{base}/backup.json");
        let actual = format!("{base}/actual/config.json");
        let imported = crate::tvbox::import_tvbox_config_with_options(
            &state, &primary, &[backup.clone()], Some("Failover fixture"),
        ).await.unwrap();
        assert_eq!(imported["imported"].as_array().unwrap().len(), 1);
        let provider_id = imported["imported"][0]["id"].as_str().unwrap();
        let mut disk = load(&dir);
        let origin = disk.origins.iter_mut().find(|o| o.primary_url == primary).unwrap();
        assert_eq!(origin.provider_ids, vec![provider_id]);
        assert_eq!(origin.last_successful_endpoint.as_deref(), Some(backup.as_str()));
        assert_eq!(origin.last_successful_url.as_deref(), Some(actual.as_str()));
        assert!(origin.last_success_at > 0);
        let cooldown_start = now_secs() - 120;
        origin.last_success_at = cooldown_start;
        save(&dir, &disk).unwrap();
        drop(state);

        let state = AppState::bootstrap(dir.clone()).await.unwrap();
        assert_eq!(primary_hits.load(Ordering::SeqCst), 1);
        assert_eq!(backup_hits.load(Ordering::SeqCst), 1);
        assert_eq!(urls_for(&dir, "tvbox", None, &primary)[0], backup);
        primary_ready.store(true, Ordering::SeqCst);
        for _ in 0..3 {
            let (_, used) = fetch_tvbox(&state, &primary).await.unwrap();
            assert_eq!(used, actual);
            let disk = load(&dir);
            let origin = disk.origins.iter().find(|o| o.primary_url == primary).unwrap();
            assert_eq!(origin.last_success_at, cooldown_start,
                "repeated backup successes must preserve the original cooldown start");
            assert_eq!(origin.last_successful_endpoint.as_deref(), Some(backup.as_str()));
        }
        assert_eq!(primary_hits.load(Ordering::SeqCst), 1, "primary stays deferred during cooldown");
        assert_eq!(backup_hits.load(Ordering::SeqCst), 4);

        let mut disk = load(&dir);
        disk.origins.iter_mut().find(|o| o.primary_url == primary).unwrap().last_success_at = now_secs() - 301;
        save(&dir, &disk).unwrap();
        let recovery_started = now_secs();
        let (_, used) = fetch_tvbox(&state, &primary).await.unwrap();
        assert_eq!(used, primary);
        assert_eq!(primary_hits.load(Ordering::SeqCst), 2, "expired cooldown must retry the recovered primary");
        assert_eq!(backup_hits.load(Ordering::SeqCst), 4, "a recovered primary must end failover");
        let disk = load(&dir);
        let origin = disk.origins.iter().find(|o| o.primary_url == primary).unwrap();
        assert_eq!(origin.last_successful_endpoint.as_deref(), Some(primary.as_str()));
        assert_eq!(origin.last_successful_url.as_deref(), Some(primary.as_str()));
        assert!(origin.last_success_at >= recovery_started);
        drop(state);
        server.abort();
        let _ = std::fs::remove_dir_all(dir);
    }
}
