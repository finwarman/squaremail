use super::*;
use crate::calendar::{DETAIL_LIMIT, EventDetail, EventKey, PendingWrite, QUEUE_LIMIT, WriteState};
use rusqlite::OptionalExtension;
use serde_json::{Value, json};

const DRAFT_LIMIT: i64 = 20;

impl Store {
    pub(crate) fn event_detail(&self, key: &EventKey) -> Result<Option<EventDetail>> {
        let value: Option<String> = self
            .connection
            .query_row(
                "SELECT data FROM event_details WHERE account_id=?1 AND calendar_id=?2 AND id=?3",
                params![key.account, key.calendar, key.id.as_deref().unwrap_or("")],
                |r| r.get(0),
            )
            .optional()?;
        value
            .map(|v| serde_json::from_str(&v).map_err(Into::into))
            .transpose()
    }
    pub(crate) fn save_event_detail(&self, detail: &EventDetail) -> Result<()> {
        let id = detail.key.id.as_deref().unwrap_or("");
        let data = serde_json::to_string(detail)?;
        if data.len() > DETAIL_LIMIT + 32 * 1024 {
            return Err("Event details exceed the cache limit".into());
        }
        let tx = self.connection.unchecked_transaction()?;
        tx.execute("INSERT INTO event_details VALUES(?1,?2,?3,?4,?5) ON CONFLICT(account_id,calendar_id,id) DO UPDATE SET data=excluded.data,touched=excluded.touched",params![detail.key.account,detail.key.calendar,id,data,chrono::Utc::now().timestamp()])?;
        tx.execute("DELETE FROM event_details WHERE rowid NOT IN(SELECT rowid FROM event_details ORDER BY touched DESC,rowid DESC LIMIT 100)",[])?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn queue_event(&self, write: &PendingWrite) -> Result<()> {
        let data = serde_json::to_string(write)?;
        if data.len() > DETAIL_LIMIT + 64 * 1024 {
            return Err("Pending edit exceeds its size limit".into());
        }
        let tx = self.connection.unchecked_transaction()?;
        let previous: Option<String> = tx
            .query_row(
                "SELECT data FROM event_writes WHERE operation=?1",
                [&write.change.operation],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(previous) = previous {
            if previous != data {
                return Err("Operation ID already belongs to a different edit".into());
            }
            return Ok(());
        }
        let count: i64 = tx.query_row(
            "SELECT COUNT(*) FROM event_writes WHERE state<>'done'",
            [],
            |r| r.get(0),
        )?;
        if count >= QUEUE_LIMIT as i64 {
            return Err("Pending edits are full. Resolve or discard an older edit.".into());
        }
        if let Some(id) = &write.change.key.id {
            let busy:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM event_writes WHERE account_id=?1 AND calendar_id=?2 AND state<>'done' AND json_extract(data,'$.change.key.id')=?3)",params![write.change.key.account,write.change.key.calendar,id],|r|r.get(0))?;
            if busy {
                return Err("This event already has a pending edit. Resolve it first.".into());
            }
        }
        tx.execute("INSERT INTO event_writes(operation,account_id,calendar_id,data,state,created) VALUES(?1,?2,?3,?4,?5,?6)",params![write.change.operation,write.change.key.account,write.change.key.calendar,data,WriteState::Pending.as_str(),chrono::Utc::now().timestamp()])?;
        tx.execute(
            "DELETE FROM event_drafts WHERE operation=?1",
            [&write.change.operation],
        )?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn next_event_write(&self) -> Result<Option<PendingWrite>> {
        let now = chrono::Utc::now().timestamp();
        // A crashed writer can be retried with the same provider idempotency key.
        let value:Option<(String,i64)>=self.connection.query_row("SELECT data,attempts FROM event_writes WHERE (state IN('pending','retry') OR (state='sending' AND next_due<?1)) AND next_due<=?1 AND NOT EXISTS(SELECT 1 FROM account_paused p WHERE p.account_id=event_writes.account_id) ORDER BY created LIMIT 1",[now],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        value
            .map(|(data, attempts)| {
                let mut write: PendingWrite = serde_json::from_str(&data)?;
                write.attempts = attempts;
                Ok(write)
            })
            .transpose()
    }
    pub(crate) fn mark_event_write(
        &self,
        operation: &str,
        state: WriteState,
        error: Option<&str>,
        delay: i64,
    ) -> Result<()> {
        let delay = if state == WriteState::Sending {
            60
        } else {
            delay
        };
        self.connection.execute("UPDATE event_writes SET state=?2,error=?3,next_due=?4,attempts=attempts+CASE WHEN ?2='sending' THEN 1 ELSE 0 END WHERE operation=?1",params![operation,state.as_str(),error,chrono::Utc::now().timestamp()+delay])?;
        Ok(())
    }
    pub(crate) fn event_writes(&self) -> Result<Value> {
        let mut stmt=self.connection.prepare("SELECT operation,state,error,created,json_extract(data,'$.change.draft.title'),account_id,calendar_id,json_extract(data,'$.change.key.id') FROM event_writes WHERE state<>'done' ORDER BY created DESC LIMIT 50")?;
        let mut values=stmt.query_map([],|r|Ok(json!({"operation":r.get::<_,String>(0)?,"state":r.get::<_,String>(1)?,"error":r.get::<_,Option<String>>(2)?,"created":r.get::<_,i64>(3)?,"title":r.get::<_,String>(4)?,"account":r.get::<_,String>(5)?,"calendar":r.get::<_,String>(6)?,"id":r.get::<_,Option<String>>(7)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let mut drafts = self
            .connection
            .prepare("SELECT data FROM event_drafts ORDER BY saved DESC LIMIT ?1")?;
        let mut rows = drafts.query([DRAFT_LIMIT])?;
        while let Some(row) = rows.next()? {
            let mut draft: PendingWrite = serde_json::from_str(&row.get::<_, String>(0)?)?;
            if let Some(base) = &mut draft.base {
                base.raw = Value::Null;
            }
            values.push(json!({"operation":draft.change.operation,"state":WriteState::Draft.as_str(),"error":null,"title":draft.change.draft.title,"account":draft.change.key.account,"calendar":draft.change.key.calendar,"id":draft.change.key.id,"draft":draft}));
        }
        Ok(json!(values))
    }
    pub(crate) fn event_draft(&self, operation: &str) -> Result<Option<PendingWrite>> {
        let data: Option<String> = self
            .connection
            .query_row(
                "SELECT data FROM event_drafts WHERE operation=?1",
                [operation],
                |r| r.get(0),
            )
            .optional()?;
        data.map(|d| serde_json::from_str(&d).map_err(Into::into))
            .transpose()
    }
    pub(crate) fn save_event_draft(&self, write: &PendingWrite) -> Result<()> {
        let data = serde_json::to_string(write)?;
        if data.len() > DETAIL_LIMIT + 64 * 1024 {
            return Err("Calendar draft exceeds its size limit".into());
        }
        let tx = self.connection.unchecked_transaction()?;
        let pending: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM event_writes WHERE operation=?1)",
            [&write.change.operation],
            |r| r.get(0),
        )?;
        if pending {
            return Err(
                "This edit is already queued. Open Pending changes before replacing it.".into(),
            );
        }
        let count: i64 = tx.query_row(
            "SELECT COUNT(*) FROM event_drafts WHERE operation<>?1",
            [&write.change.operation],
            |r| r.get(0),
        )?;
        if count >= DRAFT_LIMIT {
            return Err("Local calendar drafts are full. Remove an older draft first.".into());
        }
        tx.execute("INSERT INTO event_drafts VALUES(?1,?2,?3,unixepoch()) ON CONFLICT(operation) DO UPDATE SET account_id=excluded.account_id,data=excluded.data,saved=excluded.saved",params![write.change.operation,write.change.key.account,data])?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn discard_event(&self, operation: &str) -> Result<()> {
        if self
            .connection
            .execute("DELETE FROM event_drafts WHERE operation=?1", [operation])?
            > 0
        {
            return Ok(());
        }
        let changed = self.connection.execute(
            "DELETE FROM event_writes WHERE operation=?1 AND (state<>'sending' OR next_due<unixepoch())",
            [operation],
        )?;
        if changed == 0 {
            return Err(
                "An in-flight edit cannot be discarded until it finishes or times out".into(),
            );
        }
        Ok(())
    }
    pub(crate) fn finish_event_write(
        &self,
        write: &PendingWrite,
        detail: &EventDetail,
        event: &CalendarEvent,
    ) -> Result<()> {
        self.save_event_detail(detail)?;
        let month =
            chrono::DateTime::from_timestamp(event.start, 0).ok_or("Invalid event start")?;
        use chrono::{Datelike, TimeZone};
        let window = chrono::Utc
            .with_ymd_and_hms(month.year(), month.month(), 1, 0, 0, 0)
            .single()
            .ok_or("Invalid event month")?
            .timestamp();
        let tx = self.connection.unchecked_transaction()?;
        super::save_event(&tx, window, event)?;
        tx.execute(
            "UPDATE event_writes SET state='done',result_id=?2,error=NULL WHERE operation=?1",
            params![write.change.operation, detail.key.id],
        )?;
        tx.execute("DELETE FROM event_writes WHERE state='done' AND operation NOT IN(SELECT operation FROM event_writes WHERE state='done' ORDER BY created DESC LIMIT 200)",[])?;
        tx.execute("UPDATE sync_jobs SET next_due=0 WHERE account_id=?1 AND kind='calendar' AND resource=?2",params![detail.key.account,detail.key.calendar])?;
        tx.commit()?;
        self.write_notice(write, detail)?;
        Ok(())
    }
}
