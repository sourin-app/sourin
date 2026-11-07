//! Library covers have durable origin URLs and per-session display URLs.
use crate::{model::MediaId, state::AppState};
use std::collections::{HashMap, HashSet};

/// Recognize the internal cover route, without treating every local image server
/// as our proxy. Unknown old tokens must never be saved as durable cover URLs.
fn internal_cover(url: &str) -> bool {
    let Ok(url) = reqwest::Url::parse(url) else {
        return false;
    };
    url.scheme() == "http"
        && url.host_str() == Some("127.0.0.1")
        && url.port().is_some()
        && url
            .path()
            .strip_prefix("/s/")
            .is_some_and(|token| !token.is_empty() && !token.contains('/'))
}

pub fn durable(state: &AppState, cover: Option<&str>) -> Option<String> {
    let cover = cover.map(str::trim).filter(|s| !s.is_empty())?;
    if internal_cover(cover) {
        state.stream_proxy.unproxy_cover(cover)
    } else {
        Some(cover.to_string())
    }
}

fn origin_provider<'a>(provider: &'a str, native_id: &'a str) -> &'a str {
    if provider == crate::tvbox_aggregate::AGGREGATE_ID {
        native_id
            .split_once("::")
            .map(|(id, _)| id)
            .unwrap_or(provider)
    } else {
        provider
    }
}

pub async fn for_display(
    state: &AppState,
    provider: &str,
    native_id: &str,
    cover: Option<&str>,
) -> Option<String> {
    let raw = durable(state, cover)?;
    let origin = state.registry.get(origin_provider(provider, native_id));
    let headers = origin
        .as_ref()
        .map(|p| p.manifest().cover_headers.clone())
        .unwrap_or_default();
    if headers.is_empty() || state.stream_proxy.ensure_started().await.is_err() {
        return Some(raw);
    }
    Some(state.stream_proxy.register_cover(&raw, headers))
}

/// Repair metadata after the library has rendered. Only cover fields are changed;
/// playback positions, ordering timestamps, favorite and follow flags are retained.
pub async fn repair(state: &AppState) -> Result<usize, String> {
    let Ok(mut cursor) = state.cover_repair_cursor.try_lock() else {
        return Ok(0);
    };
    type Candidate = (String, String, Vec<Option<String>>, Option<String>);
    let mut grouped: HashMap<(String, String), Candidate> = HashMap::new();
    let mut add = |provider: String, id: String, cover: Option<String>| {
        let raw = durable(state, cover.as_deref());
        let entry = grouped
            .entry((provider.clone(), id.clone()))
            .or_insert_with(|| (provider, id, vec![], None));
        if (raw.is_none() || raw != cover) && !entry.2.contains(&cover) {
            entry.2.push(cover);
        }
        if entry.3.is_none() {
            entry.3 = raw;
        }
    };
    for item in state
        .db
        .list_favorites(false)?
        .into_iter()
        .chain(state.db.list_following_for_ui()?)
    {
        add(item.provider, item.native_id, item.cover);
    }
    for item in state.db.continue_watching(100)? {
        add(item.provider, item.native_id, item.cover);
    }
    for item in state.db.list_history(100)? {
        add(item.provider, item.native_id, item.cover);
    }
    let enabled: HashSet<_> = state
        .registry
        .enabled_manifests()
        .into_iter()
        .map(|m| m.id)
        .collect();
    let mut candidates: Vec<_> = grouped.into_values().filter(|c| !c.2.is_empty()).collect();
    candidates.sort_by(|a, b| (&a.0, &a.1).cmp(&(&b.0, &b.1)));
    let mut changed = 0;
    let mut pending = Vec::new();
    for candidate in candidates {
        if let Some(raw) = candidate.3.as_ref() {
            changed +=
                state
                    .db
                    .repair_library_cover(&candidate.0, &candidate.1, &candidate.2, raw)?;
        } else if enabled.contains(&candidate.0)
            && enabled.contains(origin_provider(&candidate.0, &candidate.1))
        {
            pending.push(candidate);
        }
    }
    // Bounded background work, with a per-provider deadline. No full-library
    // refresh waits for a slow provider, and a failed fetch leaves metadata intact.
    if !pending.is_empty() {
        let start = *cursor % pending.len();
        let count = pending.len().min(24);
        *cursor = (start + count) % pending.len();
        pending.rotate_left(start);
        pending.truncate(count);
    }
    for chunk in pending.chunks(4) {
        let mut tasks = tokio::task::JoinSet::new();
        for candidate in chunk {
            let Some(provider) = state.registry.get(&candidate.0) else {
                continue;
            };
            let candidate = candidate.clone();
            tasks.spawn(async move {
                let id = MediaId {
                    provider: candidate.0.clone(),
                    native: candidate.1.clone(),
                };
                let detail =
                    tokio::time::timeout(std::time::Duration::from_secs(4), provider.detail(&id))
                        .await;
                (
                    candidate,
                    detail.ok().and_then(Result::ok).and_then(|d| d.cover),
                )
            });
        }
        while let Some(result) = tasks.join_next().await {
            let Ok((candidate, cover)) = result else {
                continue;
            };
            if let Some(raw) = durable(state, cover.as_deref()) {
                changed += state.db.repair_library_cover(
                    &candidate.0,
                    &candidate.1,
                    &candidate.2,
                    &raw,
                )?;
            }
        }
    }
    Ok(changed)
}
