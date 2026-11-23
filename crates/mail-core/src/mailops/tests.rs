use super::*;
fn account_fixture() -> Account {
    Account {
        id: "fixture".into(),
        email: "fin@example.test".into(),
        provider: Provider::Gmail,
    }
}
fn seed(store: &Store) -> Message {
    let account = account_fixture();
    store.save_account(&account).unwrap();
    let message=mime::parse(b"From: Ada <ada@example.test>\r\nReply-To: replies@example.test\r\nTo: fin@example.test, Ada <ada@example.test>, team@example.test\r\nCc: team@example.test, cc@example.test\r\nMessage-ID: <source@example.test>\r\nReferences: <older@example.test>\r\nSubject: Notes\r\n\r\n- first\r\n  - nested\r\n\r\n> Previous reply",&account.id,"original").unwrap();
    store.save(&message, Folder::Inbox).unwrap();
    let mut headers = message.reply.clone().unwrap();
    headers.thread = "thread-1".into();
    store.save_headers(&message.id, &headers).unwrap();
    store
        .ensure_job(&account.id, JobKind::Catalog, "", 0)
        .unwrap();
    let job = SyncJob {
        account_id: account.id.clone(),
        kind: JobKind::Catalog,
        resource: String::new(),
        window: 0,
        state: json!({}),
        failures: 0,
    };
    let folders = [
        ("label:INBOX", "Inbox", Some("inbox")),
        ("label:TRASH", "Trash", Some("trash")),
        ("label:project", "Project", None),
        ("label:other", "Other", None),
        ("label:UNREAD", "Unread", None),
        ("label:SENT", "Sent", None),
    ]
    .into_iter()
    .map(|(id, name, system)| MailFolder {
        account_id: account.id.clone(),
        id: id.into(),
        name: name.into(),
        system: system.map(String::from),
        parent_id: None,
    })
    .collect::<Vec<_>>();
    store
        .apply_catalog(&job, &folders, &[], &json!({}), 60)
        .unwrap();
    message
}
fn new_draft(store: &Store) -> MailDraft {
    let reply = compose(
        store,
        "fixture",
        None,
        ComposeKind::New,
        BodyMode::Cached,
        &Context::new(None, 10),
    )
    .unwrap();
    let mut draft: MailDraft = serde_json::from_value(reply["draft"].clone()).unwrap();
    draft.to = vec!["ada@example.test".into()];
    draft.subject = "Offline draft".into();
    draft.text = "Saved body".into();
    draft
}
#[test]
fn offline_merge_and_cancel() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("mail.sqlite");
    let store = Store::open(file.to_str().unwrap()).unwrap();
    let message = seed(&store);
    queue(
        &store,
        "operation-read-0001",
        &message.id,
        MailAction::Read { unread: false },
    )
    .unwrap();
    queue(
        &store,
        "operation-flag-0001",
        &message.id,
        MailAction::Flag { flagged: true },
    )
    .unwrap();
    queue(
        &store,
        "operation-trash-0001",
        &message.id,
        MailAction::Trash,
    )
    .unwrap();
    assert!(
        store
            .list(Some("fixture"), Folder::Inbox, "", 0, 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store
            .list(Some("fixture"), Folder::Trash, "", 0, 10)
            .unwrap()
            .len(),
        1
    );
    queue(
        &store,
        "operation-read-0002",
        &message.id,
        MailAction::Read { unread: true },
    )
    .unwrap();
    assert_eq!(
        store.mail_workspace().unwrap()["work"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    drop(store);
    let store = Store::open(file.to_str().unwrap()).unwrap();
    assert!(store.action_message(&message.id).unwrap().unread);
    assert!(store.action_message(&message.id).unwrap().starred);
    store
        .mail_work_choice(
            "operation-trash-0001",
            MailWorkKind::Action,
            MailWorkChoice::Cancel,
        )
        .unwrap();
    assert_eq!(
        store
            .list(Some("fixture"), Folder::Inbox, "", 0, 10)
            .unwrap()
            .len(),
        1
    );
    assert!(store.action_message(&message.id).unwrap().starred);
    store
        .mail_work_choice(
            "operation-read-0001",
            MailWorkKind::Action,
            MailWorkChoice::Cancel,
        )
        .unwrap();
    assert!(store.action_message(&message.id).unwrap().unread);
    assert!(
        queue(
            &store,
            "operation-flag-0001",
            &message.id,
            MailAction::Trash
        )
        .is_err()
    );
}
#[test]
fn sync_does_not_erase_pending() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("replay.sqlite");
    let store = Store::open(path.to_str().unwrap()).unwrap();
    let message = seed(&store);
    queue(
        &store,
        "operation-trash-0001",
        &message.id,
        MailAction::Trash,
    )
    .unwrap();
    store
        .ensure_job("fixture", JobKind::RecentMail, "", 0)
        .unwrap();
    let mut job = SyncJob {
        account_id: "fixture".into(),
        kind: JobKind::RecentMail,
        resource: String::new(),
        window: 0,
        state: json!({}),
        failures: 0,
    };
    store
        .apply_mail(
            &job,
            &[(
                message.clone(),
                vec!["label:INBOX".into(), "label:project".into()],
            )],
            &[],
            &json!({"next":1}),
            60,
        )
        .unwrap();
    assert!(
        store
            .list(Some("fixture"), Folder::Inbox, "", 0, 10)
            .unwrap()
            .is_empty()
    );
    job.state = json!({"next":1});
    store
        .apply_mail(
            &job,
            &[],
            std::slice::from_ref(&message.remote_id),
            &json!({"next":2}),
            60,
        )
        .unwrap();
    assert_eq!(
        store
            .list(Some("fixture"), Folder::Trash, "", 0, 10)
            .unwrap()
            .len(),
        1
    );
    assert!(
        store
            .list_folder(
                Some("fixture"),
                Folder::All,
                Some("label:project"),
                "",
                0,
                10
            )
            .unwrap()
            .is_empty()
    );
    let cache = rusqlite::Connection::open(path).unwrap();
    assert!(cache.query_row("SELECT EXISTS(SELECT 1 FROM mail_membership WHERE account_id='fixture' AND remote_id=?1 AND folder_id='label:project')",[&message.remote_id],|r|r.get::<_,bool>(0)).unwrap());
}

#[test]
fn reply_all_threads() {
    let store = Store::open(":memory:").unwrap();
    let message = seed(&store);
    let result = compose(
        &store,
        "fixture",
        Some(&message.id),
        ComposeKind::ReplyAll,
        BodyMode::Cached,
        &Context::new(None, 10),
    )
    .unwrap();
    let draft: MailDraft = serde_json::from_value(result["draft"].clone()).unwrap();
    assert_eq!(
        draft.to,
        vec![
            "replies@example.test",
            "ada@example.test",
            "team@example.test"
        ]
    );
    assert_eq!(draft.cc, vec!["cc@example.test"]);
    assert!(draft.bcc.is_empty());
    assert!(draft.text.contains(">   - nested"));
    assert!(draft.text.contains("> > Previous reply"));
    let raw = mime::wire_message(&draft, "fin@example.test").unwrap();
    assert!(raw.contains("In-Reply-To: <source@example.test>"));
    let parsed = mail_parser::MessageParser::default()
        .parse(raw.as_bytes())
        .unwrap();
    assert_eq!(
        parsed
            .references()
            .as_text_list()
            .unwrap()
            .iter()
            .map(|s| s.as_ref())
            .collect::<Vec<_>>(),
        vec!["older@example.test", "source@example.test"]
    );
    assert_eq!(draft.headers.unwrap().thread, "thread-1");
}
#[test]
fn draft_revision_outbox() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("mail.sqlite");
    let store = Store::open(file.to_str().unwrap()).unwrap();
    seed(&store);
    let mut draft = new_draft(&store);
    let old = draft.clone();
    draft.revision = store.save_mail_draft(&draft).unwrap();
    assert!(store.save_mail_draft(&old).is_err());
    drop(store);
    let store = Store::open(file.to_str().unwrap()).unwrap();
    let draft = store.mail_draft(&draft.id).unwrap();
    assert_eq!(draft.text, "Saved body");
    queue_send(&store, &draft.id, draft.revision).unwrap();
    assert!(store.mail_draft(&draft.id).is_err());
    store
        .mail_work_choice(&draft.id, MailWorkKind::Outbox, MailWorkChoice::Cancel)
        .unwrap();
    assert_eq!(store.mail_draft(&draft.id).unwrap().text, "Saved body");
    queue_send(&store, &draft.id, draft.revision).unwrap();
    assert!(
        store
            .claim_mail_work(MailWorkKind::Outbox, &draft.id)
            .unwrap()
    );
    assert!(
        !store
            .claim_mail_work(MailWorkKind::Outbox, &draft.id)
            .unwrap()
    );
    store.send_phase(&draft.id, MailSendPhase::Sending).unwrap();
    rusqlite::Connection::open(&file)
        .unwrap()
        .execute("UPDATE mail_outbox SET due=0", [])
        .unwrap();
    assert!(
        store
            .next_mail_work(MailWorkKind::Outbox)
            .unwrap()
            .is_none()
    );
    assert_eq!(
        store.mail_workspace().unwrap()["work"][0]["state"],
        "uncertain"
    );
    assert!(
        store
            .mail_work_choice(&draft.id, MailWorkKind::Outbox, MailWorkChoice::Retry)
            .is_err()
    );
    store
        .mail_work_choice(&draft.id, MailWorkKind::Outbox, MailWorkChoice::Forget)
        .unwrap();
    assert_eq!(store.mail_draft(&draft.id).unwrap().text, "Saved body");
}
#[test]
fn rejects_header_injection() {
    let store = Store::open(":memory:").unwrap();
    seed(&store);
    let mut draft = new_draft(&store);
    draft.to = vec!["ada@example.test\r\nBcc:evil@example.test".into()];
    draft.revision = store.save_mail_draft(&draft).unwrap();
    assert!(queue_send(&store, &draft.id, draft.revision).is_err());
    draft.to = vec!["ada@example.test".into()];
    draft.subject = "Hi\nBcc:x@example.test".into();
    draft.revision = store.save_mail_draft(&draft).unwrap();
    assert!(queue_send(&store, &draft.id, draft.revision).is_err());
    draft.text = "x".repeat(BODY_LIMIT + 1);
    assert!(save_draft(&store, &draft).is_err());
    let mut normal = new_draft(&store);
    normal.revision = store.save_mail_draft(&normal).unwrap();
    queue_send(&store, &normal.id, normal.revision).unwrap();
    store
        .mark_mail_work(
            MailWorkKind::Outbox,
            &normal.id,
            MailWorkState::Done,
            None,
            0,
        )
        .unwrap();
    assert!(
        store
            .mail_work_choice(&normal.id, MailWorkKind::Outbox, MailWorkChoice::Retry)
            .is_err()
    );
}
#[test]
fn pins_order_without_body_load() {
    let store = Store::open(":memory:").unwrap();
    let first = seed(&store);
    let mut second = first.clone();
    second.id = mime::message_id("fixture", "newer");
    second.remote_id = "newer".into();
    second.timestamp += 10;
    store.save(&second, Folder::Inbox).unwrap();
    store.pin_mail(&first.id, true.into()).unwrap();
    let rows = store
        .list(Some("fixture"), Folder::Inbox, "", 0, 250)
        .unwrap();
    assert_eq!(rows[0].id, first.id);
    assert!(rows[0].pinned);
    assert!(rows[0].text.is_none());
    store.save(&first, Folder::Inbox).unwrap();
    assert!(store.action_message(&first.id).unwrap().pinned);
    store.pin_mail(&first.id, false.into()).unwrap();
    assert_eq!(
        store
            .list(Some("fixture"), Folder::Inbox, "", 0, 250)
            .unwrap()[0]
            .id,
        second.id
    );
}
#[test]
#[ignore]
fn seed_mail_actions_fixture() {
    let path =
        std::env::var("SQUAREMAIL_MAIL_ACTIONS_DB").expect("Use a synthetic output database");
    let store = Store::open(&path).unwrap();
    let mut original = seed(&store);
    original.reply = None;
    original.preview = "Hi both,\n\nThe review is complete.\n\nNext steps are attached.".into();
    store.save(&original, Folder::Inbox).unwrap();
    let mut other = original.clone();
    other.remote_id = "other-unread".into();
    other.id = crate::mime::message_id("fixture", &other.remote_id);
    other.timestamp -= 60;
    other.subject = "Another unread message".into();
    store.save(&other, Folder::Archive).unwrap();
    store
        .pause_account("fixture", DisconnectMode::KeepCache)
        .unwrap();
    println!(
        "Generated disconnected mail actions/compose fixture. No credentials or provider access."
    );
}

#[test]
fn provider_send_wire() {
    use crate::network::fixture::Fixture;
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    for provider in [Provider::Gmail, Provider::Outlook] {
        let store = Store::open(":memory:").unwrap();
        let mut account = account_fixture();
        account.provider = provider;
        store.save_account(&account).unwrap();
        let original = seed(&store);
        let result = compose(
            &store,
            &account.id,
            Some(&original.id),
            ComposeKind::ReplyAll,
            BodyMode::Cached,
            &Context::new(None, 10),
        )
        .unwrap();
        let mut draft: MailDraft = serde_json::from_value(result["draft"].clone()).unwrap();
        draft.text = "Hello from a synthetic fixture".into();
        draft.revision = store.save_mail_draft(&draft).unwrap();
        queue_send(&store, &draft.id, draft.revision).unwrap();
        let work = store.next_mail_work(MailWorkKind::Outbox).unwrap().unwrap();
        assert!(
            store
                .claim_mail_work(MailWorkKind::Outbox, &work.id)
                .unwrap()
        );
        let fixture = if provider == Provider::Gmail {
            Fixture::new(vec![(
                "POST /messages/send ",
                200,
                Some(json!({"id":"sent"})),
            )])
        } else {
            Fixture::new(vec![
                (
                    "POST /messages/original/createReplyAll ",
                    201,
                    Some(json!({"id":"draft-1"})),
                ),
                (
                    "GET /messages/draft-1?$select=isDraft ",
                    200,
                    Some(json!({"isDraft":true})),
                ),
                (
                    "PATCH /messages/draft-1 ",
                    200,
                    Some(json!({"id":"draft-1"})),
                ),
                ("POST /messages/draft-1/send ", 202, None),
            ])
        };
        let context = Context::new(None, 10);
        let remote = MailRemote::fixture(&account, &context, fixture.root.clone());
        let result = execute_work(
            &store,
            MailWorkKind::Outbox,
            &work,
            &account,
            &remote,
            &context,
        );
        assert!(
            finish_work(&store, MailWorkKind::Outbox, &work, result)
                .unwrap()
                .is_none()
        );
        assert!(
            store.mail_workspace().unwrap()["work"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let requests = fixture.finish();
        if provider == Provider::Gmail {
            assert_eq!(requests[0].value["threadId"], "thread-1");
            let wire = URL_SAFE_NO_PAD
                .decode(requests[0].value["raw"].as_str().unwrap())
                .unwrap();
            let parsed = mail_parser::MessageParser::default().parse(&wire).unwrap();
            assert_eq!(parsed.subject(), Some("Re: Notes"));
            assert_eq!(parsed.body_text(0).unwrap(), draft.text);
            assert!(String::from_utf8_lossy(&wire).contains("In-Reply-To: <source@example.test>"));
        } else {
            assert!(
                requests
                    .iter()
                    .all(|r| r.headers.contains("IdType=\"ImmutableId\""))
            );
            assert_eq!(requests[2].value["body"]["contentType"], "Text");
            assert_eq!(
                requests[2].value["ccRecipients"][0]["emailAddress"]["address"],
                "cc@example.test"
            );
        }
    }
}
#[test]
fn lost_send_stops() {
    use crate::network::fixture::Fixture;
    let store = Store::open(":memory:").unwrap();
    seed(&store);
    let account = account_fixture();
    let mut draft = new_draft(&store);
    draft.revision = store.save_mail_draft(&draft).unwrap();
    queue_send(&store, &draft.id, draft.revision).unwrap();
    let work = store.next_mail_work(MailWorkKind::Outbox).unwrap().unwrap();
    store
        .claim_mail_work(MailWorkKind::Outbox, &work.id)
        .unwrap();
    let fixture = Fixture::new(vec![(
        "POST /messages/send ",
        503,
        Some(json!({"error":"synthetic after acceptance"})),
    )]);
    let context = Context::new(None, 10);
    let remote = MailRemote::fixture(&account, &context, fixture.root.clone());
    let result = execute_work(
        &store,
        MailWorkKind::Outbox,
        &work,
        &account,
        &remote,
        &context,
    );
    assert!(
        finish_work(&store, MailWorkKind::Outbox, &work, result)
            .unwrap()
            .is_some()
    );
    assert!(
        store
            .next_mail_work(MailWorkKind::Outbox)
            .unwrap()
            .is_none()
    );
    assert_eq!(
        store.mail_workspace().unwrap()["work"][0]["state"],
        "uncertain"
    );
    assert!(
        store
            .mail_work_choice(&work.id, MailWorkKind::Outbox, MailWorkChoice::Retry)
            .is_err()
    );
    assert_eq!(fixture.finish().len(), 1);
}
#[test]
fn trash_uses_reversible_api() {
    use crate::network::fixture::Fixture;
    for provider in [Provider::Gmail, Provider::Outlook] {
        let store = Store::open(":memory:").unwrap();
        let mut account = account_fixture();
        account.provider = provider;
        store.save_account(&account).unwrap();
        let original = seed(&store);
        let action = MailAction::Trash;
        let queued = QueuedMail {
            operation: "synthetic-operation".into(),
            message: original,
            action,
            before: MailSnapshot {
                unread: true,
                flagged: false,
                folders: vec!["inbox".into()],
                memberships: vec!["label:INBOX".into(), "label:project".into()],
            },
        };
        let fixture = if provider == Provider::Gmail {
            Fixture::new(vec![(
                "POST /messages/original/trash ",
                200,
                Some(json!({"id":"original"})),
            )])
        } else {
            Fixture::new(vec![
                (
                    "GET /messages/original?$select=id,parentFolderId ",
                    200,
                    Some(json!({"id":"original","parentFolderId":"inbox"})),
                ),
                (
                    "POST /messages/original/move ",
                    201,
                    Some(json!({"id":"original"})),
                ),
            ])
        };
        let context = Context::new(None, 10);
        let remote = MailRemote::fixture(&account, &context, fixture.root.clone());
        remote
            .action(&queued, &store.folders(&account.id).unwrap())
            .unwrap();
        let requests = fixture.finish();
        assert!(requests.iter().all(|r| !r.line.starts_with("DELETE")));
        if provider == Provider::Outlook {
            assert_eq!(requests[1].value["destinationId"], "label:TRASH");
        }
    }
}
#[test]
fn gmail_move_keeps_labels() {
    use crate::network::fixture::Fixture;
    let store = Store::open(":memory:").unwrap();
    let original = seed(&store);
    let account = account_fixture();
    let queued = QueuedMail {
        operation: "synthetic-operation".into(),
        message: original,
        action: MailAction::Move {
            destination: "label:other".into(),
            source: Some("label:project".into()),
        },
        before: MailSnapshot {
            unread: true,
            flagged: false,
            folders: vec!["inbox".into()],
            memberships: vec![
                "label:INBOX".into(),
                "label:project".into(),
                "label:important".into(),
            ],
        },
    };
    let fixture = Fixture::new(vec![(
        "POST /messages/original/modify ",
        200,
        Some(json!({"id":"original"})),
    )]);
    let context = Context::new(None, 10);
    let remote = MailRemote::fixture(&account, &context, fixture.root.clone());
    remote
        .action(&queued, &store.folders(&account.id).unwrap())
        .unwrap();
    let requests = fixture.finish();
    assert_eq!(requests[0].value["addLabelIds"], json!(["other"]));
    assert_eq!(
        requests[0].value["removeLabelIds"],
        json!(["INBOX", "project"])
    );
}

#[test]
fn draft_and_outbox_limits() {
    let store = Store::open(":memory:").unwrap();
    seed(&store);
    let mut first = new_draft(&store);
    for i in 0..100 {
        let mut draft = first.clone();
        draft.id = format!("bounded-draft-{i:08}");
        store.save_mail_draft(&draft).unwrap();
    }
    assert!(store.save_mail_draft(&first).is_err());
    for i in 0..50 {
        let draft = store.mail_draft(&format!("bounded-draft-{i:08}")).unwrap();
        queue_send(&store, &draft.id, draft.revision).unwrap();
    }
    let overflow = store.mail_draft("bounded-draft-00000050").unwrap();
    assert!(queue_send(&store, &overflow.id, overflow.revision).is_err());
    assert!(store.mail_draft(&overflow.id).is_ok());
    first.account = "not-this-account".into();
    assert!(save_draft(&store, &first).is_err());
}
#[test]
fn retry_keeps_backoff() {
    let store = Store::open(":memory:").unwrap();
    let message = seed(&store);
    queue(
        &store,
        "throttled-operation",
        &message.id,
        MailAction::Read { unread: false },
    )
    .unwrap();
    store
        .mark_mail_work(
            MailWorkKind::Action,
            "throttled-operation",
            MailWorkState::Retry,
            Some("HTTP429"),
            600,
        )
        .unwrap();
    assert!(
        store
            .mail_work_choice(
                "throttled-operation",
                MailWorkKind::Action,
                MailWorkChoice::Retry
            )
            .is_err()
    );
    assert!(
        store
            .next_mail_work(MailWorkKind::Action)
            .unwrap()
            .is_none()
    );
}

#[test]
fn cancel_uses_latest_state() {
    let store = Store::open(":memory:").unwrap();
    let mut message = seed(&store);
    queue(
        &store,
        "pending-read-operation",
        &message.id,
        MailAction::Read { unread: false },
    )
    .unwrap();
    store
        .ensure_job("fixture", JobKind::RecentMail, "", 0)
        .unwrap();
    let job = SyncJob {
        account_id: "fixture".into(),
        kind: JobKind::RecentMail,
        resource: String::new(),
        window: 0,
        state: json!({}),
        failures: 0,
    };
    message.unread = false;
    message.starred = true;
    store
        .apply_mail(
            &job,
            &[(message.clone(), vec!["label:INBOX".into()])],
            &[],
            &json!({}),
            60,
        )
        .unwrap();
    store
        .mail_work_choice(
            "pending-read-operation",
            MailWorkKind::Action,
            MailWorkChoice::Cancel,
        )
        .unwrap();
    let cached = store.action_message(&message.id).unwrap();
    assert!(!cached.unread && cached.starred);
}
#[test]
fn pending_deleted_mail() {
    let store = Store::open(":memory:").unwrap();
    let message = seed(&store);
    queue(
        &store,
        "pending-trash-operation",
        &message.id,
        MailAction::Trash,
    )
    .unwrap();
    store
        .ensure_job("fixture", JobKind::RecentMail, "", 0)
        .unwrap();
    let job = SyncJob {
        account_id: "fixture".into(),
        kind: JobKind::RecentMail,
        resource: String::new(),
        window: 0,
        state: json!({}),
        failures: 0,
    };
    store
        .apply_mail(
            &job,
            &[],
            std::slice::from_ref(&message.remote_id),
            &json!({}),
            60,
        )
        .unwrap();
    assert!(store.message(&message.id).is_ok());
    store
        .mail_work_choice(
            "pending-trash-operation",
            MailWorkKind::Action,
            MailWorkChoice::Cancel,
        )
        .unwrap();
    assert!(store.message(&message.id).is_err());
}

#[test]
fn draft_missing_original() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("draft.sqlite");
    let store = Store::open(file.to_str().unwrap()).unwrap();
    let original = seed(&store);
    let result = compose(
        &store,
        "fixture",
        Some(&original.id),
        ComposeKind::Reply,
        BodyMode::Cached,
        &Context::new(None, 10),
    )
    .unwrap();
    let mut draft: MailDraft = serde_json::from_value(result["draft"].clone()).unwrap();
    draft.revision = store.save_mail_draft(&draft).unwrap();
    store
        .ensure_job("fixture", JobKind::RecentMail, "", 0)
        .unwrap();
    let job = SyncJob {
        account_id: "fixture".into(),
        kind: JobKind::RecentMail,
        resource: String::new(),
        window: 0,
        state: json!({}),
        failures: 0,
    };
    store
        .apply_mail(
            &job,
            &[],
            std::slice::from_ref(&original.remote_id),
            &json!({}),
            60,
        )
        .unwrap();
    draft.text = "Keep my new work".into();
    save_draft(&store, &draft).unwrap();
    let restored = store.mail_draft(&draft.id).unwrap();
    assert_eq!(restored.text, "Keep my new work");
    assert!(queue_send(&store, &restored.id, restored.revision).is_err());
}

#[test]
fn gmail_move_targets() {
    let store = Store::open(":memory:").unwrap();
    let message = seed(&store);
    let targets = move_folders(&store, "fixture").unwrap();
    assert!(
        !targets
            .iter()
            .any(|f| f.id == "label:UNREAD" || f.id == "label:SENT")
    );
    assert!(
        queue(
            &store,
            "bad-target-operation",
            &message.id,
            MailAction::Move {
                destination: "label:UNREAD".into(),
                source: None
            }
        )
        .is_err()
    );
    queue(
        &store,
        "trash-move-operation",
        &message.id,
        MailAction::Move {
            destination: "label:TRASH".into(),
            source: Some("label:INBOX".into()),
        },
    )
    .unwrap();
    let work = store.next_mail_work(MailWorkKind::Action).unwrap().unwrap();
    let queued: QueuedMail = serde_json::from_str(&work.data).unwrap();
    assert_eq!(queued.action, MailAction::Trash);
}

#[test]
fn outlook_trash_without_catalog() {
    use crate::network::fixture::Fixture;
    let store = Store::open(":memory:").unwrap();
    let account = Account {
        id: "outlook".into(),
        email: "reader@example.test".into(),
        provider: Provider::Outlook,
    };
    store.save_account(&account).unwrap();
    let message = mime::parse(
        b"From: Ada <ada@example.test>\r\nSubject: Trash fallback\r\n\r\nBody",
        &account.id,
        "original",
    )
    .unwrap();
    store.save(&message, Folder::Inbox).unwrap();
    queue(&store, "trash-without-map", &message.id, MailAction::Trash).unwrap();
    assert!(
        store
            .list(Some(&account.id), Folder::Inbox, "", 0, 250)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store
            .list(Some(&account.id), Folder::Trash, "", 0, 250)
            .unwrap()
            .len(),
        1
    );
    let pending = store.next_mail_work(MailWorkKind::Action).unwrap().unwrap();
    let work: QueuedMail = serde_json::from_str(&pending.data).unwrap();
    let fixture = Fixture::new(vec![
        (
            "GET /messages/original?$select=id,parentFolderId ",
            200,
            Some(json!({"id":"original","parentFolderId":"inbox-id"})),
        ),
        (
            "POST /messages/original/move ",
            201,
            Some(json!({"id":"original"})),
        ),
    ]);
    let context = Context::new(None, 10);
    let remote = MailRemote::fixture(&account, &context, fixture.root.clone());
    remote.action(&work, &[]).unwrap();
    let requests = fixture.finish();
    assert_eq!(requests[1].value["destinationId"], "deleteditems");
    assert!(requests.iter().all(|r| !r.line.starts_with("DELETE")));
    assert!(
        store
            .action_message("missing")
            .unwrap_err()
            .to_string()
            .contains("changed during sync")
    );
}

#[test]
#[ignore]
fn seed_action_nav_fixture() {
    let path = std::env::var("SQUAREMAIL_ACTION_NAV_DB").expect("Use a synthetic output database");
    let store = Store::open(&path).unwrap();
    let mut message = seed(&store);
    message.timestamp = 1_700_000_000;
    store.save(&message, Folder::Inbox).unwrap();
    for index in 1..260 {
        message.remote_id = format!("nav-{index}");
        message.id = crate::mime::message_id("fixture", &message.remote_id);
        message.timestamp = 1_700_000_000 + index;
        message.subject = format!("Navigation message {index}");
        store.save(&message, Folder::Inbox).unwrap();
    }
    store
        .pause_account("fixture", DisconnectMode::KeepCache)
        .unwrap();
    println!("Generated disconnected260message action-navigation fixture");
}

#[test]
fn bounded_send_receipts() {
    let store = Store::open(":memory:").unwrap();
    seed(&store);
    for _ in 0..25 {
        let mut draft = new_draft(&store);
        draft.revision = store.save_mail_draft(&draft).unwrap();
        queue_send(&store, &draft.id, draft.revision).unwrap();
        store
            .mark_mail_work(
                MailWorkKind::Outbox,
                &draft.id,
                MailWorkState::Done,
                None,
                0,
            )
            .unwrap();
    }
    let workspace = store.mail_workspace().unwrap();
    assert!(workspace["work"].as_array().unwrap().is_empty());
    let receipts = workspace["receipts"].as_array().unwrap();
    assert_eq!(receipts.len(), 20);
    assert!(receipts.iter().all(|r| r["state"] == "done"
        && r["kind"] == "outbox"
        && r.get("text").is_none()
        && r.get("data").is_none()));
}

#[test]
fn bulk_undo_atomic_offline() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("bulk.sqlite");
    let store = Store::open(path.to_str().unwrap()).unwrap();
    let first = seed(&store);
    let mut second = first.clone();
    second.id = "other".into();
    second.remote_id = "other".into();
    store.save(&second, Folder::Inbox).unwrap();
    let ids = vec![first.id.clone(), second.id.clone()];
    let edit = |action| MailEdit::Action { action };
    assert!(
        batch(
            &store,
            "bad-batch-test-operation",
            &[first.id.clone(), "missing".into()],
            edit(MailAction::Trash)
        )
        .is_err()
    );
    assert_eq!(store.list(None, Folder::Inbox, "", 0, 10).unwrap().len(), 2);
    assert!(
        store.mail_workspace().unwrap()["work"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    batch(
        &store,
        "archive-batch-test-operation",
        &ids,
        edit(MailAction::Archive),
    )
    .unwrap();
    batch(
        &store,
        "trash-batch-test-operation",
        &ids,
        edit(MailAction::Trash),
    )
    .unwrap();
    drop(store);
    let store = Store::open(path.to_str().unwrap()).unwrap();
    store.undo_mail("trash-batch-test-operation").unwrap();
    assert_eq!(
        store.list(None, Folder::Archive, "", 0, 10).unwrap().len(),
        2
    );
    store.undo_mail("archive-batch-test-operation").unwrap();
    assert_eq!(store.list(None, Folder::Inbox, "", 0, 10).unwrap().len(), 2);
    assert!(
        store.mail_workspace().unwrap()["work"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    batch(
        &store,
        "read-batch-test-operation",
        &ids,
        edit(MailAction::Read { unread: false }),
    )
    .unwrap();
    assert!(!store.message(&first.id).unwrap().unread);
    store.undo_mail("read-batch-test-operation").unwrap();
    let restored = store.message(&first.id).unwrap();
    assert!(restored.unread && !restored.keep_unread);
    batch(
        &store,
        "pin-batch-test-operation",
        &ids,
        MailEdit::Pin { pinned: true },
    )
    .unwrap();
    assert!(store.message(&first.id).unwrap().pinned);
    store.undo_mail("pin-batch-test-operation").unwrap();
    assert!(!store.message(&first.id).unwrap().pinned);
    batch(
        &store,
        "flag-batch-test-operation",
        &ids,
        edit(MailAction::Flag { flagged: true }),
    )
    .unwrap();
    store.undo_mail("flag-batch-test-operation").unwrap();
    assert!(!store.message(&first.id).unwrap().starred);
}

#[test]
fn bulk_undo_remote_wait() {
    let store = Store::open(":memory:").unwrap();
    let message = seed(&store);
    batch(
        &store,
        "remote-batch-test-operation",
        std::slice::from_ref(&message.id),
        MailEdit::Action {
            action: MailAction::Trash,
        },
    )
    .unwrap();
    store
        .mark_mail_work(
            MailWorkKind::Action,
            "remote-batch-test-operation-0",
            MailWorkState::Sending,
            None,
            0,
        )
        .unwrap();
    assert!(store.undo_mail("remote-batch-test-operation").is_err());
    assert_eq!(store.list(None, Folder::Trash, "", 0, 10).unwrap().len(), 1);
    store
        .mark_mail_work(
            MailWorkKind::Action,
            "remote-batch-test-operation-0",
            MailWorkState::Done,
            None,
            0,
        )
        .unwrap();
    store.undo_mail("remote-batch-test-operation").unwrap();
    assert_eq!(store.list(None, Folder::Inbox, "", 0, 10).unwrap().len(), 1);
    let work = store.mail_workspace().unwrap();
    assert!(
        work["work"]
            .as_array()
            .unwrap()
            .iter()
            .any(|w| w["id"] == "undo-remote-batch-test-operation-0")
    );
}

#[test]
fn bulk_undo_conflict_rollback() {
    let store = Store::open(":memory:").unwrap();
    let first = seed(&store);
    let mut other = first.clone();
    other.id = "other".into();
    other.remote_id = "other".into();
    store.save(&other, Folder::Inbox).unwrap();
    let ids = vec![first.id.clone(), other.id.clone()];
    batch(
        &store,
        "pins-test-operation",
        &ids,
        MailEdit::Pin { pinned: true },
    )
    .unwrap();
    store.pin_mail(&other.id, MailToggle::Off).unwrap();
    assert!(store.undo_mail("pins-test-operation").is_err());
    assert!(store.message(&first.id).unwrap().pinned);
    assert!(
        batch(
            &store,
            "duplicates-test-operation",
            &[first.id.clone(), first.id],
            MailEdit::Pin { pinned: true }
        )
        .is_err()
    );
    assert!(
        batch(
            &store,
            "too-many-test-operation",
            &(0..101).map(|i| format!("id-{i}")).collect::<Vec<_>>(),
            MailEdit::Pin { pinned: true }
        )
        .is_err()
    );
}

#[test]
fn undo_wire_folders() {
    use crate::network::fixture::Fixture;
    for provider in [Provider::Gmail, Provider::Outlook] {
        let store = Store::open(":memory:").unwrap();
        let message = seed(&store);
        let mut account = account_fixture();
        account.provider = provider;
        let original = MailSnapshot {
            unread: true,
            flagged: false,
            folders: vec!["inbox".into()],
            memberships: if provider == Provider::Gmail {
                vec!["label:INBOX".into(), "label:project".into()]
            } else {
                vec!["original-folder".into()]
            },
        };
        let trash = MailSnapshot {
            unread: true,
            flagged: false,
            folders: vec!["trash".into()],
            memberships: if provider == Provider::Gmail {
                vec!["label:TRASH".into(), "label:project".into()]
            } else {
                vec!["deleted-folder".into()]
            },
        };
        let work = QueuedMail {
            operation: "undo-wire-test-operation".into(),
            message,
            action: MailAction::Restore { snapshot: original },
            before: trash,
        };
        let fixture = if provider == Provider::Gmail {
            Fixture::new(vec![
                ("POST /messages/original/untrash ", 200, Some(json!({}))),
                ("POST /messages/original/modify ", 200, Some(json!({}))),
            ])
        } else {
            Fixture::new(vec![
                (
                    "GET /messages/original?$select=id,parentFolderId ",
                    200,
                    Some(json!({"id":"original","parentFolderId":"deleted-folder"})),
                ),
                (
                    "POST /messages/original/move ",
                    201,
                    Some(json!({"id":"original"})),
                ),
            ])
        };
        let context = Context::new(None, 10);
        MailRemote::fixture(&account, &context, fixture.root.clone())
            .action(&work, &[])
            .unwrap();
        let requests = fixture.finish();
        assert!(requests.iter().all(|r| !r.line.starts_with("DELETE")));
        if provider == Provider::Gmail {
            assert_eq!(requests[1].value["addLabelIds"], json!(["INBOX"]));
            assert_eq!(requests[1].value["removeLabelIds"], json!([]));
        } else {
            assert_eq!(requests[1].value["destinationId"], "original-folder");
        }
    }
}

#[test]
fn bulk_accounts_and_bounds() {
    let store = Store::open(":memory:").unwrap();
    let first = seed(&store);
    let account = Account {
        id: "second".into(),
        email: "second@example.test".into(),
        provider: Provider::Outlook,
    };
    store.save_account(&account).unwrap();
    let mut second = first.clone();
    second.account_id = account.id.clone();
    second.id = mime::message_id(&account.id, &first.remote_id);
    store.save(&second, Folder::Inbox).unwrap();
    let ids = vec![first.id.clone(), second.id.clone()];
    batch(
        &store,
        "two-account-operation",
        &ids,
        MailEdit::Action {
            action: MailAction::Trash,
        },
    )
    .unwrap();
    assert_eq!(store.list(None, Folder::Trash, "", 0, 10).unwrap().len(), 2);
    store.undo_mail("two-account-operation").unwrap();
    assert_eq!(store.list(None, Folder::Inbox, "", 0, 10).unwrap().len(), 2);
    assert!(
        batch(
            &store,
            "bad-move-operation",
            &ids,
            MailEdit::Action {
                action: MailAction::Move {
                    destination: "label:project".into(),
                    source: None
                }
            }
        )
        .is_err()
    );
    assert_eq!(store.list(None, Folder::Inbox, "", 0, 10).unwrap().len(), 2);
    for index in 0..25 {
        batch(
            &store,
            &format!("bounded-pin-operation-{index}"),
            std::slice::from_ref(&first.id),
            MailEdit::Pin {
                pinned: index % 2 == 0,
            },
        )
        .unwrap();
    }
    assert!(store.undo_mail("bounded-pin-operation-0").is_err());
    store.undo_mail("bounded-pin-operation-24").unwrap();
    batch(
        &store,
        "removed-account-operation",
        &ids,
        MailEdit::Pin { pinned: true },
    )
    .unwrap();
    store
        .pause_account(&account.id, DisconnectMode::RemoveCache)
        .unwrap();
    assert!(store.undo_mail("removed-account-operation").is_err());
    assert!(store.message(&first.id).unwrap().pinned);
}

#[test]
fn bulk_undo_coalesced_sync() {
    for settle_inverse in [false, true] {
        let store = Store::open(":memory:").unwrap();
        let message = seed(&store);
        let ids = std::slice::from_ref(&message.id);
        batch(
            &store,
            "first-archive-operation",
            ids,
            MailEdit::Action {
                action: MailAction::Archive,
            },
        )
        .unwrap();
        batch(
            &store,
            "second-trash-operation",
            ids,
            MailEdit::Action {
                action: MailAction::Trash,
            },
        )
        .unwrap();
        store
            .mark_mail_work(
                MailWorkKind::Action,
                "first-archive-operation-0",
                MailWorkState::Done,
                None,
                0,
            )
            .unwrap();
        store.undo_mail("second-trash-operation").unwrap();
        if settle_inverse {
            store
                .mark_mail_work(
                    MailWorkKind::Action,
                    "undo-second-trash-operation-0",
                    MailWorkState::Done,
                    None,
                    0,
                )
                .unwrap();
        }
        store.undo_mail("first-archive-operation").unwrap();
        assert_eq!(store.list(None, Folder::Inbox, "", 0, 10).unwrap().len(), 1);
        let pending = store.next_mail_work(MailWorkKind::Action).unwrap().unwrap();
        let work: QueuedMail = serde_json::from_str(&pending.data).unwrap();
        assert!(
            matches!(work.action,MailAction::Restore { snapshot } if snapshot.folders.contains(&"inbox".into()))
        );
    }
}

#[test]
fn trash_leaves_smart_views() {
    let store = Store::open(":memory:").unwrap();
    let mut message = seed(&store);
    message.starred = true;
    store.save(&message, Folder::Sent).unwrap();
    let ids = std::slice::from_ref(&message.id);
    batch(
        &store,
        "project-before-operation",
        ids,
        MailEdit::Action {
            action: MailAction::Move {
                destination: "label:project".into(),
                source: None,
            },
        },
    )
    .unwrap();
    batch(
        &store,
        "smart-trash-operation",
        ids,
        MailEdit::Action {
            action: MailAction::Trash,
        },
    )
    .unwrap();
    for folder in [Folder::Starred, Folder::Unread, Folder::Sent] {
        for query in ["", "Notes"] {
            assert!(store.list(None, folder, query, 0, 10).unwrap().is_empty());
        }
        let scope = crate::store::MailScope {
            account: None,
            folder,
            remote: None,
        };
        assert!(
            store
                .search_folder(scope, "Ntoes", SearchMode::Smart, 0, 10)
                .unwrap()
                .messages
                .is_empty()
        );
    }
    assert!(
        store
            .list_folder(None, Folder::All, Some("label:project"), "", 0, 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store
            .list_folder(None, Folder::All, Some("label:TRASH"), "", 0, 10)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        store.list(None, Folder::All, "Notes", 0, 10).unwrap().len(),
        1
    );
    assert_eq!(store.list(None, Folder::Trash, "", 0, 10).unwrap().len(), 1);
    store.undo_mail("smart-trash-operation").unwrap();
    assert_eq!(
        store.list(None, Folder::Starred, "", 0, 10).unwrap().len(),
        1
    );
    assert!(store.message(&message.id).unwrap().starred);
}
