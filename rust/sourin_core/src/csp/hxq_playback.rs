// Anonymous playback follows the configured client's request and AES envelope.
// One identity belongs to one engine instance; failures never rotate it or try
// another episode to work around an upstream permission or request limit.
use aes::cipher::{block_padding::{NoPadding, Pkcs7}, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use md5::{Digest, Md5};
use ring::rand::{SecureRandom, SystemRandom};
use serde_json::{json, Value};

use super::{CspPlay, Hxq};

const DEVICE_UA: &str = "HanjuTV/6.9 (25128PNA1C; Android 17; Scale/2.00)";
const MEDIA_UA: &str = "tdc.8350";
const VERSION: &str = "6.9";
const ENVELOPE_SALT: &str = "34F9Q53w/HJW8E6Q";
const QUERY_SALT: &str = "2E159Q/Z8979WckQ";
const MAX_BODY: usize = 2 * 1024 * 1024;

fn md5(text: &str) -> String { format!("{:x}", Md5::digest(text.as_bytes())) }

fn millis() -> Result<u64, String> {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| "无法读取播放请求时间")?.as_millis();
    u64::try_from(now).map_err(|_| "播放请求时间无效".into())
}

fn random(length: usize, alphabet: &[u8]) -> Result<String, String> {
    let mut bytes = vec![0; length];
    SystemRandom::new().fill(&mut bytes).map_err(|_| "无法生成播放请求标识")?;
    Ok(bytes.iter().map(|b| alphabet[usize::from(*b) % alphabet.len()] as char).collect())
}

fn encrypt(text: &str, key: &[u8], iv: &[u8]) -> Result<String, String> {
    let mut buffer = vec![0; (text.len() / 16 + 1) * 16];
    buffer[..text.len()].copy_from_slice(text.as_bytes());
    let bytes = cbc::Encryptor::<aes::Aes128>::new_from_slices(key, iv)
        .map_err(|_| "播放请求加密参数无效")?
        .encrypt_padded_mut::<Pkcs7>(&mut buffer, text.len())
        .map_err(|_| "播放请求加密失败")?;
    Ok(crate::csp::app99::b64_encode(bytes))
}

fn decrypt(text: &str, key: &[u8], iv: &[u8]) -> Result<String, String> {
    let bytes = crate::csp::app99::b64_decode(text).map_err(|_| "播放响应编码无效")?;
    if bytes.len() > MAX_BODY { return Err("播放响应过长".into()); }
    let mut buffer = bytes.clone();
    let plain = cbc::Decryptor::<aes::Aes128>::new_from_slices(key, iv)
        .map_err(|_| "播放响应解密参数无效")?
        .decrypt_padded_mut::<Pkcs7>(&mut buffer).map(|b| b.to_vec())
        .or_else(|_| {
            let mut buffer = bytes;
            cbc::Decryptor::<aes::Aes128>::new_from_slices(key, iv).unwrap()
                .decrypt_padded_mut::<NoPadding>(&mut buffer).map(|b| b.to_vec())
        }).map_err(|_| "播放响应解密失败")?;
    String::from_utf8(plain).map(|s| s.trim_end_matches('\0').to_string())
        .map_err(|_| "播放响应文本无效".into())
}

pub(super) struct Session {
    uid: String,
    said: String,
    advertising: String,
    installed: u64,
}

impl Session {
    pub(super) fn new() -> Result<Self, String> {
        Ok(Self {
            uid: random(20, b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")?,
            said: random(16, b"0123456789abcdef")?,
            advertising: random(16, b"0123456789abcdef")?,
            installed: millis()?.saturating_sub(1_209_600_000),
        })
    }

    fn key(&self) -> String { md5(&self.uid) }

    fn headers(&self, now: u64) -> Result<Vec<(&'static str, String)>, String> {
        let key = self.key();
        let device = json!({
            "emu":0,"ou":0,"it":self.installed,"iit":self.installed,"bs":0,
            "uid":self.uid,"pc":0,"tm":81,"d8m":"0,0,0,0,0,0,0,4",
            "md":"25128PNA1C","maker":"Xiaomi","osv":"17","br":95,
            "rpc":0,"scc":2,"plc":6,"toc":19,"tsc":10,"ts":now,"pa":1,
            "crec":0,"nw":2,"px":"0","isp":"","ai":self.said,
            "oa":self.advertising,"dpc":0,"dsc":0,"qpc":0,"apad":0,
            "pk":"com.babycloud.hanju"
        });
        Ok(vec![
            ("vc", "a_8350".into()), ("vn", VERSION.into()), ("ch", "qq".into()),
            ("app", "hj".into()), ("User-Agent", DEVICE_UA.into()),
            ("said", self.said.clone()),
            ("uk", encrypt(&self.uid, b"f349wghhe784tqwh", b"d3w8hf94fidk38lk")?),
            ("sign", encrypt(&device.to_string(), &key.as_bytes()[..16], &key.as_bytes()[16..])?),
        ])
    }

    fn envelope(&self, value: Value) -> Result<Value, String> {
        let Some(data) = value.get("data").and_then(Value::as_str).filter(|s| !s.is_empty()) else {
            return Ok(value);
        };
        let supplied = value.get("key").and_then(Value::as_str).filter(|s| !s.is_empty());
        let seed = match supplied {
            Some(key) => key.to_string(),
            None => {
                let time = value.get("ts").map(|v| v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string()))
                    .ok_or("播放响应缺少时间字段")?;
                md5(&format!("{}{time}", self.uid))
            }
        };
        let key = md5(&format!("{seed}{ENVELOPE_SALT}"));
        let text = decrypt(data, &key.as_bytes()[..16], &key.as_bytes()[16..])?;
        serde_json::from_str(&text).map_err(|_| "播放响应解封后格式无效".into())
    }

    fn query(&self, pid: &str, scid: &str, now: u64, uuid: &str) -> String {
        let time = (now / 1000).to_string();
        let key = self.key();
        let mut fields = std::collections::BTreeMap::from([
            ("t", time.as_str()), ("dt", "android"), ("version", VERSION),
            ("uuid", uuid), ("pid", pid), ("scid", scid), ("re", "1"),
            ("sq", "10"), ("udid", key.as_str()),
        ]);
        let signing = fields.iter().rev().map(|(k, v)| format!("&{k}={v}")).collect::<String>()
            + "&" + QUERY_SALT;
        let sign = md5(&signing);
        fields.remove("udid");
        let mut url = reqwest::Url::parse("http://fixture.invalid/").unwrap();
        url.query_pairs_mut().extend_pairs(fields).append_pair("sign", &sign);
        url.query().unwrap().to_string()
    }

    fn candidates(&self, response: &Value) -> Result<Vec<CspPlay>, String> {
        let key = md5(&format!("{}{ENVELOPE_SALT}", self.key()));
        let mut plays = Vec::new();
        for entry in response.get("datas").and_then(Value::as_array).into_iter().flatten() {
            let Some(data) = entry.get("data").and_then(Value::as_str) else { continue };
            let text = decrypt(data, &key.as_bytes()[..16], &key.as_bytes()[16..])?;
            let object: Value = serde_json::from_str(&text).map_err(|_| "播放媒体响应格式无效")?;
            let url = ["playUrl", "url", "m3u8"].iter().find_map(|key| object.get(key).and_then(Value::as_str))
                .ok_or("播放响应没有媒体地址")?;
            let parsed = reqwest::Url::parse(url).map_err(|_| "播放响应媒体地址无效")?;
            if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none()
                || !parsed.username().is_empty() || parsed.password().is_some() {
                return Err("播放响应媒体地址无效".into());
            }
            let mut headers: Vec<(String, String)> = vec![("User-Agent".into(), MEDIA_UA.into())];
            if let Some(values) = object.get("header").and_then(Value::as_object) {
                for (name, value) in values {
                    let Some(value) = value.as_str() else { continue };
                    if reqwest::header::HeaderName::from_bytes(name.as_bytes()).is_err()
                        || reqwest::header::HeaderValue::from_str(value).is_err() {
                        return Err("播放响应请求头无效".into());
                    }
                    headers.retain(|(existing, _)| !name.eq_ignore_ascii_case(existing));
                    headers.push((name.to_string(), value.to_string()));
                }
            }
            plays.push(CspPlay { url: url.to_string(), headers, label: None });
        }
        if plays.is_empty() { return Err("当前剧集没有返回可播放地址".into()); }
        Ok(plays)
    }
}

impl Hxq {
    async fn playback_json(&self, session: &Session, base: &str, path: &str) -> Result<Value, String> {
        let mut request = self.client.client()?.get(format!("{base}{path}"));
        for (name, value) in session.headers(millis()?)? { request = request.header(name, value); }
        let mut response = request.send().await.map_err(|_| "播放解析请求未完成，请稍后重试")?;
        if !response.status().is_success() {
            return Err(format!("播放解析返回 HTTP {}", response.status().as_u16()));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| "播放解析响应未完整接收")? {
            if bytes.len().saturating_add(chunk.len()) > MAX_BODY { return Err("播放响应过长".into()); }
            bytes.extend_from_slice(&chunk);
        }
        let json: Value = serde_json::from_slice(&bytes).map_err(|_| "播放解析响应格式无效")?;
        if let Some(code) = json.get("rescode").and_then(Value::as_i64).filter(|code| *code != 0) {
            return Err(format!("当前剧集解析被源站拒绝（code={code}），请稍后重试或切换来源"));
        }
        session.envelope(json)
    }

    pub(super) async fn anonymous_play(&self, pid: &str) -> Result<Vec<CspPlay>, String> {
        self.anonymous_play_at(pid, super::BASE).await
    }

    // The private base seam lets loopback tests observe the same GET chain without
    // confusing an HTTPS proxy CONNECT request with the encrypted origin request.
    async fn anonymous_play_at(&self, pid: &str, base: &str) -> Result<Vec<CspPlay>, String> {
        let pid = pid.trim();
        if pid.is_empty() || pid.len() > 256 || !pid.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') {
            return Err("剧集标识无效，请重新选择".into());
        }
        let session = self.playback_session.get_or_init(Session::new).as_ref().map_err(Clone::clone)?;
        self.playback_json(session, base, "/api/common/configs").await?;
        let detail = self.playback_json(session, base, &format!("/api/series2/episode/detail?pid={pid}&refer={}",
            urlencoding::encode(super::CANDIDATE_SECRET))).await?;
        let item = detail.get("playItem").ok_or("当前剧集没有返回播放信息")?;
        if item.get("pid").and_then(Value::as_str).is_some_and(|returned| returned != pid) {
            return Err("播放响应与所选剧集不一致".into());
        }
        if item.pointer("/permission/allowPlay").is_some_and(|v| v.as_i64() == Some(0) || v.as_bool() == Some(false)) {
            return Err("当前剧集需要源站播放权限，请切换来源".into());
        }
        let scid = item.get("sources").and_then(Value::as_array).and_then(|a| a.first())
            .and_then(|s| s.get("scid")).and_then(Value::as_str).filter(|s| !s.is_empty())
            .ok_or("当前剧集没有返回可用线路")?;
        let uuid = random(32, b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")?;
        let query = session.query(pid, scid, millis()?, &uuid);
        let response = self.playback_json(session, base, &format!("/api/series/rslvV4?{query}")).await?;
        session.candidates(&response)
    }
}

#[cfg(test)]
#[path = "hxq_playback_tests.rs"]
mod tests;
