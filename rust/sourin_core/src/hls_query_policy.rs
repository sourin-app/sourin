//! Internal opt-in for a source that declares inherited HLS media query fields.
//! Access values are copied from an issued parent URL, never calculated here.

use reqwest::Url;

#[derive(Clone, Debug)]
pub struct ScopedHlsQueryPolicy {
    origin: Url,
    keys: &'static [&'static str],
}

impl ScopedHlsQueryPolicy {
    pub(crate) fn new(url: &str, keys: &'static [&'static str]) -> Option<Self> {
        let mut origin = Url::parse(url).ok()?;
        if !matches!(origin.scheme(), "http" | "https") || origin.host_str().is_none()
            || !origin.username().is_empty() || origin.password().is_some() {
            return None;
        }
        origin.set_path("/");
        origin.set_query(None);
        origin.set_fragment(None);
        Some(Self { origin, keys })
    }

    pub(crate) fn origin_key(&self) -> &str { self.origin.as_str() }

    pub(crate) fn allows(&self, url: &Url) -> bool {
        url.origin() == self.origin.origin() && url.username().is_empty() && url.password().is_none()
    }

    pub(crate) fn allows_str(&self, url: &str) -> bool {
        Url::parse(url).is_ok_and(|url| self.allows(&url))
    }

    /// Existing query (including an empty '?') belongs to the child. Only URI
    /// lines inherit; KEY/MAP tags use standard resolution without new fields.
    pub(crate) fn resolve(&self, parent: &str, uri: &str, inherit: bool) -> Result<String, &'static str> {
        let base = Url::parse(parent).map_err(|_| "播放列表地址无效")?;
        if !self.allows(&base) { return Err("播放列表跳转到未声明的媒体来源"); }
        let mut child = base.join(uri).map_err(|_| "播放列表子地址无效")?;
        if !self.allows(&child) { return Err("播放列表包含未声明的媒体来源"); }
        child.set_fragment(None);
        if inherit && !uri.contains('?') && child.query().is_none() {
            if let Some(query) = base.query() {
                let selected = query.split('&').filter(|pair| {
                    let key = pair.split_once('=').map_or(*pair, |(key, _)| key);
                    self.keys.contains(&key)
                }).collect::<Vec<_>>().join("&");
                if !selected.is_empty() { child.set_query(Some(&selected)); }
            }
        }
        Ok(child.to_string())
    }

    pub(crate) fn rewrite(&self, text: &str, parent: &str, local_base: &str) -> Result<String, &'static str> {
        let mut output = String::with_capacity(text.len() + 512);
        for raw in text.lines() {
            let line = raw.trim();
            if line.is_empty() { output.push('\n'); continue; }
            if line.starts_with('#') {
                if let Some(start) = line.find("URI=\"").map(|start| start + 5) {
                    if let Some(end) = line[start..].find('"').map(|end| start + end) {
                        let url = self.resolve(parent, &line[start..end], false)?;
                        output.push_str(&line[..start]);
                        output.push_str(&local_url(&url, local_base));
                        output.push_str(&line[end..]);
                        output.push('\n');
                        continue;
                    }
                }
                output.push_str(line);
            } else {
                output.push_str(&local_url(&self.resolve(parent, line, true)?, local_base));
            }
            output.push('\n');
        }
        Ok(output)
    }
}

fn local_url(url: &str, local_base: &str) -> String {
    // Resolution above validates the authority. Preserve path/query spelling
    // from that URL instead of decoding signed bytes into an axum query map.
    let (scheme, rest) = url.split_once("://").expect("validated absolute URL");
    // axum Path decodes one layer before reconstructing the upstream URL.
    // Protect existing path escapes; RawQuery already preserves query bytes.
    let (path, query) = rest.split_once('?').map_or((rest, None), |(path, query)| (path, Some(query)));
    let path = path.replace('%', "%25");
    match query {
        Some(query) => format!("{local_base}{scheme}/{path}?{query}"),
        None => format!("{local_base}{scheme}/{path}"),
    }
}

#[cfg(test)]
#[path = "hls_query_policy_tests.rs"]
mod tests;
