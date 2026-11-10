//! Bounded protobuf and crypto operations for the AppDrama protocol.
use aes::cipher::{block_padding::Pkcs7, BlockEncrypt, BlockEncryptMut, KeyInit, KeyIvInit};
use rsa::traits::PublicKeyParts;
use rsa::{pkcs8::DecodePublicKey, rand_core::OsRng, Pkcs1v15Encrypt, RsaPublicKey};
use serde_json::Value;

pub(super) const MAX_BODY: usize = 1024 * 1024;
const MAX_FIELDS: usize = 16384;

#[derive(Clone, Debug)]
pub(super) enum Failure {
    Unsupported(&'static str),
    Access(u16),
    Http(u16),
    Transport,
    Parse(&'static str),
    Business(i64),
    Restricted,
    PolicyChanged,
}

impl Failure {
    pub(super) fn public(&self) -> String {
        match self {
            Self::Unsupported(reason) => format!("unsupported: 当前协议不支持此操作（{reason}）"),
            Self::Access(code) => format!("HTTP {code}，当前请求被拒绝，请切换来源"),
            Self::Http(code) => format!("HTTP {code}，请稍后重试或切换来源"),
            Self::Business(code) => format!("上游返回 code={code}，未取得可用结果"),
            Self::Restricted => "unsupported: 当前内容声明了访问权限要求，请选择其他内容".into(),
            Self::Transport => "network: 请求未完成，请稍后重试或切换来源".into(),
            Self::Parse(reason) => format!("parse: 响应格式不符合协议（{reason}）"),
            Self::PolicyChanged => "network: 请求策略已变化，请重试".into(),
        }
    }
}

pub(super) type Result<T> = std::result::Result<T, Failure>;

pub(super) fn b64(data: &[u8]) -> String {
    crate::csp::shared::b64_encode(data)
}
pub(super) fn unb64(value: &str) -> Result<Vec<u8>> {
    if value.len() > MAX_BODY * 2 {
        return Err(Failure::Parse("Base64 大小"));
    }
    crate::csp::shared::b64_decode(value).map_err(|_| Failure::Parse("Base64"))
}

pub(super) fn varint(out: &mut Vec<u8>, mut value: u64) {
    while value >= 128 {
        out.push((value as u8 & 127) | 128);
        value >>= 7;
    }
    out.push(value as u8);
}
pub(super) fn number(out: &mut Vec<u8>, field: u64, value: u64) {
    varint(out, field << 3);
    varint(out, value);
}
pub(super) fn bytes(out: &mut Vec<u8>, field: u64, value: &[u8]) {
    varint(out, field << 3 | 2);
    varint(out, value.len() as u64);
    out.extend_from_slice(value);
}
pub(super) fn text(out: &mut Vec<u8>, field: u64, value: &str) {
    bytes(out, field, value.as_bytes());
}

#[derive(Clone, Copy)]
pub(super) enum Field<'a> {
    Number(u64),
    Bytes(&'a [u8]),
    Fixed,
}
pub(super) struct Message<'a> {
    fields: Vec<(u64, Field<'a>)>,
}

impl<'a> Message<'a> {
    pub(super) fn parse(input: &'a [u8]) -> Result<Self> {
        if input.len() > MAX_BODY {
            return Err(Failure::Parse("protobuf 大小"));
        }
        let mut at = 0;
        let mut fields = Vec::new();
        fn read(input: &[u8], at: &mut usize) -> Result<u64> {
            let mut value = 0u64;
            for shift in (0..70).step_by(7) {
                let byte = *input.get(*at).ok_or(Failure::Parse("protobuf 截断"))?;
                *at += 1;
                if shift == 63 && byte > 1 {
                    return Err(Failure::Parse("protobuf 数值溢出"));
                }
                value |= u64::from(byte & 127) << shift;
                if byte & 128 == 0 {
                    return Ok(value);
                }
            }
            Err(Failure::Parse("protobuf varint"))
        }
        while at < input.len() {
            if fields.len() == MAX_FIELDS {
                return Err(Failure::Parse("protobuf 字段数"));
            }
            let tag = read(input, &mut at)?;
            let field = tag >> 3;
            if field == 0 || field > 0x1fffffff {
                return Err(Failure::Parse("protobuf tag"));
            }
            match tag & 7 {
                0 => fields.push((field, Field::Number(read(input, &mut at)?))),
                2 => {
                    let size = usize::try_from(read(input, &mut at)?)
                        .map_err(|_| Failure::Parse("protobuf 长度"))?;
                    let end = at
                        .checked_add(size)
                        .ok_or(Failure::Parse("protobuf 长度"))?;
                    fields.push((
                        field,
                        Field::Bytes(input.get(at..end).ok_or(Failure::Parse("protobuf 截断"))?),
                    ));
                    at = end;
                }
                1 | 5 => {
                    at = at
                        .checked_add(if tag & 7 == 1 { 8 } else { 4 })
                        .ok_or(Failure::Parse("protobuf 长度"))?;
                    if at > input.len() {
                        return Err(Failure::Parse("protobuf 截断"));
                    }
                    fields.push((field, Field::Fixed));
                }
                _ => return Err(Failure::Parse("protobuf wire type")),
            }
        }
        Ok(Self { fields })
    }
    pub(super) fn integer(&self, number: u64) -> Result<Option<u64>> {
        if self
            .fields
            .iter()
            .any(|(field, value)| *field == number && !matches!(value, Field::Number(_)))
        {
            return Err(Failure::Parse("protobuf 数值类型"));
        }
        self.fields
            .iter()
            .rev()
            .find(|(field, _)| *field == number)
            .map(|(_, field)| match field {
                Field::Number(value) => Ok(*value),
                _ => Err(Failure::Parse("protobuf 数值类型")),
            })
            .transpose()
    }
    pub(super) fn int32(&self, number: u64) -> Result<Option<i32>> {
        self.integer(number)?
            .map(|value| {
                if value <= i32::MAX as u64 || value >= 0xffff_ffff_8000_0000 {
                    Ok(value as i32)
                } else {
                    Err(Failure::Parse("protobuf int32 范围"))
                }
            })
            .transpose()
    }
    pub(super) fn blob(&self, number: u64) -> Result<Option<&'a [u8]>> {
        if self
            .fields
            .iter()
            .any(|(field, value)| *field == number && !matches!(value, Field::Bytes(_)))
        {
            return Err(Failure::Parse("protobuf bytes 类型"));
        }
        self.fields
            .iter()
            .rev()
            .find(|(field, _)| *field == number)
            .map(|(_, field)| match field {
                Field::Bytes(value) => Ok(*value),
                _ => Err(Failure::Parse("protobuf bytes 类型")),
            })
            .transpose()
    }
    pub(super) fn string(&self, number: u64) -> Result<Option<&'a str>> {
        self.blob(number)?
            .map(|data| std::str::from_utf8(data).map_err(|_| Failure::Parse("protobuf UTF-8")))
            .transpose()
    }
    pub(super) fn merged_message(&self, number: u64) -> Result<Option<Message<'a>>> {
        let parts = self.repeated(number)?;
        if parts.is_empty() {
            return Ok(None);
        }
        // Only the consumed cover submessage uses this helper. Its two fields
        // are strings, so ordered field concatenation implements protobuf merge:
        // later singular scalar/string fields win; absent fields are retained.
        let mut fields = Vec::new();
        for part in parts {
            let parsed = Self::parse(part)?;
            if fields.len().saturating_add(parsed.fields.len()) > MAX_FIELDS {
                return Err(Failure::Parse("protobuf 合并字段数"));
            }
            fields.extend(parsed.fields);
        }
        Ok(Some(Self { fields }))
    }
    pub(super) fn repeated(&self, number: u64) -> Result<Vec<&'a [u8]>> {
        self.fields
            .iter()
            .filter(|(field, _)| *field == number)
            .map(|(_, field)| match field {
                Field::Bytes(value) => Ok(*value),
                _ => Err(Failure::Parse("protobuf repeated 类型")),
            })
            .collect()
    }
}

pub(super) fn api_data(input: &[u8]) -> Result<&[u8]> {
    let message = Message::parse(input)?;
    // Reference reads data directly, without a success-code equality branch.
    // Never invent 0/1/200 as this API's success code. The caller MUST validate
    // the expected submessage, not merely accept nonempty arbitrary data.
    let code = message.integer(1)?.unwrap_or(0) as i64;
    message
        .blob(3)?
        .filter(|data| !data.is_empty())
        .ok_or(Failure::Business(code))
}

pub(super) fn checked_public_key(public_key: &str) -> Result<RsaPublicKey> {
    if public_key.len() > 4096 {
        return Err(Failure::Parse("RSA 公钥大小"));
    }
    let der = unb64(public_key)?;
    if der.len() > 1024 {
        return Err(Failure::Parse("RSA 公钥大小"));
    }
    let key = RsaPublicKey::from_public_key_der(&der).map_err(|_| Failure::Parse("RSA 公钥"))?;
    // Only the retained reference's 1024-bit geometry is qualified here.
    if key.n().bits() != 1024 || key.e().bits() > 32 {
        return Err(Failure::Unsupported("RSA 公钥规格未确认"));
    }
    Ok(key)
}

pub(super) fn rsa_encrypt(public_key: &str, message: &[u8]) -> Result<String> {
    let key = checked_public_key(public_key)?;
    let ciphertext = key
        .encrypt(&mut OsRng, Pkcs1v15Encrypt, message)
        .map_err(|_| Failure::Parse("RSA 请求参数"))?;
    Ok(b64(&ciphertext))
}

pub(super) fn checked_page_total(value: Option<i32>) -> Result<(Option<u64>, Option<u32>)> {
    match value {
        Some(value) if value < 0 => Err(Failure::Parse("分页 total 不能为负")),
        None | Some(0) => Ok((None, None)),
        Some(value) => {
            let total = u64::try_from(value).map_err(|_| Failure::Parse("分页 total"))?;
            let pages = total.checked_add(20).ok_or(Failure::Parse("分页计算"))? / 21;
            Ok((
                Some(total),
                Some(u32::try_from(pages).map_err(|_| Failure::Parse("分页范围"))?),
            ))
        }
    }
}

pub(super) fn nonce(length: usize) -> Result<String> {
    use rsa::rand_core::RngCore;
    const ALPHABET: &[u8] = b"1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    if !(2..=64).contains(&length) {
        return Err(Failure::Parse("nonce 长度"));
    }
    let mut value = String::with_capacity(length);
    while value.len() < length - 1 {
        let mut byte = [0u8];
        OsRng
            .try_fill_bytes(&mut byte)
            .map_err(|_| Failure::Transport)?;
        // Uniform modulo 62; no semantic imitation of Java's weak RNG seed.
        if byte[0] < 248 {
            value.push(ALPHABET[(byte[0] % 62) as usize] as char);
        }
    }
    value.push('=');
    Ok(value)
}

pub(super) fn now() -> Result<u64> {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| Failure::Transport)?
        .as_millis()
        .try_into()
        .map_err(|_| Failure::Transport)
}

pub(super) fn ecb(key: &[u8], input: &[u8]) -> Result<Vec<u8>> {
    let padding = 16 - input.len() % 16;
    let mut out = input.to_vec();
    out.resize(input.len() + padding, padding as u8);
    macro_rules! encrypt {
        ($kind:ty) => {{
            let cipher =
                <$kind as KeyInit>::new_from_slice(key).map_err(|_| Failure::Parse("AES key"))?;
            for chunk in out.chunks_mut(16) {
                cipher.encrypt_block(aes::cipher::Block::<$kind>::from_mut_slice(chunk));
            }
        }};
    }
    match key.len() {
        16 => encrypt!(aes::Aes128),
        24 => encrypt!(aes::Aes192),
        32 => encrypt!(aes::Aes256),
        _ => return Err(Failure::Parse("AES key 长度")),
    }
    Ok(out)
}

pub(super) fn cbc_hex(key: &[u8; 16], input: &[u8]) -> Result<String> {
    let mut buffer = vec![0; input.len() + 16];
    buffer[..input.len()].copy_from_slice(input);
    let output = cbc::Encryptor::<aes::Aes128>::new_from_slices(key, key)
        .map_err(|_| Failure::Parse("AES CBC key"))?
        .encrypt_padded_mut::<Pkcs7>(&mut buffer, input.len())
        .map_err(|_| Failure::Parse("AES CBC"))?;
    Ok(output.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub(super) fn ordered_json(fields: &[(String, Value)]) -> Result<String> {
    if fields.len() > 64 {
        return Err(Failure::Parse("描述字段数"));
    }
    let mut names = std::collections::HashSet::new();
    let mut encoded = Vec::with_capacity(fields.len());
    for (key, value) in fields {
        if !names.insert(key) {
            return Err(Failure::Parse("重复描述字段"));
        }
        encoded.push(format!(
            "{}:{}",
            serde_json::to_string(key).map_err(|_| Failure::Parse("JSON key"))?,
            serde_json::to_string(value).map_err(|_| Failure::Parse("JSON value"))?
        ));
    }
    Ok(format!("{{{}}}", encoded.join(",")))
}

pub(super) fn public_params(
    header_key: &[u8; 16],
    descriptor: &[(String, Value)],
    proto: bool,
    public_key: &str,
    data_iv_raw: &[u8],
    time: u64,
    random: &str,
) -> Result<String> {
    let mut fields = descriptor.to_vec();
    if proto {
        let version = fields
            .iter()
            .find(|(key, _)| key == "vApp")
            .and_then(|(_, value)| value.as_str())
            .ok_or(Failure::Unsupported("桌面版本描述未确认"))?;
        let sig = rsa_encrypt(public_key, format!("{time}{random}{version}").as_bytes())?;
        let sig2_3 = b64(&ecb(data_iv_raw, format!("{time}{random}").as_bytes())?);
        if sig2_3.len() < 8 {
            return Err(Failure::Parse("sig2/sig3"));
        }
        fields.extend([
            (String::from("sig"), Value::String(sig)),
            (String::from("random_str"), Value::String(random.into())),
            (String::from("timestamp"), Value::Number(time.into())),
            (String::from("sig2"), Value::String(sig2_3[..8].into())),
            (String::from("sig3"), Value::String(sig2_3[8..].into())),
        ]);
    }
    let ciphertext = cbc_hex(header_key, ordered_json(&fields)?.as_bytes())?;
    Ok(format!("{{\"paramsData\":\"{ciphertext}\"}}"))
}

pub(super) fn rsa_request(
    public_key: &str,
    time: u64,
    random: &str,
    fake1: &str,
    fake2: &str,
) -> Result<Vec<u8>> {
    let sign = rsa_encrypt(public_key, format!("{time}{random}").as_bytes())?;
    let mut out = Vec::new();
    number(&mut out, 1, time);
    text(&mut out, 2, &sign);
    text(&mut out, 3, fake1);
    text(&mut out, 4, random);
    text(&mut out, 5, fake2);
    Ok(out)
}

pub(super) fn secure_request(
    key: &[u8],
    pairs_in_explicit_order: &[(String, String)],
    time: u64,
    random: &str,
    decoy: &str,
) -> Result<Vec<u8>> {
    // Caller supplies a separately qualified order; do not invent a global sort.
    let raw = pairs_in_explicit_order
        .iter()
        .filter(|(_, value)| !value.is_empty())
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("&");
    let encrypted = format!(
        "{random}{}",
        b64(&ecb(key, format!("{raw}{time}").as_bytes())?)
    );
    if encrypted.len() < 20 {
        return Err(Failure::Parse("SecureRequest 长度"));
    }
    let mut out = Vec::new();
    text(&mut out, 1, &encrypted[..20]);
    text(&mut out, 2, &encrypted[20..]);
    text(&mut out, 3, decoy);
    number(&mut out, 4, time);
    text(&mut out, 5, random);
    Ok(out)
}
