use super::*;
use serde_json::{Value, json};

mod calendar;

const EVENT_LIMIT: usize = 2000;
const WINDOW_LIMIT: i64 = 6;

impl Store {
    pub(crate) fn sync_ready(&self, now: i64) -> Result<bool> {
        Ok(self.connection.query_row("SELECT
            EXISTS(SELECT 1 FROM sync_jobs j WHERE active=1 AND next_due<=?1 AND NOT EXISTS(SELECT 1 FROM account_paused p WHERE p.account_id=j.account_id)) OR
            EXISTS(SELECT 1 FROM mail_actions a WHERE state IN('pending','retry','sending') AND due<=?1 AND NOT EXISTS(SELECT 1 FROM account_paused p WHERE p.account_id=a.account)) OR
            EXISTS(SELECT 1 FROM mail_outbox a WHERE state IN('pending','retry') AND due<=?1 AND NOT EXISTS(SELECT 1 FROM account_paused p WHERE p.account_id=a.account)) OR
            EXISTS(SELECT 1 FROM event_writes e WHERE state IN('pending','retry','sending') AND next_due<=?1 AND NOT EXISTS(SELECT 1 FROM account_paused p WHERE p.account_id=e.account_id))",[now],|r|r.get(0))?)
    }
    pub(crate) fn connected(&self, account: &str) -> Result<bool> {
        Ok(!self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM account_paused WHERE account_id=?1)",
            [account],
            |r| r.get::<_, bool>(0),
        )?)
    }
    pub(crate) fn resume_account(&self, account: &Account) -> Result<()> {
        self.save_account(account)?;
        self.connection.execute(
            "DELETE FROM account_paused WHERE account_id=?1",
            [&account.id],
        )?;
        self.ensure_job(&account.id, JobKind::Catalog, "", 0)?;
        self.ensure_job(&account.id, JobKind::RecentMail, "", 0)?;
        if account.provider == Provider::Gmail {
            self.ensure_job(&account.id, JobKind::Mail, "", 0)?;
        }
        self.connection.execute("UPDATE sync_jobs SET next_due=0,failures=0,error=NULL,retry_class='' WHERE account_id=?1",[&account.id])?;
        Ok(())
    }
    pub(crate) fn pause_account(&self, account: &str, mode: DisconnectMode) -> Result<()> {
        let tx = self.connection.unchecked_transaction()?;
        tx.execute("INSERT OR IGNORE INTO account_paused VALUES(?1)", [account])?;
        if matches!(mode, DisconnectMode::RemoveCache) {
            for table in ["messages", "sync_seen", "event_stage"] {
                tx.execute(
                    &format!("DELETE FROM {table} WHERE account_id=?1"),
                    [account],
                )?;
            }
            tx.execute("DELETE FROM accounts WHERE id=?1", [account])?;
        }
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn ensure_job(
        &self,
        account: &str,
        kind: JobKind,
        resource: &str,
        window: i64,
    ) -> Result<()> {
        self.connection.execute(
            "INSERT OR IGNORE INTO sync_jobs(account_id,kind,resource,window) VALUES(?1,?2,?3,?4)",
            params![account, kind.as_str(), resource, window],
        )?;
        Ok(())
    }
    pub(crate) fn sync_now(&self) -> Result<()> {
        // Honour provider throttling. A manual refresh must not defeat Retry-After.
        self.connection.execute(
            "UPDATE sync_jobs SET next_due=0 WHERE failures=0 OR retry_class='network'",
            [],
        )?;
        Ok(())
    }
    pub(crate) fn next_job(&self, now: i64) -> Result<Option<SyncJob>> {
        let mut stmt = self.connection.prepare("WITH served AS (SELECT account_id,MAX(last_attempt) AS recent FROM sync_jobs WHERE active=1 GROUP BY account_id) SELECT j.account_id,kind,resource,window,state,failures FROM sync_jobs j JOIN served a ON a.account_id=j.account_id
            WHERE next_due<=?1 AND active=1 AND NOT EXISTS(SELECT 1 FROM account_paused p WHERE p.account_id=j.account_id)
            ORDER BY a.recent,CASE WHEN kind='catalog' THEN 0 WHEN kind='recent_mail' THEN 1 WHEN kind='calendar' AND last_success IS NULL THEN 2 ELSE 3 END,last_attempt LIMIT 1")?;
        let mut rows = stmt.query([now])?;
        let Some(row) = rows.next()? else {
            return Ok(None);
        };
        let kind: String = row.get(1)?;
        let state: String = row.get(4)?;
        Ok(Some(SyncJob {
            account_id: row.get(0)?,
            kind: serde_json::from_value(json!(kind))?,
            resource: row.get(2)?,
            window: row.get(3)?,
            state: serde_json::from_str(&state)?,
            failures: row.get(5)?,
        }))
    }
    pub(crate) fn mark_attempt(&self, job: &SyncJob, now: i64) -> Result<()> {
        self.connection.execute("UPDATE sync_jobs SET last_attempt=?5 WHERE account_id=?1 AND kind=?2 AND resource=?3 AND window=?4",
            params![job.account_id,job.kind.as_str(),job.resource,job.window,now])?;
        Ok(())
    }
    pub(crate) fn fail_job(
        &self,
        job: &SyncJob,
        now: i64,
        message: &str,
        retry: i64,
        class: RetryClass,
    ) -> Result<()> {
        self.connection.execute("UPDATE sync_jobs SET failures=failures+1,next_due=?5,error=?6,retry_class=?7 WHERE account_id=?1 AND kind=?2 AND resource=?3 AND window=?4",
            params![job.account_id,job.kind.as_str(),job.resource,job.window,now.saturating_add(retry),message,class.as_str()])?;
        Ok(())
    }
    pub(crate) fn job_status(&self) -> Result<Value> {
        let mut stmt = self.connection.prepare("SELECT account_id,kind,resource,window,last_success,next_due,error FROM sync_jobs ORDER BY account_id,kind,resource,window LIMIT 2000")?;
        let rows = stmt.query_map([], |r| Ok(json!({"account_id":r.get::<_,String>(0)?,"kind":r.get::<_,String>(1)?,"resource":r.get::<_,String>(2)?,"window":r.get::<_,i64>(3)?,"last_success":r.get::<_,Option<i64>>(4)?,"next_due":r.get::<_,i64>(5)?,"error":r.get::<_,Option<String>>(6)?})))?;
        Ok(serde_json::to_value(
            rows.collect::<rusqlite::Result<Vec<_>>>()?,
        )?)
    }
    pub(crate) fn folders(&self, account: &str) -> Result<Vec<MailFolder>> {
        let mut stmt = self.connection.prepare("SELECT account_id,id,name,parent_id,system FROM mail_folders WHERE account_id=?1 ORDER BY name LIMIT 2000")?;
        Ok(stmt
            .query_map([account], |r| {
                Ok(MailFolder {
                    account_id: r.get(0)?,
                    id: r.get(1)?,
                    name: r.get(2)?,
                    parent_id: r.get(3)?,
                    system: r.get(4)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?)
    }
    pub(crate) fn calendars(&self) -> Result<Vec<CalendarSource>> {
        let mut stmt = self.connection.prepare("SELECT account_id,id,name,color,is_primary FROM calendar_sources ORDER BY account_id,name LIMIT 1000")?;
        Ok(stmt
            .query_map([], |r| {
                Ok(CalendarSource {
                    account_id: r.get(0)?,
                    id: r.get(1)?,
                    name: r.get(2)?,
                    color: r.get(3)?,
                    is_primary: r.get(4)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?)
    }
    pub(crate) fn calendar_window(&self, month: i64) -> Result<()> {
        // The month is its UTC first day. Reject arbitrary unbounded windows.
        let day = chrono::DateTime::from_timestamp(month, 0).ok_or("Invalid calendar month")?;
        use chrono::Datelike;
        if day.day() != 1 || day.timestamp().rem_euclid(86400) != 0 {
            return Err("Calendar window must start on a UTC month boundary".into());
        }
        let sources = self.calendars()?;
        for source in sources {
            self.ensure_job(&source.account_id, JobKind::Calendar, &source.id, month)?;
        }
        let tx = self.connection.unchecked_transaction()?;
        // Keep at most six recently viewed windows per source. Job state owns eviction order.
        tx.execute("UPDATE sync_jobs SET viewed_at=MAX(viewed_at,?2),active=1 WHERE kind='calendar' AND window=?1", params![month,chrono::Utc::now().timestamp_micros()])?;
        tx.execute("DELETE FROM sync_jobs WHERE kind='calendar' AND rowid IN (
            SELECT rowid FROM (SELECT rowid,ROW_NUMBER() OVER(PARTITION BY account_id,resource ORDER BY viewed_at DESC,window DESC) AS rank FROM sync_jobs WHERE kind='calendar') WHERE rank>?1)", [WINDOW_LIMIT])?;
        tx.execute("DELETE FROM calendar_events WHERE NOT EXISTS(SELECT 1 FROM sync_jobs j WHERE j.account_id=calendar_events.account_id AND j.resource=calendar_events.calendar_id AND j.window=calendar_events.window AND j.kind='calendar')", [])?;
        tx.execute("DELETE FROM event_stage WHERE NOT EXISTS(SELECT 1 FROM sync_jobs j WHERE j.account_id=event_stage.account_id AND j.resource=event_stage.calendar_id AND j.window=event_stage.window AND j.kind='calendar')", [])?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn set_windows(&self, months: &[i64]) -> Result<()> {
        if months.is_empty() || months.len() > 5 {
            return Err("Track one to five calendar months at a time".into());
        }
        for month in months {
            self.calendar_window(*month)?;
        }
        let mut values = months.to_vec();
        while values.len() < 5 {
            values.push(months[0]);
        }
        self.connection.execute(
            "UPDATE sync_jobs SET active=(window IN (?1,?2,?3,?4,?5)) WHERE kind='calendar'",
            rusqlite::params_from_iter(values),
        )?;
        Ok(())
    }

    pub(crate) fn events(
        &self,
        start: i64,
        end: i64,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<CalendarEvent>> {
        if end <= start || end - start > 100 * 86400 {
            return Err("Calendar range must be under 100 days".into());
        }
        let mut stmt=self.connection.prepare("SELECT account_id,calendar_id,id,title,start,end,all_day,start_day,end_day,location,version FROM calendar_events WHERE start<?2 AND end>?1 GROUP BY account_id,calendar_id,id ORDER BY start,id LIMIT ?3 OFFSET ?4")?;
        Ok(stmt
            .query_map(
                params![
                    start,
                    end,
                    limit.min(EVENT_LIMIT) as i64,
                    offset.min(i64::MAX as usize) as i64
                ],
                |r| {
                    Ok(CalendarEvent {
                        reminder_times: Vec::new(),
                        account_id: r.get(0)?,
                        calendar_id: r.get(1)?,
                        id: r.get(2)?,
                        title: r.get(3)?,
                        start: r.get(4)?,
                        end: r.get(5)?,
                        all_day: r.get(6)?,
                        start_day: r.get(7)?,
                        end_day: r.get(8)?,
                        location: r.get(9)?,
                        version: r.get(10)?,
                    })
                },
            )?
            .collect::<rusqlite::Result<_>>()?)
    }
    pub(crate) fn checkpoint(&self, job: &SyncJob, state: &Value, delay: i64) -> Result<()> {
        self.finish_job(job, state, delay)
    }

    fn finish_job(&self, job: &SyncJob, state: &Value, delay: i64) -> Result<()> {
        let changed=self.connection.execute("UPDATE sync_jobs SET state=?5,next_due=?6,last_success=?7,failures=0,error=NULL,retry_class='' WHERE account_id=?1 AND kind=?2 AND resource=?3 AND window=?4 AND state=?8",
            params![job.account_id,job.kind.as_str(),job.resource,job.window,state.to_string(),chrono::Utc::now().timestamp()+delay,chrono::Utc::now().timestamp(),job.state.to_string()])?;
        if changed != 1 {
            return Err("Sync job was removed".into());
        }
        Ok(())
    }
    pub(crate) fn apply_catalog(
        &self,
        job: &SyncJob,
        folders: &[MailFolder],
        sources: &[CalendarSource],
        state: &Value,
        delay: i64,
    ) -> Result<()> {
        let tx = self.connection.unchecked_transaction()?;
        tx.execute("UPDATE sync_jobs SET state=state WHERE account_id=?1 AND kind=?2 AND resource=?3 AND window=?4",params![job.account_id,job.kind.as_str(),job.resource,job.window])?;
        if !self.connected(&job.account_id)? {
            return Err("Account is disconnected".into());
        }
        for f in folders {
            tx.execute(
                "INSERT OR IGNORE INTO sync_seen VALUES(?1,'catalog:folders',0,?2)",
                params![job.account_id, f.id],
            )?;
            tx.execute("INSERT INTO mail_folders(account_id,id,name,parent_id,system) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(account_id,id) DO UPDATE SET name=excluded.name,parent_id=excluded.parent_id,system=excluded.system", params![f.account_id,f.id,f.name,f.parent_id,f.system])?;
            if !f.id.starts_with("label:") {
                self.ensure_job(&f.account_id, JobKind::Mail, &f.id, 0)?;
            }
        }
        for c in sources {
            tx.execute(
                "INSERT OR IGNORE INTO sync_seen VALUES(?1,'catalog:calendars',0,?2)",
                params![job.account_id, c.id],
            )?;
            tx.execute("INSERT INTO calendar_sources(account_id,id,name,color,is_primary) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(account_id,id) DO UPDATE SET name=excluded.name,color=excluded.color,is_primary=excluded.is_primary",params![c.account_id,c.id,c.name,c.color,c.is_primary])?;
        }
        if state["finish_catalog"].as_bool() == Some(true) {
            tx.execute("DELETE FROM mail_folders WHERE account_id=?1 AND NOT EXISTS(SELECT 1 FROM sync_seen s WHERE s.account_id=?1 AND s.resource='catalog:folders' AND s.remote_id=mail_folders.id)",[&job.account_id])?;
            tx.execute("DELETE FROM calendar_sources WHERE account_id=?1 AND NOT EXISTS(SELECT 1 FROM sync_seen s WHERE s.account_id=?1 AND s.resource='catalog:calendars' AND s.remote_id=calendar_sources.id)",[&job.account_id])?;
            tx.execute("DELETE FROM sync_jobs WHERE account_id=?1 AND ((kind='calendar' AND NOT EXISTS(SELECT 1 FROM calendar_sources c WHERE c.account_id=?1 AND c.id=sync_jobs.resource)) OR (kind='mail' AND resource<>'' AND NOT EXISTS(SELECT 1 FROM mail_folders f WHERE f.account_id=?1 AND f.id=sync_jobs.resource)))",[&job.account_id])?;
            tx.execute("DELETE FROM event_stage WHERE account_id=?1 AND NOT EXISTS(SELECT 1 FROM calendar_sources c WHERE c.account_id=?1 AND c.id=event_stage.calendar_id)",[&job.account_id])?;
            tx.execute("DELETE FROM mail_membership WHERE account_id=?1 AND NOT EXISTS(SELECT 1 FROM mail_folders f WHERE f.account_id=?1 AND f.id=mail_membership.folder_id)",[&job.account_id])?;
            tx.execute("DELETE FROM sync_seen WHERE account_id=?1 AND resource IN('catalog:folders','catalog:calendars')",[&job.account_id])?;
        }
        self.finish_job(job, state, delay)?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn apply_mail(
        &self,
        job: &SyncJob,
        changes: &[(Message, Vec<String>)],
        removed: &[String],
        state: &Value,
        delay: i64,
    ) -> Result<()> {
        let tx = self.connection.unchecked_transaction()?;
        tx.execute("UPDATE sync_jobs SET state=state WHERE account_id=?1 AND kind=?2 AND resource=?3 AND window=?4",params![job.account_id,job.kind.as_str(),job.resource,job.window])?;
        if !self.connected(&job.account_id)? {
            return Err("Account is disconnected".into());
        }
        let gmail = self
            .accounts()?
            .into_iter()
            .any(|a| a.id == job.account_id && a.provider == Provider::Gmail);
        for (message, memberships) in changes {
            let is_new = !tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM messages WHERE id=?1)",
                [&message.id],
                |r| r.get::<_, bool>(0),
            )?;
            Self::upsert(&tx, message)?;
            if job.kind == JobKind::RecentMail {
                let resources = if gmail {
                    vec![String::new()]
                } else {
                    memberships.clone()
                };
                for resource in resources {
                    tx.execute("INSERT OR IGNORE INTO sync_seen SELECT ?1,?2,0,?3 WHERE EXISTS(SELECT 1 FROM sync_jobs WHERE account_id=?1 AND kind='mail' AND resource=?2 AND json_extract(state,'$.cursor') IS NULL AND json_extract(state,'$.history') IS NULL)",params![job.account_id,resource,message.remote_id])?;
                }
            }
            if job.resource.is_empty() {
                tx.execute(
                    "DELETE FROM mail_membership WHERE account_id=?1 AND remote_id=?2",
                    params![job.account_id, message.remote_id],
                )?;
                tx.execute("DELETE FROM folders WHERE message_id=?1", [&message.id])?;
            }
            for folder in memberships {
                tx.execute("INSERT OR IGNORE INTO mail_membership(account_id,remote_id,folder_id) VALUES(?1,?2,?3)",params![job.account_id,message.remote_id,folder])?;
                let system = if let Some(label) = folder.strip_prefix("label:") {
                    gmail_system(label)
                } else {
                    tx.query_row(
                        "SELECT system FROM mail_folders WHERE account_id=?1 AND id=?2",
                        params![job.account_id, folder],
                        |r| r.get::<_, Option<String>>(0),
                    )
                    .unwrap_or(None)
                };
                if let Some(system) = system {
                    tx.execute(
                        "INSERT OR IGNORE INTO folders VALUES(?1,?2)",
                        params![message.id, system],
                    )?;
                }
            }
            if gmail
                && job.resource.is_empty()
                && !memberships.iter().any(|f| {
                    [
                        "label:INBOX",
                        "label:SENT",
                        "label:DRAFT",
                        "label:TRASH",
                        "label:SPAM",
                    ]
                    .contains(&f.as_str())
                })
            {
                tx.execute(
                    "INSERT OR IGNORE INTO folders VALUES(?1,'archive')",
                    [&message.id],
                )?;
            }
            if state["scanning"].as_bool() == Some(true)
                || state["scan_done"].as_bool() == Some(true)
                || job.state["scanning"].as_bool() == Some(true)
            {
                tx.execute(
                    "INSERT OR IGNORE INTO sync_seen VALUES(?1,?2,0,?3)",
                    params![job.account_id, job.resource, message.remote_id],
                )?;
            }
            self.rebase_mail(&message.id)?;
            super::notices::observe_mail(
                &tx,
                message,
                if is_new {
                    crate::notices::Arrival::New
                } else {
                    crate::notices::Arrival::Existing
                },
            )?;
        }
        for remote in removed {
            if self.keep_mail(&job.account_id, remote)? {
                if job.resource.is_empty() {
                    self.missing_mail(&job.account_id, remote)?;
                }
                continue;
            }
            if job.resource.is_empty() {
                tx.execute(
                    "DELETE FROM messages WHERE account_id=?1 AND remote_id=?2",
                    params![job.account_id, remote],
                )?;
            } else {
                tx.execute("DELETE FROM mail_membership WHERE account_id=?1 AND remote_id=?2 AND folder_id=?3",params![job.account_id,remote,job.resource])?;
                tx.execute("DELETE FROM folders WHERE message_id IN(SELECT id FROM messages WHERE account_id=?1 AND remote_id=?2) AND folder IN(SELECT system FROM mail_folders WHERE account_id=?1 AND id=?3)",params![job.account_id,remote,job.resource])?;
                tx.execute("DELETE FROM messages WHERE account_id=?1 AND remote_id=?2 AND NOT EXISTS(SELECT 1 FROM mail_membership f WHERE f.account_id=?1 AND f.remote_id=?2)",params![job.account_id,remote])?;
            }
        }
        if state["scan_done"].as_bool() == Some(true) {
            if job.resource.is_empty() {
                tx.execute("INSERT OR IGNORE INTO mail_tombstones SELECT id FROM messages WHERE account_id=?1 AND EXISTS(SELECT 1 FROM mail_actions a WHERE a.message_id=messages.id AND a.state<>'done') AND NOT EXISTS(SELECT 1 FROM sync_seen s WHERE s.account_id=?1 AND s.resource='' AND s.remote_id=messages.remote_id)",[&job.account_id])?;
                tx.execute("DELETE FROM messages WHERE account_id=?1 AND NOT EXISTS(SELECT 1 FROM mail_actions a WHERE a.message_id=messages.id AND a.state<>'done') AND NOT EXISTS(SELECT 1 FROM sync_seen s WHERE s.account_id=?1 AND s.resource='' AND s.remote_id=messages.remote_id)",[&job.account_id])?;
            } else {
                tx.execute("DELETE FROM mail_membership WHERE account_id=?1 AND folder_id=?2 AND NOT EXISTS(SELECT 1 FROM sync_seen s WHERE s.account_id=?1 AND s.resource=?2 AND s.remote_id=mail_membership.remote_id)",params![job.account_id,job.resource])?;
                tx.execute("DELETE FROM folders WHERE folder IN(SELECT system FROM mail_folders WHERE account_id=?1 AND id=?2) AND message_id IN(SELECT m.id FROM messages m WHERE m.account_id=?1 AND NOT EXISTS(SELECT 1 FROM mail_membership f WHERE f.account_id=?1 AND f.remote_id=m.remote_id AND f.folder_id=?2))",params![job.account_id,job.resource])?;
            }
            tx.execute(
                "DELETE FROM sync_seen WHERE account_id=?1 AND resource=?2 AND window=0",
                params![job.account_id, job.resource],
            )?;
        }
        self.project_mail(&job.account_id)?;
        self.finish_job(job, state, delay)?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn reset_job(&self, job: &SyncJob) -> Result<()> {
        let tx = self.connection.unchecked_transaction()?;
        if job.kind == JobKind::Mail {
            tx.execute(
                "DELETE FROM sync_seen WHERE account_id=?1 AND resource=?2 AND window=?3",
                params![job.account_id, job.resource, job.window],
            )?;
        }
        if job.kind == JobKind::Calendar {
            tx.execute(
                "DELETE FROM event_stage WHERE account_id=?1 AND calendar_id=?2 AND window=?3",
                params![job.account_id, job.resource, job.window],
            )?;
        }
        self.finish_job(job, &json!({}), 0)?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn apply_events(
        &self,
        job: &SyncJob,
        events: &[CalendarEvent],
        removed: &[String],
        state: &Value,
        delay: i64,
    ) -> Result<()> {
        let tx = self.connection.unchecked_transaction()?;
        tx.execute("UPDATE sync_jobs SET state=state WHERE account_id=?1 AND kind=?2 AND resource=?3 AND window=?4",params![job.account_id,job.kind.as_str(),job.resource,job.window])?;
        if !self.connected(&job.account_id)? {
            return Err("Account is disconnected".into());
        }
        let baseline: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM notice_calendars WHERE account_id=?1 AND calendar_id=?2)",
            params![job.account_id, job.resource],
            |r| r.get(0),
        )?;
        let baseline = if baseline {
            crate::notices::EventBaseline::Known
        } else {
            crate::notices::EventBaseline::Initial
        };
        let snapshot = state["snapshot"].as_bool() == Some(true);
        for e in events {
            if snapshot {
                tx.execute("INSERT INTO event_stage VALUES(?1,?2,?3,?4,?5) ON CONFLICT(account_id,calendar_id,window,id) DO UPDATE SET data=excluded.data", params![job.account_id,job.resource,job.window,e.id,serde_json::to_string(e)?])?;
            } else {
                cache_event(&tx, job.window, e, baseline)?;
            }
        }
        for id in removed {
            tx.execute("DELETE FROM calendar_events WHERE account_id=?1 AND calendar_id=?2 AND window=?3 AND id=?4",params![job.account_id,job.resource,job.window,id])?;
        }
        if snapshot && state["next"].is_null() {
            tx.execute(
                "DELETE FROM calendar_events WHERE account_id=?1 AND calendar_id=?2 AND window=?3 AND NOT EXISTS(SELECT 1 FROM event_stage s WHERE s.account_id=?1 AND s.calendar_id=?2 AND s.window=?3 AND s.id=calendar_events.id)",
                params![job.account_id, job.resource, job.window],
            )?;
            let mut stmt = tx.prepare(
                "SELECT data FROM event_stage WHERE account_id=?1 AND calendar_id=?2 AND window=?3",
            )?;
            let mut rows = stmt.query(params![job.account_id, job.resource, job.window])?;
            while let Some(row) = rows.next()? {
                cache_event(
                    &tx,
                    job.window,
                    &serde_json::from_str::<CalendarEvent>(&row.get::<_, String>(0)?)?,
                    baseline,
                )?;
            }
            drop(rows);
            drop(stmt);
            tx.execute(
                "DELETE FROM event_stage WHERE account_id=?1 AND calendar_id=?2 AND window=?3",
                params![job.account_id, job.resource, job.window],
            )?;
        }
        if state["next"].is_null() {
            tx.execute(
                "INSERT OR IGNORE INTO notice_calendars VALUES(?1,?2)",
                params![job.account_id, job.resource],
            )?;
        }
        self.finish_job(job, state, delay)?;
        tx.commit()?;
        Ok(())
    }
}
fn cache_event(
    tx: &Connection,
    window: i64,
    event: &CalendarEvent,
    baseline: crate::notices::EventBaseline,
) -> Result<()> {
    let previous: Option<i64> = tx.query_row(
        "SELECT MAX(version) FROM calendar_events WHERE account_id=?1 AND calendar_id=?2 AND id=?3",
        params![event.account_id, event.calendar_id, event.id],
        |r| r.get(0),
    )?;
    save_event(tx, window, event)?;
    if previous.is_none_or(|v| event.version > v) {
        super::notices::observe_event(tx, event, baseline)?;
    }
    Ok(())
}
fn save_event(tx: &Connection, window: i64, e: &CalendarEvent) -> Result<()> {
    tx.execute("INSERT INTO calendar_events(account_id,calendar_id,window,id,title,start,end,all_day,start_day,end_day,location,version) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) ON CONFLICT(account_id,calendar_id,window,id) DO UPDATE SET title=excluded.title,start=excluded.start,end=excluded.end,all_day=excluded.all_day,start_day=excluded.start_day,end_day=excluded.end_day,location=excluded.location,version=excluded.version WHERE excluded.version>=calendar_events.version",params![e.account_id,e.calendar_id,window,e.id,e.title,e.start,e.end,e.all_day,e.start_day,e.end_day,e.location,e.version])?;
    let newest: i64 = tx.query_row(
        "SELECT MAX(version) FROM calendar_events WHERE account_id=?1 AND calendar_id=?2 AND id=?3",
        params![e.account_id, e.calendar_id, e.id],
        |r| r.get(0),
    )?;
    if e.version >= newest {
        tx.execute(
            "DELETE FROM event_reminders WHERE account_id=?1 AND calendar_id=?2 AND id=?3",
            params![e.account_id, e.calendar_id, e.id],
        )?;
        for due in e.reminder_times.iter().take(5) {
            tx.execute("INSERT OR IGNORE INTO event_reminders SELECT account_id,calendar_id,window,id,?4 FROM calendar_events WHERE account_id=?1 AND calendar_id=?2 AND id=?3",params![e.account_id,e.calendar_id,e.id,due])?;
        }
    }
    tx.execute("INSERT OR IGNORE INTO event_reminders SELECT account_id,calendar_id,?4,id,due FROM event_reminders WHERE account_id=?1 AND calendar_id=?2 AND id=?3",params![e.account_id,e.calendar_id,e.id,window])?;
    // Overlapping month windows share the newest server version of an occurrence.
    tx.execute("WITH latest AS MATERIALIZED (SELECT title,start,end,all_day,start_day,end_day,location,version FROM calendar_events WHERE account_id=?1 AND calendar_id=?2 AND id=?3 ORDER BY version DESC LIMIT 1) UPDATE calendar_events SET (title,start,end,all_day,start_day,end_day,location,version)=(SELECT * FROM latest) WHERE account_id=?1 AND calendar_id=?2 AND id=?3",params![e.account_id,e.calendar_id,e.id])?;
    Ok(())
}

fn gmail_system(label: &str) -> Option<String> {
    match label {
        "INBOX" => Some(Folder::Inbox),
        "SENT" => Some(Folder::Sent),
        "DRAFT" => Some(Folder::Drafts),
        "TRASH" => Some(Folder::Trash),
        _ => None,
    }
    .map(|f| f.as_str().into())
}

#[cfg(test)]
impl Store {
    pub(crate) fn test_job(&self, seed: &SyncJob) -> SyncJob {
        let mut job = seed.clone();
        let (state,failures):(String,i64)=self.connection.query_row("SELECT state,failures FROM sync_jobs WHERE account_id=?1 AND kind=?2 AND resource=?3 AND window=?4",params![seed.account_id,seed.kind.as_str(),seed.resource,seed.window],|r|Ok((r.get(0)?,r.get(1)?))).unwrap();
        job.state = serde_json::from_str(&state).unwrap();
        job.failures = failures;
        job
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn account(store: &Store, id: &str) {
        store
            .save_account(&Account {
                id: id.into(),
                email: format!("{id}@example.test"),
                provider: Provider::Outlook,
            })
            .unwrap();
    }
    fn job(store: &Store, id: &str, kind: JobKind, resource: &str, window: i64) -> SyncJob {
        store.ensure_job(id, kind, resource, window).unwrap();
        SyncJob {
            account_id: id.into(),
            kind,
            resource: resource.into(),
            window,
            state: json!({}),
            failures: 0,
        }
    }
    #[test]
    fn ready_respects_retry_and_pause() {
        let store = Store::open(":memory:").unwrap();
        account(&store, "a");
        assert!(!store.sync_ready(100).unwrap());
        let due = job(&store, "a", JobKind::Mail, "inbox", 0);
        assert!(store.sync_ready(100).unwrap());
        store
            .fail_job(&due, 100, "throttled", 120, RetryClass::Throttled)
            .unwrap();
        store.sync_now().unwrap();
        assert!(!store.sync_ready(219).unwrap());
        assert!(store.sync_ready(220).unwrap());
        store.pause_account("a", DisconnectMode::KeepCache).unwrap();
        assert!(!store.sync_ready(220).unwrap());
        store
            .connection
            .execute("DELETE FROM account_paused", [])
            .unwrap();
        store
            .connection
            .execute("DELETE FROM sync_jobs", [])
            .unwrap();
        // These isolated queues must keep the batch alive even with no provider job.
        for (table, insert, due) in [
            (
                "mail_actions",
                "INSERT INTO mail_actions(id,account,message_id,data,state,created) VALUES('work','a','message','{}','pending',0)",
                "due",
            ),
            (
                "mail_outbox",
                "INSERT INTO mail_outbox(id,account,data,state,created) VALUES('work','a','{}','pending',0)",
                "due",
            ),
            (
                "event_writes",
                "INSERT INTO event_writes(operation,account_id,calendar_id,data,state,created) VALUES('work','a','cal','{}','pending',0)",
                "next_due",
            ),
        ] {
            store.connection.execute(insert, []).unwrap();
            assert!(store.sync_ready(100).unwrap(), "{table}");
            store
                .connection
                .execute(&format!("UPDATE {table} SET state='retry',{due}=200"), [])
                .unwrap();
            assert!(!store.sync_ready(199).unwrap(), "{table}");
            store.pause_account("a", DisconnectMode::KeepCache).unwrap();
            assert!(!store.sync_ready(200).unwrap(), "{table}");
            store
                .connection
                .execute("DELETE FROM account_paused", [])
                .unwrap();
            assert!(store.sync_ready(200).unwrap(), "{table}");
            store
                .connection
                .execute(&format!("UPDATE {table} SET state='uncertain'"), [])
                .unwrap();
            assert!(!store.sync_ready(200).unwrap(), "{table}");
            store
                .connection
                .execute(&format!("DELETE FROM {table}"), [])
                .unwrap();
        }
    }
    #[test]
    fn page_and_cursor_are_atomic() {
        let store = Store::open(":memory:").unwrap();
        account(&store, "a");
        account(&store, "b");
        let j = job(&store, "a", JobKind::Mail, "", 0);
        let message =
            crate::mime::parse(b"Subject: Cached\r\n\r\nOffline body", "a", "same").unwrap();
        let other =
            crate::mime::parse(b"Subject: Other\r\n\r\nAnother account", "b", "same").unwrap();
        store.save(&other, Folder::Inbox).unwrap();
        store
            .apply_mail(
                &j,
                &[(message.clone(), vec!["label:INBOX".into()])],
                &[],
                &json!({"history":"10","scan_done":true}),
                0,
            )
            .unwrap();
        assert_eq!(
            store
                .list(Some("a"), Folder::Inbox, "", 0, 10)
                .unwrap()
                .len(),
            1
        );
        // A stale worker rolls its body/labels back when its cursor CAS fails.
        let mut stale = message.clone();
        stale.subject = "Must roll back".into();
        assert!(
            store
                .apply_mail(&j, &[(stale, vec![])], &[], &json!({"history":"11"}), 0)
                .is_err()
        );
        assert_eq!(store.message(&message.id).unwrap().subject, "Cached");
        let j = store.test_job(&j);
        store
            .apply_mail(&j, &[], &["same".into()], &json!({"history":"11"}), 60)
            .unwrap();
        assert!(store.message(&message.id).is_err());
        assert!(store.message(&other.id).is_ok());
    }
    #[test]
    fn snapshot_survives_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cache.sqlite");
        let store = Store::open(path.to_str().unwrap()).unwrap();
        account(&store, "a");
        let catalog = job(&store, "a", JobKind::Catalog, "", 0);
        let source = CalendarSource {
            account_id: "a".into(),
            id: "primary".into(),
            name: "Work".into(),
            color: "#123456".into(),
            is_primary: true,
        };
        store
            .apply_catalog(
                &catalog,
                &[],
                &[source],
                &json!({"finish_catalog":true}),
                900,
            )
            .unwrap();
        let month = 1735689600;
        let j = job(&store, "a", JobKind::Calendar, "primary", month);
        let event = CalendarEvent {
            reminder_times: Vec::new(),
            version: 0,
            account_id: "a".into(),
            calendar_id: "primary".into(),
            id: "one".into(),
            title: "Offline event".into(),
            start: month + 3600,
            end: month + 7200,
            all_day: false,
            start_day: None,
            end_day: None,
            location: "".into(),
        };
        store
            .apply_events(
                &j,
                std::slice::from_ref(&event),
                &[],
                &json!({"snapshot":true,"next":null}),
                60,
            )
            .unwrap();
        let j = store.test_job(&j);
        let mut changed = event.clone();
        changed.title = "Staged only".into();
        changed.version = 2;
        store
            .apply_events(
                &j,
                &[changed],
                &[],
                &json!({"snapshot":true,"next":"page-two"}),
                0,
            )
            .unwrap();
        drop(store);
        let store = Store::open(path.to_str().unwrap()).unwrap();
        assert_eq!(
            store.events(month, month + 86400, 0, 2000).unwrap()[0].title,
            "Offline event"
        );
        let j = store.test_job(&j);
        store
            .apply_events(&j, &[], &[], &json!({"snapshot":true,"next":null}), 60)
            .unwrap();
        assert_eq!(
            store.events(month, month + 86400, 0, 2000).unwrap()[0].title,
            "Staged only"
        );
        let j = store.test_job(&j);
        store.pause_account("a", DisconnectMode::KeepCache).unwrap();
        assert!(
            store
                .apply_events(&j, &[], &[], &json!({"snapshot":true}), 60)
                .is_err()
        );
        assert_eq!(
            store.events(month, month + 86400, 0, 2000).unwrap().len(),
            1
        );
    }
    #[test]
    fn retry_window_bounds() {
        let store = Store::open(":memory:").unwrap();
        account(&store, "a");
        let catalog = job(&store, "a", JobKind::Catalog, "", 0);
        let source = CalendarSource {
            account_id: "a".into(),
            id: "primary".into(),
            name: "Work".into(),
            color: "#123456".into(),
            is_primary: true,
        };
        store
            .apply_catalog(
                &catalog,
                &[],
                &[source],
                &json!({"finish_catalog":true}),
                900,
            )
            .unwrap();
        use chrono::{TimeZone, Utc};
        for month in 1..=12 {
            store
                .calendar_window(
                    Utc.with_ymd_and_hms(2026, month, 1, 0, 0, 0)
                        .unwrap()
                        .timestamp(),
                )
                .unwrap();
        }
        let count: i64 = store
            .connection
            .query_row(
                "SELECT COUNT(*) FROM sync_jobs WHERE kind='calendar'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, WINDOW_LIMIT);
        let due = job(&store, "a", JobKind::Mail, "inbox", 0);
        let now = chrono::Utc::now().timestamp();
        store
            .fail_job(&due, now, "throttled", 120, RetryClass::Throttled)
            .unwrap();
        store.sync_now().unwrap();
        let next: i64 = store
            .connection
            .query_row(
                "SELECT next_due FROM sync_jobs WHERE kind='mail'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(next, now + 120);
        store
            .pause_account("a", DisconnectMode::RemoveCache)
            .unwrap();
        assert!(store.accounts().unwrap().is_empty());
        assert!(store.calendars().unwrap().is_empty());
        assert!(store.next_job(i64::MAX).unwrap().is_none());
    }
}

#[cfg(test)]
mod qualification {
    use super::*;
    #[test]
    #[ignore = "generates a disconnected synthetic multi-account native fixture"]
    fn seed_account_fixture() {
        use chrono::{Datelike, TimeZone, Utc};
        let path = std::env::var("SQUAREMAIL_ACCOUNT_DB")
            .expect("Set SQUAREMAIL_ACCOUNT_DB to a disposable path");
        assert!(
            !std::path::Path::new(&path).exists(),
            "Choose a new disposable fixture path"
        );
        let store = Store::open(&path).unwrap();
        let now = Utc::now();
        let month = Utc
            .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
            .unwrap()
            .timestamp();
        for (key, provider) in [
            ("fixture-gmail", Provider::Gmail),
            ("fixture-live", Provider::Outlook),
            ("fixture-365", Provider::Outlook),
        ] {
            let account = Account {
                id: key.into(),
                email: format!("{key}@example.test"),
                provider,
            };
            store.save_account(&account).unwrap();
            let catalog = SyncJob {
                account_id: key.into(),
                kind: JobKind::Catalog,
                resource: "".into(),
                window: 0,
                state: json!({}),
                failures: 0,
            };
            store.ensure_job(key, JobKind::Catalog, "", 0).unwrap();
            let folders = vec![
                MailFolder {
                    account_id: key.into(),
                    id: "inbox".into(),
                    name: "Inbox".into(),
                    parent_id: None,
                    system: Some(Folder::Inbox.as_str().into()),
                },
                MailFolder {
                    account_id: key.into(),
                    id: "projects".into(),
                    name: "Projects".into(),
                    parent_id: None,
                    system: None,
                },
                MailFolder {
                    account_id: key.into(),
                    id: "project-mail".into(),
                    name: "Square Mail".into(),
                    parent_id: Some("projects".into()),
                    system: None,
                },
            ];
            let sources = (0..4)
                .map(|i| CalendarSource {
                    account_id: key.into(),
                    id: format!("calendar-{i}"),
                    name: format!("Calendar {}", i + 1),
                    color: "#2C68AD".into(),
                    is_primary: i == 0,
                })
                .collect::<Vec<_>>();
            store
                .apply_catalog(
                    &catalog,
                    &folders,
                    &sources,
                    &json!({"finish_catalog":true}),
                    900,
                )
                .unwrap();
            for source in &sources {
                store
                    .ensure_job(key, JobKind::Calendar, &source.id, month)
                    .unwrap();
            }
            let tx = store.connection.unchecked_transaction().unwrap();
            for i in 0..10_000 {
                let id = crate::mime::message_id(key, &i.to_string());
                let body =
                    (i >= 9900).then(|| format!("Offline message for {key}. ") + &"x".repeat(8192));
                let message = Message {
                    pinned: false,
                    reply: None,
                    id,
                    account_id: key.into(),
                    remote_id: i.to_string(),
                    sender: "Ada Example".into(),
                    sender_address: "ada@example.test".into(),
                    recipient: account.email.clone(),
                    subject: format!("{key} project notes {i}"),
                    preview: "Synthetic offline fixture".into(),
                    timestamp: now.timestamp() - 10000 + i,
                    unread: i % 3 == 0,
                    starred: false,
                    has_attachments: false,
                    text: body,
                    html: Some("<p>Synthetic offline fixture</p>".into()),
                };
                Store::upsert(&tx, &message).unwrap();
                tx.execute(
                    "INSERT OR IGNORE INTO folders VALUES(?1,'inbox')",
                    [&message.id],
                )
                .unwrap();
                tx.execute(
                    "INSERT OR IGNORE INTO mail_membership VALUES(?1,?2,'inbox')",
                    params![key, message.remote_id],
                )
                .unwrap();
                if i % 10 == 0 {
                    tx.execute(
                        "INSERT OR IGNORE INTO mail_membership VALUES(?1,?2,'project-mail')",
                        params![key, message.remote_id],
                    )
                    .unwrap();
                }
            }
            for i in 0..700 {
                let event = CalendarEvent {
                    reminder_times: Vec::new(),
                    version: 1,
                    account_id: key.into(),
                    calendar_id: format!("calendar-{}", i % 4),
                    id: format!("event-{i}"),
                    title: format!("{key} meeting {i}"),
                    start: month + 86400 * (i % 28) + 3600 * (8 + i % 10),
                    end: month + 86400 * (i % 28) + 3600 * (9 + i % 10),
                    all_day: false,
                    start_day: None,
                    end_day: None,
                    location: "Demo studio".into(),
                };
                save_event(&tx, month, &event).unwrap();
            }
            tx.commit().unwrap();
            store.pause_account(key, DisconnectMode::KeepCache).unwrap();
        }
        println!(
            "Generated 30,000 headers, 300 cached bodies, 12 calendars and 2,100 events. Accounts are disconnected."
        );
    }
}
