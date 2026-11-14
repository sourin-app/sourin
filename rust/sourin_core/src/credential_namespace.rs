//! A private data directory does not isolate the platform credential store.
//! Every credential family must honor the same explicitly configured namespace.

pub(crate) enum CredentialRole {
    Pan,
    Proxy,
    Sync,
    CredentialKey,
}

impl CredentialRole {
    fn suffix(&self) -> &'static str {
        match self {
            Self::Pan => "",
            Self::Proxy => "-proxy",
            Self::Sync => "-sync",
            Self::CredentialKey => "-credential-key",
        }
    }
}

pub(crate) fn service_name(legacy: &str, role: CredentialRole) -> Result<String, String> {
    match std::env::var("SOURIN_KEYRING_SERVICE") {
        Err(std::env::VarError::NotPresent) => Ok(legacy.to_owned()),
        Ok(value) if !value.trim().is_empty() && !value.chars().any(char::is_control) => {
            // Keep a valid pan override byte-for-byte compatible. Other roles
            // share its prefix while retaining independent credential entries.
            Ok(format!("{value}{}", role.suffix()))
        }
        _ => Err("凭据服务名无效".into()),
    }
}
