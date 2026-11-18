use crate::{Result, model::*};
use rusqlite::{Connection, params};

mod mail;
mod media;
mod notices;
mod search;
mod sync;

pub(crate) const PAGE_LIMIT: usize = 250;

#[derive(Clone, Copy)]
pub(crate) struct MailScope<'a> {
    pub(crate) account: Option<&'a str>,
    pub(crate) folder: Folder,
    pub(crate) remote: Option<&'a str>,
}

pub(crate) struct Store {
    connection: Connection,
}

impl Store {
    pub(crate) fn open(path: &str) -> Result<Self> {
        if path != ":memory:" {
            use std::os::unix::fs::OpenOptionsExt;
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
            {
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error.into()),
            }
        }
        let connection = Connection::open(path)?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch(include_str!("schema.sql"))?;
        let schema_version: i64 = connection.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if schema_version < 2 {
            connection.execute_batch("BEGIN IMMEDIATE; DROP TRIGGER IF EXISTS message_update;
                CREATE TRIGGER message_update AFTER UPDATE ON messages
                WHEN old.subject IS NOT new.subject OR old.sender IS NOT new.sender OR old.preview IS NOT new.preview OR old.text IS NOT new.text BEGIN
                INSERT INTO message_search(message_search,rowid,subject,sender,preview,text) VALUES('delete',old.rowid,old.subject,old.sender,old.preview,old.text);
                INSERT INTO message_search(rowid,subject,sender,preview,text) VALUES(new.rowid,new.subject,new.sender,new.preview,new.text); END;")?;
            let retry_column: bool = connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('sync_jobs') WHERE name='retry_class')",
            [],
            |r| r.get(0),
        )?;
            if !retry_column {
                connection.execute(
                    "ALTER TABLE sync_jobs ADD COLUMN retry_class TEXT NOT NULL DEFAULT ''",
                    [],
                )?;
            }
            for (name, definition) in [
                ("viewed_at", "INTEGER NOT NULL DEFAULT 0"),
                ("active", "INTEGER NOT NULL DEFAULT 1"),
            ] {
                let exists: bool = connection.query_row(
                    "SELECT EXISTS(SELECT 1 FROM pragma_table_info('sync_jobs') WHERE name=?1)",
                    [name],
                    |r| r.get(0),
                )?;
                if !exists {
                    connection.execute(
                        &format!("ALTER TABLE sync_jobs ADD COLUMN {name} {definition}"),
                        [],
                    )?;
                }
            }
            let version_column:bool=connection.query_row("SELECT EXISTS(SELECT 1 FROM pragma_table_info('calendar_events') WHERE name='version')",[],|r|r.get(0))?;
            if !version_column {
                connection.execute(
                    "ALTER TABLE calendar_events ADD COLUMN version INTEGER NOT NULL DEFAULT 0",
                    [],
                )?;
            }
            connection.execute("CREATE INDEX IF NOT EXISTS event_versions ON calendar_events(account_id,calendar_id,id,version DESC)",[])?;
            connection.execute_batch("PRAGMA user_version=2; COMMIT;")?;
        }
        if schema_version < 3 {
            connection.execute_batch("BEGIN IMMEDIATE; ALTER TABLE messages ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX messages_pins ON messages(pinned DESC,timestamp DESC,id);
                CREATE INDEX messages_account_pins ON messages(account_id,pinned DESC,timestamp DESC,id);
                PRAGMA user_version=3; COMMIT;")?;
        }
        if schema_version < search::SCHEMA_VERSION {
            let tx = connection.unchecked_transaction()?;
            let current: i64 = tx.query_row("PRAGMA user_version", [], |r| r.get(0))?;
            if current < search::SCHEMA_VERSION {
                tx.execute_batch(include_str!("search-schema.sql"))?;
                tx.pragma_update(None, "user_version", search::SCHEMA_VERSION)?;
            }
            tx.commit()?;
        }
        Ok(Self { connection })
    }

    pub(crate) fn save_account(&self, account: &Account) -> Result<()> {
        self.connection.execute(
            "INSERT INTO accounts(id,email,provider) VALUES (?1,?2,?3)
             ON CONFLICT(id) DO UPDATE SET email=excluded.email",
            params![account.id, account.email, account.provider.as_str()],
        )?;
        Ok(())
    }

    pub(crate) fn accounts(&self) -> Result<Vec<Account>> {
        let mut statement = self
            .connection
            .prepare("SELECT id,email,provider FROM accounts ORDER BY provider,email")?;
        let rows = statement.query_map([], |row| {
            let provider: String = row.get(2)?;
            Ok(Account {
                id: row.get(0)?,
                email: row.get(1)?,
                provider: match provider.as_str() {
                    "gmail" => Provider::Gmail,
                    "outlook" => Provider::Outlook,
                    _ => Provider::Local,
                },
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub(crate) fn save(&self, message: &Message, folder: Folder) -> Result<()> {
        let tx = self.connection.unchecked_transaction()?;
        Self::upsert(&tx, message)?;
        tx.execute(
            "INSERT OR IGNORE INTO folders(message_id,folder) VALUES (?1,?2)",
            params![message.id, folder.as_str()],
        )?;
        tx.commit()?;
        Ok(())
    }

    fn upsert(connection: &Connection, message: &Message) -> Result<()> {
        connection.execute(
            "INSERT INTO messages(id,account_id,remote_id,sender,sender_address,recipient,subject,
             preview,timestamp,unread,starred,has_attachments,text,html)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)
             ON CONFLICT(id) DO UPDATE SET sender=excluded.sender,sender_address=excluded.sender_address,
             recipient=excluded.recipient,subject=excluded.subject,preview=excluded.preview,
             timestamp=excluded.timestamp,unread=excluded.unread,starred=excluded.starred,
             has_attachments=excluded.has_attachments,text=COALESCE(excluded.text,messages.text),
             html=COALESCE(excluded.html,messages.html)",
            params![message.id,message.account_id,message.remote_id,message.sender,
                message.sender_address,message.recipient,message.subject,message.preview,
                message.timestamp,message.unread,message.starred,message.has_attachments,
                message.text,message.html],
        )?;
        if let Some(headers) = &message.reply {
            let data = serde_json::to_string(headers)?;
            if data.len() <= REPLY_LIMIT {
                connection.execute("INSERT INTO mail_headers VALUES(?1,?2) ON CONFLICT(message_id) DO UPDATE SET data=excluded.data",params![message.id,data])?;
            }
        }
        Ok(())
    }

    pub(crate) fn list(
        &self,
        account: Option<&str>,
        folder: Folder,
        query: &str,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<Message>> {
        self.list_folder(account, folder, None, query, offset, limit)
    }

    pub(crate) fn list_folder(
        &self,
        account: Option<&str>,
        folder: Folder,
        remote: Option<&str>,
        query: &str,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<Message>> {
        let terms = search::literal(query)?;
        self.match_rows(account, folder, remote, &terms, offset, limit)
    }

    fn match_rows(
        &self,
        account: Option<&str>,
        folder: Folder,
        remote: Option<&str>,
        terms: &str,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<Message>> {
        let (join, search) = if terms.is_empty() {
            ("", "")
        } else {
            (
                "JOIN message_search ON message_search.rowid=m.rowid",
                " AND message_search MATCH ?5",
            )
        };
        let account_filter = if account.is_some() {
            "m.account_id=?1"
        } else {
            "1"
        };
        let folder_filter = if remote.is_some() {
            "EXISTS(SELECT 1 FROM mail_membership f WHERE f.account_id=m.account_id AND f.remote_id=m.remote_id AND f.folder_id=?2)"
        } else {
            match folder {
                Folder::All => "1",
                Folder::Unread => "m.unread=1",
                Folder::Starred => "m.starred=1",
                _ => "EXISTS(SELECT 1 FROM folders f WHERE f.message_id=m.id AND f.folder=?2)",
            }
        };
        let sql = format!(
            "SELECT m.id,m.account_id,m.remote_id,m.sender,m.sender_address,m.recipient,
            m.subject,m.preview,m.timestamp,m.unread,m.starred,m.has_attachments,NULL,NULL,m.pinned
            FROM messages m {join} WHERE {account_filter} AND {folder_filter}
            {search} ORDER BY m.pinned DESC,m.timestamp DESC,m.id LIMIT ?3 OFFSET ?4"
        );
        let mut statement = self.connection.prepare(&sql)?;
        statement.raw_bind_parameter(1, account)?;
        statement.raw_bind_parameter(2, remote.unwrap_or(folder.as_str()))?;
        statement.raw_bind_parameter(3, limit.min(PAGE_LIMIT) as i64)?;
        statement.raw_bind_parameter(4, offset.min(i64::MAX as usize) as i64)?;
        if !terms.is_empty() {
            statement.raw_bind_parameter(5, terms)?;
        }
        let rows = statement.raw_query();
        Ok(rows
            .mapped(Self::read_row)
            .collect::<rusqlite::Result<_>>()?)
    }

    pub(crate) fn message(&self, id: &str) -> Result<Message> {
        Ok(self.connection.query_row("SELECT id,account_id,remote_id,sender,sender_address,recipient,
            subject,preview,timestamp,unread,starred,has_attachments,text,html,pinned FROM messages WHERE id=?1",
            [id], Self::read_row)?)
    }

    pub(crate) fn save_body(&self, id: &str, text: &str, html: &str) -> Result<()> {
        self.connection.execute(
            "UPDATE messages SET text=?2,html=?3 WHERE id=?1",
            params![id, text, html],
        )?;
        Ok(())
    }

    fn read_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Message> {
        Ok(Message {
            pinned: row.get(14)?,
            reply: None,
            id: row.get(0)?,
            account_id: row.get(1)?,
            remote_id: row.get(2)?,
            sender: row.get(3)?,
            sender_address: row.get(4)?,
            recipient: row.get(5)?,
            subject: row.get(6)?,
            preview: row.get(7)?,
            timestamp: row.get(8)?,
            unread: row.get(9)?,
            starred: row.get(10)?,
            has_attachments: row.get(11)?,
            text: row.get(12)?,
            html: row.get(13)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mime;

    fn mail(account: &str) -> Message {
        mime::parse(b"From: Ada <ada@example.test>\r\nTo: fin@example.test\r\nSubject: Engine notes\r\n\r\nA searchable difference engine.", account, "same-id").unwrap()
    }

    fn account(store: &Store, id: &str) {
        store
            .save_account(&Account {
                id: id.into(),
                email: format!("{id}@example.test"),
                provider: Provider::Local,
            })
            .unwrap();
    }

    #[test]
    fn account_isolation_and_restart() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("mail.sqlite");
        {
            let store = Store::open(path.to_str().unwrap()).unwrap();
            for id in ["a", "b"] {
                account(&store, id);
                store.save(&mail(id), Folder::Inbox).unwrap();
            }
        }
        let store = Store::open(path.to_str().unwrap()).unwrap();
        let rows = store
            .list(Some("a"), Folder::Inbox, "difference", 0, 250)
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].account_id, "a");
        assert!(rows[0].text.is_none());
        assert!(
            store
                .message(&rows[0].id)
                .unwrap()
                .text
                .unwrap()
                .contains("difference")
        );
        assert_eq!(
            store.list(None, Folder::Inbox, "", 0, 250).unwrap().len(),
            2
        );
    }

    #[test]
    fn header_refresh_keeps_body() {
        let store = Store::open(":memory:").unwrap();
        account(&store, "a");
        let mut message = mail("a");
        store.save(&message, Folder::Inbox).unwrap();
        message.text = None;
        message.html = None;
        message.unread = false;
        store.save(&message, Folder::Inbox).unwrap();
        let saved = store.message(&message.id).unwrap();
        assert!(saved.text.unwrap().contains("difference"));
        assert!(!saved.unread);
    }

    #[test]
    fn query_is_literal_and_pages_bound() {
        let store = Store::open(":memory:").unwrap();
        account(&store, "a");
        for index in 0..300 {
            let mut message = mail("a");
            message.id = format!("a:{index}");
            message.remote_id = index.to_string();
            store.save(&message, Folder::Inbox).unwrap();
        }
        assert_eq!(
            store
                .list(None, Folder::Inbox, "", 0, usize::MAX)
                .unwrap()
                .len(),
            PAGE_LIMIT
        );
        assert_eq!(
            store.list(None, Folder::Inbox, "", 250, 250).unwrap().len(),
            50
        );
        for query in [
            "\" OR 1=1 --",
            "NEAR(a b)",
            "*",
            "'",
            "\"",
            "engine OR forbidden",
        ] {
            assert!(
                store
                    .list(None, Folder::Inbox, query, 0, 250)
                    .unwrap()
                    .is_empty(),
                "{query}"
            );
        }
        assert_eq!(
            store.list(None, Folder::Inbox, "eng", 0, 1).unwrap().len(),
            1
        );
    }

    #[test]
    #[ignore = "release-only performance probe with a real 100,000-message SQLite cache"]
    fn mailbox_benchmark() {
        use std::time::Instant;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("benchmark.sqlite");
        let store = Store::open(path.to_str().unwrap()).unwrap();
        account(&store, "a");
        let mut message = mail("a");
        let start = Instant::now();
        for index in 0..100_000 {
            message.remote_id = index.to_string();
            message.id = format!("a:{index}");
            message.subject = format!("Engine invoice {index:06}");
            message.timestamp = index;
            store.save(&message, Folder::Inbox).unwrap();
        }
        let seed_ms = start.elapsed().as_secs_f64() * 1000.0;
        let mut list = Vec::new();
        let mut selective = Vec::new();
        let mut common = Vec::new();
        for _ in 0..30 {
            let start = Instant::now();
            assert_eq!(
                store
                    .list(Some("a"), Folder::Inbox, "", 0, 250)
                    .unwrap()
                    .len(),
                250
            );
            list.push(start.elapsed().as_secs_f64() * 1000.0);
            let start = Instant::now();
            assert_eq!(
                store
                    .list(Some("a"), Folder::Inbox, "073000", 0, 250)
                    .unwrap()
                    .len(),
                1
            );
            selective.push(start.elapsed().as_secs_f64() * 1000.0);
            let start = Instant::now();
            assert_eq!(
                store
                    .list(Some("a"), Folder::Inbox, "engine", 0, 250)
                    .unwrap()
                    .len(),
                250
            );
            common.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        for values in [&mut list, &mut selective, &mut common] {
            values.sort_by(f64::total_cmp);
        }
        println!(
            "BENCHMARK {}",
            serde_json::json!({
                "messages":100000,"seed_ms":seed_ms,"list_p95_ms":list[28],
                "selective_search_p95_ms":selective[28],"common_search_p95_ms":common[28],
                "sqlite_bytes":std::fs::metadata(path).unwrap().len()
            })
        );
    }

    #[test]
    #[ignore = "creates generated mail for the native reader performance probe"]
    fn seed_reader_benchmark() {
        let path = std::env::var("SQUAREMAIL_PROFILE_DB")
            .expect("Set SQUAREMAIL_PROFILE_DB to a disposable database");
        let store = Store::open(&path).unwrap();
        account(&store, "reader-profile");
        let count = std::env::var("SQUAREMAIL_PROFILE_COUNT")
            .ok()
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(64);
        for index in 0..count {
            let mut message = mail("reader-profile");
            let size = if index == count - 2 {
                1024 * 1024
            } else if index % 10 == 0 {
                128 * 1024
            } else {
                8 * 1024
            };
            let paragraph = "Generated performance fixture. This is not real mail.\nThe reader should show this text without blocking input.\n\n";
            let body = paragraph.repeat(size / paragraph.len());
            message.id = format!("reader-profile:{index}");
            message.remote_id = index.to_string();
            message.subject = format!("Reader fixture {index}: {size} bytes");
            message.timestamp = index;
            message.preview = "Generated local mail for performance measurements".into();
            message.text = Some(body.clone());
            message.html = Some(format!(
                "<p>Generated HTML fixture {index}</p><pre>{body}</pre>"
            ));
            store.save(&message, Folder::Inbox).unwrap();
        }
        println!("Generated {count} cached messages in {path}");
    }

    #[test]
    #[ignore = "release-only 100,000-message multi-account search probe"]
    fn account_search_benchmark() {
        use std::time::Instant;
        let directory = tempfile::tempdir().unwrap();
        let store = Store::open(directory.path().join("mail.sqlite").to_str().unwrap()).unwrap();
        for index in 0..10 {
            store
                .save_account(&Account {
                    id: format!("scale-{index}"),
                    email: format!("scale-{index}@example.invalid"),
                    provider: if index % 2 == 0 {
                        Provider::Gmail
                    } else {
                        Provider::Outlook
                    },
                })
                .unwrap();
        }
        let mut message = mail("scale-0");
        for index in 0..100_000 {
            message.account_id = format!("scale-{}", index % 10);
            message.remote_id = (index / 10).to_string();
            message.id = format!("{}:{}", message.account_id, message.remote_id);
            message.subject = format!("Engine invoice {index:06}");
            message.sender_address = format!("sender{index:06}@dept{}.example.test", index % 10);
            message.timestamp = index;
            let folder = [Folder::Inbox, Folder::Sent, Folder::Archive][index as usize % 3];
            store.save(&message, folder).unwrap();
        }
        let cases = [
            ("account_inbox", Some("scale-0"), Folder::Inbox, "", 250),
            ("unified_inbox", None, Folder::Inbox, "", 250),
            (
                "scoped_selective",
                Some("scale-0"),
                Folder::Sent,
                "073000",
                1,
            ),
            ("unified_selective", None, Folder::All, "073000", 1),
            (
                "account_common",
                Some("scale-0"),
                Folder::All,
                "engine",
                250,
            ),
            (
                "folder_common",
                Some("scale-0"),
                Folder::Inbox,
                "engine",
                250,
            ),
            ("unified_common", None, Folder::All, "engine", 250),
        ];
        let mut results = serde_json::Map::new();
        for (name, account, folder, query, expected) in cases {
            let mut times = Vec::new();
            for _ in 0..30 {
                let start = Instant::now();
                let rows = store.list(account, folder, query, 0, PAGE_LIMIT).unwrap();
                assert_eq!(rows.len(), expected);
                if let Some(account) = account {
                    assert!(rows.iter().all(|m| m.account_id == account));
                }
                times.push(start.elapsed().as_secs_f64() * 1000.0);
            }
            times.sort_by(f64::total_cmp);
            results.insert(name.into(), serde_json::json!({"p95_ms": times[28]}));
        }
        let scope = MailScope {
            account: Some("scale-0"),
            folder: Folder::All,
            remote: None,
        };
        for (name, query, expected, kind) in [
            (
                "address_exact",
                "sender073000@dept0.example.test",
                1,
                SearchMatch::Literal,
            ),
            (
                "address_typo",
                "sender073000@dept0.exmaple.test",
                1,
                SearchMatch::Approximate,
            ),
            ("name_typo", "Exmaple", 250, SearchMatch::Approximate),
            ("body_typo", "differnece", 250, SearchMatch::Approximate),
            ("typo_no_hit", "zzzzzzzz", 0, SearchMatch::None),
        ] {
            let mut times = Vec::new();
            for _ in 0..30 {
                let begin = Instant::now();
                let page = store
                    .search_folder(scope, query, SearchMode::Smart, 0, PAGE_LIMIT)
                    .unwrap();
                assert_eq!(page.messages.len(), expected, "{name}");
                assert_eq!(page.kind, kind, "{name}");
                assert!(
                    page.messages
                        .iter()
                        .all(|m| m.account_id == "scale-0" && m.text.is_none())
                );
                times.push(begin.elapsed().as_secs_f64() * 1000.0);
            }
            times.sort_by(f64::total_cmp);
            results.insert(name.into(), serde_json::json!({"p95_ms":times[28]}));
        }
        for (name, query, expected) in [
            ("unified_address_typo", "sender073000@dept0.exmaple.test", 1),
            ("unified_body_typo", "differnece", 250),
        ] {
            let scope = MailScope {
                account: None,
                folder: Folder::All,
                remote: None,
            };
            let mut times = Vec::new();
            for _ in 0..30 {
                let begin = Instant::now();
                let page = store
                    .search_folder(scope, query, SearchMode::Smart, 0, PAGE_LIMIT)
                    .unwrap();
                assert_eq!(page.messages.len(), expected);
                assert_eq!(page.kind, SearchMatch::Approximate);
                times.push(begin.elapsed().as_secs_f64() * 1000.0);
            }
            times.sort_by(f64::total_cmp);
            results.insert(name.into(), serde_json::json!({"p95_ms":times[28]}));
        }
        println!(
            "MULTI_ACCOUNT_BENCHMARK {}",
            serde_json::Value::Object(results)
        );
    }
}
