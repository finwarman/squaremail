use super::*;
fn context() -> network::Context<'static> {
    network::Context::new(None, 120)
}
fn text(database: &str, id: &str, value: &str) {
    let note = super::super::open(database, id).unwrap();
    super::super::save(database, id, value, Some(&note.revision)).unwrap();
}
#[test]
fn changed_during_upload_stays_due() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("mail.sqlite");
    let database = path.to_str().unwrap();
    let note = super::super::new(database, None).unwrap();
    let db = connection(database, "account-a").unwrap();
    text(database, &note.id, "# Edited during upload");
    save_state(
        database,
        &db,
        &note.id,
        "opaque",
        &note.revision,
        "accepted-revision",
    )
    .unwrap();
    let stamp: String = db
        .query_row("SELECT stamp FROM state WHERE id=?1", [&note.id], |r| {
            r.get(0)
        })
        .unwrap();
    assert!(stamp.is_empty());
    db.execute("UPDATE cursor SET value=99", []).unwrap();
    drop(db);
    let changed = connection(database, "account-b").unwrap();
    assert_eq!(
        changed
            .query_row("SELECT value FROM cursor", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        changed
            .query_row("SELECT count(*) FROM state", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
}
#[test]
fn secret_debug_is_redacted() {
    let command = Command::Connect {
        account_key: "private-auth-key".into(),
        password: "private-vault-passphrase".into(),
        remember: false,
    };
    let value = format!("{command:?}");
    assert!(!value.contains("private-auth"));
    assert!(!value.contains("passphrase"));
}
#[test]
fn busy_cannot_reload_locked_key() {
    let _lease = WORKER.lock().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("mail.sqlite");
    let database = path.to_str().unwrap();
    assert!(run(database, Command::Status, &context()).is_err());
    let result = run(database, Command::Sync, &context()).unwrap();
    assert_eq!(result["phase"], "busy");
    assert_eq!(result["unlocked"], false);
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
}

#[test]
fn takeover_forgets_unlock() {
    let _worker = WORKER.lock().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("mail.sqlite");
    let database = file.to_str().unwrap();
    let id = key_id(database);
    keys::save(
        &id,
        &keys::Credentials {
            auth: "synthetic-account".into(),
            key: Some(vec![7; 32]),
        },
    )
    .unwrap();
    assert!(session(database).unwrap().is_some());
    keys::save(
        &id,
        &keys::Credentials {
            auth: "synthetic-account".into(),
            key: None,
        },
    )
    .unwrap();
    assert!(session(database).unwrap().is_some());
    assert!(claim_owner(database).unwrap());
    assert!(session(database).unwrap().is_none());
    super::super::lease::release(database).unwrap();
}
#[test]
#[ignore]
fn backup_two_device_http() {
    let invite = Zeroizing::new(
        fs::read_to_string(std::env::var("SQUAREMAIL_VAULT_INVITE_FILE").unwrap()).unwrap(),
    );
    let endpoint = fixture_endpoint().unwrap();
    let hosted = std::env::var("SQUAREMAIL_VAULT_HOSTED").as_deref() == Ok("1");
    assert!(
        endpoint.starts_with("http://127.0.0.1:")
            || (hosted && endpoint == "https://f1nb0.dev/notes-sync/v1")
    );
    let a = tempfile::tempdir().unwrap();
    let b = tempfile::tempdir().unwrap();
    let ap = a.path().join("mail.sqlite");
    let bp = b.path().join("mail.sqlite");
    let a = ap.to_str().unwrap();
    let b = bp.to_str().unwrap();
    let password = "synthetic-only-vault-passphrase";
    let created = run(
        a,
        Command::Create {
            invite: invite.trim().into(),
            password: password.into(),
            remember: false,
        },
        &context(),
    )
    .unwrap();
    assert_eq!(created["status"]["phase"], "recovery");
    let account_key = Zeroizing::new(created["account_key"].as_str().unwrap().to_owned());
    if hosted {
        let (id, _) = pair(&account_key).unwrap();
        fs::write(std::env::var("SQUAREMAIL_VAULT_RESULT_FILE").unwrap(), id).unwrap();
    }
    let note = super::super::new(a, Some("2026-11-23")).unwrap();
    text(a, &note.id, "# Original\nOffline first");
    assert!(run(a, Command::Sync, &context()).is_err());
    run(a, Command::Enable, &context()).unwrap();
    run(a, Command::Sync, &context()).unwrap();
    run(
        b,
        Command::Connect {
            account_key: account_key.to_string(),
            password: password.into(),
            remember: false,
        },
        &context(),
    )
    .unwrap();
    run(b, Command::Enable, &context()).unwrap();
    run(b, Command::Sync, &context()).unwrap();
    assert_eq!(
        super::super::open(b, &note.id).unwrap().text,
        "# Original\nOffline first"
    );
    text(a, &note.id, "# Mac A edits");
    text(b, &note.id, "# Mac B edits");
    run(a, Command::Sync, &context()).unwrap();
    run(b, Command::Sync, &context()).unwrap();
    assert_eq!(
        super::super::open(b, &note.id).unwrap().text,
        "# Mac A edits"
    );
    let listed = super::super::list(b).unwrap();
    assert!(listed.notes.iter().any(|n| n.id.starts_with("conflict-")
        && super::super::open(b, &n.id).unwrap().text == "# Mac B edits"));
    run(a, Command::Sync, &context()).unwrap();
    assert!(
        super::super::list(a)
            .unwrap()
            .notes
            .iter()
            .any(|n| n.id.starts_with("conflict-"))
    );
    let history = run(
        a,
        Command::History {
            id: note.id.clone(),
        },
        &context(),
    )
    .unwrap();
    let revision = history["items"][0]["revision"].as_str().unwrap();
    let copy = run(
        a,
        Command::Restore {
            id: note.id.clone(),
            revision: revision.into(),
        },
        &context(),
    )
    .unwrap();
    assert_ne!(copy["id"], note.id);
    assert_eq!(copy["text"], "# Original\nOffline first");
    run(b, Command::Lock, &context()).unwrap();
    assert!(run(b, Command::Sync, &context()).is_err());
    run(
        b,
        Command::Unlock {
            password: password.into(),
            remember: false,
        },
        &context(),
    )
    .unwrap();
    run(b, Command::Sync, &context()).unwrap();
    fs::remove_file(super::super::root(b).unwrap().join(&note.id)).unwrap();
    run(b, Command::Sync, &context()).unwrap();
    assert_eq!(
        super::super::open(b, &note.id).unwrap().text,
        "# Mac A edits"
    );
    run(b, Command::Disconnect, &context()).unwrap();
    assert_eq!(
        run(b, Command::Status, &context()).unwrap()["phase"],
        "disabled"
    );
    assert_eq!(
        super::super::open(b, &note.id).unwrap().text,
        "# Mac A edits"
    );
    println!(
        "Encrypted Notes two-device sync, conflict preservation, recovery gate, history restore, lock/unlock and disconnect verified. Synthetic data; no Keychain or real Notes access."
    );
}
