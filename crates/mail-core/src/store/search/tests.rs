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
fn decoded_headers_and_scopes() {
    let store = setup(":memory:");
    let mut mail = message("a", "escaped");
    mail.subject = "You're invited to R&amp;D".into();
    mail.sender = "Jos&eacute; O&#39;Brien &amp; Partners".into();
    mail.preview = "Salt &amp; Pepper: it&#x2019;s ready".into();
    mail.sender_address = "raw&amp;address@example.test".into();
    mail.text = Some("Body's literal &amp;notdecoded;".into());
    for (account, folder) in [("a", Folder::Inbox), ("b", Folder::Archive)] {
        mail.account_id = account.into();
        mail.id = format!("{account}:escaped");
        store.save(&mail, folder).unwrap();
    }
    let here = scope(Some("a"), Folder::Inbox);
    for query in [
        "you're",
        "you’re",
        "R&D",
        "O'Brien",
        "O’Brien",
        "Jose",
        "Salt & Pepper",
        "it's ready",
        "it’s ready",
    ] {
        let found = smart(&store, here, query);
        assert_eq!(found.kind, SearchMatch::Literal, "{query}");
        assert_eq!(found.messages.len(), 1, "{query}");
        assert_eq!(found.messages[0].account_id, "a");
        assert_eq!(found.messages[0].subject, mail.subject);
        assert_eq!(found.messages[0].preview, mail.preview);
        assert!(found.messages[0].text.is_none());
        assert_eq!(
            smart(&store, scope(None, Folder::All), query)
                .messages
                .len(),
            2
        );
        assert!(
            smart(&store, scope(Some("b"), Folder::Inbox), query)
                .messages
                .is_empty()
        );
    }
    assert_eq!(
        smart(&store, here, "O’Brein & Partenrs").kind,
        SearchMatch::Approximate
    );
    for query in ["&", "’", "...", "& \" ' ", "raw&address"] {
        assert!(smart(&store, here, query).messages.is_empty(), "{query}");
    }
    assert_eq!(smart(&store, here, "ampnotdecoded").messages.len(), 0);
    assert_eq!(smart(&store, here, "notdecoded").messages.len(), 1);
    assert_eq!(smart(&store, here, "amp").messages.len(), 1); // Raw body/address stay indexed literally.
    store
        .connection
        .execute(
            "INSERT INTO mail_folders VALUES('b','nested','Nested',NULL,NULL)",
            [],
        )
        .unwrap();
    store
        .connection
        .execute(
            "INSERT INTO mail_membership VALUES('b','escaped','nested')",
            [],
        )
        .unwrap();
    let nested = MailScope {
        account: Some("b"),
        folder: Folder::All,
        remote: Some("nested"),
    };
    assert_eq!(
        smart(&store, nested, "O’Brein & Partenrs").messages[0].account_id,
        "b"
    );
}

#[test]
fn decoded_index_lifecycle() {
    let store = setup(":memory:");
    let mut mail = message("a", "escaped");
    mail.subject = "You&#39;re invited".into();
    mail.sender = "M&uuml;ller".into();
    mail.preview = "We&apos;re ready".into();
    store.save(&mail, Folder::Inbox).unwrap();
    let here = scope(None, Folder::All);
    for query in ["you're", "muller", "we're"] {
        assert_eq!(smart(&store, here, query).messages.len(), 1);
    }
    mail.subject = "They&#39;ve arrived".into();
    mail.sender = "Dvo&rcaron;ak".into();
    mail.preview = "She&#x27;s here".into();
    store.save(&mail, Folder::Inbox).unwrap();
    for query in ["you're", "muller", "we're"] {
        assert!(smart(&store, here, query).messages.is_empty());
    }
    for query in ["they’ve", "dvorak", "she's"] {
        assert_eq!(smart(&store, here, query).messages.len(), 1);
    }
    store
        .save_body(&mail.id, "Fresh cached nebula", "")
        .unwrap();
    store
        .connection
        .execute(
            "INSERT INTO message_search(message_search,rank) VALUES('integrity-check',1)",
            [],
        )
        .unwrap();
    store
        .connection
        .execute(
            "INSERT INTO message_search(message_search) VALUES('rebuild')",
            [],
        )
        .unwrap();
    assert_eq!(smart(&store, here, "nebula").messages.len(), 1);
    // Queries and pin/read-only changes must not run the header decoder or load a content view.
    store
        .connection
        .create_scalar_function(
            "squaremail_header_text",
            1,
            rusqlite::functions::FunctionFlags::SQLITE_UTF8,
            |_| -> rusqlite::Result<String> { Err(rusqlite::Error::InvalidQuery) },
        )
        .unwrap();
    store.pin_mail(&mail.id, true.into()).unwrap();
    store
        .connection
        .execute(
            "UPDATE messages SET unread=0,starred=1 WHERE id=?1",
            [&mail.id],
        )
        .unwrap();
    assert_eq!(smart(&store, here, "they’ve").messages.len(), 1);
    assert_eq!(smart(&store, here, "dvorka").kind, SearchMatch::Approximate);
    register(&store.connection).unwrap();
    store
        .connection
        .execute("DELETE FROM messages WHERE id=?1", [&mail.id])
        .unwrap();
    assert!(smart(&store, here, "they've").messages.is_empty());
    store
        .connection
        .execute(
            "INSERT INTO message_search(message_search,rank) VALUES('integrity-check',1)",
            [],
        )
        .unwrap();
}

#[test]
fn escaped_schema4_migration() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mail.sqlite");
    let path = path.to_str().unwrap();
    let id;
    {
        let store = setup(path);
        store
            .connection
            .execute_batch(include_str!("legacy-v4.sql"))
            .unwrap();
        store
            .connection
            .pragma_update(None, "user_version", 4)
            .unwrap();
        let mut mail = message("a", "escaped");
        mail.subject = "You&#39;re invited to R&amp;D".into();
        mail.sender = "O&#39;Brien".into();
        mail.preview = "It&apos;s ready".into();
        id = mail.id.clone();
        store.save(&mail, Folder::Inbox).unwrap();
        store
            .queue_mail("kept-read", mail, MailAction::Read { unread: false })
            .unwrap();
        let draft = MailDraft {
            id: "kept".into(),
            account: "a".into(),
            kind: ComposeKind::New,
            original: None,
            to: vec![],
            cc: vec![],
            bcc: vec![],
            subject: "Draft &amp; subject".into(),
            text: "Unsent draft".into(),
            headers: None,
            revision: 0,
        };
        store.save_mail_draft(&draft).unwrap();
        assert!(
            smart(&store, scope(None, Folder::All), "you're")
                .messages
                .is_empty()
        );
    }
    for _ in 0..2 {
        let store = Store::open(path).unwrap();
        for query in ["you're", "R&D", "O'Brien", "it's"] {
            assert_eq!(
                smart(&store, scope(None, Folder::All), query)
                    .messages
                    .len(),
                1,
                "{query}"
            );
        }
        let raw = store.message(&id).unwrap();
        assert_eq!(raw.subject, "You&#39;re invited to R&amp;D");
        assert_eq!(raw.sender, "O&#39;Brien");
        assert_eq!(raw.preview, "It&apos;s ready");
        assert!(raw.text.unwrap().contains("quartz"));
        assert_eq!(
            store.mail_draft("kept").unwrap().subject,
            "Draft &amp; subject"
        );
        assert_eq!(
            store.mail_workspace().unwrap()["work"][0]["id"],
            "kept-read"
        );
        store
            .connection
            .execute(
                "INSERT INTO message_search(message_search,rank) VALUES('integrity-check',1)",
                [],
            )
            .unwrap();
    }
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
