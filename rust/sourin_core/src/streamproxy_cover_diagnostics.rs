//! Bounded, value-free diagnostics for a failed registered cover response.
//! HTTP response headers are untrusted claims: even an exact proxy marker is
//! advertised evidence, never proof of which network participant sent it.
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum FinalScheme {
    Http,
    Https,
    Other,
}

#[derive(Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum HttpsOnlyMarker {
    Absent,
    Explicit,
    Unrecognized,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum Attribution {
    ProxyAdvertisedBlock,
    HttpResponseUnattributed,
}

/// Keep this schema closed. Strings from URLs, bodies and header values must
/// never become additional fields, including an unrestricted `other` value.
#[derive(Serialize)]
pub(super) struct CoverFailureDiagnostic {
    status: u16,
    final_scheme: FinalScheme,
    https_only_marker: HttpsOnlyMarker,
    proxy_status_present: bool,
    proxy_authenticate_present: bool,
    via_present: bool,
    attribution: Attribution,
}

impl CoverFailureDiagnostic {
    pub(super) fn from_response(response: &reqwest::Response) -> Self {
        let headers = response.headers();
        let marker_values = headers.get_all("x-mitmproxy-blocked-reason");
        let mut markers = marker_values.iter();
        let https_only_marker = match (markers.next(), markers.next()) {
            (None, _) => HttpsOnlyMarker::Absent,
            (Some(value), None) if value.to_str().is_ok_and(|value| {
                value.trim().eq_ignore_ascii_case("HTTPS-ONLY")
            }) => HttpsOnlyMarker::Explicit,
            _ => HttpsOnlyMarker::Unrecognized,
        };
        let attribution = if response.status() == reqwest::StatusCode::FORBIDDEN
            && https_only_marker == HttpsOnlyMarker::Explicit
        {
            Attribution::ProxyAdvertisedBlock
        } else {
            Attribution::HttpResponseUnattributed
        };
        Self {
            status: response.status().as_u16(),
            final_scheme: match response.url().scheme() {
                "http" => FinalScheme::Http,
                "https" => FinalScheme::Https,
                _ => FinalScheme::Other,
            },
            https_only_marker,
            proxy_status_present: headers.contains_key("proxy-status"),
            proxy_authenticate_present: headers.contains_key("proxy-authenticate"),
            via_present: headers.contains_key("via"),
            attribution,
        }
    }
}
