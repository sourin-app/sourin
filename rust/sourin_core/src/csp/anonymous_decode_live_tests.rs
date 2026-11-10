use crate::csp::CspSite;

// Explicitly invoked by the serial test owner. Uses no profile, account,
// credential store, sharing, saving or cloud cleanup operations.
#[tokio::test]
#[ignore = "explicit anonymous network + bounded installed ffmpeg decode; CSP_LIVE=1"]
async fn anonymous_resolver_immediately_decodes_selected_media() {
    assert_eq!(std::env::var("CSP_LIVE").ok().as_deref(), Some("1"));
    let engine = std::env::var("CSP_DECODE_ENGINE").expect("set CSP_DECODE_ENGINE=hxq or yun_duo");
    let site: Box<dyn CspSite> = match engine.as_str() {
        "hxq" => Box::new(crate::csp::hxq::Hxq::new()),
        "yun_duo" => Box::new(crate::csp::yun_duo::YunDuo::new()),
        _ => panic!("unsupported explicitly selected engine"),
    };
    let selected = if engine == "hxq" {
        ("line".to_string(), "141c82DAA0Q68QI6ACCHS".to_string())
    } else {
        let detail = site.detail("86421", "").await.expect("anonymous detail must resolve");
        let index = std::env::var("CSP_DECODE_EPISODE_INDEX").ok().and_then(|v| v.parse().ok()).unwrap_or(0usize);
        let episode = detail.episodes.get(index).expect("selected episode index exists");
        (episode.flag.clone(), episode.id.clone())
    };
    let plays = site.play(&selected.0, &selected.1, "").await.expect("production Rust media resolution must succeed");
    let media = plays.first().expect("one actual media candidate");
    // Explicit diagnosis output is confined to an existing repository .probe
    // directory. Never print or overwrite an access-bearing media address.
    if let Some(output) = std::env::var_os("CSP_DECODE_PRIVATE_OUTPUT") {
        use std::io::Write;
        let output = std::path::PathBuf::from(output);
        let scope = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../.probe").canonicalize().expect("repository probe directory exists");
        let parent = output.parent().expect("explicit private artifact has a parent")
            .canonicalize().expect("private artifact parent already exists");
        assert!(parent.starts_with(scope), "private media artifact must stay inside repository .probe");
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&output)
            .expect("create a fresh private media artifact");
        let payload = serde_json::json!({"engine":engine,"url":media.url,"headers":media.headers,
            "selectedLine":selected.0,"selectedEpisode":selected.1,"networkRoute":"explicit_direct",
            "createdUnixMs":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()});
        file.write_all(payload.to_string().as_bytes()).expect("write private media artifact");
    }
    let mut command = tokio::process::Command::new("ffmpeg");
    for variable in ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy",
        "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"] {
        command.env_remove(variable);
    }
    command.env("NO_PROXY", "*").env("no_proxy", "*");
    command.kill_on_drop(true).args([
        "-hide_banner", "-loglevel", "error", "-nostdin", "-http_proxy", "", "-rw_timeout", "10000000",
        "-analyzeduration", "5000000", "-probesize", "5000000",
    ]);
    let mut headers = String::new();
    for (name, value) in &media.headers {
        if name.eq_ignore_ascii_case("user-agent") { command.args(["-user_agent", value]); }
        else { headers.push_str(&format!("{name}: {value}\r\n")); }
    }
    if !headers.is_empty() { command.args(["-headers", &headers]); }
    command.args(["-i", &media.url, "-map", "0:v:0", "-an", "-frames:v", "12", "-t", "2",
        "-f", "null", "-", "-progress", "pipe:1", "-nostats"]);
    let output = tokio::time::timeout(std::time::Duration::from_secs(40), command.output()).await;
    let output = match output {
        Ok(Ok(output)) => output,
        Ok(Err(_)) => panic!("installed ffmpeg failed to start"),
        Err(_) => panic!("bounded immediate decode timed out; media URL was not logged"),
    };
    let frames = String::from_utf8_lossy(&output.stdout).lines().filter_map(|line|
        line.strip_prefix("frame=").and_then(|value| value.trim().parse::<u64>().ok())).max().unwrap_or(0);
    let error = String::from_utf8_lossy(&output.stderr);
    let classification = if error.contains("403") { "http403" }
        else if error.contains("404") { "http404" }
        else if error.contains("Invalid data") { "invalid_media" }
        else if error.contains("Error opening") { "open_failed" }
        else { "other_or_none" };
    eprintln!("[ANONYMOUS-DECODE] engine={engine} route=explicit_direct candidates={} frames={frames} exit={:?} errorClass={classification}",
        plays.len(), output.status.code());
    assert!(output.status.success() && frames >= 12,
        "immediate production resolve + decode failed: frames={frames}, errorClass={classification}");
}
