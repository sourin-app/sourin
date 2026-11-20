//! Run this std-only helper target directly; no account probe is executed.
#[path = "mod.rs"]
mod support;

use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::Path;
use std::process::Command;
use support::t38_fixture::{ProbeWorkspace, T38Fixture, FIXTURE_ROOT_ENV};

fn input(root: &ProbeWorkspace) -> T38Fixture {
    T38Fixture::from_input(Some(root.path().as_os_str())).unwrap()
}

fn snapshot() -> ProbeWorkspace {
    let root = ProbeWorkspace::new("fixture-input").unwrap();
    fs::create_dir_all(root.path().join("plugins/.data")).unwrap();
    fs::create_dir(root.path().join("reference")).unwrap();
    fs::write(
        root.path().join("plugins/srca.js"),
        "deployed synthetic fixture",
    )
    .unwrap();
    fs::write(
        root.path().join("reference/srca.js"),
        "reference synthetic fixture",
    )
    .unwrap();
    fs::write(
        root.path().join("plugins/.data/srca.json"),
        br#"{"credentials":"synthetic-only","session":"fixture-only"}"#,
    )
    .unwrap();
    root
}

#[test]
fn a_missing_input_is_a_real_child_error_before_input_io() {
    const CHILD: &str = "SOURIN_T38_HELPER_MISSING_CHILD";
    if std::env::var_os(CHILD).is_some() {
        // No path exists to read here: from_env must fail at input selection.
        match T38Fixture::from_env() {
            Err(error) if error.kind() == io::ErrorKind::InvalidInput => {
                eprintln!("PRE_INPUT_IO_ERROR: {error}");
                std::process::exit(23);
            }
            _ => std::process::exit(0),
        }
    }
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "a_missing_input_is_a_real_child_error_before_input_io",
            "--nocapture",
        ])
        .env_remove(FIXTURE_ROOT_ENV)
        .env(CHILD, "1")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(23));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("PRE_INPUT_IO_ERROR: SOURIN_T38_FIXTURE_ROOT must be set explicitly"));
    println!("missing-input child exit=23; {stderr}");
}

#[test]
fn b_bad_root_syntax_precedes_filesystem_lookup() {
    for value in [
        "",
        "  ",
        "relative-input",
        "./relative",
        "../relative",
        "bad\ninput",
    ] {
        assert_eq!(
            T38Fixture::from_input(Some(OsStr::new(value)))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidInput
        );
    }
    let root = ProbeWorkspace::new("root-syntax").unwrap();
    // Intermediate directory is absent. Metadata-first behavior would be NotFound.
    for suffix in [
        "/absent/./child",
        "/absent/../child",
        "\\absent\\.\\child",
        "\\absent\\..\\child",
    ] {
        let value = format!("{}{suffix}", root.path().display());
        assert_eq!(
            T38Fixture::from_input(Some(OsStr::new(&value)))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidInput
        );
    }
}

#[test]
fn c_missing_roots_and_required_members_are_errors() {
    let root = ProbeWorkspace::new("missing-files").unwrap();
    let absent = root.path().join("absent");
    assert_eq!(
        T38Fixture::from_input(Some(absent.as_os_str()))
            .unwrap_err()
            .kind(),
        io::ErrorKind::NotFound
    );
    let file = root.path().join("not-a-directory");
    fs::write(&file, b"synthetic").unwrap();
    assert_eq!(
        T38Fixture::from_input(Some(file.as_os_str()))
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidInput
    );
    let fixture = input(&root);
    assert_eq!(
        fixture.read_deployed_source().unwrap_err().kind(),
        io::ErrorKind::NotFound
    );
    assert_eq!(
        fixture.read_reference_source().unwrap_err().kind(),
        io::ErrorKind::NotFound
    );
    assert_eq!(
        fixture.require_store().unwrap_err().kind(),
        io::ErrorKind::NotFound
    );
    assert_eq!(
        fixture.copy_store("missing-store").unwrap_err().kind(),
        io::ErrorKind::NotFound
    );
    assert_eq!(
        fixture.copy_plugins("missing-plugins").unwrap_err().kind(),
        io::ErrorKind::NotFound
    );
}

#[test]
fn d_member_escape_and_nonregular_file_are_errors() {
    let root = snapshot();
    let fixture = input(&root);
    for member in [
        "",
        ".",
        "../outside",
        "plugins/../reference/srca.js",
        "plugins/./srca.js",
        "plugins\\..\\outside",
        "C:/outside",
        "/outside",
        "plugins/srca.js:stream",
    ] {
        assert_eq!(
            fixture.read_member(member).unwrap_err().kind(),
            io::ErrorKind::InvalidInput,
            "member: {member}"
        );
    }
    assert_eq!(
        fixture.read_member("plugins/.data").unwrap_err().kind(),
        io::ErrorKind::InvalidInput
    );
}

struct RestorePermissions {
    path: std::path::PathBuf,
    permissions: fs::Permissions,
}
impl Drop for RestorePermissions {
    fn drop(&mut self) {
        fs::set_permissions(&self.path, self.permissions.clone()).unwrap();
    }
}

#[test]
fn e_explicit_env_reads_only_selected_synthetic_fixture() {
    const CHILD: &str = "SOURIN_T38_HELPER_EXPLICIT_CHILD";
    if std::env::var_os(CHILD).is_some() {
        let fixture = T38Fixture::from_env().unwrap();
        assert_eq!(
            fixture.read_deployed_source().unwrap(),
            "deployed synthetic fixture"
        );
        assert_eq!(
            fixture.read_reference_source().unwrap(),
            "reference synthetic fixture"
        );
        assert_eq!(support::real_creds_required(), None);
        println!("EXPLICIT_FIXTURE_READ_OK");
        return;
    }
    let root = snapshot();
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "e_explicit_env_reads_only_selected_synthetic_fixture",
            "--nocapture",
        ])
        .env(FIXTURE_ROOT_ENV, root.path())
        .env(CHILD, "1")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("EXPLICIT_FIXTURE_READ_OK"));
    println!("explicit-fixture child exit=0");
}

#[test]
fn f_readonly_source_bytes_survive_unique_writable_copy_lifecycle() {
    let root = snapshot();
    let source = root.path().join("plugins/.data/srca.json");
    let before = fs::read(&source).unwrap();
    let original_permissions = fs::metadata(&source).unwrap().permissions();
    let _restore = RestorePermissions {
        path: source.clone(),
        permissions: original_permissions.clone(),
    };
    let mut readonly = original_permissions;
    readonly.set_readonly(true);
    fs::set_permissions(&source, readonly).unwrap();
    let fixture = input(&root);
    let first = fixture.copy_store("same-tag").unwrap();
    let second = fixture.copy_store("same-tag").unwrap();
    let first_path = first.path().to_path_buf();
    let second_path = second.path().to_path_buf();
    assert_ne!(first_path, second_path);
    assert!(!first_path.starts_with(root.path()));
    assert_eq!(fs::read(first_path.join("srca.json")).unwrap(), before);
    assert!(!fs::metadata(first_path.join("srca.json"))
        .unwrap()
        .permissions()
        .readonly());
    fs::write(first_path.join("srca.json"), b"copy changed").unwrap();
    assert_eq!(fs::read(&source).unwrap(), before);
    assert!(fs::metadata(&source).unwrap().permissions().readonly());
    drop(first);
    assert!(!first_path.exists());
    assert!(second_path.is_dir());
    assert_eq!(fs::read(second_path.join("srca.json")).unwrap(), before);
    drop(second);
    assert!(!second_path.exists());
    assert_eq!(fs::read(&source).unwrap(), before);
}

#[test]
fn g_plugin_tree_copy_is_private_and_cleans_only_itself() {
    let root = snapshot();
    fs::create_dir(root.path().join("plugins/nested")).unwrap();
    fs::write(
        root.path().join("plugins/nested/marker.txt"),
        b"nested synthetic",
    )
    .unwrap();
    let fixture = input(&root);
    let workspace = fixture.copy_plugins("plugin-tree").unwrap();
    let path = workspace.path().to_path_buf();
    assert_eq!(
        fs::read(path.join("nested/marker.txt")).unwrap(),
        b"nested synthetic"
    );
    fs::write(path.join(".data/srca.json"), b"private mutation").unwrap();
    assert_ne!(
        fs::read(root.path().join("plugins/.data/srca.json")).unwrap(),
        b"private mutation"
    );
    drop(workspace);
    assert!(!path.exists());
    assert_eq!(
        fs::read(root.path().join("plugins/nested/marker.txt")).unwrap(),
        b"nested synthetic"
    );
}

fn directory_link(target: &Path, link: &Path) {
    #[cfg(windows)]
    {
        let output = Command::new("cmd.exe")
            .args(["/C", "mklink", "/J"])
            .arg(link)
            .arg(target)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "junction creation failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        use std::os::windows::fs::MetadataExt;
        assert_ne!(
            fs::symlink_metadata(link).unwrap().file_attributes() & 0x400,
            0
        );
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(target, link).unwrap();
}

fn remove_directory_link(link: &Path) {
    #[cfg(windows)]
    fs::remove_dir(link).unwrap();
    #[cfg(unix)]
    fs::remove_file(link).unwrap();
}

#[test]
fn h_junction_root_and_ancestor_escape_are_errors() {
    let owner = ProbeWorkspace::new("junction-root").unwrap();
    let target = snapshot();
    fs::create_dir(target.path().join("child")).unwrap();
    let link = owner.path().join("input-link");
    directory_link(target.path(), &link);
    assert_eq!(
        T38Fixture::from_input(Some(link.as_os_str()))
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidInput
    );
    let child = link.join("child");
    assert_eq!(
        T38Fixture::from_input(Some(child.as_os_str()))
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidInput
    );
    remove_directory_link(&link);
    assert!(target.path().join("plugins/srca.js").is_file());
    println!("real directory junction/symlink rejected for root and ancestor");
}

#[test]
fn i_junction_member_and_copy_tree_escape_are_errors() {
    let root = snapshot();
    let target = ProbeWorkspace::new("junction-outside").unwrap();
    fs::write(
        target.path().join("outside.txt"),
        b"outside synthetic marker",
    )
    .unwrap();
    let link = root.path().join("plugins/escape");
    directory_link(target.path(), &link);
    let fixture = input(&root);
    assert_eq!(
        fixture
            .read_member("plugins/escape/outside.txt")
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidInput
    );
    assert_eq!(
        fixture.copy_plugins("escape-tree").unwrap_err().kind(),
        io::ErrorKind::InvalidInput
    );
    remove_directory_link(&link);
    assert_eq!(
        fs::read(target.path().join("outside.txt")).unwrap(),
        b"outside synthetic marker"
    );
    println!("real directory junction/symlink rejected for member read and tree copy");
}

#[test]
fn j_workspace_tag_escape_and_broad_root_are_errors() {
    for tag in ["", "../escape", "a/b", "a\\b", "a:b", ".", "two words"] {
        assert_eq!(
            ProbeWorkspace::new(tag).unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }
    let temp = fs::canonicalize(std::env::temp_dir()).unwrap();
    assert_eq!(
        T38Fixture::from_input(Some(temp.as_os_str()))
            .unwrap_err()
            .kind(),
        io::ErrorKind::InvalidInput
    );
}

#[test]
fn k_concurrent_workspaces_do_not_share_or_delete_a_peer() {
    let handles: Vec<_> = (0..4)
        .map(|_| {
            std::thread::spawn(|| {
                let workspace = ProbeWorkspace::new("concurrent").unwrap();
                fs::write(workspace.path().join("marker.txt"), b"owned").unwrap();
                workspace
            })
        })
        .collect();
    let workspaces: Vec<_> = handles
        .into_iter()
        .map(|handle| handle.join().unwrap())
        .collect();
    let paths: std::collections::HashSet<_> = workspaces
        .iter()
        .map(|workspace| workspace.path().to_path_buf())
        .collect();
    assert_eq!(paths.len(), 4);
    assert!(paths.iter().all(|path| path.join("marker.txt").is_file()));
    drop(workspaces);
    assert!(paths.iter().all(|path| !path.exists()));
}
