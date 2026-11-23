pub(crate) mod backup;
use crate::Result;
use chrono::NaiveDate;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Component, Path, PathBuf},
    sync::Mutex,
};

const NOTE_BYTES: usize = 1024 * 1024;
const NOTE_LIMIT: usize = 2000;
const TITLE_BYTES: u64 = 4096;
const BACKUP_LIMIT: usize = 50;
static WRITER: Mutex<()> = Mutex::new(());

#[derive(Serialize)]
pub(crate) struct NoteSummary {
    id: String,
    title: String,
    modified: u64,
}
#[derive(Serialize, Deserialize)]
pub(crate) struct NoteDocument {
    pub(crate) id: String,
    pub(crate) text: String,
    pub(crate) revision: String,
}
#[derive(Serialize)]
pub(crate) struct NoteList {
    directory: String,
    notes: Vec<NoteSummary>,
}

fn root(database: &str) -> Result<PathBuf> {
    let root = Path::new(database)
        .parent()
        .ok_or("Missing notes directory")?
        .join("Notes");
    ensure_dir(&root)?;
    Ok(root)
}
fn ensure_dir(path: &Path) -> Result<()> {
    if path.exists() {
        let info = fs::symlink_metadata(path)?;
        if !info.is_dir() || info.file_type().is_symlink() {
            return Err("Notes folders cannot be symbolic links".into());
        }
        return Ok(());
    }
    fs::DirBuilder::new().mode(0o700).create(path)?;
    Ok(())
}
fn note_path(root: &Path, id: &str) -> Result<PathBuf> {
    if id.len() > 200 || !id.ends_with(".md") {
        return Err("Choose a Markdown note".into());
    }
    let parts: Vec<_> = Path::new(id).components().collect();
    if parts.is_empty()
        || parts.len() > 2
        || parts.iter().any(|c| !matches!(c, Component::Normal(_)))
        || (parts.len() == 2 && parts[0].as_os_str() != "Daily")
    {
        return Err("Note path must stay inside the notes folder".into());
    }
    if id.starts_with('.') || id.contains("/.") {
        return Err("Hidden paths are reserved for note recovery".into());
    }
    if parts.len() == 2 {
        ensure_dir(&root.join("Daily"))?;
    }
    let path = root.join(id);
    if let Ok(info) = fs::symlink_metadata(&path)
        && (!info.is_file() || info.file_type().is_symlink())
    {
        return Err("A note must be a regular Markdown file".into());
    }
    Ok(path)
}
fn read_text(path: &Path) -> Result<String> {
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take((NOTE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > NOTE_BYTES {
        return Err(
            "This note exceeds the 1 MiB editor limit. The original file was not changed.".into(),
        );
    }
    Ok(String::from_utf8(bytes)?)
}
fn revision(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}
fn title(text: &str, id: &str) -> String {
    text.lines()
        .find_map(|line| line.strip_prefix("# "))
        .map(|s| s.chars().take(200).collect::<String>())
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| id.trim_end_matches(".md").to_string())
}
fn random_id() -> String {
    let mut bytes = [0u8; 16];
    rand::rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn note_ids(database: &str) -> Result<Vec<String>> {
    let root = root(database)?;
    let mut ids = Vec::new();
    for (directory, prefix) in [(root.clone(), ""), (root.join("Daily"), "Daily/")] {
        if !directory.exists() {
            continue;
        }
        ensure_dir(&directory)?;
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            if name.starts_with('.') || !name.ends_with(".md") {
                continue;
            }
            if ids.len() >= NOTE_LIMIT {
                return Err(
                    "Notes folder exceeds the 2,000-note list limit. Files were not changed."
                        .into(),
                );
            }
            let id = format!("{prefix}{name}");
            note_path(&root, &id)?;
            ids.push(id);
        }
    }
    ids.sort();
    Ok(ids)
}
pub(crate) fn list(database: &str) -> Result<NoteList> {
    let root = root(database)?;
    let mut notes = Vec::new();
    for id in note_ids(database)? {
        let path = note_path(&root, &id)?;
        let info = fs::metadata(&path)?;
        let mut bytes = Vec::new();
        fs::File::open(&path)?
            .take(TITLE_BYTES)
            .read_to_end(&mut bytes)?;
        notes.push(NoteSummary {
            title: title(&String::from_utf8_lossy(&bytes), &id),
            id,
            modified: info
                .modified()?
                .duration_since(std::time::UNIX_EPOCH)?
                .as_secs(),
        });
    }
    notes.sort_by(|a, b| b.modified.cmp(&a.modified).then(a.id.cmp(&b.id)));
    Ok(NoteList {
        directory: root.to_string_lossy().into_owned(),
        notes,
    })
}
pub(crate) fn open(database: &str, id: &str) -> Result<NoteDocument> {
    let path = note_path(&root(database)?, id)?;
    let text = read_text(&path)?;
    Ok(NoteDocument {
        id: id.into(),
        revision: revision(&text),
        text,
    })
}
pub(crate) fn new(database: &str, day: Option<&str>) -> Result<NoteDocument> {
    let (id, title) = if let Some(day) = day {
        let date = NaiveDate::parse_from_str(day, "%Y-%m-%d")?;
        if date.format("%Y-%m-%d").to_string() != day {
            return Err("Daily note needs a YYYY-MM-DD date".into());
        }
        (
            format!("Daily/{day}.md"),
            date.format("%A, %-d %B %Y").to_string(),
        )
    } else {
        (format!("note-{}.md", random_id()), "Untitled note".into())
    };
    let path = note_path(&root(database)?, &id)?;
    if path.exists() {
        return open(database, &id);
    }
    match save(database, &id, &format!("# {title}\n\n"), None) {
        Ok(note) => Ok(note),
        Err(_) if day.is_some() && path.exists() => open(database, &id),
        Err(error) => Err(error),
    }
}
pub(crate) fn save(
    database: &str,
    id: &str,
    text: &str,
    base: Option<&str>,
) -> Result<NoteDocument> {
    if text.len() > NOTE_BYTES {
        return Err("Note exceeds the 1 MiB editor limit".into());
    }
    let _lock = WRITER.lock().map_err(|_| "Notes writer is unavailable")?;
    let root = root(database)?;
    let path = note_path(&root, id)?;
    let old = if path.exists() {
        Some(read_text(&path)?)
    } else {
        None
    };
    if old.as_ref().map(|s| revision(s)).as_deref() != base {
        return Err("This note changed outside Square Mail. Your edits are kept here. Save a copy or reload the file before saving.".into());
    }
    if old.as_deref() == Some(text) {
        return Ok(NoteDocument {
            id: id.into(),
            text: text.into(),
            revision: revision(text),
        });
    }
    if let Some(old) = &old {
        backup(&root, id, old)?;
    }
    let temp = path
        .parent()
        .ok_or("Missing note folder")?
        .join(format!(".note-write-{}", random_id()));
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        let current = if path.exists() {
            Some(revision(&read_text(&path)?))
        } else {
            None
        };
        if current.as_deref() != base {
            return Err(
                "External edit detected. Your original file and editor text were preserved.".into(),
            );
        }
        if base.is_none() {
            fs::hard_link(&temp, &path)?;
            fs::remove_file(&temp)?;
        } else {
            fs::rename(&temp, &path)?;
        }
        fs::File::open(path.parent().ok_or("Missing note folder")?)?.sync_all()?;
        Ok(())
    })();
    if temp.exists() {
        let _ = fs::remove_file(&temp);
    }
    result?;
    Ok(NoteDocument {
        id: id.into(),
        text: text.into(),
        revision: revision(text),
    })
}
fn backup(root: &Path, id: &str, text: &str) -> Result<()> {
    let folder = root.join(".history");
    ensure_dir(&folder)?;
    let name = format!("{:x}-{}.md", Sha256::digest(id.as_bytes()), revision(text));
    let path = folder.join(name);
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Ok(mut file) => file.write_all(text.as_bytes())?,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.into()),
    }
    let mut files = fs::read_dir(&folder)?.collect::<std::io::Result<Vec<_>>>()?;
    files.sort_by_key(|f| f.metadata().and_then(|m| m.modified()).ok());
    let remove = files.len().saturating_sub(BACKUP_LIMIT);
    for file in files.into_iter().take(remove) {
        if file.file_type()?.is_file() {
            fs::remove_file(file.path())?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
