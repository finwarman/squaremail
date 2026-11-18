use super::*;
use crate::network::Reply;
use std::{
    io::{Read, Write},
    net::TcpListener,
    thread,
    time::{Duration, Instant},
};

fn account(provider: Provider) -> Account {
    Account {
        id: "fixture".into(),
        email: "fin@example.test".into(),
        provider,
    }
}
fn key() -> EventKey {
    EventKey {
        account: "fixture".into(),
        calendar: "primary".into(),
        id: Some("event".into()),
    }
}
fn raw(provider: Provider) -> Value {
    if provider == Provider::Gmail {
        json!({"id":"event","etag":"\"v1\"","summary":"Original","start":{"dateTime":"2026-11-18T10:00:00Z","timeZone":"Europe/London"},"end":{"dateTime":"2026-11-18T11:00:00Z","timeZone":"Europe/London"},"organizer":{"self":true,"displayName":"Team","email":"opaque@group.calendar.google.com"},"attendees":[{"email":"ada@example.test","displayName":"Ada","responseStatus":"accepted"}],"recurringEventId":"series","conferenceData":{"signature":"keep-me"},"extendedProperties":{"private":{"unknown":"preserve"}},"description":"Original meeting data"})
    } else {
        json!({"id":"event","@odata.etag":"\"v1\"","subject":"Original","start":{"dateTime":"2026-11-18T10:00:00","timeZone":"UTC"},"end":{"dateTime":"2026-11-18T11:00:00","timeZone":"UTC"},"originalStartTimeZone":"GMT Standard Time","organizer":{"emailAddress":{"name":"Team","address":"team@example.test"}},"isOrganizer":true,"attendees":[{"emailAddress":{"name":"Ada","address":"ada@example.test"},"status":{"response":"accepted"}}],"seriesMasterId":"series","onlineMeeting":{"joinUrl":"https://teams.example.test/meeting"},"body":{"contentType":"HTML","content":"Meeting blob"},"categories":["Keep"]})
    }
}
fn detail(provider: Provider) -> EventDetail {
    remote::Remote::decode(
        &account(provider),
        &key(),
        Reply {
            value: raw(provider),
            etag: None,
        },
        remote::SourceAccess::Write,
    )
    .unwrap()
}
fn change(base: &EventDetail) -> EventChange {
    let mut draft = base.draft.clone();
    draft.title = "Updated".into();
    EventChange {
        operation: "fixture-operation-0001".into(),
        key: base.key.clone(),
        revision: Some(base.revision.clone()),
        draft,
        updates: GuestUpdates::Notify,
    }
}

#[test]
fn edit_patch_preserves_metadata() {
    for provider in [Provider::Gmail, Provider::Outlook] {
        let base = detail(provider);
        let change = change(&base);
        let patch = draft::patch(provider, &change, &base).unwrap();
        assert_eq!(patch.as_object().unwrap().len(), 1);
        assert_eq!(
            patch[if provider == Provider::Gmail {
                "summary"
            } else {
                "subject"
            }],
            "Updated"
        );
        assert_eq!(base.raw, raw(provider));
        assert_eq!(base.organizer, "Team");
        assert!(base.recurring);
        assert_eq!(base.participants, ["Ada (accepted)"]);
        let mut unapproved = change;
        unapproved.updates = GuestUpdates::Personal;
        assert!(draft::patch(provider, &unapproved, &base).is_err());
    }
}
#[test]
fn queue_is_durable_bounded() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("cache.sqlite");
    let store = Store::open(path.to_str().unwrap()).unwrap();
    let account = account(Provider::Gmail);
    store.save_account(&account).unwrap();
    let base = detail(Provider::Gmail);
    let mut change = change(&base);
    change.key.id = None;
    change.revision = None;
    let write = PendingWrite {
        change,
        base: None,
        attempts: 0,
    };
    store.queue_event(&write).unwrap();
    store.queue_event(&write).unwrap();
    drop(store);
    let store = Store::open(path.to_str().unwrap()).unwrap();
    assert_eq!(
        store.next_event_write().unwrap().unwrap().change.operation,
        write.change.operation
    );
    let mut altered = write;
    altered.change.draft.title = "Different".into();
    assert!(store.queue_event(&altered).is_err());
    for index in 2..=QUEUE_LIMIT {
        altered.change.operation = format!("fixture-operation-{index:04}");
        store.queue_event(&altered).unwrap();
    }
    altered.change.operation = "fixture-operation-overflow".into();
    assert!(store.queue_event(&altered).is_err());
    assert_eq!(
        store.event_writes().unwrap().as_array().unwrap().len(),
        QUEUE_LIMIT
    );
}

struct Fixture {
    root: String,
    worker: Option<thread::JoinHandle<()>>,
}
impl Fixture {
    fn new(replies: Vec<(&str, Value)>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let root = format!("http://{}", listener.local_addr().unwrap());
        let replies = replies
            .into_iter()
            .map(|(request, value)| (request.to_string(), value))
            .collect::<Vec<_>>();
        let worker = thread::spawn(move || {
            for (expected, value) in replies {
                let begin = Instant::now();
                let mut stream = loop {
                    match listener.accept() {
                        Ok((s, _)) => break s,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            assert!(
                                begin.elapsed() < Duration::from_secs(3),
                                "Missing {expected}"
                            );
                            thread::sleep(Duration::from_millis(2));
                        }
                        Err(e) => panic!("{e}"),
                    }
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut data = Vec::new();
                let mut buffer = [0; 1024];
                let header_end = loop {
                    let n = stream.read(&mut buffer).unwrap();
                    assert!(n > 0);
                    data.extend_from_slice(&buffer[..n]);
                    if let Some(i) = data.windows(4).position(|s| s == b"\r\n\r\n") {
                        break i + 4;
                    }
                };
                let headers = String::from_utf8_lossy(&data[..header_end]).to_lowercase();
                assert!(String::from_utf8_lossy(&data).starts_with(&expected));
                let length = headers
                    .lines()
                    .find_map(|s| {
                        s.strip_prefix("content-length: ")?
                            .trim()
                            .parse::<usize>()
                            .ok()
                    })
                    .unwrap_or(0);
                while data.len() < header_end + length {
                    let n = stream.read(&mut buffer).unwrap();
                    assert!(n > 0);
                    data.extend_from_slice(&buffer[..n]);
                }
                if expected.starts_with("PATCH") {
                    assert!(headers.contains("if-match: \"v1\""));
                    let body: Value =
                        serde_json::from_slice(&data[header_end..header_end + length]).unwrap();
                    assert_eq!(body, json!({"subject":"Updated"}));
                }
                let bytes = value.to_string();
                write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{bytes}",bytes.len()).unwrap();
            }
        });
        Self {
            root,
            worker: Some(worker),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.worker.take().unwrap().join().unwrap();
    }
}
#[test]
fn graph_save_is_conditional() {
    let account = account(Provider::Outlook);
    let base = detail(Provider::Outlook);
    let change = change(&base);
    let mut updated = raw(Provider::Outlook);
    updated["subject"] = json!("Updated");
    updated["@odata.etag"] = json!("\"v2\"");
    let source = json!({"canEdit":true});
    let fixture = Fixture::new(vec![
        ("GET /calendars/primary ", source.clone()),
        (
            "GET /calendars/primary/events/event ",
            raw(Provider::Outlook),
        ),
        ("PATCH /calendars/primary/events/event ", updated.clone()),
        ("GET /calendars/primary ", source),
        ("GET /calendars/primary/events/event ", updated.clone()),
    ]);
    let context = Context::new(None, 10);
    let remote = remote::Remote::fixture(&account, &context, fixture.root.clone());
    let saved = remote
        .save(&PendingWrite {
            change,
            base: Some(base),
            attempts: 0,
        })
        .unwrap();
    assert_eq!(saved.draft.title, "Updated");
    assert_eq!(saved.raw["body"], updated["body"]);
}
#[test]
fn stale_revision_is_blocked() {
    let account = account(Provider::Outlook);
    let base = detail(Provider::Outlook);
    let change = change(&base);
    let mut newer = raw(Provider::Outlook);
    newer["@odata.etag"] = json!("\"v2\"");
    let fixture = Fixture::new(vec![
        ("GET /calendars/primary ", json!({"canEdit":true})),
        ("GET /calendars/primary/events/event ", newer),
    ]);
    let context = Context::new(None, 10);
    let remote = remote::Remote::fixture(&account, &context, fixture.root.clone());
    let error = remote
        .save(&PendingWrite {
            change,
            base: Some(base),
            attempts: 0,
        })
        .unwrap_err();
    assert!(crate::network::is_status(error.as_ref(), 412));
}

#[test]
#[ignore = "generates a disconnected editor/notification native fixture"]
fn seed_actions_fixture() {
    let path = std::env::var("SQUAREMAIL_ACTIONS_DB")
        .expect("Set SQUAREMAIL_ACTIONS_DB to a new disposable path");
    assert!(!std::path::Path::new(&path).exists());
    let store = Store::open(&path).unwrap();
    let account = account(Provider::Gmail);
    store.save_account(&account).unwrap();
    store
        .ensure_job(&account.id, JobKind::Catalog, "", 0)
        .unwrap();
    let job = SyncJob {
        account_id: account.id.clone(),
        kind: JobKind::Catalog,
        resource: "".into(),
        window: 0,
        state: json!({}),
        failures: 0,
    };
    store
        .apply_catalog(
            &job,
            &[],
            &[CalendarSource {
                account_id: account.id.clone(),
                id: "primary".into(),
                name: "Fixture calendar".into(),
                color: "#2C68AD".into(),
                is_primary: true,
            }],
            &json!({"finish_catalog":true}),
            900,
        )
        .unwrap();
    store.save_event_detail(&detail(Provider::Gmail)).unwrap();
    let message = crate::mime::parse(
        b"From: Ada <ada@example.test>\r\nSubject: Notification fixture\r\n\r\nNotification body",
        &account.id,
        "notification",
    )
    .unwrap();
    store.save(&message, Folder::Inbox).unwrap();
    store.seed_action_notices(&account.id);
    store
        .pause_account(&account.id, DisconnectMode::KeepCache)
        .unwrap();
    println!(
        "Generated cached event metadata and bounded notifications. No credentials or provider access."
    );
}

#[test]
fn creates_use_stable_ids() {
    let base = detail(Provider::Gmail);
    let mut change = change(&base);
    change.key.id = None;
    change.revision = None;
    for provider in [Provider::Gmail, Provider::Outlook] {
        let first = draft::create(provider, &change).unwrap();
        let retry = draft::create(provider, &change).unwrap();
        assert_eq!(first, retry);
        assert!(first.get("attendees").is_none());
        assert!(first.get("recurrence").is_none());
        if provider == Provider::Gmail {
            assert_eq!(
                first["extendedProperties"]["private"]["squaremailOperation"],
                change.operation
            );
            assert!(
                first["id"]
                    .as_str()
                    .unwrap()
                    .chars()
                    .all(|c| c.is_ascii_hexdigit())
            );
        } else {
            assert_eq!(first["transactionId"], change.operation);
        }
    }
}
#[test]
fn lost_patch_result_is_recovered() {
    let account = account(Provider::Outlook);
    let base = detail(Provider::Outlook);
    let change = change(&base);
    let mut updated = raw(Provider::Outlook);
    updated["subject"] = json!("Updated");
    updated["@odata.etag"] = json!("\"v2\"");
    let fixture = Fixture::new(vec![
        ("GET /calendars/primary ", json!({"canEdit":true})),
        ("GET /calendars/primary/events/event ", updated),
    ]);
    let context = Context::new(None, 10);
    let remote = remote::Remote::fixture(&account, &context, fixture.root.clone());
    let saved = remote
        .save(&PendingWrite {
            change,
            base: Some(base),
            attempts: 1,
        })
        .unwrap();
    assert_eq!(saved.draft.title, "Updated");
}
#[test]
fn reminders_keep_floating_dates() {
    let account = account(Provider::Gmail);
    let mut value = raw(Provider::Gmail);
    value["start"] = json!({"date":"2026-03-30"});
    value["end"] = json!({"date":"2026-03-31"});
    value["reminders"] = json!({"useDefault":true});
    let event = parsed_event(&account, &key(), &value).unwrap();
    let defaults = json!([{"method":"popup","minutes":10},{"method":"email","minutes":30}]);
    let expected = chrono::DateTime::parse_from_rfc3339("2026-03-29T22:50:00Z")
        .unwrap()
        .timestamp();
    assert_eq!(
        crate::notices::reminder_times(&account, &event, &value, &defaults, "Europe/London"),
        [expected]
    );
    let mut draft = detail(Provider::Outlook).draft;
    draft.time = EventTime::AllDay {
        start: "2026-03-30".into(),
        end: "2026-03-31".into(),
        zone: "Europe/London".into(),
    };
    draft::validate(&draft).unwrap();
    let body = draft::create(
        Provider::Outlook,
        &EventChange {
            operation: "all-day-operation".into(),
            key: EventKey {
                account: "fixture".into(),
                calendar: "primary".into(),
                id: None,
            },
            revision: None,
            draft,
            updates: GuestUpdates::Personal,
        },
    )
    .unwrap();
    assert_eq!(body["start"]["dateTime"], "2026-03-30T00:00:00");
    assert_eq!(body["start"]["timeZone"], "Europe/London");
    assert_eq!(body["isAllDay"], true);
}

#[test]
fn local_drafts_survive_and_bound() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("drafts.sqlite");
    let store = Store::open(path.to_str().unwrap()).unwrap();
    store.save_account(&account(Provider::Gmail)).unwrap();
    let base = detail(Provider::Gmail);
    let change = change(&base);
    let write = PendingWrite {
        change,
        base: Some(base),
        attempts: 0,
    };
    store.save_event_draft(&write).unwrap();
    drop(store);
    let store = Store::open(path.to_str().unwrap()).unwrap();
    let restored = store.event_draft(&write.change.operation).unwrap().unwrap();
    assert_eq!(restored.base.unwrap().raw, raw(Provider::Gmail));
    for i in 2..=20 {
        let mut draft = PendingWrite {
            change: write.change.clone(),
            base: write.base.clone(),
            attempts: 0,
        };
        draft.change.operation = format!("fixture-draft-operation-{i:04}");
        store.save_event_draft(&draft).unwrap();
    }
    let mut overflow = PendingWrite {
        change: write.change.clone(),
        base: write.base.clone(),
        attempts: 0,
    };
    overflow.change.operation = "draft-overflow-operation".into();
    assert!(store.save_event_draft(&overflow).is_err());
    store.queue_event(&write).unwrap();
    assert!(
        store
            .event_draft(&write.change.operation)
            .unwrap()
            .is_none()
    );
    assert_eq!(store.event_writes().unwrap().as_array().unwrap().len(), 20);
}

#[test]
fn moved_draft_follows_account() {
    let store = Store::open(":memory:").unwrap();
    let first = account(Provider::Gmail);
    let mut second = account(Provider::Outlook);
    second.id = "second".into();
    store.save_account(&first).unwrap();
    store.save_account(&second).unwrap();
    let mut change = change(&detail(Provider::Gmail));
    change.key.id = None;
    change.revision = None;
    save_draft(&store, change.clone()).unwrap();
    change.key.account = second.id.clone();
    save_draft(&store, change.clone()).unwrap();
    store
        .pause_account(&first.id, DisconnectMode::RemoveCache)
        .unwrap();
    let saved = store.event_draft(&change.operation).unwrap().unwrap();
    assert_eq!(saved.change.key.account, second.id);
    store
        .pause_account(&second.id, DisconnectMode::RemoveCache)
        .unwrap();
    assert!(store.event_draft(&change.operation).unwrap().is_none());
}
