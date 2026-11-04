//! 分享有效性检查、具体文件标识与选集。分享页本身永不交给播放器。

use serde::{Deserialize, Serialize};

use crate::pan::PanKind;
use crate::pan_check::{CheckOutcome, CheckState, PanChecker};

use super::pan_drive::{DriveEntry, PanDrive};
use super::{CspDetail, CspEpisode, CspPlay};

const FILE_PREFIX: &str = "panfile:";

#[derive(Debug, Clone, Default)]
pub struct EpisodeSpec {
    pub title: String,
    pub order: Option<u32>,
}

/// 只存稳定文件 id；临时 stoken/fid_token 必须在播放时重新配对取得。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShareFileRef {
    pub kind: String,
    pub share_id: String,
    pub passcode: String,
    pub fid: String,
}

pub fn encode_file_id(kind: PanKind, share_id: &str, passcode: &str, fid: &str) -> String {
    let file = ShareFileRef {
        kind: kind.code().to_string(),
        share_id: share_id.to_string(),
        passcode: passcode.to_string(),
        fid: fid.to_string(),
    };
    format!("{FILE_PREFIX}{}", super::shared::b64_encode_url(
        &serde_json::to_vec(&file).expect("share file reference serializes")
    ))
}

pub fn decode_file_id(id: &str) -> Result<ShareFileRef, String> {
    let encoded = id.strip_prefix(FILE_PREFIX).ok_or("不是网盘文件标识")?;
    let bytes = super::shared::b64_decode(encoded)?;
    let file: ShareFileRef = serde_json::from_slice(&bytes).map_err(|_| "网盘文件标识无效")?;
    if kind_of_code(&file.kind).is_none()
        || [&file.share_id, &file.fid].iter().any(|v| v.is_empty() || v.chars().any(char::is_control))
        || file.passcode.chars().any(char::is_control)
    {
        return Err("网盘文件标识无效".into());
    }
    Ok(file)
}

pub fn is_file_id(id: &str) -> bool {
    id.starts_with(FILE_PREFIX)
}

pub fn kind_of_code(code: &str) -> Option<PanKind> {
    [
        PanKind::Quark, PanKind::Uc, PanKind::Baidu, PanKind::Aliyun, PanKind::Xunlei,
        PanKind::Pan115, PanKind::Pan123, PanKind::Tianyi, PanKind::Guangya,
    ].into_iter().find(|kind| kind.code() == code)
}

pub fn share_url(kind: PanKind, share_id: &str, passcode: &str) -> Result<String, String> {
    let base = match kind {
        PanKind::Quark => "https://pan.quark.cn/s/",
        PanKind::Uc => "https://drive.uc.cn/s/",
        PanKind::Baidu => "https://pan.baidu.com/s/",
        PanKind::Aliyun => "https://www.aliyundrive.com/s/",
        PanKind::Xunlei => "https://pan.xunlei.com/s/",
        PanKind::Pan115 => "https://115.com/s/",
        PanKind::Pan123 => "https://www.123pan.com/s/",
        PanKind::Tianyi => "https://cloud.189.cn/t/",
        PanKind::Guangya => "https://www.guangyapan.com/s/",
        PanKind::Unknown => return Err("无法识别网盘种类".into()),
    };
    let mut url = reqwest::Url::parse(base).map_err(|_| "网盘分享地址无效")?;
    url.path_segments_mut().map_err(|_| "网盘分享地址无效")?.pop_if_empty().push(share_id);
    if !passcode.is_empty() {
        url.query_pairs_mut().append_pair("pwd", passcode);
    }
    Ok(url.to_string())
}

/// 已知死链/提取码错误立即终止；不确定时必须由真实列文件请求再次验证。
pub fn validity_gate(outcome: &CheckOutcome) -> Result<(), String> {
    match outcome.state {
        CheckState::Bad => Err(format!("网盘链接无效：{}", outcome.summary)),
        CheckState::Locked => Err(format!("这个网盘分享需要正确的提取码：{}", outcome.summary)),
        CheckState::Ok | CheckState::Uncertain | CheckState::Unsupported => Ok(()),
    }
}

pub async fn check_before_listing(checker: &PanChecker, url: &str, pwd: &str) -> Result<CheckOutcome, String> {
    let (outcome, _, _) = checker.check_one(url, Some(pwd)).await;
    validity_gate(&outcome)?;
    Ok(outcome)
}

/// 年份/分辨率不作为集号。文件名中的显式 E/EP/第N集 或独立短数字可识别。
pub fn episode_number(text: &str) -> Option<u32> {
    let stem = if super::pan_drive::is_video_name(text) {
        let text = text.rsplit('/').next().unwrap_or(text);
        text.rsplit_once('.').map(|(stem, _)| stem).unwrap_or(text)
    } else { text };
    let chars: Vec<char> = stem.trim().chars().collect();
    let mut found = None;
    let mut i = 0;
    while i < chars.len() {
        if !chars[i].is_ascii_digit() { i += 1; continue; }
        let start = i;
        while i < chars.len() && chars[i].is_ascii_digit() { i += 1; }
        let number: String = chars[start..i].iter().collect();
        let n = number.parse::<u32>().ok()?;
        let prev = start.checked_sub(1).and_then(|p| chars.get(p)).copied();
        let next = chars.get(i).copied();
        let e_prefix = prev.is_some_and(|c| c.eq_ignore_ascii_case(&'e')) && (
            start == 1 || (start >= 2 && is_separator(chars[start - 2]))
                || {
                    let before: String = chars[..start.saturating_sub(1)].iter().rev()
                        .take_while(|c| !is_separator(**c) && **c != '/').collect::<String>()
                        .chars().rev().collect();
                    before.strip_prefix(['s', 'S']).is_some_and(|digits| !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()))
                }
        );
        let ep_prefix = start >= 2
            && chars[start - 2..start].iter().collect::<String>().eq_ignore_ascii_case("ep")
            && (start == 2 || is_separator(chars[start - 3]));
        let explicit = matches!(next, Some('集' | '话' | '期' | '回')) || e_prefix || ep_prefix;
        let boundary = (start == 0 || prev.is_some_and(is_separator))
            && (i == chars.len() || next.is_some_and(is_separator));
        if n > 0 && n <= 999 && (explicit || (boundary && number.len() <= 3)) {
            if found.is_some_and(|old| old != n) { return None; }
            found = Some(n);
        }
    }
    found
}

fn is_separator(c: char) -> bool {
    c.is_whitespace() || "._-[]()【】（）".contains(c)
}

fn normalized_stem(text: &str) -> String {
    let text = text.rsplit('/').next().unwrap_or(text);
    let stem = if super::pan_drive::is_video_name(text) {
        text.rsplit_once('.').map(|(stem, _)| stem).unwrap_or(text)
    } else { text };
    stem.chars().filter(|c| !is_separator(*c)).flat_map(char::to_lowercase).collect()
}

/// 精确文件名或唯一集号才能选中；模糊包含关系不够证明是哪一集。
pub fn pick_episode_index(spec: &EpisodeSpec, names: &[String]) -> Result<usize, String> {
    if names.is_empty() {
        return Err("分享里没有可播放的视频文件".into());
    }
    let title = normalized_stem(&spec.title);
    if !title.is_empty() {
        let exact: Vec<usize> = names.iter().enumerate()
            .filter(|(_, name)| normalized_stem(name) == title).map(|(i, _)| i).collect();
        match exact.as_slice() {
            [i] => return Ok(*i),
            [] => {}
            _ => return Err("分享里有多个同名视频，请在文件列表里选择具体文件".into()),
        }
    }
    let desired = episode_number(&spec.title).or(spec.order.filter(|n| *n > 0));
    if let Some(order) = desired {
        let matches: Vec<usize> = names.iter().enumerate()
            .filter(|(_, name)| episode_number(name) == Some(order)).map(|(i, _)| i).collect();
        match matches.as_slice() {
            [i] => return Ok(*i),
            [] => {}
            _ => return Err(format!("第{order}集有多个视频版本，请在文件列表里选择具体文件")),
        }
        // 电影通常有 order=1，但唯一视频文件不一定叫「第1集」。
        if order == 1 && names.len() == 1 && episode_number(&spec.title).is_none() && episode_number(&names[0]).is_none() {
            return Ok(0);
        }
        return Err(format!("分享里没有对应第{order}集的视频，请刷新详情后选择具体文件"));
    }
    if names.len() == 1 { return Ok(0); }
    Err("分享里有多个视频，请刷新详情后选择具体文件".into())
}

pub fn pick_episode_file<'a>(spec: &EpisodeSpec, files: &'a [DriveEntry], fid: Option<&str>) -> Result<&'a DriveEntry, String> {
    let files: Vec<&DriveEntry> = files.iter()
        .filter(|f| !f.is_dir && f.size > 0 && super::pan_drive::is_video_name(&f.name)).collect();
    if let Some(fid) = fid {
        return files.into_iter().find(|f| f.fid == fid)
            .ok_or_else(|| "所选视频已不在分享里，请刷新详情后重新选集".into());
    }
    let names: Vec<String> = files.iter().map(|f| f.name.clone()).collect();
    Ok(files[pick_episode_index(spec, &names)?])
}

/// 生产与协议回放共用此入口：检查 → 列真实文件 → 选文件 → 转存 → 取媒体地址。
pub async fn resolve_family_with(
    checker: &PanChecker, drive: &PanDrive, url: &str, share_id: &str,
    passcode: &str, fid: Option<&str>, spec: &EpisodeSpec,
) -> Result<CspPlay, String> {
    check_before_listing(checker, url, passcode).await?;
    let cookie = drive.cookie().ok_or_else(|| format!(
        "NEED_LOGIN:{}|还未登录{}账号，请前往配置中心登录",
        drive.kind().code(), drive.kind().display()
    ))?;
    let files = drive.share_video_files(&cookie, share_id, passcode, "0").await?;
    let selected = pick_episode_file(spec, &files, fid)?;
    // 验证/选片失败不动网盘，转存前才收走上一次临时文件。
    let _mutation = super::pan_playback_guard::mutation_lock(drive.kind().code()).await;
    super::pan_playback_guard::check_current()?;
    drive.purge_previous().await;
    super::pan_playback_guard::check_current()?;
    let mut play = drive.degrade_attempt(&cookie, share_id, passcode, selected).await?;
    super::pan_playback_guard::check_current()?;
    play.label = Some(format!("{} · {}", drive.kind().display(), selected.name));
    Ok(play)
}

pub async fn resolve_family(url: &str, fid: Option<&str>, spec: &EpisodeSpec) -> Result<CspPlay, String> {
    let share = super::pan_share_play::parse_share_page(url).ok_or("网盘分享地址无效")?;
    let drive = super::pan_share_play::drive_for(share.kind).ok_or("该网盘的分享解析尚未接入")?;
    resolve_family_with(crate::pan_check::global_checker(), &drive, url,
        &share.share_id, &share.passcode, fid, spec).await
}

pub async fn resolve_share(url: &str, fid: Option<&str>, spec: &EpisodeSpec) -> Result<CspPlay, String> {
    if super::pan_share_play::parse_share_page(url).is_some() {
        return resolve_family(url, fid, spec).await;
    }
    let share = crate::pan::parse_share(url);
    let passcode = share.pwd_in_url.as_deref().unwrap_or("");
    let outcome = check_before_listing(crate::pan_check::global_checker(), url, passcode).await?;
    match share.kind {
        PanKind::Xunlei => super::pan_xunlei_play::resolve_selected(&share.share_id, passcode, fid, spec).await,
        // 此解析器会先列真实文件再给出缺少取址的明确错误，不把网页交回播放器。
        PanKind::Baidu => super::pan_baidu_play::resolve(&share.share_id, passcode).await,
        _ => Err(format!("{}的分享播放尚未接入：{}", share.kind.display(), outcome.summary)),
    }
}

pub async fn resolve_file_id(id: &str, spec: &EpisodeSpec) -> Result<CspPlay, String> {
    let file = decode_file_id(id)?;
    let kind = kind_of_code(&file.kind).ok_or("无法识别网盘种类")?;
    let url = share_url(kind, &file.share_id, &file.passcode)?;
    resolve_share(&url, Some(&file.fid), spec).await
}

pub async fn family_episodes(url: &str, flag: &str) -> Result<Vec<CspEpisode>, String> {
    family_episodes_at(url, flag, "0").await
}

pub async fn family_episodes_at(url: &str, flag: &str, folder: &str) -> Result<Vec<CspEpisode>, String> {
    let share = super::pan_share_play::parse_share_page(url).ok_or("网盘分享地址无效")?;
    check_before_listing(crate::pan_check::global_checker(), url, &share.passcode).await?;
    let drive = super::pan_share_play::drive_for(share.kind).ok_or("该网盘的分享解析尚未接入")?;
    // 浏览分享无需账号；取流入口再要求登录。
    let files = drive.share_video_files("", &share.share_id, &share.passcode, folder).await?;
    Ok(files.into_iter().map(|f| CspEpisode {
        id: encode_file_id(share.kind, &share.share_id, &share.passcode, &f.fid),
        title: f.name,
        flag: flag.to_string(),
    }).collect())
}

pub async fn share_episodes(url: &str, flag: &str) -> Result<Vec<CspEpisode>, String> {
    if super::pan_share_play::parse_share_page(url).is_some() {
        return family_episodes(url, flag).await;
    }
    let share = crate::pan::parse_share(url);
    let passcode = share.pwd_in_url.as_deref().unwrap_or("");
    let outcome = check_before_listing(crate::pan_check::global_checker(), url, passcode).await?;
    match share.kind {
        PanKind::Xunlei => {
            let files = super::pan_xunlei_play::list_share_files(&share.share_id, passcode).await?;
            Ok(files.into_iter().map(|f| CspEpisode {
                id: encode_file_id(share.kind, &share.share_id, passcode, &f.id),
                title: f.name,
                flag: flag.to_string(),
            }).collect())
        }
        _ => Err(format!("{}的分享文件列表尚未接入：{}", share.kind.display(), outcome.summary)),
    }
}

fn share_page_payload(id: &str) -> String {
    super::app99::episode_url(id)
        .unwrap_or_else(|| id.split_once('\u{1}').map(|(_, tail)| tail).unwrap_or(id).to_string())
}

/// 只展开本来把整份分享当一集的线路。真实文件 id/媒体直链保持原样。
pub async fn expand_detail(mut detail: CspDetail) -> CspDetail {
    let mut join = tokio::task::JoinSet::new();
    let sem = std::sync::Arc::new(tokio::sync::Semaphore::new(4));
    let mut shares = std::collections::HashMap::<String, Vec<usize>>::new();
    for (index, episode) in detail.episodes.iter().enumerate() {
        let url = share_page_payload(&episode.id);
        let share = crate::pan::parse_share(&url);
        if !matches!(share.kind, PanKind::Quark | PanKind::Uc | PanKind::Xunlei) || share.share_id.is_empty() { continue; }
        shares.entry(url).or_default().push(index);
    }
    for (url, indexes) in shares {
        let sem = sem.clone();
        join.spawn(async move {
            let _permit = sem.acquire_owned().await;
            (indexes, share_episodes(&url, "").await)
        });
    }
    let mut expanded = std::collections::HashMap::new();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(75);
    while !join.is_empty() {
        let done = match tokio::time::timeout_at(deadline, join.join_next()).await {
            Ok(Some(done)) => done,
            _ => {
                crate::applog::write_file_log("PAN", "分享文件展开超过总预算，保留待检查的分享入口");
                join.abort_all();
                break;
            }
        };
        match done {
            Ok((indexes, Ok(episodes))) => {
                if episodes.is_empty() { continue; }
                for index in indexes {
                    let mut episodes = episodes.clone();
                    for episode in &mut episodes { episode.flag = detail.episodes[index].flag.clone(); }
                    expanded.insert(index, episodes);
                }
            }
            // 上游错误可能带分享地址或 token，只记类别和保留入口的事实。
            Ok((indexes, Err(_))) => crate::applog::write_file_log("PAN", &format!(
                "分享文件展开失败，保留 {} 个入口；点击时需重新检查", indexes.len()
            )),
            Err(_) => crate::applog::write_file_log("PAN", "分享文件展开任务异常，保留待检查的分享入口"),
        }
    }
    let mut episodes = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for (index, episode) in detail.episodes.into_iter().enumerate() {
        for ep in expanded.remove(&index).unwrap_or_else(|| vec![episode]) {
            if seen.insert((ep.flag.clone(), ep.id.clone())) { episodes.push(ep); }
        }
    }
    detail.episodes = episodes;
    detail
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(fid: &str, name: &str, size: u64) -> DriveEntry {
        DriveEntry { fid: fid.into(), name: name.into(), size, is_dir: false, fid_token: None }
    }

    #[test]
    fn file_reference_roundtrips_and_does_not_store_temporary_tokens() {
        let id = encode_file_id(PanKind::Quark, "share1", "a+b", "file2");
        let out = decode_file_id(&id).unwrap();
        assert_eq!(out.kind, "quark");
        assert_eq!(out.share_id, "share1");
        assert_eq!(out.passcode, "a+b");
        assert_eq!(out.fid, "file2");
        assert!(is_file_id(&id));
        assert!(decode_file_id("panfile:invalid").is_err());
        assert!(decode_file_id(&encode_file_id(PanKind::Quark, "s", "", "")).is_err());
    }

    #[test]
    fn file_reference_urlsafe_unicode_payload_roundtrips() {
        let fid = "文件\u{ffff}";
        let id = encode_file_id(PanKind::Uc, "分享", "口令", fid);
        assert!(id.contains('-') || id.contains('_'), "夹具必须实际覆盖URL-safe字母表");
        let out = decode_file_id(&id).unwrap();
        assert_eq!(out.kind, "uc");
        assert_eq!(out.share_id, "分享");
        assert_eq!(out.passcode, "口令");
        assert_eq!(out.fid, fid);
    }

    #[test]
    fn share_payload_extracts_structured_and_legacy_source_episode_ids() {
        let url = "https://pan.quark.cn/s/fixture?pwd=ab";
        let id = format!("app99:{}", super::super::shared::b64_encode(&serde_json::to_vec(
            &serde_json::json!({"url":url,"code":"line","title":"第3集","index":3})
        ).unwrap()));
        assert_eq!(share_page_payload(&id), url);
        assert_eq!(share_page_payload(&format!("line\u{1}{url}")), url);
        assert_eq!(share_page_payload(url), url);
        assert_eq!(share_page_payload("https://cdn.example/movie.mp4"), "https://cdn.example/movie.mp4");
    }

    #[test]
    fn chooses_explicit_episode_not_largest_or_similar_title() {
        let files = [file("first", "第1集.mkv", 9000), file("third", "第3集.mkv", 1000)];
        let spec = EpisodeSpec { title: "第3集".into(), order: Some(3) };
        assert_eq!(pick_episode_file(&spec, &files, None).unwrap().fid, "third");
        let unrelated = vec!["第13集.mkv".into(), "第30集.mkv".into()];
        assert!(pick_episode_index(&spec, &unrelated).is_err());
    }

    #[test]
    fn exact_file_id_beats_title_and_duplicate_episode_versions() {
        let files = [file("a", "第3集.mkv", 1000), file("b", "第3集.mp4", 2000)];
        let spec = EpisodeSpec { title: "第3集".into(), order: Some(3) };
        assert!(pick_episode_file(&spec, &files, None).is_err());
        assert_eq!(pick_episode_file(&spec, &files, Some("b")).unwrap().fid, "b");
        assert!(pick_episode_file(&spec, &files, Some("missing")).is_err());
    }

    #[test]
    fn ignores_empty_files_and_does_not_guess_for_multi_file_shares() {
        let files = [file("empty", "第3集.mkv", 0), file("real", "第3集.mp4", 10)];
        let spec = EpisodeSpec { title: "第3集".into(), order: None };
        assert_eq!(pick_episode_file(&spec, &files, None).unwrap().fid, "real");
        assert!(pick_episode_index(&EpisodeSpec::default(), &["A.mkv".into(), "B.mkv".into()]).is_err());
        assert_eq!(pick_episode_index(&EpisodeSpec { title: "正片".into(), order: Some(1) }, &["电影.mkv".into()]).unwrap(), 0);
        assert!(pick_episode_index(&EpisodeSpec { title: "未知标题".into(), order: Some(2) }, &["电影.mkv".into()]).is_err());
    }

    #[test]
    fn episode_numbers_are_narrow() {
        for (name, number) in [("第03集", 3), ("03.mp4", 3), ("EP07.mkv", 7), ("S01E09.mkv", 9), ("剧.12.1080p.mkv", 12), ("第1季/EP03.WEBRip.mkv", 3)] {
            assert_eq!(episode_number(name), Some(number), "{name}");
        }
        for name in ["1080P", "2023", "2023.mkv", "Movie.2023.1080p.mkv", "03/45", "第3集第4集", "第3季", "Movie2.mkv"] {
            assert_eq!(episode_number(name), None, "{name}");
        }
    }

    #[test]
    fn invalid_and_locked_stop_before_listing_but_uncertain_needs_listing() {
        for state in [CheckState::Bad, CheckState::Locked] {
            assert!(validity_gate(&CheckOutcome { state, summary: "检查原文".into(), cacheable: true }).is_err());
        }
        for state in [CheckState::Ok, CheckState::Uncertain, CheckState::Unsupported] {
            assert!(validity_gate(&CheckOutcome { state, summary: "检查原文".into(), cacheable: false }).is_ok());
        }
        // 放行预检不确定态不是放行媒体；没有真实文件仍然不可选。
        assert!(pick_episode_file(&EpisodeSpec::default(), &[], None).is_err());
    }
}
