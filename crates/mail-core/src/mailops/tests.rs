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
    let store = Store::open(":memory:").unwrap();
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
            .iter()
            .any(|m| m.id == message.id)
    );
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
