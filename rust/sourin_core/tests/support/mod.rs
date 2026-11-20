// T38 account diagnostics consume only an explicitly selected task snapshot.
// No application data or plugin directory is discovered implicitly.
// Existing #[ignore] attributes remain the opt-in for the network diagnostics.
// Missing inputs are errors, not successful early returns.
#![allow(dead_code)]

pub mod t38_fixture;

/// Preserve the diagnostic gate API; fail before copying if no fixture is set.
pub fn real_creds_required() -> Option<&'static str> {
    let fixture = t38_fixture::T38Fixture::from_env()
        .expect("T38 requires an explicit SOURIN_T38_FIXTURE_ROOT snapshot");
    fixture
        .require_store()
        .expect("T38 fixture requires plugins/.data/srca.json");
    None
}

/// The caller's existing ignored-test opt-in still governs network execution.
pub fn real_creds_required_echo(tag: &str) -> Option<&'static str> {
    let result = real_creds_required();
    println!(
        "[T38:{tag}] explicit fixture selected; this opted-in diagnostic uses the real network login chain"
    );
    result
}
