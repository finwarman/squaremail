use crate::Result;
use std::{
    collections::HashMap,
    fs::{self, File, TryLockError},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::Path,
    sync::{Mutex, OnceLock},
};

fn owners() -> &'static Mutex<HashMap<String, File>> {
    static OWNERS: OnceLock<Mutex<HashMap<String, File>>> = OnceLock::new();
    OWNERS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn file(path: &Path) -> Result<File> {
    let opened = match File::options()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let info = fs::symlink_metadata(path)?;
            if !info.is_file() || info.file_type().is_symlink() {
                return Err("Notes lock must be a private regular file".into());
            }
            File::options().read(true).write(true).open(path)?
        }
        Err(error) => return Err(error.into()),
    };
    let info = fs::symlink_metadata(path)?;
    let actual = opened.metadata()?;
    if info.file_type().is_symlink()
        || actual.ino() != info.ino()
        || actual.dev() != info.dev()
        || actual.nlink() != 1
        || actual.permissions().mode() & 0o077 != 0
    {
        return Err("Notes lock must be a private regular file".into());
    }
    Ok(opened)
}

pub(super) fn take(path: &Path) -> Result<Option<File>> {
    let file = file(path)?;
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(error)) => Err(error.into()),
    }
}

fn path(database: &str) -> Result<std::path::PathBuf> {
    Ok(Path::new(database)
        .parent()
        .ok_or("Missing Notes directory")?
        .join("NotesSync.lock"))
}

pub(super) fn claim(database: &str) -> Result<bool> {
    let mut owners = owners()
        .lock()
        .map_err(|_| "Notes sync ownership is busy")?;
    if owners.contains_key(database) {
        return Ok(true);
    }
    const OWNER_LIMIT: usize = 4;
    if owners.len() >= OWNER_LIMIT {
        return Err("Too many Notes backup owners in this process".into());
    }
    let Some(file) = take(&path(database)?)? else {
        return Ok(false);
    };
    owners.insert(database.into(), file);
    Ok(true)
}

pub(super) fn release(database: &str) -> Result<()> {
    owners()
        .lock()
        .map_err(|_| "Notes sync ownership is busy")?
        .remove(database);
    Ok(())
}

pub(super) fn owned(database: &str) -> Result<bool> {
    Ok(owners()
        .lock()
        .map_err(|_| "Notes sync ownership is busy")?
        .contains_key(database))
}

pub(super) struct Access {
    _file: Option<File>,
}
pub(super) fn access(database: &str) -> Result<Option<Access>> {
    if owners()
        .lock()
        .map_err(|_| "Notes sync ownership is busy")?
        .contains_key(database)
    {
        return Ok(Some(Access { _file: None }));
    }
    Ok(take(&path(database)?)?.map(|file| Access { _file: Some(file) }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exclusive_ownership_releases() {
        let dir = tempfile::tempdir().unwrap();
        let database = dir
            .path()
            .join("mail.sqlite")
            .to_string_lossy()
            .into_owned();
        assert!(claim(&database).unwrap());
        assert!(claim(&database).unwrap());
        assert!(take(&path(&database).unwrap()).unwrap().is_none());
        assert!(access(&database).unwrap().is_some());
        release(&database).unwrap();
        let other = take(&path(&database).unwrap()).unwrap().unwrap();
        assert!(!claim(&database).unwrap());
        assert!(access(&database).unwrap().is_none());
        drop(other);
        assert!(claim(&database).unwrap());
        release(&database).unwrap();
    }

    #[test]
    fn writer_lock_rejects_links() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target");
        fs::write(&target, "unchanged").unwrap();
        let link = dir.path().join("lock");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(take(&link).is_err());
        assert_eq!(fs::read_to_string(target).unwrap(), "unchanged");
    }

    #[test]
    fn competing_save_keeps_both_edits() {
        let dir = tempfile::tempdir().unwrap();
        let database = dir
            .path()
            .join("mail.sqlite")
            .to_string_lossy()
            .into_owned();
        let note = super::super::new(&database, None).unwrap();
        let held = take(&dir.path().join("Notes/.writer.lock"))
            .unwrap()
            .unwrap();
        assert!(
            super::super::save(&database, &note.id, "competing edit", Some(&note.revision))
                .is_err()
        );
        assert_eq!(
            super::super::open(&database, &note.id).unwrap().text,
            note.text
        );
        drop(held);
        let saved = super::super::save(
            &database,
            &note.id,
            "first saved edit",
            Some(&note.revision),
        )
        .unwrap();
        assert!(
            super::super::save(&database, &note.id, "stale edit", Some(&note.revision)).is_err()
        );
        assert_eq!(
            super::super::open(&database, &note.id).unwrap().text,
            saved.text
        );
    }

    #[test]
    #[ignore = "Child process for the ownership contract"]
    fn hold_owner_fixture() {
        use std::io::{Read, Write};
        let database = std::env::var("SQUAREMAIL_NOTES_OWNER_FIXTURE").unwrap();
        assert!(claim(&database).unwrap());
        println!("NOTES_OWNER_READY");
        std::io::stdout().flush().unwrap();
        let mut byte = [0];
        let _ = std::io::stdin().read(&mut byte);
    }

    #[test]
    fn owner_transfers_processes() {
        use std::io::{BufRead, BufReader};
        use std::process::{Command, Stdio};
        let dir = tempfile::tempdir().unwrap();
        let database = dir
            .path()
            .join("mail.sqlite")
            .to_string_lossy()
            .into_owned();
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "notes::lease::tests::hold_owner_fixture",
                "--ignored",
                "--nocapture",
            ])
            .env("SQUAREMAIL_NOTES_OWNER_FIXTURE", &database)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (send, receive) = std::sync::mpsc::channel();
        let reader = std::thread::spawn(move || {
            for line in BufReader::new(stdout)
                .lines()
                .map_while(std::result::Result::ok)
            {
                if line == "NOTES_OWNER_READY" {
                    let _ = send.send(());
                }
            }
        });
        if receive
            .recv_timeout(std::time::Duration::from_secs(5))
            .is_err()
        {
            let _ = child.kill();
            let _ = child.wait();
            panic!("Notes owner fixture did not start");
        }
        assert!(!claim(&database).unwrap());
        assert!(access(&database).unwrap().is_none());
        drop(child.stdin.take());
        assert!(child.wait().unwrap().success());
        reader.join().unwrap();
        assert!(claim(&database).unwrap());
        release(&database).unwrap();
    }
}
