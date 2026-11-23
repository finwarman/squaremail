mod crypto;
mod keys;
mod remote;
use crate::{Result, network};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use crypto::{Header, Secret};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::{
    collections::HashMap,
    fs,
    os::unix::fs::OpenOptionsExt,
    path::Path,
    sync::{Mutex, OnceLock},
};
use zeroize::Zeroizing;

static WORKER: Mutex<()> = Mutex::new(());
const CONFIG_FILE: &str = "notes-backup.json";
const STATE_FILE: &str = "NotesBackup.sqlite";
const BATCH: usize = 4;
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Activation {
    Pending,
    Recovery,
    Enabled,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Retention {
    Session,
    Device,
}
impl From<bool> for Retention {
    fn from(value: bool) -> Self {
        if value { Self::Device } else { Self::Session }
    }
}
#[derive(Serialize, Deserialize, Clone)]
struct Config {
    activation: Activation,
    account: String,
    header: Header,
    #[cfg(test)]
    #[serde(default)]
    fixture_endpoint: Option<String>,
}
#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub(crate) enum Command {
    Status,
    Invitation,
    Enable,
    Recovery,
    Create {
        invite: String,
        password: String,
        remember: bool,
    },
    Connect {
        account_key: String,
        password: String,
        remember: bool,
    },
    Unlock {
        password: String,
        remember: bool,
    },
    Lock,
    Disconnect,
    Sync,
    History {
        id: String,
    },
    Restore {
        id: String,
        revision: String,
    },
}
impl std::fmt::Debug for Command {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("NotesBackup([redacted])")
    }
}
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Disabled,
    Setup,
    Recovery,
    Locked,
    Ready,
    Busy,
}
#[derive(Serialize)]
struct Status {
    phase: Phase,
    unlocked: bool,
    account: Option<String>,
    completed: usize,
    more: bool,
    message: String,
}
#[derive(Serialize)]
struct Created {
    status: Status,
    account_key: String,
}
#[derive(Clone)]
struct Session {
    auth: Zeroizing<String>,
    key: Secret,
}
fn sessions() -> &'static Mutex<HashMap<String, Session>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Session>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}
fn valid_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn parent(database: &str) -> Result<&Path> {
    Path::new(database)
        .parent()
        .ok_or_else(|| "Missing Notes backup directory".into())
}
fn config(database: &str) -> Result<Option<Config>> {
    let file = parent(database)?.join(CONFIG_FILE);
    if !file.exists() {
        return Ok(None);
    }
    let value = super::read_text(&file)?;
    Ok(Some(serde_json::from_str(&value)?))
}
fn key_id(database: &str) -> String {
    format!("notes:{:x}", Sha256::digest(database.as_bytes()))
}
fn write_config(database: &str, config: &Config) -> Result<()> {
    let path = parent(database)?.join(CONFIG_FILE);
    let temp = path.with_extension(format!("{}.tmp", crypto::identifier()));
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)?;
        file.write_all(&serde_json::to_vec(config)?)?;
        file.sync_all()?;
        fs::rename(&temp, &path)?;
        fs::File::open(parent(database)?)?.sync_all()?;
        Ok(())
    })();
    let _ = fs::remove_file(temp);
    result
}
fn connection(database: &str, account: &str) -> Result<Connection> {
    let path = parent(database)?.join(STATE_FILE);
    let connection = Connection::open(&path)?;
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    connection.busy_timeout(std::time::Duration::from_secs(2))?;
    connection.execute_batch("PRAGMA journal_mode=WAL;CREATE TABLE IF NOT EXISTS state(id TEXT PRIMARY KEY,object TEXT NOT NULL,local_hash TEXT NOT NULL,remote_revision TEXT NOT NULL,stamp TEXT NOT NULL);CREATE TABLE IF NOT EXISTS cursor(singleton INTEGER PRIMARY KEY CHECK(singleton=1),value INTEGER NOT NULL);INSERT OR IGNORE INTO cursor VALUES(1,0);CREATE TABLE IF NOT EXISTS identity(singleton INTEGER PRIMARY KEY CHECK(singleton=1),account TEXT NOT NULL);")?;
    let previous: Option<String> = connection
        .query_row("SELECT account FROM identity WHERE singleton=1", [], |r| {
            r.get(0)
        })
        .optional()?;
    if previous.as_deref() != Some(account) {
        connection.execute_batch("BEGIN IMMEDIATE;DELETE FROM state;UPDATE cursor SET value=0 WHERE singleton=1;DELETE FROM identity;")?;
        connection.execute("INSERT INTO identity VALUES(1,?1)", [account])?;
        connection.execute_batch("COMMIT")?;
    }
    Ok(connection)
}
fn session(database: &str) -> Result<Option<Session>> {
    if let Some(value) = sessions()
        .lock()
        .map_err(|_| "Notes key is busy")?
        .get(database)
        .cloned()
    {
        return Ok(Some(value));
    }
    let Some(creds) = keys::load(&key_id(database))? else {
        return Ok(None);
    };
    let Some(key) = &creds.key else {
        return Ok(None);
    };
    if key.len() != 32 {
        return Err("Invalid saved Notes key".into());
    }
    let value = Session {
        auth: Zeroizing::new(creds.auth.clone()),
        key: Zeroizing::new(key.clone()),
    };
    cache(database, value.clone())?;
    Ok(Some(value))
}
fn cache(database: &str, value: Session) -> Result<()> {
    let mut values = sessions().lock().map_err(|_| "Notes key is busy")?;
    if values.len() >= 4 && !values.contains_key(database) {
        values.clear();
    }
    values.insert(database.into(), value);
    Ok(())
}
fn status(database: &str) -> Result<Status> {
    let config = config(database)?;
    let phase = match config.as_ref() {
        None => Phase::Disabled,
        Some(value) if value.activation == Activation::Pending => Phase::Setup,
        Some(value) if value.activation == Activation::Recovery => Phase::Recovery,
        Some(_) if session(database)?.is_some() => Phase::Ready,
        Some(_) => Phase::Locked,
    };
    let message = match phase {
        Phase::Disabled => "Backup is off. Notes save on this Mac.",
        Phase::Setup => "Finish setting up your encrypted backup.",
        Phase::Recovery => "Save your recovery account key before enabling backup.",
        Phase::Locked => "Unlock encrypted backup to sync.",
        Phase::Ready => "Encrypted backup is ready.",
        Phase::Busy => "Backup is working.",
    };
    let unlocked = config.is_some() && session(database)?.is_some();
    Ok(Status {
        phase,
        unlocked,
        account: config.map(|c| c.account),
        completed: 0,
        more: false,
        message: message.into(),
    })
}
fn remember(database: &str, auth: &str, key: &[u8], retention: Retention) -> Result<()> {
    keys::save(
        &key_id(database),
        &keys::Credentials {
            auth: auth.into(),
            key: (retention == Retention::Device).then(|| key.to_vec()),
        },
    )
}
fn pair(account_key: &str) -> Result<(String, String)> {
    let (id, auth) = account_key
        .trim()
        .split_once('.')
        .ok_or("Enter the account key saved in your password manager")?;
    if !valid_hex(id, 32) || auth.len() != 43 || URL_SAFE_NO_PAD.decode(auth)?.len() != 32 {
        return Err("Invalid backup account key".into());
    }
    Ok((id.into(), auth.into()))
}
pub(crate) fn run(
    database: &str,
    command: Command,
    context: &network::Context<'_>,
) -> Result<serde_json::Value> {
    use serde_json::{json, to_value};
    // Keychain reads can populate the session cache. Serialize them with Lock/Disconnect.
    let _lease = match WORKER.try_lock() {
        Ok(guard) => guard,
        Err(_) if matches!(&command, Command::Sync) => {
            return Ok(to_value(Status {
                phase: Phase::Busy,
                unlocked: false,
                account: None,
                completed: 0,
                more: true,
                message: "Backup is finishing another operation.".into(),
            })?);
        }
        Err(_) => {
            return Err(
                "Backup is finishing another operation. Try again when it completes.".into(),
            );
        }
    };

    match command {
        Command::Status => to_value(status(database)?).map_err(Into::into),
        Command::Invitation => {
            use std::os::unix::fs::PermissionsExt;
            let path = parent(database)?.join("NotesBackupInvitation.txt");
            if !path.exists() {
                return Ok(json!({"code":null}));
            }
            let info = fs::symlink_metadata(&path)?;
            if !info.is_file()
                || info.file_type().is_symlink()
                || info.permissions().mode() & 0o077 != 0
            {
                return Err(
                    "The private backup invitation needs user-only file permissions".into(),
                );
            }
            let code = Zeroizing::new(super::read_text(&path)?.trim().to_owned());
            if code.len() != 43 || URL_SAFE_NO_PAD.decode(&*code)?.len() != 32 {
                return Err("Invalid backup invitation".into());
            }
            Ok(json!({"code":*code}))
        }
        Command::Create {
            invite,
            password,
            remember: save_key,
        } => {
            let password = Zeroizing::new(password);
            let invite = Zeroizing::new(invite);
            let (mut config, auth, key) = if let Some(config) = config(database)? {
                if config.activation != Activation::Pending {
                    return Err("Disconnect the current backup before creating another".into());
                }
                let creds =
                    keys::load(&key_id(database))?.ok_or("Restore with your backup account key")?;
                let key = crypto::unlock(&config.account, &password, &config.header)?;
                (config, Zeroizing::new(creds.auth.clone()), key)
            } else {
                let account = crypto::identifier();
                let auth = Zeroizing::new(URL_SAFE_NO_PAD.encode(crypto::random::<32>()));
                let (header, key) = crypto::create(&account, &password)?;
                let config = Config {
                    activation: Activation::Pending,
                    account,
                    header,
                    #[cfg(test)]
                    fixture_endpoint: fixture_endpoint(),
                };
                write_config(database, &config)?;
                if let Err(error) = remember(database, &auth, &key, save_key.into()) {
                    let _ = fs::remove_file(parent(database)?.join(CONFIG_FILE));
                    return Err(error);
                }
                (config, auth, key)
            };
            remote::Remote::new(&config, &auth, context).create(invite.trim())?;
            config.activation = Activation::Recovery;
            write_config(database, &config)?;
            let invitation = parent(database)?.join("NotesBackupInvitation.txt");
            if fs::read_to_string(&invitation).is_ok_and(|value| value.trim() == invite.trim()) {
                let _ = fs::remove_file(invitation);
            }
            cache(
                database,
                Session {
                    auth: auth.clone(),
                    key,
                },
            )?;
            to_value(Created {
                status: status(database)?,
                account_key: format!("{}.{}", config.account, *auth),
            })
            .map_err(Into::into)
        }
        Command::Enable => {
            let mut config = config(database)?.ok_or("Set up Notes backup first")?;
            if config.activation == Activation::Pending {
                return Err("Finish Notes backup setup first".into());
            }
            if session(database)?.is_none() {
                return Err("Unlock Notes backup first".into());
            }
            config.activation = Activation::Enabled;
            write_config(database, &config)?;
            to_value(status(database)?).map_err(Into::into)
        }
        Command::Recovery => {
            let config = config(database)?.ok_or("Set up Notes backup first")?;
            let creds = keys::load(&key_id(database))?
                .ok_or("No backup account key is saved on this Mac")?;
            to_value(json!({"account_key":format!("{}.{}",config.account,creds.auth)}))
                .map_err(Into::into)
        }
        Command::Connect {
            account_key,
            password,
            remember: save_key,
        } => {
            let account_key = Zeroizing::new(account_key);
            let password = Zeroizing::new(password);
            if config(database)?.is_some() {
                return Err("Disconnect the current backup before restoring another".into());
            }
            let (account, auth) = pair(&account_key)?;
            let auth = Zeroizing::new(auth);
            let mut config = Config {
                activation: Activation::Recovery,
                account,
                header: Header {
                    version: 0,
                    kdf: String::new(),
                    salt: String::new(),
                    wrapped: String::new(),
                },
                #[cfg(test)]
                fixture_endpoint: fixture_endpoint(),
            };
            config.header = remote::Remote::new(&config, &auth, context).header()?;
            let key = crypto::unlock(&config.account, &password, &config.header)?;
            remember(database, &auth, &key, save_key.into())?;
            write_config(database, &config)?;
            cache(database, Session { auth, key })?;
            to_value(status(database)?).map_err(Into::into)
        }
        Command::Unlock {
            password,
            remember: save_key,
        } => {
            let password = Zeroizing::new(password);
            let config = config(database)?.ok_or("Set up Notes backup first")?;
            let creds =
                keys::load(&key_id(database))?.ok_or("Restore with your backup account key")?;
            let key = crypto::unlock(&config.account, &password, &config.header)?;
            remember(database, &creds.auth, &key, save_key.into())?;
            cache(
                database,
                Session {
                    auth: Zeroizing::new(creds.auth.clone()),
                    key,
                },
            )?;
            to_value(status(database)?).map_err(Into::into)
        }
        Command::Lock => {
            sessions()
                .lock()
                .map_err(|_| "Notes key is busy")?
                .remove(database);
            if let Some(creds) = keys::load(&key_id(database))? {
                keys::save(
                    &key_id(database),
                    &keys::Credentials {
                        auth: creds.auth.clone(),
                        key: None,
                    },
                )?;
            }
            to_value(status(database)?).map_err(Into::into)
        }
        Command::Disconnect => {
            sessions()
                .lock()
                .map_err(|_| "Notes key is busy")?
                .remove(database);
            keys::remove(&key_id(database))?;
            for name in [
                CONFIG_FILE,
                STATE_FILE,
                "NotesBackup.sqlite-wal",
                "NotesBackup.sqlite-shm",
            ] {
                let path = parent(database)?.join(name);
                if path.exists() {
                    fs::remove_file(path)?;
                }
            }
            to_value(status(database)?).map_err(Into::into)
        }
        Command::Sync => to_value(sync(database, context)?).map_err(Into::into),
        Command::History { id } => {
            let config = config(database)?.ok_or("Set up Notes backup first")?;
            let session = session(database)?.ok_or("Unlock Notes backup first")?;
            let object = crypto::object_id(&session.key, &id)?;
            to_value(json!({"items":remote::Remote::new(&config,&session.auth,context).history(&object)?})).map_err(Into::into)
        }
        Command::Restore { id, revision } => {
            let config = config(database)?.ok_or("Set up Notes backup first")?;
            let session = session(database)?.ok_or("Unlock Notes backup first")?;
            let object = crypto::object_id(&session.key, &id)?;
            let remote = remote::Remote::new(&config, &session.auth, context)
                .get(&object, Some(&revision))?;
            let (_, text) = crypto::decrypt(
                &session.key,
                &config.account,
                &object,
                &remote.revision,
                &remote.blob,
            )?;
            let copy = super::new(database, None)?;
            let saved = super::save(database, &copy.id, &text, Some(&copy.revision))?;
            to_value(saved).map_err(Into::into)
        }
    }
}
fn save_state(
    database: &str,
    db: &Connection,
    id: &str,
    object: &str,
    hash: &str,
    remote: &str,
) -> Result<()> {
    let before = file_stamp(database, id)?;
    let observed = super::open(database, id)?.revision;
    let after = file_stamp(database, id)?;
    let stamp = if before == after && observed == hash {
        after
    } else {
        String::new()
    };
    db.execute("INSERT INTO state(id,object,local_hash,remote_revision,stamp) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(id) DO UPDATE SET object=excluded.object,local_hash=excluded.local_hash,remote_revision=excluded.remote_revision,stamp=excluded.stamp",params![id,object,hash,remote,stamp])?;
    Ok(())
}
fn apply(
    database: &str,
    db: &Connection,
    config: &Config,
    session: &Session,
    remote: &remote::RemoteObject,
) -> Result<()> {
    let (id, text) = crypto::decrypt(
        &session.key,
        &config.account,
        &remote.id,
        &remote.revision,
        &remote.blob,
    )?;
    // Validate paths before any filesystem lookup, including data from an authenticated vault.
    let path = super::note_path(&super::root(database)?, &id)?;
    let current = if path.exists() {
        Some(super::open(database, &id)?)
    } else {
        None
    };
    let previous: Option<String> = db
        .query_row("SELECT local_hash FROM state WHERE id=?1", [&id], |r| {
            r.get(0)
        })
        .optional()?;
    if let Some(current) = &current {
        if current.text == text {
            save_state(
                database,
                db,
                &id,
                &remote.id,
                &current.revision,
                &remote.revision,
            )?;
            return Ok(());
        }
        if previous.as_deref() != Some(current.revision.as_str()) {
            let copy_id = format!(
                "conflict-{:x}.md",
                Sha256::digest(
                    format!("{}:{}:{}", id, current.revision, remote.revision).as_bytes()
                )
            );
            let copy = super::note_path(&super::root(database)?, &copy_id)?;
            if !copy.exists() {
                super::save(database, &copy_id, &current.text, None)?;
            }
        }
    }
    let saved = super::save(
        database,
        &id,
        &text,
        current.as_ref().map(|n| n.revision.as_str()),
    )?;
    save_state(
        database,
        db,
        &id,
        &remote.id,
        &saved.revision,
        &remote.revision,
    )
}
// Deletion is not propagated in this preview. Restore missing mapped files in bounded steps.
fn restore_missing(
    database: &str,
    db: &Connection,
    config: &Config,
    session: &Session,
    remote: &remote::Remote<'_>,
    context: &network::Context<'_>,
    budget: usize,
) -> Result<(usize, bool)> {
    let root = super::root(database)?;
    let rows: Vec<(String, String)> = db
        .prepare("SELECT id,object FROM state ORDER BY id LIMIT ?1")?
        .query_map([super::NOTE_LIMIT as i64], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let mut restored = 0;
    for (id, object) in rows {
        context.check()?;
        if super::note_path(&root, &id)?.exists() {
            continue;
        }
        if restored >= budget {
            return Ok((restored, true));
        }
        apply(database, db, config, session, &remote.get(&object, None)?)?;
        restored += 1;
    }
    Ok((restored, false))
}
fn sync(database: &str, context: &network::Context<'_>) -> Result<Status> {
    let config = config(database)?.ok_or("Set up Notes backup first")?;
    let session = session(database)?.ok_or("Unlock Notes backup first")?;
    let remote = remote::Remote::new(&config, &session.auth, context);
    if config.activation != Activation::Enabled {
        return Err("Save your recovery account key and enable backup first".into());
    }
    let db = connection(database, &config.account)?;
    let cursor: i64 = db.query_row("SELECT value FROM cursor WHERE singleton=1", [], |r| {
        r.get(0)
    })?;
    let changes = remote.changes(cursor)?;
    let mut completed = 0;
    for change in changes.items.iter().take(BATCH) {
        context.check()?;
        let known: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM state WHERE object=?1 AND remote_revision=?2)",
            params![change.id, change.revision],
            |r| r.get(0),
        )?;
        if !known {
            apply(
                database,
                &db,
                &config,
                &session,
                &remote.get(&change.id, None)?,
            )?;
        }
        db.execute(
            "UPDATE cursor SET value=?1 WHERE singleton=1",
            [change.sequence],
        )?;
        completed += 1;
    }
    let mut more = changes.more || changes.items.len() > BATCH;
    if !more {
        let (restored, pending) = restore_missing(
            database,
            &db,
            &config,
            &session,
            &remote,
            context,
            BATCH - completed,
        )?;
        completed += restored;
        more = pending;
    }
    if !more {
        // No body or network work enters the UI queue. Each step uploads at most four notes.
        let ids = super::note_ids(database)?;
        for id in ids {
            context.check()?;
            let previous: Option<(String, String, String)> = db
                .query_row(
                    "SELECT local_hash,remote_revision,stamp FROM state WHERE id=?1",
                    [&id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()?;
            if previous.as_ref().is_some_and(|(_, _, stamp)| {
                file_stamp(database, &id).is_ok_and(|current| *stamp == current)
            }) {
                continue;
            }
            let note = super::open(database, &id)?;
            if let Some((hash, remote_revision, _)) = &previous
                && hash == &note.revision
            {
                save_state(
                    database,
                    &db,
                    &note.id,
                    &crypto::object_id(&session.key, &note.id)?,
                    hash,
                    remote_revision,
                )?;
                continue;
            }
            if completed >= BATCH {
                more = true;
                break;
            }
            let object = crypto::object_id(&session.key, &note.id)?;
            let revision = crypto::identifier();
            let blob = crypto::encrypt(
                &session.key,
                &config.account,
                &object,
                &revision,
                &note.id,
                &note.text,
            )?;
            match remote.put(
                &object,
                &revision,
                previous.as_ref().map(|(_, r, _)| r.as_str()),
                &blob,
            ) {
                Ok(()) => save_state(database, &db, &note.id, &object, &note.revision, &revision)?,
                Err(error) if network::is_status(error.as_ref(), 409) => apply(
                    database,
                    &db,
                    &config,
                    &session,
                    &remote.get(&object, None)?,
                )?,
                Err(error) => return Err(error),
            }
            completed += 1;
        }
    }
    Ok(Status {
        phase: Phase::Ready,
        unlocked: true,
        account: Some(config.account),
        completed,
        more,
        message: if more {
            "Encrypted backup is syncing."
        } else {
            "Encrypted backup is up to date."
        }
        .into(),
    })
}

fn file_stamp(database: &str, id: &str) -> Result<String> {
    let path = super::note_path(&super::root(database)?, id)?;
    Ok(super::stamp(&fs::metadata(path)?))
}
#[cfg(test)]
fn fixture_endpoint() -> Option<String> {
    std::env::var("SQUAREMAIL_VAULT_ENDPOINT").ok()
}

#[cfg(test)]
mod tests;
