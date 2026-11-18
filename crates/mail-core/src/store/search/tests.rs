use super::*;
use crate::mime;

fn setup(path: &str) -> Store {
    let store = Store::open(path).unwrap();
    for id in ["a", "b"] {
        store
            .save_account(&Account {
                id: id.into(),
                email: format!("{id}@example.test"),
                provider: Provider::Local,
            })
            .unwrap();
    }
    store
}
fn message(account: &str, id: &str) -> Message {
    let mut value = mime::parse(b"From: Accounts Desk <billing@needle.test>\r\nSubject: Engine invoice\r\n\r\nOriginal searchable quartz.", account, id).unwrap();
    value.preview = "Summary".into();
    value
}
fn scope(account: Option<&str>, folder: Folder) -> MailScope<'_> {
    MailScope {
        account,
        folder,
        remote: None,
    }
}
fn smart(store: &Store, scope: MailScope<'_>, query: &str) -> SearchPage {
    store
        .search_folder(scope, query, SearchMode::Smart, 0, 250)
        .unwrap()
}

#[test]
fn address_and_body_lifecycle() {
    let store = setup(":memory:");
    let mut mail = message("a", "1");
    store.save(&mail, Folder::Inbox).unwrap();
    let here = scope(Some("a"), Folder::Inbox);
    assert_eq!(smart(&store, here, "BILLING@NEEDLE.TEST").messages.len(), 1);
    assert_eq!(smart(&store, here, "needle").messages.len(), 1);
    mail.sender_address = "dispatch@changed.test".into();
    mail.text = None;
    mail.html = None;
    store.save(&mail, Folder::Inbox).unwrap();
    assert!(smart(&store, here, "billing").messages.is_empty());
    assert_eq!(smart(&store, here, "dispatch").messages.len(), 1);
    assert_eq!(smart(&store, here, "quartz").messages.len(), 1);
    store
        .save_body(&mail.id, "Newly downloaded telescope", "<b>HTML only</b>")
        .unwrap();
    assert_eq!(smart(&store, here, "telescope").messages.len(), 1);
    assert!(smart(&store, here, "quartz").messages.is_empty());
    assert!(smart(&store, here, "HTML only").messages.is_empty());
    store
        .connection
        .execute("DELETE FROM messages WHERE id=?1", [&mail.id])
        .unwrap();
    assert!(smart(&store, here, "telesocpe").messages.is_empty());
}

#[test]
fn fuzzy_scopes_and_literal_first() {
    let store = setup(":memory:");
    for (account, folder) in [
        ("a", Folder::Inbox),
        ("a", Folder::Archive),
        ("b", Folder::Inbox),
    ] {
        let mail = message(account, folder.as_str());
        store.save(&mail, folder).unwrap();
        store
            .connection
            .execute(
                "INSERT OR IGNORE INTO mail_folders VALUES(?1,'shared','Nested',NULL,NULL)",
                [account],
            )
            .unwrap();
        store
            .connection
            .execute(
                "INSERT INTO mail_membership VALUES(?1,?2,'shared')",
                params![account, mail.remote_id],
            )
            .unwrap();
    }
    for query in [
        "engnie",
        "invocie",
        "billnig@needle.test",
        "billing@needel.test",
        "bngine",
        "enggine",
        "engne",
    ] {
        let result = smart(&store, scope(Some("a"), Folder::Inbox), query);
        assert_eq!(result.kind, SearchMatch::Approximate, "{query}");
        assert_eq!(result.messages.len(), 1, "{query}");
        assert_eq!(result.messages[0].account_id, "a");
        assert!(result.messages[0].text.is_none());
    }
    assert_eq!(
        smart(&store, scope(None, Folder::All), "engnie")
            .messages
            .len(),
        3
    );
    assert_eq!(
        smart(&store, scope(Some("a"), Folder::Archive), "engnie")
            .messages
            .len(),
        1
    );
    let nested = MailScope {
        account: Some("b"),
        folder: Folder::All,
        remote: Some("shared"),
    };
    let result = smart(&store, nested, "engnie");
    assert_eq!(result.messages.len(), 1);
    assert_eq!(result.messages[0].account_id, "b");
    let result = store
        .search_folder(
            scope(None, Folder::All),
            "engnie",
            SearchMode::Literal,
            0,
            250,
        )
        .unwrap();
    assert!(result.messages.is_empty());
    let mut literal = message("b", "literal");
    literal.subject = "engnie".into();
    store.save(&literal, Folder::Inbox).unwrap();
    let result = smart(&store, scope(None, Folder::All), "engnie");
    assert_eq!(result.kind, SearchMatch::Literal);
    assert_eq!(result.messages.len(), 1);
    // Literal hits in another account do not suppress this account's fuzzy fallback.
    assert_eq!(
        smart(&store, scope(Some("a"), Folder::Inbox), "engnie").kind,
        SearchMatch::Approximate
    );
    let next = store
        .search_folder(
            scope(None, Folder::All),
            "engnie",
            SearchMode::Smart,
            250,
            250,
        )
        .unwrap();
    assert_eq!(next.kind, SearchMatch::Literal);
    assert!(next.messages.is_empty());
}

#[test]
fn legacy_search_migration() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("mail.sqlite");
    let path = path.to_str().unwrap();
    let id;
    {
        let store = setup(path);
        let mail = message("a", "legacy");
        id = mail.id.clone();
        store.save(&mail, Folder::Archive).unwrap();
        let draft = MailDraft {
            id: "kept-draft".into(),
            account: "a".into(),
            kind: ComposeKind::New,
            original: None,
            to: vec!["reader@example.test".into()],
            cc: vec![],
            bcc: vec![],
            subject: "Unsent draft".into(),
            text: "Keep this local text".into(),
            headers: None,
            revision: 0,
        };
        store.save_mail_draft(&draft).unwrap();
        store
            .queue_mail(
                "kept-action",
                mail.clone(),
                MailAction::Read { unread: false },
            )
            .unwrap();
        store.pin_mail(&id, true.into()).unwrap();
        store.connection.execute_batch("DROP TRIGGER message_insert;DROP TRIGGER message_update;DROP TRIGGER message_delete;DROP TABLE message_vocabulary;DROP TABLE message_search;").unwrap();
        store
            .connection
            .execute_batch(include_str!("legacy-v3.sql"))
            .unwrap();
        store.connection.execute_batch("INSERT INTO message_search(message_search) VALUES('rebuild');PRAGMA user_version=3;").unwrap();
        assert!(
            store
                .list(Some("a"), Folder::Archive, "billing", 0, 250)
                .unwrap()
                .is_empty()
        );
    }
    let store = Store::open(path).unwrap();
    let page = smart(
        &store,
        scope(Some("a"), Folder::Archive),
        "billing@needle.test",
    );
    assert_eq!(page.messages.len(), 1);
    assert_eq!(page.messages[0].id, id);
    assert!(page.messages[0].pinned);
    assert!(store.message(&id).unwrap().text.unwrap().contains("quartz"));
    assert_eq!(
        store.mail_draft("kept-draft").unwrap().text,
        "Keep this local text"
    );
    assert_eq!(
        store.mail_workspace().unwrap()["work"][0]["id"],
        "kept-action"
    );
    let version: i64 = store
        .connection
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, SCHEMA_VERSION);
    drop(store);
    let store = Store::open(path).unwrap();
    assert_eq!(
        smart(&store, scope(None, Folder::All), "bililng")
            .messages
            .len(),
        1
    );
}

#[test]
fn bounds_and_literal_input() {
    let store = setup(":memory:");
    let here = scope(None, Folder::All);
    store.save(&message("a", "1"), Folder::Inbox).unwrap();
    for query in [
        "*",
        "'",
        "\"",
        "engine OR forbidden",
        "NEAR(a b)",
        "\" OR 1=1 --",
        "123456",
    ] {
        assert!(smart(&store, here, query).messages.is_empty(), "{query}");
    }
    assert!(
        store
            .search_folder(
                here,
                &"a".repeat(QUERY_BYTES + 1),
                SearchMode::Smart,
                0,
                250
            )
            .is_err()
    );
    assert!(
        store
            .search_folder(
                here,
                &"a ".repeat(QUERY_PARTS + 1),
                SearchMode::Smart,
                0,
                250
            )
            .is_err()
    );
    assert!(edits(&"a".repeat(WORD_MAX)).len() <= CANDIDATE_LIMIT);
    let mut mail = message("a", "unicode");
    mail.sender = "José Müller".into();
    mail.subject = "Café notes".into();
    store.save(&mail, Folder::Inbox).unwrap();
    assert_eq!(smart(&store, here, "cafe").messages.len(), 1);
    assert_eq!(smart(&store, here, "Josèe").messages.len(), 1);
    let plan:String=store.connection.query_row("EXPLAIN QUERY PLAN SELECT term FROM message_vocabulary WHERE term IN('engine','engnie')",[],|r|r.get(3)).unwrap();
    let equality: String = store
        .connection
        .query_row(
            "EXPLAIN QUERY PLAN SELECT term FROM message_vocabulary WHERE term='engine'",
            [],
            |r| r.get(3),
        )
        .unwrap();
    let index = |plan: &str| {
        plan.split("INDEX ")
            .nth(1)
            .unwrap()
            .split(':')
            .next()
            .unwrap()
            .parse::<u32>()
            .unwrap()
    };
    assert!(
        index(&equality) > 0 && index(&plan) & index(&equality) == index(&equality),
        "Vocabulary IN must retain equality seeks: {plan}"
    );
    for index in 0..260 {
        mail.id = format!("a:page-{index}");
        mail.remote_id = format!("page-{index}");
        store.save(&mail, Folder::Inbox).unwrap();
    }
    assert_eq!(smart(&store, here, "muller").messages.len(), PAGE_LIMIT);
}

#[test]
fn fuzzy_pages_are_stable() {
    let store = setup(":memory:");
    for index in 0..300 {
        let mut mail = message("a", &format!("page-{index}"));
        mail.timestamp = index;
        store.save(&mail, Folder::Inbox).unwrap();
    }
    let here = scope(Some("a"), Folder::Inbox);
    let first = store
        .search_folder(here, "engnie", SearchMode::Smart, 0, 250)
        .unwrap();
    let second = store
        .search_folder(here, "engnie", SearchMode::Smart, 250, 250)
        .unwrap();
    assert_eq!(first.messages.len(), 250);
    assert_eq!(second.messages.len(), 50);
    assert_eq!(first.kind, SearchMatch::Approximate);
    assert_eq!(second.kind, SearchMatch::Approximate);
    let ids: std::collections::BTreeSet<_> = first
        .messages
        .iter()
        .chain(&second.messages)
        .map(|m| &m.id)
        .collect();
    assert_eq!(ids.len(), 300);
}
