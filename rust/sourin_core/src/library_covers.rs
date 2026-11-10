//! Library covers have durable origin URLs and per-session display URLs.
use crate::{model::MediaId, state::AppState};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

type CheckKey = (String, String, String);

#[derive(Default)]
pub(crate) struct CoverRepairState {
    cursor: usize,
    checked: HashMap<CheckKey, Instant>,
}

impl CoverRepairState {
    fn remember(&mut self, key: CheckKey, ttl: Duration) {
        let now = Instant::now();
        self.checked.retain(|_, expires| *expires > now);
        if self.checked.len() >= 512 {
            if let Some(oldest) = self.checked.iter().min_by_key(|(_, expires)| **expires)
                .map(|(key, _)| key.clone()) {
                self.checked.remove(&oldest);
            }
        }
        self.checked.insert(key, now + ttl);
    }
}

#[derive(Clone)]
struct Candidate {
    provider: String,
    id: String,
    invalid: Vec<Option<String>>,
    variants: Vec<(String, Vec<Option<String>>)>,
}

impl Candidate {
    fn single_cover_key(&self) -> Option<CheckKey> {
        if self.invalid.is_empty() && self.variants.len() == 1 {
            Some((self.provider.clone(), self.id.clone(), self.variants[0].0.clone()))
        } else {
            None
        }
    }

    fn add_cover(&mut self, state: &AppState, cover: Option<String>) {
        let raw = durable(state, cover.as_deref());
        if (raw.is_none() || raw != cover) && !self.invalid.contains(&cover) {
            self.invalid.push(cover.clone());
        }
        if let Some(raw) = raw {
            if let Some(variant) = self.variants.iter_mut().find(|v| v.0 == raw) {
                if !variant.1.contains(&cover) { variant.1.push(cover); }
            } else {
                self.variants.push((raw, vec![cover]));
            }
        }
    }
}

/// Read intrinsic dimensions, not the URL suffix or a server's MIME claim.
/// This is a bounded header probe, not an image decoder. Unknown formats and
/// incomplete headers remain unknown and never justify replacing a cover.
fn image_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    let le16 = |p: usize| bytes.get(p..p + 2).map(|s| u16::from_le_bytes([s[0], s[1]]) as u32);
    let be16 = |p: usize| bytes.get(p..p + 2).map(|s| u16::from_be_bytes([s[0], s[1]]) as u32);
    let le24 = |p: usize| bytes.get(p..p + 3).map(|s| s[0] as u32 | (s[1] as u32) << 8 | (s[2] as u32) << 16);
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some((le16(6)?, le16(8)?));
    }
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") && bytes.get(12..16) == Some(b"IHDR") {
        return Some((
            u32::from_be_bytes(bytes.get(16..20)?.try_into().ok()?),
            u32::from_be_bytes(bytes.get(20..24)?.try_into().ok()?),
        ));
    }
    if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        match bytes.get(12..16)? {
            b"VP8X" => return Some((le24(24)? + 1, le24(27)? + 1)),
            b"VP8 " if bytes.get(23..26) == Some(b"\x9d\x01\x2a") => {
                return Some((le16(26)? & 0x3fff, le16(28)? & 0x3fff));
            }
            b"VP8L" if bytes.get(20) == Some(&0x2f) => {
                let packed = u32::from_le_bytes(bytes.get(21..25)?.try_into().ok()?);
                return Some(((packed & 0x3fff) + 1, ((packed >> 14) & 0x3fff) + 1));
            }
            _ => return None,
        }
    }
    if bytes.starts_with(b"\xff\xd8") {
        let mut offset = 2;
        while bytes.get(offset) == Some(&0xff) {
            while bytes.get(offset) == Some(&0xff) {
                offset += 1;
            }
            let marker = *bytes.get(offset)?;
            offset += 1;
            if matches!(marker, 0xda | 0xd9) {
                return None;
            }
            let size = be16(offset)? as usize;
            if size < 2 { return None; }
            if size >= 7 && matches!(marker, 0xc0..=0xc3 | 0xc5..=0xc7 | 0xc9..=0xcb | 0xcd..=0xcf) {
                return Some((be16(offset + 5)?, be16(offset + 3)?));
            }
            offset += size;
        }
    }
    None
}

#[derive(Clone, Copy)]
enum CoverProbe {
    Dimensions(u32, u32),
    Missing,
    Unknown,
}

impl CoverProbe {
    fn invalid(self) -> bool {
        matches!(self, Self::Missing) || matches!(self, Self::Dimensions(w, h) if w <= 8 && h <= 8)
    }

    fn poster(self) -> bool {
        matches!(self, Self::Dimensions(w, h) if w >= 32 && h >= 32)
    }
}

async fn probe_cover(client: &reqwest::Client, url: &str) -> CoverProbe {
    const LIMIT: usize = 64 * 1024;
    let Ok(mut response) = client.get(url).send().await else { return CoverProbe::Unknown; };
    if matches!(response.status().as_u16(), 404 | 410) { return CoverProbe::Missing; }
    if !response.status().is_success() { return CoverProbe::Unknown; }
    let mut bytes = Vec::new();
    while let Ok(Some(chunk)) = response.chunk().await {
        bytes.extend_from_slice(&chunk[..chunk.len().min(LIMIT - bytes.len())]);
        if let Some((w, h)) = image_dimensions(&bytes) { return CoverProbe::Dimensions(w, h); }
        if bytes.len() == LIMIT { break; }
    }
    CoverProbe::Unknown
}

async fn existing_replacement(
    client: &reqwest::Client,
    variants: &[(String, String, Vec<Option<String>>)],
    mut invalid: Vec<Option<String>>,
    budget: std::time::Duration,
) -> Option<(Vec<Option<String>>, String)> {
    let deadline = tokio::time::Instant::now() + budget;
    let mut probes = tokio::task::JoinSet::new();
    for (raw, display, originals) in variants.iter().take(3).cloned() {
        let client = client.clone();
        probes.spawn(async move {
            let dimensions = probe_cover(&client, &display).await;
            (raw, originals, dimensions)
        });
    }
    let mut donor: Option<String> = None;
    // These are library posters, not favicons or channel logos. A missing URL
    // or intrinsically tiny image is unsuitable; outages remain uncertain.
    while !probes.is_empty() {
        let result = tokio::select! {
            // Drain ready results before enforcing the deadline. Keep completed
            // evidence even when another URL never returns.
            biased;
            result = probes.join_next() => result,
            _ = tokio::time::sleep_until(deadline) => break,
        };
        let Some(Ok((raw, originals, dimensions))) = result else {
            continue;
        };
        match dimensions {
            probe if probe.invalid() => {
                invalid.extend(originals);
            }
            probe if probe.poster() => {
                // Do not return until the other probes have supplied invalid
                // originals. Choose consistently regardless of completion order.
                if donor.as_ref().is_none_or(|current| raw.as_str() < current.as_str()) {
                    donor = Some(raw);
                }
            }
            _ => {}
        }
    }
    probes.abort_all();
    invalid.sort();
    invalid.dedup();
    if invalid.is_empty() {
        None
    } else {
        donor.map(|raw| (invalid, raw))
    }
}

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

// Local wrappers hide the upstream host from Flutter's image header policy.
// Keep the same exact-host defaults here; explicit source headers take priority.
fn display_headers(raw: &str, mut headers: Vec<(String, String)>) -> Vec<(String, String)> {
    let is_cdn = reqwest::Url::parse(raw).ok().is_some_and(|url| {
        matches!(url.scheme(), "http" | "https") && url.host_str().is_some_and(|host| {
            host.strip_prefix("img").and_then(|h| h.strip_suffix(".doubanio.com"))
                .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|c| c.is_ascii_digit()))
        })
    });
    if is_cdn {
        for (name, value) in [
            ("Referer", "https://movie.douban.com/"),
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"),
        ] {
            if !headers.iter().any(|(existing, _)| existing.eq_ignore_ascii_case(name)) {
                headers.push((name.into(), value.into()));
            }
        }
    }
    headers
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
    display_url(&state.stream_proxy, &raw, headers).await
}

async fn display_url(
    proxy: &Arc<crate::streamproxy::StreamProxy>,
    raw: &str,
    headers: Vec<(String, String)>,
) -> Option<String> {
    // Every remote cover follows the global API policy, including sources with
    // no custom headers. Keep local/data images intact and never bypass a chosen
    // proxy just because the loopback service could not start.
    if !reqwest::Url::parse(raw).ok().is_some_and(|url| matches!(url.scheme(), "http" | "https")) {
        return Some(raw.to_string());
    }
    proxy.ensure_started().await.ok()?;
    let headers = display_headers(raw, headers);
    Some(proxy.register_cover(raw, headers))
}

/// Repair metadata after the library has rendered. Only cover fields are changed;
/// playback positions, ordering timestamps, favorite and follow flags are retained.
pub async fn repair(state: &AppState) -> Result<usize, String> {
    let Ok(mut checks) = state.cover_repair.try_lock() else {
        return Ok(0);
    };
    let mut grouped: HashMap<(String, String), Candidate> = HashMap::new();
    let mut add = |provider: String, id: String, cover: Option<String>| {
        grouped
            .entry((provider.clone(), id.clone()))
            .or_insert_with(|| Candidate { provider, id, invalid: vec![], variants: vec![] })
            .add_cover(state, cover);
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
    // UI queries only identify the library items being repaired. They omit
    // finished/brief/older episodes and history outside the latest 100 rows,
    // all of which may hold the only working cover for an exact identity.
    for candidate in grouped.values_mut() {
        for cover in state.db.library_cover_variants(&candidate.provider, &candidate.id)? {
            candidate.add_cover(state, cover);
        }
    }
    let enabled: HashSet<_> = state
        .registry
        .enabled_manifests()
        .into_iter()
        .map(|m| m.id)
        .collect();
    let now = Instant::now();
    checks.checked.retain(|_, expires| *expires > now);
    let mut candidates: Vec<_> = grouped.into_values().filter(|c| {
        if !c.invalid.is_empty() || c.variants.len() > 1 { return true; }
        c.single_cover_key().is_some_and(|key| !checks.checked.contains_key(&key))
            && enabled.contains(&c.provider)
            && enabled.contains(origin_provider(&c.provider, &c.id))
    }).collect();
    candidates.sort_by(|a, b| (&a.provider, &a.id).cmp(&(&b.provider, &b.id)));
    let mut changed = 0;
    let mut pending = Vec::new();
    for candidate in candidates {
        if candidate.single_cover_key().is_some() {
            pending.push(candidate);
        } else if candidate.variants.len() > 1 {
            // Conflicting persisted covers can be checked even for disabled
            // sources: no source detail/list/resolve request is made here.
            pending.push(candidate);
        } else if let Some((raw, _)) = candidate.variants.first() {
            changed +=
                state
                    .db
                    .repair_library_cover(&candidate.provider, &candidate.id, &candidate.invalid, raw)?;
            // Filling a missing row from an existing URL must not hide an
            // expired singleton until the next visit/cooldown. Check it in this
            // pass too; the conditional write still protects newer metadata.
            if enabled.contains(&candidate.provider)
                && enabled.contains(origin_provider(&candidate.provider, &candidate.id)) {
                let mut check = candidate;
                check.invalid.clear();
                if check.single_cover_key().is_some_and(|key| !checks.checked.contains_key(&key)) {
                    pending.push(check);
                }
            }
        } else if enabled.contains(&candidate.provider)
            && enabled.contains(origin_provider(&candidate.provider, &candidate.id))
        {
            pending.push(candidate);
        }
    }
    // Bounded background work, with a per-group deadline. No full-library
    // refresh waits for a slow provider, and a failed fetch leaves metadata intact.
    if !pending.is_empty() {
        let start = checks.cursor % pending.len();
        let count = pending.len().min(24);
        checks.cursor = (start + count) % pending.len();
        pending.rotate_left(start);
        pending.truncate(count);
    } else {
        return Ok(changed);
    }
    let client = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(2))
        .timeout(std::time::Duration::from_secs(4))
        .user_agent("Mozilla/5.0")
        .no_proxy()
        .build().map_err(|e| e.to_string())?;
    for chunk in pending.chunks(4) {
        let mut tasks = tokio::task::JoinSet::new();
        for candidate in chunk {
            if candidate.variants.len() > 1 {
                let mut variants = Vec::new();
                for (raw, originals) in candidate.variants.iter().take(3) {
                    if let Some(display) = for_display(state, &candidate.provider, &candidate.id, Some(raw)).await {
                        variants.push((raw.clone(), display, originals.clone()));
                    }
                }
                let candidate = candidate.clone();
                let client = client.clone();
                tasks.spawn(async move {
                    let replacement = existing_replacement(
                        &client,
                        &variants,
                        candidate.invalid.clone(),
                        std::time::Duration::from_secs(4),
                    ).await;
                    (candidate, replacement, None)
                });
                continue;
            }
            let Some(provider) = state.registry.get(&candidate.provider) else {
                continue;
            };
            let candidate = candidate.clone();
            let single_key = candidate.single_cover_key();
            let proxy = state.stream_proxy.clone();
            let client = client.clone();
            let headers = state.registry.get(origin_provider(&candidate.provider, &candidate.id))
                .map(|p| p.manifest().cover_headers.clone()).unwrap_or_default();
            tasks.spawn(async move {
                if let Some(key) = single_key {
                    let result = tokio::time::timeout(Duration::from_secs(4), async {
                        let (raw, originals) = &candidate.variants[0];
                        let display = display_url(&proxy, raw, headers.clone()).await?;
                        let status = probe_cover(&client, &display).await;
                        if status.poster() {
                            return Some((None, Duration::from_secs(600)));
                        }
                        if !status.invalid() { return None; }
                        let id = MediaId::new(&candidate.provider, &candidate.id);
                        let detail = provider.detail(&id).await.ok()?;
                        if detail.id != id { return None; }
                        let fresh = detail.cover?;
                        let fresh = if internal_cover(&fresh) {
                            proxy.unproxy_cover(&fresh)?
                        } else { fresh.trim().to_string() };
                        if fresh.is_empty() || fresh == *raw { return None; }
                        let display = display_url(&proxy, &fresh, headers).await?;
                        if !probe_cover(&client, &display).await.poster() { return None; }
                        Some((Some((originals.clone(), fresh)), Duration::from_secs(600)))
                    }).await.ok().flatten();
                    let (replacement, ttl) = result.unwrap_or((None, Duration::from_secs(60)));
                    return (candidate, replacement, Some((key, ttl)));
                }
                let id = MediaId {
                    provider: candidate.provider.clone(),
                    native: candidate.id.clone(),
                };
                let detail =
                    tokio::time::timeout(std::time::Duration::from_secs(4), provider.detail(&id))
                        .await;
                let replacement = detail.ok().and_then(Result::ok).and_then(|d| d.cover)
                    .map(|cover| (candidate.invalid.clone(), cover));
                (candidate, replacement, None)
            });
        }
        while let Some(result) = tasks.join_next().await {
            let Ok((candidate, replacement, checked)) = result else { continue; };
            if let Some((key, ttl)) = checked { checks.remember(key, ttl); }
            let Some((invalid, cover)) = replacement else { continue; };
            if let Some(raw) = durable(state, Some(&cover)) {
                changed += state.db.repair_library_cover(
                    &candidate.provider,
                    &candidate.id,
                    &invalid,
                    &raw,
                )?;
            }
        }
    }
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::existing_replacement;
    use std::{
        sync::{Arc, Mutex},
        time::Duration,
    };

    struct ProbeFixture {
        base: String,
        hits: Arc<Mutex<Vec<String>>>,
        server: tokio::task::JoinHandle<()>,
    }

    impl ProbeFixture {
        async fn new() -> Self {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let hits = Arc::new(Mutex::new(Vec::new()));
            let observed = hits.clone();
            let app = axum::Router::new().route("/{kind}", axum::routing::get(
                move |axum::extract::Path(kind): axum::extract::Path<String>| {
                    let observed = observed.clone();
                    async move {
                        observed.lock().unwrap().push(kind.clone());
                        // Only headers are needed by the bounded dimension probe.
                        match kind.as_str() {
                            "tiny" => b"GIF89a\x04\x00\x08\x00".as_slice(),
                            "poster-a" | "poster-z" | "fourth" =>
                                b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x20\0\0\0\x30".as_slice(),
                            "slow" => std::future::pending::<&'static [u8]>().await,
                            _ => b"unknown image".as_slice(),
                        }
                    }
                },
            ));
            let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
            Self { base, hits, server }
        }

        fn variant(&self, kind: &str) -> (String, String, Vec<Option<String>>) {
            let raw = format!("{}/{kind}", self.base);
            (raw.clone(), raw.clone(), vec![Some(raw)])
        }

        async fn replacement(&self, kinds: &[&str]) -> Option<(Vec<Option<String>>, String)> {
            let client = reqwest::Client::builder().no_proxy().build().unwrap();
            let variants: Vec<_> = kinds.iter().map(|kind| self.variant(kind)).collect();
            tokio::time::timeout(
                Duration::from_secs(3),
                existing_replacement(&client, &variants, vec![], Duration::from_secs(1)),
            ).await.expect("one stalled URL must not outlive the group deadline")
        }

        fn expected(&self) -> Option<(Vec<Option<String>>, String)> {
            Some((vec![Some(self.variant("tiny").0)], self.variant("poster-a").0))
        }
    }

    impl Drop for ProbeFixture {
        fn drop(&mut self) {
            self.server.abort();
        }
    }

    #[tokio::test]
    async fn replacement_is_independent_of_valid_first_order() {
        let fixture = ProbeFixture::new().await;
        // A valid cover before the tiny one must not return None early. With
        // multiple donors the result must also be stable across permutations.
        for kinds in [
            ["poster-a", "tiny", "poster-z"],
            ["poster-a", "poster-z", "tiny"],
            ["poster-z", "tiny", "poster-a"],
            ["poster-z", "poster-a", "tiny"],
            ["tiny", "poster-a", "poster-z"],
            ["tiny", "poster-z", "poster-a"],
        ] {
            assert_eq!(fixture.replacement(&kinds).await, fixture.expected(), "{kinds:?}");
        }
    }

    #[tokio::test]
    async fn slow_first_variant_does_not_starve_other_probes_or_exceed_three_urls() {
        let fixture = ProbeFixture::new().await;
        assert_eq!(
            fixture.replacement(&["slow", "tiny", "poster-a", "fourth"]).await,
            fixture.expected(),
        );
        let mut hits = fixture.hits.lock().unwrap().clone();
        hits.sort();
        assert_eq!(hits, vec!["poster-a", "slow", "tiny"]);
    }

    #[tokio::test]
    async fn deadline_preserves_completed_evidence_before_slow_trailing_variant() {
        let fixture = ProbeFixture::new().await;
        assert_eq!(
            fixture.replacement(&["tiny", "poster-a", "slow"]).await,
            fixture.expected(),
        );
        assert!(fixture.hits.lock().unwrap().iter().any(|kind| kind == "slow"));
    }

    #[tokio::test]
    async fn timed_out_and_unknown_originals_do_not_become_invalid() {
        let fixture = ProbeFixture::new().await;
        assert_eq!(fixture.replacement(&["slow", "unknown", "poster-a"]).await, None);
    }
}
