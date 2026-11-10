//! Decode per-image TVBox request metadata without changing durable cover URLs.
//! Note: .agents/notes/implemented/bug-fix/2026-11-10-inline-cover-request-headers.md
use std::sync::LazyLock;

/// Only the Referer/User-Agent suffix observed in catalog posters is supported.
/// Query strings and percent escapes in the image URL itself remain untouched.
pub(crate) fn decode(
    raw: &str,
    mut headers: Vec<(String, String)>,
) -> (String, Vec<(String, String)>) {
    if let Some((url, inline)) = suffix(raw) {
        // Per-image requirements override source-wide defaults, without duplicate
        // header names. Keep the source's unrelated headers and routing policy.
        for (name, value) in inline {
            headers.retain(|(key, _)| !key.eq_ignore_ascii_case(&name));
            headers.push((name, value));
        }
        (url.to_string(), headers)
    } else {
        (raw.to_string(), headers)
    }
}

fn suffix(raw: &str) -> Option<(&str, Vec<(String, String)>)> {
    static MARKER: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"@([A-Za-z][A-Za-z0-9-]*)=").expect("cover header suffix")
    });
    let markers: Vec<_> = MARKER.captures_iter(raw).collect();
    let first = markers.first()?.get(0)?.start();
    let prefix = &raw[..first];
    // Some TVBox catalogs put an empty '?' before the first header.
    let parsed = reqwest::Url::parse(prefix).ok()?;
    let url = if parsed.query() == Some("") {
        prefix.strip_suffix('?').unwrap_or(prefix)
    } else {
        prefix
    };
    if !matches!(parsed.scheme(), "http" | "https")
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.fragment().is_some()
    {
        return None;
    }
    let mut headers = Vec::with_capacity(markers.len());
    for (index, marker) in markers.iter().enumerate() {
        let name = match marker.get(1)?.as_str().to_ascii_lowercase().as_str() {
            "referer" => "Referer",
            "user-agent" => "User-Agent",
            _ => return None,
        };
        let start = marker.get(0)?.end();
        let end = markers
            .get(index + 1)
            .and_then(|next| next.get(0))
            .map_or(raw.len(), |next| next.start());
        // Url::join can encode spaces in extracted HTML attributes. Decode
        // the header value once; never decode the image URL/query itself.
        let value = urlencoding::decode(&raw[start..end]).ok()?.into_owned();
        if value.is_empty() || reqwest::header::HeaderValue::from_str(&value).is_err() {
            return None;
        }
        if name == "Referer"
            && !reqwest::Url::parse(&value)
                .ok()
                .is_some_and(|u| matches!(u.scheme(), "http" | "https") && u.host_str().is_some())
        {
            return None;
        }
        headers.push((name.to_string(), value));
    }
    Some((url, headers))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supported_forms_keep_image_query_and_decode_headers_only_once() {
        for separator in ["", "?", "?size=2&name=a%2Bb", "?name=value?"] {
            let raw = format!("https://img.example/poster.jpg{separator}@Referer=https://ref.example/frame@User-Agent=Browser%20Fixture%2520+1.0");
            let (url, headers) = decode(&raw, vec![]);
            let expected = if separator == "?" { "" } else { separator };
            assert_eq!(url, format!("https://img.example/poster.jpg{expected}"));
            assert_eq!(
                headers,
                vec![
                    ("Referer".into(), "https://ref.example/frame".into()),
                    ("User-Agent".into(), "Browser Fixture%20+1.0".into())
                ]
            );
        }
    }

    #[test]
    fn per_image_headers_override_defaults_case_insensitively() {
        let (_, headers) = decode(
            "https://img.example/p.jpg@user-agent=Browser 1@REFERER=https://ref.example/",
            vec![
                ("User-AGENT".into(), "old".into()),
                ("REFERER".into(), "old".into()),
                ("X-Source".into(), "keep".into()),
            ],
        );
        assert_eq!(
            headers,
            vec![
                ("X-Source".into(), "keep".into()),
                ("User-Agent".into(), "Browser 1".into()),
                ("Referer".into(), "https://ref.example/".into())
            ]
        );
    }

    #[test]
    fn ordinary_or_malformed_urls_are_not_reinterpreted() {
        for raw in [
            "https://img.example/p@2x.jpg?email=a@b.test",
            "https://img.example/p.jpg?q=%40Referer%3Dx",
            "https://img.example/p.jpg#note@User-Agent=literal",
            "https://img.example/p.jpg@token=secret",
            "https://user@referer=pass.example/p.jpg",
            "https://img.example/p.jpg@Referer=invalid",
            "https://img.example/p.jpg@User-Agent=",
            "https://img.example/p.jpg@User-Agent=ok%0d%0aX-Other%3Ainjected",
            "https://img.example/p.jpg@Referer=https://r.example/@Unknown=x",
            "data:image/png@User-Agent=Browser",
        ] {
            let original = vec![("X-Source".into(), "unchanged".into())];
            assert_eq!(
                decode(raw, original.clone()),
                (raw.into(), original),
                "{raw}"
            );
        }
    }
}
