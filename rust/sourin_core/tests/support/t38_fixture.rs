//! Explicit T38 fixture inputs. This module never discovers application data.
//!
//! SOURIN_T38_FIXTURE_ROOT must name an absolute task-owned snapshot containing:
//!   plugins/srca.js, plugins/.data/srca.json, reference/srca.js.
//! Sources are read-only inputs; providers receive only uniquely owned copies.
#![allow(dead_code)]

use std::env;
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub const FIXTURE_ROOT_ENV: &str = "SOURIN_T38_FIXTURE_ROOT";
static NEXT_WORKSPACE: AtomicU64 = AtomicU64::new(0);

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

fn reject_link(path: &Path) -> io::Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path)?;
    #[cfg(windows)]
    let is_reparse = {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    };
    #[cfg(not(windows))]
    let is_reparse = false;
    if metadata.file_type().is_symlink() || is_reparse {
        return Err(invalid("T38 fixture symlink or junction is not an input"));
    }
    Ok(metadata)
}

fn validate_absolute(path: &Path) -> io::Result<()> {
    let value = path
        .to_str()
        .ok_or_else(|| invalid("T38 fixture root must be Unicode"))?;
    if value.trim().is_empty() || value.chars().any(char::is_control) {
        return Err(invalid(
            "T38 fixture root must be nonempty and contain no control characters",
        ));
    }
    if value
        .split(['/', '\\'])
        .any(|part| part == "." || part == "..")
    {
        return Err(invalid("T38 fixture root must not contain dot traversal"));
    }
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir | Component::CurDir))
    {
        return Err(invalid(
            "T38 fixture root must be absolute without dot traversal",
        ));
    }
    #[cfg(windows)]
    if !matches!(path.components().next(), Some(Component::Prefix(prefix))
        if matches!(prefix.kind(), std::path::Prefix::Disk(_) | std::path::Prefix::VerbatimDisk(_)))
    {
        return Err(invalid("T38 fixture root must use a local disk path"));
    }
    Ok(())
}

fn validate_relative(path: &Path) -> io::Result<()> {
    if path.to_str().is_some_and(|value| {
        value
            .split(['/', '\\'])
            .any(|part| part == "." || part == "..")
    }) {
        return Err(invalid("T38 fixture member must not contain dot traversal"));
    }
    if path.as_os_str().is_empty()
        || path
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Err(invalid(
            "T38 fixture member must be a nonempty relative path without traversal",
        ));
    }
    // Reject Windows alternate streams and separator syntax on every platform.
    if path.components().any(|part| matches!(part, Component::Normal(name)
        if name.to_str().is_none_or(|value| value.contains(':') || value.contains('\\') || value.chars().any(char::is_control)))) {
        return Err(invalid("T38 fixture member contains nonportable path syntax"));
    }
    Ok(())
}

#[derive(Debug)]
pub struct T38Fixture {
    root: PathBuf,
}

impl T38Fixture {
    pub fn from_env() -> io::Result<Self> {
        let value = env::var_os(FIXTURE_ROOT_ENV);
        Self::from_input(value.as_deref())
    }

    /// Input presence and syntax are checked before the first filesystem access.
    pub fn from_input(input: Option<&OsStr>) -> io::Result<Self> {
        let input =
            input.ok_or_else(|| invalid("SOURIN_T38_FIXTURE_ROOT must be set explicitly"))?;
        let path = Path::new(input);
        validate_absolute(path)?;
        let mut ancestor = PathBuf::new();
        for part in path.components() {
            ancestor.push(part.as_os_str());
            if matches!(part, Component::Normal(_)) {
                reject_link(&ancestor)?;
            }
        }
        if !reject_link(path)?.is_dir() {
            return Err(invalid("T38 fixture root must be a directory"));
        }
        let root = fs::canonicalize(path)?;
        if fs::canonicalize(env::temp_dir())?.starts_with(&root) {
            return Err(invalid(
                "T38 fixture root must not contain the system temporary directory",
            ));
        }
        Ok(Self { root })
    }

    fn checked(&self, relative: &Path) -> io::Result<PathBuf> {
        validate_relative(relative)?;
        let mut candidate = self.root.clone();
        for part in relative.components() {
            candidate.push(part.as_os_str());
            reject_link(&candidate)?;
        }
        let canonical = fs::canonicalize(candidate)?;
        if !canonical.starts_with(&self.root) {
            return Err(invalid("T38 fixture member escapes the selected root"));
        }
        Ok(canonical)
    }

    fn input_file(&self, relative: &Path) -> io::Result<PathBuf> {
        let path = self.checked(relative)?;
        if !reject_link(&path)?.is_file() {
            return Err(invalid("T38 fixture member must be a regular file"));
        }
        Ok(path)
    }

    pub fn read_member(&self, relative: &str) -> io::Result<String> {
        fs::read_to_string(self.input_file(Path::new(relative))?)
    }

    pub fn read_reference_source(&self) -> io::Result<String> {
        self.read_member("reference/srca.js")
    }

    pub fn read_deployed_source(&self) -> io::Result<String> {
        self.read_member("plugins/srca.js")
    }

    pub fn require_store(&self) -> io::Result<()> {
        self.input_file(Path::new("plugins/.data/srca.json"))
            .map(|_| ())
    }

    pub fn copy_store(&self, tag: &str) -> io::Result<ProbeWorkspace> {
        let source = self.input_file(Path::new("plugins/.data/srca.json"))?;
        let workspace = self.workspace(tag)?;
        copy_new_file(&source, &workspace.path().join("srca.json"))?;
        Ok(workspace)
    }

    pub fn copy_plugins(&self, tag: &str) -> io::Result<ProbeWorkspace> {
        let source = self.checked(Path::new("plugins"))?;
        if !reject_link(&source)?.is_dir() {
            return Err(invalid("T38 plugins fixture must be a directory"));
        }
        // The account-dependent assertions require this selected snapshot input.
        self.require_store()?;
        self.input_file(Path::new("plugins/srca.js"))?;
        let workspace = self.workspace(tag)?;
        if workspace.path().starts_with(&self.root) {
            return Err(invalid(
                "T38 workspace must be outside the fixture input root",
            ));
        }
        self.copy_tree(Path::new("plugins"), workspace.path())?;
        Ok(workspace)
    }

    fn workspace(&self, tag: &str) -> io::Result<ProbeWorkspace> {
        if fs::canonicalize(env::temp_dir())?.starts_with(&self.root) {
            return Err(invalid(
                "T38 workspace must be outside the fixture input root",
            ));
        }
        ProbeWorkspace::new(tag)
    }

    fn copy_tree(&self, relative: &Path, destination: &Path) -> io::Result<()> {
        for entry in fs::read_dir(self.checked(relative)?)? {
            let entry = entry?;
            let child = relative.join(entry.file_name());
            let source = self.checked(&child)?;
            let metadata = reject_link(&source)?;
            let target = destination.join(entry.file_name());
            if metadata.is_dir() {
                fs::create_dir(&target)?;
                self.copy_tree(&child, &target)?;
            } else if metadata.is_file() {
                copy_new_file(&source, &target)?;
            } else {
                return Err(invalid("T38 fixture tree contains a nonregular member"));
            }
        }
        Ok(())
    }
}

fn copy_new_file(source: &Path, destination: &Path) -> io::Result<()> {
    // Do not propagate the snapshot's read-only permissions to writable copies.
    let mut input = File::open(source)?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)?;
    io::copy(&mut input, &mut output)?;
    Ok(())
}

/// Owns exactly the directory created by this value; never deletes an input.
#[derive(Debug)]
pub struct ProbeWorkspace {
    root: PathBuf,
}

impl ProbeWorkspace {
    pub fn new(tag: &str) -> io::Result<Self> {
        if tag.is_empty()
            || !tag
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
        {
            return Err(invalid(
                "T38 workspace tag must be alphanumeric, dash or underscore",
            ));
        }
        let temp = fs::canonicalize(env::temp_dir())?;
        let tick = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| invalid("T38 workspace clock is before the epoch"))?
            .as_nanos();
        for _ in 0..32 {
            let sequence = NEXT_WORKSPACE.fetch_add(1, Ordering::Relaxed);
            let root = temp.join(format!(
                "sourin-t38-{tag}-{}-{tick}-{sequence}",
                std::process::id()
            ));
            match fs::create_dir(&root) {
                Ok(()) => return Ok(Self { root }),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "T38 unique workspace attempts exhausted",
        ))
    }

    pub fn path(&self) -> &Path {
        &self.root
    }
}

impl Drop for ProbeWorkspace {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.root) {
            eprintln!("[T38] owned workspace cleanup failed: {:?}", error.kind());
        }
    }
}
