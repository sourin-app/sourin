//! Observe the real public credential paths through an in-memory keyring builder.
//! This binary never installs or calls a platform credential backend. Its tests
//! serialize environment changes even when invoked without --test-threads=1.

use keyring::credential::{Credential, CredentialApi, CredentialBuilderApi, CredentialPersistence};
use sourin_core::{pan::PanKind, pan_auth, proxy, sync};
use std::any::Any;
use std::collections::{BTreeSet, HashMap};
use std::ffi::OsString;
use std::sync::{Arc, Mutex, MutexGuard};

const VARIABLE: &str = "SOURIN_KEYRING_SERVICE";
const LEGACY: [&str; 4] = [
    "dsh-media-client-pan",
    "dsh-media-client-proxy",
    "dsh-media-client-sync",
    "dsh-media-client-credential-key",
];
const KINDS: [PanKind; 9] = [
    PanKind::Quark,
    PanKind::Uc,
    PanKind::Baidu,
    PanKind::Aliyun,
    PanKind::Pan123,
    PanKind::Pan115,
    PanKind::Tianyi,
    PanKind::Guangya,
    PanKind::Xunlei,
];
static ENVIRONMENT_LOCK: Mutex<()> = Mutex::new(());

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
struct Event {
    service: String,
    user: String,
    operation: &'static str,
}

#[derive(Default)]
struct RecordingStore {
    events: Mutex<Vec<Event>>,
    values: Mutex<HashMap<(String, String), Vec<u8>>>,
}

impl RecordingStore {
    fn record(&self, service: &str, user: &str, operation: &'static str) {
        self.events.lock().unwrap().push(Event {
            service: service.into(),
            user: user.into(),
            operation,
        });
    }
    fn events(&self) -> Vec<Event> {
        self.events.lock().unwrap().clone()
    }
}

struct RecordingBuilder(Arc<RecordingStore>);

impl CredentialBuilderApi for RecordingBuilder {
    fn build(
        &self,
        target: Option<&str>,
        service: &str,
        user: &str,
    ) -> keyring::Result<Box<Credential>> {
        assert_eq!(
            target, None,
            "public credential paths retain the default target"
        );
        self.0.record(service, user, "entry");
        Ok(Box::new(RecordingCredential {
            store: self.0.clone(),
            key: (service.into(), user.into()),
        }))
    }
    fn as_any(&self) -> &dyn Any {
        self
    }
    fn persistence(&self) -> CredentialPersistence {
        CredentialPersistence::ProcessOnly
    }
}

struct RecordingCredential {
    store: Arc<RecordingStore>,
    key: (String, String),
}

impl CredentialApi for RecordingCredential {
    fn set_password(&self, value: &str) -> keyring::Result<()> {
        self.store.record(&self.key.0, &self.key.1, "set_password");
        self.store
            .values
            .lock()
            .unwrap()
            .insert(self.key.clone(), value.as_bytes().to_vec());
        Ok(())
    }
    fn get_password(&self) -> keyring::Result<String> {
        self.store.record(&self.key.0, &self.key.1, "get_password");
        let value = self
            .store
            .values
            .lock()
            .unwrap()
            .get(&self.key)
            .cloned()
            .ok_or(keyring::Error::NoEntry)?;
        Ok(String::from_utf8(value).expect("only synthetic UTF-8 values are stored"))
    }
    fn set_secret(&self, value: &[u8]) -> keyring::Result<()> {
        self.store.record(&self.key.0, &self.key.1, "set_secret");
        self.store
            .values
            .lock()
            .unwrap()
            .insert(self.key.clone(), value.to_vec());
        Ok(())
    }
    fn get_secret(&self) -> keyring::Result<Vec<u8>> {
        self.store.record(&self.key.0, &self.key.1, "get_secret");
        self.store
            .values
            .lock()
            .unwrap()
            .get(&self.key)
            .cloned()
            .ok_or(keyring::Error::NoEntry)
    }
    fn delete_credential(&self) -> keyring::Result<()> {
        self.store
            .record(&self.key.0, &self.key.1, "delete_credential");
        self.store
            .values
            .lock()
            .unwrap()
            .remove(&self.key)
            .map(|_| ())
            .ok_or(keyring::Error::NoEntry)
    }
    fn as_any(&self) -> &dyn Any {
        self
    }
}

struct TestEnvironment {
    previous: Option<OsString>,
    _lock: MutexGuard<'static, ()>,
}

impl TestEnvironment {
    fn install(value: Option<&std::ffi::OsStr>) -> (Self, Arc<RecordingStore>) {
        let lock = ENVIRONMENT_LOCK
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let previous = std::env::var_os(VARIABLE);
        match value {
            Some(value) => std::env::set_var(VARIABLE, value),
            None => std::env::remove_var(VARIABLE),
        }
        let store = Arc::new(RecordingStore::default());
        keyring::set_default_credential_builder(Box::new(RecordingBuilder(store.clone())));
        (
            Self {
                previous,
                _lock: lock,
            },
            store,
        )
    }
}

impl Drop for TestEnvironment {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => std::env::set_var(VARIABLE, value),
            None => std::env::remove_var(VARIABLE),
        }
    }
}

fn credential(kind: PanKind) -> pan_auth::PanCredential {
    pan_auth::PanCredential {
        kind,
        account: "synthetic-account".into(),
        cookie: "synthetic=value".into(),
        saved_at: 123,
        expires_at: None,
    }
}

fn exercise_public_operations() {
    for user in [proxy::GLOBAL_PROXY, "legacy-provider"] {
        assert_eq!(proxy::get_proxy_password(user), None);
        proxy::set_proxy_password(user, "synthetic-proxy").unwrap();
        assert_eq!(
            proxy::get_proxy_password(user).as_deref(),
            Some("synthetic-proxy")
        );
        proxy::set_proxy_password(user, "").unwrap();
        assert_eq!(proxy::get_proxy_password(user), None);
        proxy::set_proxy_password(user, "synthetic-proxy").unwrap();
        proxy::clear_proxy_password(user).unwrap();
        assert_eq!(proxy::get_proxy_password(user), None);
    }
    assert_eq!(sync::webdav_credential::get("webdav"), None);
    assert_eq!(
        sync::webdav_credential::set("webdav", "synthetic-dav").unwrap(),
        "synthetic-dav"
    );
    assert_eq!(
        sync::webdav_credential::get("webdav").as_deref(),
        Some("synthetic-dav")
    );
    assert_eq!(sync::webdav_credential::set("webdav", "").unwrap(), "");
    assert_eq!(sync::webdav_credential::get("webdav"), None);
    sync::webdav_credential::set("webdav", "synthetic-dav").unwrap();
    sync::webdav_credential::clear("webdav").unwrap();
    assert_eq!(sync::webdav_credential::get("webdav"), None);

    assert!(!sync::credentials_passphrase::is_set());
    sync::credentials_passphrase::set("synthetic-passphrase").unwrap();
    assert!(sync::credentials_passphrase::is_set());
    assert_eq!(
        sync::credentials_passphrase::get().as_deref(),
        Some("synthetic-passphrase")
    );
    sync::credentials_passphrase::set("").unwrap();
    assert_eq!(sync::credentials_passphrase::get(), None);
    sync::credentials_passphrase::set("synthetic-passphrase").unwrap();
    sync::credentials_passphrase::clear().unwrap();
    assert!(!sync::credentials_passphrase::is_set());

    for kind in KINDS {
        let mut value = credential(kind);
        assert_eq!(pan_auth::load(kind), None);
        pan_auth::save(&value).unwrap();
        assert_eq!(pan_auth::load(kind), Some(value.clone()));
        value.cookie = " \t ".into();
        pan_auth::save(&value).unwrap();
        assert_eq!(pan_auth::load(kind), None);
        pan_auth::save(&credential(kind)).unwrap();
        pan_auth::clear(kind).unwrap();
        assert_eq!(pan_auth::load(kind), None);
    }
    assert_eq!(pan_auth::load(PanKind::Unknown), None);
    assert!(
        pan_auth::keyring_available(),
        "NoEntry responds from the selected backend"
    );
}

fn assert_actual_services(store: &RecordingStore, expected: &[String; 4], case: &str) {
    let events = store.events();
    println!(
        "credential_namespace_observation {}",
        serde_json::json!({
            "case": case, "events": events, "entryCount": events.iter().filter(|event| event.operation == "entry").count(),
            "platformBackendInstalled": false,
        })
    );
    let mut operations: [BTreeSet<&str>; 4] = std::array::from_fn(|_| BTreeSet::new());
    let mut users = BTreeSet::new();
    for event in &events {
        let family = match event.user.as_str() {
            "__global__" | "legacy-provider" => 1,
            "webdav" => 2,
            "credentials" => 3,
            "__probe__" => 0,
            user if user.starts_with("pan/") => 0,
            _ => panic!("unexpected actual credential user: {}", event.user),
        };
        assert_eq!(
            event.service, expected[family],
            "actual Entry/backend event: {event:?}"
        );
        operations[family].insert(event.operation);
        users.insert(event.user.clone());
    }
    let expected_operations =
        BTreeSet::from(["entry", "get_password", "set_password", "delete_credential"]);
    for actual in operations {
        assert_eq!(actual, expected_operations);
    }
    let mut expected_users = BTreeSet::from([
        "__global__".into(),
        "legacy-provider".into(),
        "webdav".into(),
        "credentials".into(),
        "__probe__".into(),
        "pan/unknown".into(),
    ]);
    expected_users.extend(KINDS.map(|kind| format!("pan/{}", kind.code())));
    assert_eq!(users, expected_users);
    assert!(
        store.values.lock().unwrap().is_empty(),
        "empty-input and explicit clear delete entries"
    );
    println!(
        "observed {} actual Entry/backend events for {} users",
        events.len(),
        users.len()
    );
}

#[test]
fn unset_override_preserves_legacy_services_and_users() {
    let (_environment, store) = TestEnvironment::install(None);
    exercise_public_operations();
    assert_actual_services(&store, &LEGACY.map(str::to_owned), "unset");
}

#[test]
fn valid_override_isolates_all_operations_and_preserves_raw_pan_name() {
    let (_environment, _) = TestEnvironment::install(None);
    for prefix in [
        "sourin-credential-test-unique",
        "  sourin-credential-测试  ",
    ] {
        std::env::set_var(VARIABLE, prefix);
        let store = Arc::new(RecordingStore::default());
        keyring::set_default_credential_builder(Box::new(RecordingBuilder(store.clone())));
        exercise_public_operations();
        let expected = [
            prefix.into(),
            format!("{prefix}-proxy"),
            format!("{prefix}-sync"),
            format!("{prefix}-credential-key"),
        ];
        assert_actual_services(&store, &expected, "valid");
    }
}

#[test]
fn missing_isolated_entries_do_not_read_or_delete_legacy_entries() {
    let (_environment, store) = TestEnvironment::install(None);
    proxy::set_proxy_password(proxy::GLOBAL_PROXY, "synthetic-proxy").unwrap();
    sync::webdav_credential::set("webdav", "synthetic-dav").unwrap();
    sync::credentials_passphrase::set("synthetic-passphrase").unwrap();
    for kind in KINDS {
        pan_auth::save(&credential(kind)).unwrap();
    }
    let before = store.values.lock().unwrap().clone();
    store.events.lock().unwrap().clear();
    std::env::set_var(VARIABLE, "sourin-credential-test-empty");
    assert_eq!(proxy::get_proxy_password(proxy::GLOBAL_PROXY), None);
    assert_eq!(sync::webdav_credential::get("webdav"), None);
    assert_eq!(sync::credentials_passphrase::get(), None);
    assert!(!sync::credentials_passphrase::is_set());
    for kind in KINDS {
        assert_eq!(pan_auth::load(kind), None);
        pan_auth::clear(kind).unwrap();
    }
    proxy::clear_proxy_password(proxy::GLOBAL_PROXY).unwrap();
    sync::webdav_credential::clear("webdav").unwrap();
    sync::credentials_passphrase::clear().unwrap();
    assert!(pan_auth::keyring_available());
    println!(
        "credential_namespace_observation {}",
        serde_json::json!({
            "case": "missing-isolated-entry", "events": store.events(), "legacyRowsBefore": before.len(),
            "legacyRowsAfter": store.values.lock().unwrap().len(), "platformBackendInstalled": false,
        })
    );
    assert_eq!(*store.values.lock().unwrap(), before);
    assert!(store
        .events()
        .iter()
        .all(|event| !LEGACY.contains(&event.service.as_str())));
}

#[test]
fn invalid_override_rejects_every_operation_before_entry_construction() {
    let (_environment, store) = TestEnvironment::install(None);
    let mut invalid = vec![
        ("empty", OsString::from("")),
        ("whitespace", OsString::from("   ")),
        (
            "unicode-whitespace",
            OsString::from("\u{2003}\u{00a0}\u{3000}"),
        ),
        ("whitespace-with-control", OsString::from(" \t\r\n ")),
        ("control", OsString::from("sourin-test\n")),
    ];
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStringExt;
        invalid.push(("non-unicode", OsString::from_wide(&[0xD800])));
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStringExt;
        invalid.push(("non-unicode", OsString::from_vec(vec![0xFF])));
    }
    for (case, value) in invalid {
        std::env::set_var(VARIABLE, value);
        let actual_os_value = std::env::var_os(VARIABLE).expect("configured test namespace");
        let actual_non_unicode = matches!(
            std::env::var(VARIABLE),
            Err(std::env::VarError::NotUnicode(_))
        );
        assert_eq!(actual_non_unicode, case == "non-unicode");
        #[cfg(windows)]
        let environment_representation = {
            use std::os::windows::ffi::OsStrExt;
            serde_json::json!({"encoding": "utf16-code-units", "units": actual_os_value.encode_wide().collect::<Vec<_>>()})
        };
        #[cfg(unix)]
        let environment_representation = {
            use std::os::unix::ffi::OsStrExt;
            serde_json::json!({"encoding": "os-bytes", "units": actual_os_value.as_bytes()})
        };
        let mut rejected = Vec::new();
        for user in [proxy::GLOBAL_PROXY, "legacy-provider"] {
            rejected.push(proxy::get_proxy_password(user).is_none());
            rejected.push(proxy::set_proxy_password(user, "synthetic-proxy").is_err());
            rejected.push(proxy::set_proxy_password(user, "").is_err());
            rejected.push(proxy::clear_proxy_password(user).is_err());
        }
        rejected.extend([
            sync::webdav_credential::get("webdav").is_none(),
            sync::webdav_credential::set("webdav", "synthetic-dav").is_err(),
            sync::webdav_credential::set("webdav", "").is_err(),
            sync::webdav_credential::clear("webdav").is_err(),
            sync::credentials_passphrase::get().is_none(),
            !sync::credentials_passphrase::is_set(),
            sync::credentials_passphrase::set("synthetic-passphrase").is_err(),
            sync::credentials_passphrase::set("").is_err(),
            sync::credentials_passphrase::clear().is_err(),
        ]);
        for kind in KINDS {
            let mut empty = credential(kind);
            empty.cookie.clear();
            rejected.extend([
                pan_auth::load(kind).is_none(),
                pan_auth::save(&credential(kind)).is_err(),
                pan_auth::save(&empty).is_err(),
                pan_auth::clear(kind).is_err(),
            ]);
        }
        rejected.extend([
            pan_auth::load(PanKind::Unknown).is_none(),
            !pan_auth::keyring_available(),
        ]);
        println!(
            "credential_namespace_observation {}",
            serde_json::json!({
                "case": case, "publicOperationCount": rejected.len(), "actualRejected": rejected,
            "actualEnvironmentNotUnicode": actual_non_unicode, "environmentRepresentation": environment_representation,
                "events": store.events(), "entryCount": store.events().iter().filter(|event| event.operation == "entry").count(),
                "platformBackendInstalled": false,
            })
        );
        assert_eq!(
            store.events(),
            Vec::<Event>::new(),
            "invalid overrides never construct or access entries"
        );
        assert!(
            rejected.iter().all(|value| *value),
            "all public operations reject the invalid namespace"
        );
        assert!(store.values.lock().unwrap().is_empty());
        println!(
            "rejected {} public operations with zero Entry/backend events",
            rejected.len()
        );
    }
}
