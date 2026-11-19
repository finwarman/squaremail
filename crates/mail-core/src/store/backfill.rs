use super::*;
use rusqlite::OptionalExtension;

const BODY_RETRY_SECONDS: i64 = 86400;

impl Store {
    pub(crate) fn backfill_mode(&self, mode: Option<BackfillMode>) -> Result<BackfillMode> {
        if let Some(mode) = mode {
            let tx = self.write_tx()?;
            let enabled = mode == BackfillMode::Enabled;
            tx.execute(
                "UPDATE backfill_settings SET enabled=?1 WHERE id=1",
                [enabled],
            )?;
            tx.execute(
                "UPDATE sync_jobs SET active=?1 WHERE kind='body_backfill'",
                [enabled],
            )?;
            tx.commit()?;
        }
        let enabled: bool = self.connection.query_row(
            "SELECT enabled FROM backfill_settings WHERE id=1",
            [],
            |r| r.get(0),
        )?;
        Ok(if enabled {
            BackfillMode::Enabled
        } else {
            BackfillMode::Paused
        })
    }

    pub(crate) fn ensure_backfill(&self, account: &str) -> Result<()> {
        self.connection.execute("INSERT OR IGNORE INTO sync_jobs(account_id,kind,resource,active) SELECT ?1,'body_backfill','',enabled FROM backfill_settings WHERE id=1", [account])?;
        Ok(())
    }

    pub(crate) fn backfill_candidate(&self, account: &str, now: i64) -> Result<Option<Message>> {
        let id: Option<String> = self.connection.query_row("SELECT m.id FROM messages m INDEXED BY messages_missing_body
            WHERE m.account_id=?1 AND m.text IS NULL
            AND NOT EXISTS(SELECT 1 FROM body_deferred d WHERE d.message_id=m.id AND d.retry_after>?2)
            AND NOT EXISTS(SELECT 1 FROM mail_tombstones t WHERE t.message_id=m.id)
            ORDER BY m.timestamp DESC,m.id DESC LIMIT 1", params![account, now], |r| r.get(0)).optional()?;
        id.map(|id| self.action_message(&id)).transpose()
    }

    pub(crate) fn backfill_counts(&self, account: &str) -> Result<(i64, i64)> {
        // Both counts share one read snapshot, including during header imports.
        let (total, missing): (i64, i64) = self.connection.query_row(
            "SELECT COUNT(*),(SELECT COUNT(*) FROM messages WHERE account_id=?1 AND text IS NULL) FROM messages WHERE account_id=?1",
            [account], |r| Ok((r.get(0)?,r.get(1)?)),
        )?;
        Ok((total - missing, total))
    }

    pub(crate) fn finish_backfill(
        &self,
        job: &SyncJob,
        id: &str,
        body: Option<(&str, &str)>,
        delay: i64,
    ) -> Result<()> {
        let tx = self.write_tx()?;
        let active: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM sync_jobs WHERE account_id=?1 AND kind='body_backfill' AND active=1)", [&job.account_id], |r|r.get(0))?;
        if !active || !self.connected(&job.account_id)? {
            return Err("Older-mail caching was paused".into());
        }
        let now = chrono::Utc::now().timestamp();
        if let Some((text, html)) = body {
            // Only body columns change. A concurrent read/flag/move remains authoritative.
            self.save_body(id, text, html)?;
            tx.execute("DELETE FROM body_deferred WHERE message_id=?1", [id])?;
        } else {
            tx.execute("INSERT INTO body_deferred SELECT id,?2 FROM messages WHERE id=?1 ON CONFLICT(message_id) DO UPDATE SET retry_after=excluded.retry_after", params![id, now + BODY_RETRY_SECONDS])?;
        }
        let mut state = job.state.clone();
        let key = if body.is_some() { "cached" } else { "deferred" };
        state[key] = serde_json::json!(state[key].as_u64().unwrap_or(0).saturating_add(1));
        self.checkpoint(job, &state, delay)?;
        tx.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn header(store: &Store, account: &str, remote: &str, timestamp: i64) -> Message {
        store
            .save_account(&Account {
                id: account.into(),
                email: format!("{account}@example.test"),
                provider: Provider::Gmail,
            })
            .unwrap();
        let mut message =
            crate::mime::parse(b"Subject: Header only\r\n\r\n", account, remote).unwrap();
        message.text = None;
        message.html = None;
        message.timestamp = timestamp;
        store.save(&message, Folder::Archive).unwrap();
        store.ensure_backfill(account).unwrap();
        message
    }
    fn job(account: &str) -> SyncJob {
        SyncJob {
            account_id: account.into(),
            kind: JobKind::BodyBackfill,
            resource: String::new(),
            window: 0,
            state: json!({}),
            failures: 0,
        }
    }

    #[test]
    fn resumable_local_backfill() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("mail.sqlite");
        let path = file.to_str().unwrap();
        let store = Store::open(path).unwrap();
        let old = header(&store, "a", "old", 1);
        let new = header(&store, "a", "new", 2);
        let other = header(&store, "b", "new", 3);
        assert_eq!(
            store.backfill_candidate("a", 0).unwrap().unwrap().id,
            new.id
        );
        store
            .queue_read("held", new.clone(), ReadChoice::KeepUnread)
            .unwrap();
        store
            .finish_backfill(
                &job("a"),
                &new.id,
                Some(("Buried aubergine", "<p>Body</p>")),
                20,
            )
            .unwrap();
        let saved = store.message(&new.id).unwrap();
        assert!(saved.unread && saved.keep_unread);
        assert_eq!(
            store
                .list(Some("a"), Folder::All, "aubergine", 0, 10)
                .unwrap()
                .len(),
            1
        );
        assert!(store.message(&other.id).unwrap().text.is_none());
        drop(store);
        let store = Store::open(path).unwrap();
        assert_eq!(
            store.backfill_candidate("a", 0).unwrap().unwrap().id,
            old.id
        );
        assert_eq!(store.backfill_counts("a").unwrap(), (1, 2));
        store.backfill_mode(Some(BackfillMode::Paused)).unwrap();
        assert!(
            store
                .finish_backfill(&job("a"), &old.id, Some(("Discard stale response", "")), 20)
                .is_err()
        );
        assert!(store.message(&old.id).unwrap().text.is_none());
        header(&store, "c", "late-account", 4);
        let active: bool = store
            .connection
            .query_row(
                "SELECT active FROM sync_jobs WHERE account_id='c'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(!active);
        drop(store);
        assert_eq!(
            Store::open(path).unwrap().backfill_mode(None).unwrap(),
            BackfillMode::Paused
        );
    }

    #[test]
    fn retries_and_foreground_priority() {
        let store = Store::open(":memory:").unwrap();
        let new = header(&store, "a", "new", 2);
        let old = header(&store, "a", "old", 1);
        store.finish_backfill(&job("a"), &new.id, None, 20).unwrap();
        assert_eq!(
            store
                .backfill_candidate("a", chrono::Utc::now().timestamp())
                .unwrap()
                .unwrap()
                .id,
            old.id
        );
        assert_eq!(
            store.backfill_candidate("a", i64::MAX).unwrap().unwrap().id,
            new.id
        );
        store.ensure_job("a", JobKind::RecentMail, "", 0).unwrap();
        assert_eq!(
            store.next_job(i64::MAX).unwrap().unwrap().kind,
            JobKind::RecentMail
        );
        let due: i64 = store
            .connection
            .query_row(
                "SELECT next_due FROM sync_jobs WHERE kind='body_backfill'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        store.sync_now().unwrap();
        let after: i64 = store
            .connection
            .query_row(
                "SELECT next_due FROM sync_jobs WHERE kind='body_backfill'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(due, after);
    }
}
