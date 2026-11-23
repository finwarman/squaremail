use super::*;
use crate::network;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use std::collections::{HashMap, HashSet};
use std::os::unix::fs::PermissionsExt;
use unicode_normalization::UnicodeNormalization;

const INDEX_FILE: &str = "NotesIndex.sqlite";
const SCHEMA: i64 = 1;
const BATCH: usize = 8;
const MATCH_LIMIT: usize = 200;
const QUERY_BYTES: usize = 512;
const TERM_LIMIT: usize = 16;
const STEP_MS: u128 = 25;
struct Entry {
    row: i64,
    title: String,
    modified: i64,
    stamp: String,
    available: bool,
}
fn connection(database: &str) -> Result<Connection> {
    let path = Path::new(database)
        .parent()
        .ok_or("Missing Notes directory")?
        .join(INDEX_FILE);
    if let Ok(info) = fs::symlink_metadata(&path)
        && (!info.is_file() || info.file_type().is_symlink())
    {
        return Err("Notes index must be a regular file".into());
    }
    fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    let mut db = Connection::open(path)?;
    db.busy_timeout(std::time::Duration::from_millis(250))?;
    db.pragma_update(None, "journal_mode", "WAL")?;
    db.pragma_update(None, "cache_size", -2048)?;
    let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
    if version != 0 && version != SCHEMA {
        return Err("Notes index needs a newer app. Markdown files were not changed.".into());
    }
    if version == 0 {
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute_batch("CREATE TABLE catalog(row INTEGER PRIMARY KEY,id TEXT NOT NULL UNIQUE,title TEXT NOT NULL,modified INTEGER NOT NULL,stamp TEXT NOT NULL,indexed TEXT NOT NULL DEFAULT '',available INTEGER NOT NULL);CREATE VIRTUAL TABLE note_fts USING fts5(title,id,body,content='',contentless_delete=1,tokenize='unicode61 remove_diacritics 2');CREATE TABLE identity(singleton INTEGER PRIMARY KEY CHECK(singleton=1),directory TEXT NOT NULL);")?;
        tx.pragma_update(None, "user_version", SCHEMA)?;
        tx.commit()?;
    }
    let directory = root(database)?
        .canonicalize()?
        .to_string_lossy()
        .into_owned();
    let previous: Option<String> = db
        .query_row(
            "SELECT directory FROM identity WHERE singleton=1",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if previous.as_deref() != Some(&directory) {
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute_batch("DELETE FROM note_fts;DELETE FROM catalog;DELETE FROM identity;")?;
        tx.execute("INSERT INTO identity VALUES(1,?1)", [directory])?;
        tx.commit()?;
    }
    Ok(db)
}
fn refresh(db: &mut Connection, database: &str) -> Result<()> {
    let root = root(database)?;
    let cached: HashMap<String, Entry> = db
        .prepare("SELECT id,row,title,modified,stamp,available FROM catalog")?
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                Entry {
                    row: r.get(1)?,
                    title: r.get(2)?,
                    modified: r.get(3)?,
                    stamp: r.get(4)?,
                    available: r.get(5)?,
                },
            ))
        })?
        .collect::<rusqlite::Result<_>>()?;
    let mut seen = HashSet::new();
    let mut changed = Vec::new();
    for id in note_ids(database)? {
        let path = note_path(&root, &id)?;
        let info = fs::metadata(&path)?;
        let current = stamp(&info);
        seen.insert(id.clone());
        if cached.get(&id).is_some_and(|v| v.stamp == current) {
            continue;
        }
        let available = readable(&info);
        let mut bytes = Vec::new();
        if available {
            fs::File::open(&path)?
                .take(TITLE_BYTES)
                .read_to_end(&mut bytes)?;
        }
        changed.push((
            id.clone(),
            Entry {
                row: 0,
                title: title(&String::from_utf8_lossy(&bytes), &id),
                modified: info
                    .modified()?
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs()
                    .try_into()?,
                stamp: current,
                available,
            },
        ));
    }
    let removed: Vec<_> = cached
        .iter()
        .filter(|(id, _)| !seen.contains(*id))
        .map(|(_, v)| v.row)
        .collect();
    if changed.is_empty() && removed.is_empty() {
        return Ok(());
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    for row in removed {
        tx.execute("DELETE FROM note_fts WHERE rowid=?1", [row])?;
        tx.execute("DELETE FROM catalog WHERE row=?1", [row])?;
    }
    for (id, value) in changed {
        if let Some(old) = cached.get(&id) {
            tx.execute("DELETE FROM note_fts WHERE rowid=?1", [old.row])?;
        }
        tx.execute("INSERT INTO catalog(id,title,modified,stamp,available) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(id) DO UPDATE SET title=excluded.title,modified=excluded.modified,stamp=excluded.stamp,available=excluded.available,indexed=''",params![id,value.title,value.modified,value.stamp,value.available])?;
    }
    tx.commit()?;
    Ok(())
}
fn pending(db: &Connection) -> Result<usize> {
    Ok(db.query_row(
        "SELECT count(*) FROM catalog WHERE available=1 AND stamp<>indexed",
        [],
        |r| r.get::<_, i64>(0),
    )? as usize)
}
fn summary(r: &rusqlite::Row<'_>) -> rusqlite::Result<NoteSummary> {
    Ok(NoteSummary {
        id: r.get(0)?,
        title: r.get(1)?,
        modified: r.get::<_, i64>(2)?.max(0) as u64,
        available: r.get(3)?,
    })
}
pub(super) fn list(database: &str) -> Result<NoteList> {
    let mut db = connection(database)?;
    refresh(&mut db, database)?;
    let notes = db
        .prepare(
            "SELECT id,title,modified,available FROM catalog ORDER BY modified DESC,id LIMIT ?1",
        )?
        .query_map([NOTE_LIMIT as i64], summary)?
        .collect::<rusqlite::Result<_>>()?;
    Ok(NoteList {
        directory: root(database)?.to_string_lossy().into_owned(),
        notes,
        pending: pending(&db)?,
    })
}
pub(super) fn step(database: &str, context: &network::Context<'_>) -> Result<IndexProgress> {
    let mut db = connection(database)?;
    let root = root(database)?;
    let rows:Vec<(i64,String,String)>=db.prepare("SELECT row,id,stamp FROM catalog WHERE available=1 AND stamp<>indexed ORDER BY modified DESC,id LIMIT ?1")?.query_map([BATCH as i64],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?.collect::<rusqlite::Result<_>>()?;
    let start = std::time::Instant::now();
    let mut indexed = 0;
    let mut skipped = 0;
    for (row, id, expected) in rows {
        context.check()?;
        let path = note_path(&root, &id)?;
        let before = match fs::metadata(&path) {
            Ok(v) => stamp(&v),
            Err(_) => {
                refresh(&mut db, database)?;
                continue;
            }
        };
        if before != expected {
            refresh(&mut db, database)?;
            continue;
        }
        let text = match read_text(&path) {
            Ok(text) => text,
            Err(_) => {
                db.execute(
                    "UPDATE catalog SET indexed=stamp,available=0 WHERE row=?1 AND stamp=?2",
                    params![row, expected],
                )?;
                skipped += 1;
                continue;
            }
        };
        context.check()?;
        if !fs::metadata(&path).is_ok_and(|v| stamp(&v) == before) {
            refresh(&mut db, database)?;
            continue;
        }
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "INSERT OR REPLACE INTO note_fts(rowid,title,id,body) VALUES(?1,?2,?3,?4)",
            params![row, title(&text, &id), id, text],
        )?;
        tx.execute(
            "UPDATE catalog SET indexed=stamp,title=?3 WHERE row=?1 AND stamp=?2",
            params![row, expected, title(&text, &id)],
        )?;
        context.check()?;
        tx.commit()?;
        indexed += 1;
        if start.elapsed().as_millis() >= STEP_MS {
            break;
        }
    }
    Ok(IndexProgress {
        pending: pending(&db)?,
        indexed,
        skipped,
    })
}
pub(super) fn search(database: &str, query: &str) -> Result<NoteMatches> {
    if query.len() > QUERY_BYTES {
        return Err("Notes search is limited to 512 bytes".into());
    }
    let db = connection(database)?;
    let normalized: String = query.nfkc().collect();
    let terms: Vec<_> = normalized
        .split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty())
        .take(TERM_LIMIT)
        .map(|s| format!("\"{s}\"*"))
        .collect();
    let notes = if query.trim().is_empty() {
        Vec::new()
    } else if terms.is_empty() {
        db.prepare("SELECT id,title,modified,available FROM catalog WHERE instr(title,?1)>0 OR instr(id,?1)>0 ORDER BY modified DESC,id LIMIT ?2")?.query_map(params![query.trim(),MATCH_LIMIT as i64],summary)?.collect::<rusqlite::Result<_>>()?
    } else {
        db.prepare("SELECT c.id,c.title,c.modified,c.available FROM note_fts JOIN catalog c ON c.row=note_fts.rowid WHERE note_fts MATCH ?1 AND c.available=1 AND c.stamp=c.indexed ORDER BY bm25(note_fts,8.0,4.0,1.0),c.modified DESC,c.id LIMIT ?2")?.query_map(params![terms.join(" AND "),MATCH_LIMIT as i64],summary)?.collect::<rusqlite::Result<_>>()?
    };
    let total = db.query_row("SELECT count(*) FROM catalog", [], |r| r.get::<_, i64>(0))? as usize;
    Ok(NoteMatches {
        notes,
        pending: pending(&db)?,
        total,
    })
}

#[cfg(test)]
mod tests;
