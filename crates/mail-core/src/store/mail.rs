use super::*;
use rusqlite::OptionalExtension;
use serde_json::{Value, json};

const ACTION_LIMIT: i64 = 100;
const DRAFT_LIMIT: i64 = 100;
const OUTBOX_LIMIT: i64 = 50;
const RECEIPT_LIMIT: i64 = 200;

impl Store {
    pub(crate) fn action_message(&self, id: &str) -> Result<Message> {
        self.connection.query_row("SELECT id,account_id,remote_id,sender,sender_address,recipient,subject,preview,timestamp,unread,starred,has_attachments,NULL,NULL,pinned FROM messages WHERE id=?1",[id],Self::read_row).optional()?.ok_or_else(|| "This message changed during sync. Refresh the list and select it again.".into())
    }
    pub(crate) fn reply_headers(&self, id: &str) -> Result<Option<ReplyHeaders>> {
        let data: Option<String> = self
            .connection
            .query_row(
                "SELECT data FROM mail_headers WHERE message_id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        data.map(|s| serde_json::from_str(&s).map_err(Into::into))
            .transpose()
    }
    pub(crate) fn save_headers(&self, id: &str, headers: &ReplyHeaders) -> Result<()> {
        let data = serde_json::to_string(headers)?;
        if data.len() > REPLY_LIMIT {
            return Err("Reply headers exceed the cache limit".into());
        }
        self.connection.execute("INSERT INTO mail_headers VALUES(?1,?2) ON CONFLICT(message_id) DO UPDATE SET data=excluded.data",params![id,data])?;
        Ok(())
    }
    pub(crate) fn pin_mail(&self, id: &str, pinned: MailToggle) -> Result<()> {
        self.connection.execute(
            "UPDATE messages SET pinned=?2 WHERE id=?1",
            params![id, pinned.enabled()],
        )?;
        Ok(())
    }
    pub(crate) fn queue_mail(
        &self,
        operation: &str,
        message: Message,
        action: MailAction,
    ) -> Result<()> {
        let tx = self.write_tx()?;
        let existing: Option<String> = tx
            .query_row(
                "SELECT data FROM mail_actions WHERE id=?1",
                [operation],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(data) = existing {
            let old: QueuedMail = serde_json::from_str(&data)?;
            if old.message.id != message.id || old.action != action {
                return Err("Operation ID belongs to a different mail change".into());
            }
            return Ok(());
        }
        let pending:Option<(String,String,i64)>=tx.query_row("SELECT data,state,attempts FROM mail_actions WHERE message_id=?1 AND state<>'done' AND CASE WHEN json_extract(data,'$.action.kind') IN('read','flag') THEN json_extract(data,'$.action.kind') ELSE 'placement' END=?2 LIMIT 1",params![message.id,action.lane().as_str()],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
        if let Some((data, state, attempts)) = pending {
            if attempts > 0 || state == MailWorkState::Sending.as_str() {
                return Err(
                    "This kind of change is syncing. Wait or resolve it in Drafts / outbox.".into(),
                );
            }
            let mut work: QueuedMail = serde_json::from_str(&data)?;
            let mut action = action;
            if let (MailAction::Move { source: old, .. }, MailAction::Move { source, .. }) =
                (&work.action, &mut action)
            {
                *source = old.clone();
            }
            restore_action(&tx, &work)?;
            work.action = action;
            project(&tx, &work)?;
            tx.execute(
                "UPDATE mail_actions SET data=?2,state='pending',due=0,error=NULL WHERE id=?1",
                params![work.operation, serde_json::to_string(&work)?],
            )?;
            self.project_mail(&message.account_id)?;
            tx.commit()?;
            return Ok(());
        }
        let count: i64 = tx.query_row(
            "SELECT COUNT(*) FROM mail_actions WHERE state<>'done'",
            [],
            |r| r.get(0),
        )?;
        if count >= ACTION_LIMIT {
            return Err("Mail actions are full. Resolve older changes first.".into());
        }
        let before = snapshot(&tx, &message)?;
        let work = QueuedMail {
            operation: operation.into(),
            message,
            action,
            before,
        };
        project(&tx, &work)?;
        tx.execute("INSERT INTO mail_actions(id,account,message_id,data,state,created) VALUES(?1,?2,?3,?4,?5,unixepoch())",params![operation,work.message.account_id,work.message.id,serde_json::to_string(&work)?,MailWorkState::Pending.as_str()])?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn keep_mail(&self, account: &str, remote: &str) -> Result<bool> {
        Ok(self.connection.query_row("SELECT EXISTS(SELECT 1 FROM mail_actions a JOIN messages m ON m.id=a.message_id WHERE m.account_id=?1 AND m.remote_id=?2 AND a.state<>'done')",params![account,remote],|r|r.get(0))?)
    }
    pub(crate) fn project_mail(&self, account: &str) -> Result<()> {
        let mut q=self.connection.prepare("SELECT data FROM mail_actions WHERE account=?1 AND state<>'done' ORDER BY created,id LIMIT ?2")?;
        let data = q
            .query_map(params![account, ACTION_LIMIT], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        for data in data {
            project(&self.connection, &serde_json::from_str(&data)?)?;
        }
        Ok(())
    }
    pub(crate) fn save_mail_draft(&self, draft: &MailDraft) -> Result<i64> {
        let data = serde_json::to_string(draft)?;
        if data.len() > 2 * 1024 * 1024 {
            return Err("Draft exceeds its 2 MiB storage limit".into());
        }
        let tx = self.write_tx()?;
        let sending: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM mail_outbox WHERE id=?1 AND state<>'done')",
            [&draft.id],
            |r| r.get(0),
        )?;
        if sending {
            return Err(
                "This draft is in the outbox. Cancel its queued send before editing.".into(),
            );
        }
        let revision: Option<i64> = tx
            .query_row(
                "SELECT revision FROM mail_drafts WHERE id=?1",
                [&draft.id],
                |r| r.get(0),
            )
            .optional()?;
        if revision.unwrap_or(0) != draft.revision {
            return Err("Draft changed in another window. Reopen the saved draft.".into());
        }
        let count: i64 = tx.query_row(
            "SELECT COUNT(*) FROM mail_drafts WHERE id<>?1",
            [&draft.id],
            |r| r.get(0),
        )?;
        if count >= DRAFT_LIMIT {
            return Err("Local drafts are full. Remove an older draft.".into());
        }
        let next = draft.revision + 1;
        tx.execute("INSERT INTO mail_drafts VALUES(?1,?2,?3,?4,unixepoch()) ON CONFLICT(id) DO UPDATE SET account=excluded.account,data=excluded.data,revision=excluded.revision,updated=excluded.updated",params![draft.id,draft.account,data,next])?;
        tx.commit()?;
        Ok(next)
    }
    pub(crate) fn mail_draft(&self, id: &str) -> Result<MailDraft> {
        let (data, revision): (String, i64) = self.connection.query_row(
            "SELECT data,revision FROM mail_drafts WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let mut draft: MailDraft = serde_json::from_str(&data)?;
        draft.revision = revision;
        Ok(draft)
    }
    pub(crate) fn delete_mail_draft(&self, id: &str, revision: i64) -> Result<()> {
        let changed = self.connection.execute(
            "DELETE FROM mail_drafts WHERE id=?1 AND revision=?2",
            params![id, revision],
        )?;
        if changed == 0 {
            return Err("Draft changed. Refresh before deleting.".into());
        }
        Ok(())
    }
    pub(crate) fn queue_send(&self, draft: &MailDraft) -> Result<()> {
        let tx = self.write_tx()?;
        let count: i64 = tx.query_row(
            "SELECT COUNT(*) FROM mail_outbox WHERE state<>'done'",
            [],
            |r| r.get(0),
        )?;
        if count >= OUTBOX_LIMIT {
            return Err("Outbox is full. Resolve older messages first.".into());
        }
        tx.execute("INSERT INTO mail_outbox(id,account,data,state,created) VALUES(?1,?2,?3,?4,unixepoch())",params![draft.id,draft.account,serde_json::to_string(draft)?,MailWorkState::Pending.as_str()])?;
        self.delete_mail_draft(&draft.id, draft.revision)?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn mail_workspace(&self) -> Result<Value> {
        let mut drafts=self.connection.prepare("SELECT id,account,json_extract(data,'$.subject'),updated,revision FROM mail_drafts ORDER BY updated DESC LIMIT ?1")?;
        let values=drafts.query_map([DRAFT_LIMIT],|r|Ok(json!({"id":r.get::<_,String>(0)?,"account":r.get::<_,String>(1)?,"subject":r.get::<_,String>(2)?,"updated":r.get::<_,i64>(3)?,"revision":r.get::<_,i64>(4)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let mut items = Vec::new();
        for kind in [MailWorkKind::Action, MailWorkKind::Outbox] {
            let sql = format!(
                "SELECT id,account,state,error,attempts,remote,CASE WHEN ?1='mail_actions' THEN json_extract(data,'$.message.subject') ELSE json_extract(data,'$.subject') END FROM {} WHERE state<>'done' ORDER BY created LIMIT ?2",
                kind.table()
            );
            let mut stmt = self.connection.prepare(&sql)?;
            let rows=stmt.query_map(params![kind.table(),ACTION_LIMIT],|r|Ok(json!({"id":r.get::<_,String>(0)?,"account":r.get::<_,String>(1)?,"state":r.get::<_,String>(2)?,"error":r.get::<_,Option<String>>(3)?,"attempts":r.get::<_,i64>(4)?,"remote":r.get::<_,Option<String>>(5)?,"subject":r.get::<_,String>(6)?,"kind":kind})))?.collect::<rusqlite::Result<Vec<_>>>()?;
            items.extend(rows);
        }
        Ok(json!({"drafts":values,"work":items}))
    }
    pub(crate) fn next_mail_work(&self, kind: MailWorkKind) -> Result<Option<MailWork>> {
        // A send interrupted at any stage is never replayed automatically.
        if matches!(kind, MailWorkKind::Outbox) {
            self.connection.execute("UPDATE mail_outbox SET state='uncertain',error='Interrupted send. Check Sent and provider Drafts before trying again.' WHERE state='sending' AND due<unixepoch()",[])?;
        }
        let sql = format!(
            "SELECT id,account,data,attempts,remote FROM {} WHERE (state IN('pending','retry') OR (state='sending' AND due<unixepoch())) AND due<=unixepoch() AND NOT EXISTS(SELECT 1 FROM account_paused WHERE account_id=account) ORDER BY created,id LIMIT 1",
            kind.table()
        );
        Ok(self
            .connection
            .query_row(&sql, [], |r| {
                Ok(MailWork {
                    id: r.get(0)?,
                    account: r.get(1)?,
                    data: r.get(2)?,
                    attempts: r.get(3)?,
                    remote: r.get(4)?,
                })
            })
            .optional()?)
    }
    pub(crate) fn mark_mail_work(
        &self,
        kind: MailWorkKind,
        id: &str,
        state: MailWorkState,
        error: Option<&str>,
        delay: i64,
    ) -> Result<()> {
        let sql = format!(
            "UPDATE {} SET state=?2,error=?3,due=unixepoch()+?4,attempts=attempts+CASE WHEN ?2='sending' THEN 1 ELSE 0 END WHERE id=?1",
            kind.table()
        );
        self.connection
            .execute(&sql, params![id, state.as_str(), error, delay])?;
        if state == MailWorkState::Done {
            self.clear_missing()?;
            self.connection.execute(&format!("DELETE FROM {0} WHERE state='done' AND rowid NOT IN(SELECT rowid FROM {0} WHERE state='done' ORDER BY created DESC,rowid DESC LIMIT ?1)",kind.table()),[RECEIPT_LIMIT])?;
        }
        Ok(())
    }
    pub(crate) fn mail_work_remote(&self, id: &str, remote: &str) -> Result<()> {
        self.connection.execute(
            "UPDATE mail_outbox SET remote=?2 WHERE id=?1",
            params![id, remote],
        )?;
        Ok(())
    }
    pub(crate) fn mail_work_choice(
        &self,
        id: &str,
        kind: MailWorkKind,
        choice: MailWorkChoice,
    ) -> Result<()> {
        let tx = self.write_tx()?;
        let (state, attempts, data, remote, due): (String, i64, String, Option<String>, i64) = tx
            .query_row(
            &format!(
                "SELECT state,attempts,data,remote,due FROM {} WHERE id=?1",
                kind.table()
            ),
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )?;
        if state == MailWorkState::Sending.as_str() || state == MailWorkState::Done.as_str() {
            return Err("This operation is in flight. Wait for its result.".into());
        }
        match choice {
            MailWorkChoice::Retry => {
                if state == MailWorkState::Retry.as_str() && due > chrono::Utc::now().timestamp() {
                    return Err(
                        "The retry delay has not elapsed. Provider backoff is preserved.".into(),
                    );
                }
                if state != MailWorkState::Retry.as_str()
                    && state != MailWorkState::Blocked.as_str()
                {
                    return Err("Check Sent/provider Drafts first. Uncertain sends cannot be retried automatically.".into());
                }
                tx.execute(
                    &format!(
                        "UPDATE {} SET state='pending',due=0,error=NULL,attempts=0 WHERE id=?1",
                        kind.table()
                    ),
                    [id],
                )?;
            }
            MailWorkChoice::Cancel => {
                if attempts > 0
                    && (matches!(kind, MailWorkKind::Action)
                        || remote.is_some()
                        || state == MailWorkState::Uncertain.as_str())
                {
                    return Err("This operation may have reached the provider. Resolve its result before removing it.".into());
                }
                if matches!(kind, MailWorkKind::Action) {
                    let work: QueuedMail = serde_json::from_str(&data)?;
                    restore_action(&tx, &work)?;
                } else {
                    let count: i64 =
                        tx.query_row("SELECT COUNT(*) FROM mail_drafts", [], |r| r.get(0))?;
                    if count >= DRAFT_LIMIT {
                        return Err(
                            "Local drafts are full. Remove one before returning this send.".into(),
                        );
                    }
                    let draft: MailDraft = serde_json::from_str(&data)?;
                    tx.execute(
                        "INSERT INTO mail_drafts VALUES(?1,?2,?3,?4,unixepoch())",
                        params![draft.id, draft.account, data, draft.revision],
                    )?;
                }
                tx.execute(&format!("DELETE FROM {} WHERE id=?1", kind.table()), [id])?;
                if matches!(kind, MailWorkKind::Action) {
                    let work: QueuedMail = serde_json::from_str(&data)?;
                    self.project_mail(&work.message.account_id)?;
                }
            }
            MailWorkChoice::Forget => {
                if state != MailWorkState::Uncertain.as_str()
                    && state != MailWorkState::Blocked.as_str()
                {
                    return Err("Only stopped work can be acknowledged.".into());
                }
                if matches!(kind, MailWorkKind::Outbox) {
                    let count: i64 =
                        tx.query_row("SELECT COUNT(*) FROM mail_drafts", [], |r| r.get(0))?;
                    if count >= DRAFT_LIMIT {
                        return Err(
                            "Local drafts are full. Remove one before recovering this send.".into(),
                        );
                    }
                    let draft: MailDraft = serde_json::from_str(&data)?;
                    tx.execute(
                        "INSERT INTO mail_drafts VALUES(?1,?2,?3,?4,unixepoch())",
                        params![draft.id, draft.account, data, draft.revision],
                    )?;
                }
                tx.execute(&format!("DELETE FROM {} WHERE id=?1", kind.table()), [id])?;
            }
        }
        self.clear_missing()?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn resume_mail_work(&self, account: &str) -> Result<()> {
        for kind in [MailWorkKind::Action, MailWorkKind::Outbox] {
            self.connection.execute(&format!("UPDATE {} SET state='pending',due=0,attempts=0,error=NULL WHERE account=?1 AND state='blocked'",kind.table()),[account])?;
        }
        Ok(())
    }
}
fn snapshot(db: &Connection, message: &Message) -> Result<MailSnapshot> {
    let mut folders = db.prepare("SELECT folder FROM folders WHERE message_id=?1 LIMIT 2000")?;
    let mut memberships = db.prepare(
        "SELECT folder_id FROM mail_membership WHERE account_id=?1 AND remote_id=?2 LIMIT 2000",
    )?;
    Ok(MailSnapshot {
        unread: message.unread,
        flagged: message.starred,
        folders: folders
            .query_map([&message.id], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?,
        memberships: memberships
            .query_map(params![message.account_id, message.remote_id], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?,
    })
}
fn restore_action(db: &Connection, work: &QueuedMail) -> Result<()> {
    let m = &work.message;
    let before = &work.before;
    match work.action {
        MailAction::Read { .. } => {
            db.execute(
                "UPDATE messages SET unread=?2 WHERE id=?1",
                params![m.id, before.unread],
            )?;
            flag_membership(db, m, "label:UNREAD", (before.unread).into())?;
        }
        MailAction::Flag { .. } => {
            db.execute(
                "UPDATE messages SET starred=?2 WHERE id=?1",
                params![m.id, before.flagged],
            )?;
            flag_membership(db, m, "label:STARRED", (before.flagged).into())?;
        }
        _ => {
            db.execute("DELETE FROM folders WHERE message_id=?1", [&m.id])?;
            db.execute(
                "DELETE FROM mail_membership WHERE account_id=?1 AND remote_id=?2",
                params![m.account_id, m.remote_id],
            )?;
            for folder in &before.folders {
                db.execute(
                    "INSERT OR IGNORE INTO folders VALUES(?1,?2)",
                    params![m.id, folder],
                )?;
            }
            for folder in &before.memberships {
                db.execute(
                    "INSERT OR IGNORE INTO mail_membership VALUES(?1,?2,?3)",
                    params![m.account_id, m.remote_id, folder],
                )?;
            }
            let (unread, flagged): (bool, bool) = db.query_row(
                "SELECT unread,starred FROM messages WHERE id=?1",
                [&m.id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            flag_membership(db, m, "label:UNREAD", (unread).into())?;
            flag_membership(db, m, "label:STARRED", (flagged).into())?;
        }
    }
    Ok(())
}
fn flag_membership(db: &Connection, m: &Message, label: &str, enabled: MailToggle) -> Result<()> {
    let gmail: bool = db.query_row(
        "SELECT provider='gmail' FROM accounts WHERE id=?1",
        [&m.account_id],
        |r| r.get(0),
    )?;
    if !gmail {
        return Ok(());
    }
    if enabled.enabled() {
        db.execute(
            "INSERT OR IGNORE INTO mail_membership VALUES(?1,?2,?3)",
            params![m.account_id, m.remote_id, label],
        )?;
    } else {
        db.execute(
            "DELETE FROM mail_membership WHERE account_id=?1 AND remote_id=?2 AND folder_id=?3",
            params![m.account_id, m.remote_id, label],
        )?;
    }
    Ok(())
}
fn project(db: &Connection, work: &QueuedMail) -> Result<()> {
    let m = &work.message;
    let action = &work.action;
    match action {
        MailAction::Read { unread } => {
            db.execute(
                "UPDATE messages SET unread=?2 WHERE id=?1",
                params![m.id, unread],
            )?;
            flag_membership(db, m, "label:UNREAD", (*unread).into())?;
            return Ok(());
        }
        MailAction::Flag { flagged } => {
            db.execute(
                "UPDATE messages SET starred=?2 WHERE id=?1",
                params![m.id, flagged],
            )?;
            flag_membership(db, m, "label:STARRED", (*flagged).into())?;
            return Ok(());
        }
        _ => {}
    }
    let provider: String = db.query_row(
        "SELECT provider FROM accounts WHERE id=?1",
        [&m.account_id],
        |r| r.get(0),
    )?;
    let gmail = provider == Provider::Gmail.as_str();
    let (destination, system) = match action {
        MailAction::Trash => (
            if gmail {
                "label:TRASH".into()
            } else {
                system_folder(db, &m.account_id, Folder::Trash)?
            },
            Some(Folder::Trash.as_str().to_string()),
        ),
        MailAction::Archive => (
            if gmail {
                String::new()
            } else {
                system_folder(db, &m.account_id, Folder::Archive)?
            },
            Some(Folder::Archive.as_str().to_string()),
        ),
        MailAction::Move { destination, .. } => (
            destination.clone(),
            db.query_row(
                "SELECT system FROM mail_folders WHERE account_id=?1 AND id=?2",
                params![m.account_id, destination],
                |r| r.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten(),
        ),
        _ => unreachable!(),
    };
    if !gmail {
        db.execute(
            "DELETE FROM mail_membership WHERE account_id=?1 AND remote_id=?2",
            params![m.account_id, m.remote_id],
        )?;
        db.execute("DELETE FROM folders WHERE message_id=?1", [&m.id])?;
    } else {
        let mut remove = vec!["label:INBOX".to_string()];
        if let MailAction::Move {
            source: Some(source),
            ..
        } = action
        {
            remove.push(source.clone());
        }
        if matches!(action, MailAction::Move { .. }) {
            remove.push("label:TRASH".into());
        }
        for folder in remove {
            db.execute(
                "DELETE FROM mail_membership WHERE account_id=?1 AND remote_id=?2 AND folder_id=?3",
                params![m.account_id, m.remote_id, folder],
            )?;
        }
        db.execute(
            "DELETE FROM folders WHERE message_id=?1 AND folder IN('inbox','archive','trash')",
            [&m.id],
        )?;
    }
    if !destination.is_empty() {
        db.execute(
            "INSERT OR IGNORE INTO mail_membership VALUES(?1,?2,?3)",
            params![m.account_id, m.remote_id, destination],
        )?;
    }
    if let Some(system) = system {
        db.execute(
            "INSERT OR IGNORE INTO folders VALUES(?1,?2)",
            params![m.id, system],
        )?;
    }
    Ok(())
}
fn system_folder(db: &Connection, account: &str, folder: Folder) -> Result<String> {
    if let Some(id) = db
        .query_row(
            "SELECT id FROM mail_folders WHERE account_id=?1 AND system=?2 LIMIT 1",
            params![account, folder.as_str()],
            |r| r.get(0),
        )
        .optional()?
    {
        return Ok(id);
    }
    // Graph accepts these aliases before the catalog has resolved physical IDs.
    match folder {
        Folder::Trash => Ok("deleteditems".into()),
        Folder::Archive => Ok("archive".into()),
        _ => Err("This account's destination folder is not cached. Refresh folders first.".into()),
    }
}

impl Store {
    pub(crate) fn claim_mail_work(&self, kind: MailWorkKind, id: &str) -> Result<bool> {
        Ok(self.connection.execute(&format!("UPDATE {} SET state='sending',attempts=attempts+1,due=unixepoch()+60 WHERE id=?1 AND (state IN('pending','retry') OR (state='sending' AND due<unixepoch())) AND due<=unixepoch()",kind.table()),[id])?==1)
    }
    pub(crate) fn send_phase(&self, id: &str, phase: MailSendPhase) -> Result<()> {
        self.connection.execute(
            "UPDATE mail_outbox SET phase=?2 WHERE id=?1",
            params![id, serde_json::to_value(phase)?.as_str()],
        )?;
        Ok(())
    }
    pub(crate) fn mail_phase(&self, id: &str) -> Result<MailSendPhase> {
        let phase: String =
            self.connection
                .query_row("SELECT phase FROM mail_outbox WHERE id=?1", [id], |r| {
                    r.get(0)
                })?;
        Ok(serde_json::from_value(json!(phase))?)
    }
    pub(crate) fn mail_remote(&self, id: &str) -> Result<Option<String>> {
        Ok(self
            .connection
            .query_row("SELECT remote FROM mail_outbox WHERE id=?1", [id], |r| {
                r.get(0)
            })?)
    }
}

impl Store {
    pub(crate) fn rebase_mail(&self, id: &str) -> Result<()> {
        self.connection
            .execute("DELETE FROM mail_tombstones WHERE message_id=?1", [id])?;
        let mut stmt = self.connection.prepare(
            "SELECT data FROM mail_actions WHERE message_id=?1 AND state<>'done' AND attempts=0",
        )?;
        let rows = stmt
            .query_map([id], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        if rows.is_empty() {
            return Ok(());
        }
        let message = self.action_message(id)?;
        let before = snapshot(&self.connection, &message)?;
        for data in rows {
            let mut work: QueuedMail = serde_json::from_str(&data)?;
            work.message = message.clone();
            work.before = before.clone();
            self.connection.execute(
                "UPDATE mail_actions SET data=?2 WHERE id=?1",
                params![work.operation, serde_json::to_string(&work)?],
            )?;
        }
        Ok(())
    }
    pub(crate) fn missing_mail(&self, account: &str, remote: &str) -> Result<()> {
        self.connection.execute("INSERT OR IGNORE INTO mail_tombstones SELECT id FROM messages WHERE account_id=?1 AND remote_id=?2",params![account,remote])?;
        Ok(())
    }
    fn clear_missing(&self) -> Result<()> {
        self.connection.execute("DELETE FROM messages WHERE id IN(SELECT message_id FROM mail_tombstones) AND NOT EXISTS(SELECT 1 FROM mail_actions WHERE message_id=messages.id AND state<>'done')",[])?;
        Ok(())
    }
}
