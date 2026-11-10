// The public web client uses protobuf and SHA-256 for anonymous decoding.
// Its published WASM output is reproduced here so playback needs no JS host.
// The fixed values identify that public client; they are not account credentials.
use ring::{digest, rand::{SecureRandom, SystemRandom}};

const APP: &str = "com.web.player";
const FINGER: &str = "WF-2c064bc5b3400788f31b848849bc3a60f835423ba2dfe69d7ea93974c216e4f2";
const PUBLIC_KEY: &str = "WEB-50a8e9c84a1dc05669a692ded99a2dac46527229e607a7be15db88dbc59059d1";
pub(super) const MAX_RESPONSE: usize = 1024 * 1024;

fn varint(out: &mut Vec<u8>, mut value: u64) {
    while value >= 128 {
        out.push((value as u8 & 127) | 128);
        value >>= 7;
    }
    out.push(value as u8);
}

fn number(out: &mut Vec<u8>, field: u64, value: u64) {
    varint(out, field << 3);
    varint(out, value);
}

fn string(out: &mut Vec<u8>, field: u64, value: &str) {
    varint(out, field << 3 | 2);
    varint(out, value.len() as u64);
    out.extend_from_slice(value.as_bytes());
}

fn hex(bytes: &[u8], uppercase: bool) -> String {
    let alphabet = if uppercase { b"0123456789ABCDEF" } else { b"0123456789abcdef" };
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(alphabet[(byte >> 4) as usize] as char);
        out.push(alphabet[(byte & 15) as usize] as char);
    }
    out
}

fn request_at(value: &str, line: &str, time: u64, nonce: &str) -> Vec<u8> {
    let input = format!("finger={FINGER}&id={APP}&nonce={nonce}&sk={PUBLIC_KEY}&time={time}&v=1");
    let sign = hex(digest::digest(&digest::SHA256, input.as_bytes()).as_ref(), true);
    let mut out = Vec::with_capacity(value.len() + line.len() + 160);
    string(&mut out, 1, value);
    string(&mut out, 2, line);
    number(&mut out, 3, time);
    string(&mut out, 4, nonce);
    string(&mut out, 5, &sign);
    string(&mut out, 6, APP);
    number(&mut out, 7, 1);
    out
}

pub(super) fn request(value: &str, line: &str) -> Result<Vec<u8>, String> {
    if value.len() > MAX_RESPONSE || line.len() > 1024 {
        return Err("播放地址参数过长".into());
    }
    let time = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| "无法读取播放请求时间")?.as_millis();
    let time = u64::try_from(time).map_err(|_| "播放请求时间无效")?;
    let mut nonce = [0u8; 16];
    SystemRandom::new().fill(&mut nonce).map_err(|_| "无法生成播放请求标识")?;
    Ok(request_at(value, line, time, &hex(&nonce, false)))
}

struct Reader<'a> { bytes: &'a [u8], at: usize }

impl<'a> Reader<'a> {
    fn varint(&mut self) -> Result<u64, String> {
        let mut value = 0u64;
        for shift in (0..70).step_by(7) {
            let byte = *self.bytes.get(self.at).ok_or("播放解析响应不完整")?;
            self.at += 1;
            if shift == 63 && byte > 1 { return Err("播放解析响应数值无效".into()); }
            value |= u64::from(byte & 127) << shift;
            if byte & 128 == 0 { return Ok(value); }
        }
        Err("播放解析响应数值无效".into())
    }

    fn bytes(&mut self, length: usize) -> Result<&'a [u8], String> {
        let end = self.at.checked_add(length).ok_or("播放解析响应长度无效")?;
        let bytes = self.bytes.get(self.at..end).ok_or("播放解析响应不完整")?;
        self.at = end;
        Ok(bytes)
    }

    fn text(&mut self) -> Result<String, String> {
        let length = usize::try_from(self.varint()?).map_err(|_| "播放解析响应长度无效")?;
        let bytes = self.bytes(length)?;
        String::from_utf8(bytes.to_vec()).map_err(|_| "播放解析响应文本无效".into())
    }

    fn skip(&mut self, wire: u64) -> Result<(), String> {
        match wire {
            0 => { self.varint()?; }
            1 => { self.bytes(8)?; }
            2 => {
                let length = usize::try_from(self.varint()?).map_err(|_| "播放解析响应长度无效")?;
                self.bytes(length)?;
            }
            5 => { self.bytes(4)?; }
            _ => return Err("播放解析响应格式无效".into()),
        }
        Ok(())
    }
}

pub(super) fn response(bytes: &[u8]) -> Result<String, String> {
    if bytes.len() > MAX_RESPONSE { return Err("播放解析响应过长".into()); }
    let mut reader = Reader { bytes, at: 0 };
    let mut code = 0;
    let mut message = String::new();
    let mut url = String::new();
    while reader.at < bytes.len() {
        let key = reader.varint()?;
        let (field, wire) = (key >> 3, key & 7);
        if field == 0 { return Err("播放解析响应格式无效".into()); }
        match (field, wire) {
            (1, 0) => code = reader.varint()?,
            (2, 2) => message = reader.text()?,
            (3, 2) => url = reader.text()?,
            (1, _) | (2, _) | (3, _) => return Err("播放解析响应格式无效".into()),
            _ => reader.skip(wire)?,
        }
    }
    if code != 1 {
        // Preserve the server's access decision without reflecting URLs or tokens.
        let restriction = [
            ("PLATFORM_NOT_ALLOWED", "当前线路仅支持源站指定客户端，请切换线路"),
            ("LOGIN_REQUIRED", "当前线路需要源站账号，请切换线路"),
            ("VIP_REQUIRED", "当前线路需要源站会员权限，请切换线路"),
        ].into_iter().find(|(tag, _)| message.trim() == *tag);
        return Err(restriction.map(|(_, text)| text.to_string())
            .unwrap_or_else(|| format!("播放地址解析失败（code={code}）")));
    }
    let parsed = reqwest::Url::parse(url.trim()).map_err(|_| "播放解析没有返回有效媒体地址")?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none()
        || !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("播放解析没有返回有效媒体地址".into());
    }
    Ok(url.trim().to_string())
}

#[cfg(test)]
#[path = "yun_duo_decode_tests.rs"]
mod tests;
