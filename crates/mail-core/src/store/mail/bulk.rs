use super::*;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const UNDO_LIMIT: i64 = 20;
const UNDO_BYTES: usize = 1024 * 1024;

struct Pending {
    id: String,
    data: String,
    state: String,
    attempts: i64,
}
#[derive(Serialize, Deserialize)]
struct UndoEntry {
    message: String,
    account: String,
    before: MailSnapshot,
    after: MailSnapshot,
    hold: bool,
    pin: bool,
    edit: MailEdit,
    applied: Option<String>,
}
// Every local projection and its undo record commit together, across accounts.
impl Store {
    pub(crate) fn batch_mail(
        &self,
        operation: &str,
        ids: &[String],
        edit: MailEdit,
        validate: impl Fn(&str, MailAction) -> Result<(Message, MailAction)>,
    ) -> Result<Value> {
        if ids.is_empty()
            || ids.len() > ACTION_LIMIT as usize
            || ids.iter().collect::<HashSet<_>>().len() != ids.len()
        {
            return Err("Select between 1 and 100 different messages per action".into());
        }
        let tx = self.write_tx()?;
        if tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM mail_undo WHERE id=?1)",
            [operation],
            |r| r.get::<_, bool>(0),
        )? {
            return Err("This batch was already recorded. Refresh before trying again.".into());
        }
        let mut entries = Vec::new();
        for (index, id) in ids.iter().enumerate() {
            let message = self.action_message(id)?;
            let before = snapshot(&tx, &message)?;
            let (hold, pin) = flags(&tx, id)?;
            match &edit {
                MailEdit::Action { action } => {
                    let (message, action) = validate(id, action.clone())?;
                    self.queue_mail_in(
                        &tx,
                        &format!("{operation}-{index}"),
                        message,
                        action,
                        ReadWrite::Manual,
                    )?;
                }
                MailEdit::Pin { pinned } => {
                    self.pin_mail(id, (*pinned).into())?;
                }
            }
            let after = snapshot(&tx, &self.action_message(id)?)?;
            let applied = pending(&tx, id, &edit)?.map(|p| p.id);
            entries.push(UndoEntry {
                message: id.clone(),
                account: message.account_id.clone(),
                before,
                after,
                hold,
                pin,
                edit: edit.clone(),
                applied,
            });
        }
        let data = serde_json::to_string(&entries)?;
        if data.len() > UNDO_BYTES {
            return Err("This batch exceeds the undo storage limit. Select fewer messages.".into());
        }
        tx.execute(
            "INSERT INTO mail_undo VALUES(?1,?2,unixepoch())",
            params![operation, data],
        )?;
        tx.execute("DELETE FROM mail_undo WHERE id NOT IN(SELECT id FROM mail_undo ORDER BY created DESC,rowid DESC LIMIT ?1)",[UNDO_LIMIT])?;
        tx.commit()?;
        Ok(json!({"operation":operation,"count":ids.len()}))
    }
    pub(crate) fn undo_mail(&self, operation: &str) -> Result<Value> {
        let tx = self.write_tx()?;
        let data: String = tx
            .query_row("SELECT data FROM mail_undo WHERE id=?1", [operation], |r| {
                r.get(0)
            })
            .optional()?
            .ok_or("This undo has expired. Mail data was not changed.")?;
        let entries: Vec<UndoEntry> = serde_json::from_str(&data)?;
        for (index, entry) in entries.iter().enumerate() {
            let message = self.action_message(&entry.message)?;
            let current = snapshot(&tx, &message)?;
            let (hold, pin) = flags(&tx, &entry.message)?;
            let matches = match &entry.edit {
                MailEdit::Pin { pinned } => pin == *pinned,
                MailEdit::Action {
                    action: MailAction::Read { .. },
                } => current.unread == entry.after.unread && hold == entry.after.unread,
                MailEdit::Action {
                    action: MailAction::Flag { .. },
                } => current.flagged == entry.after.flagged,
                _ => {
                    current.folders == entry.after.folders
                        && current.memberships.iter().filter(|s| !is_flag(s)).eq(entry
                            .after
                            .memberships
                            .iter()
                            .filter(|s| !is_flag(s)))
                }
            };
            if !matches {
                return Err("A selected message changed since this action. Undo stopped without changing the batch.".into());
            }
            let active = pending(&tx, &entry.message, &entry.edit)?;
            let completed = if let Some(active) = &active {
                if active.attempts > 0 || active.state == MailWorkState::Sending.as_str() {
                    return Err(
                        "This action is syncing. Wait for its result, then Undo again.".into(),
                    );
                }
                false
            } else if let Some(applied) = &entry.applied {
                let state: Option<String> = tx
                    .query_row(
                        "SELECT state FROM mail_actions WHERE id=?1",
                        [applied],
                        |r| r.get(0),
                    )
                    .optional()?;
                match state.as_deref() {
                    Some(value) if value == MailWorkState::Done.as_str() => true,
                    Some(_) => {
                        return Err(
                            "This action is syncing. Wait for its result, then Undo again.".into(),
                        );
                    }
                    None => return Err("The action receipt expired. Undo is unavailable.".into()),
                }
            } else {
                false
            };
            if let MailEdit::Pin { .. } = entry.edit {
                self.pin_mail(&entry.message, entry.pin.into())?;
                continue;
            }
            let action = match entry.edit {
                MailEdit::Action {
                    action: MailAction::Read { .. },
                } => MailAction::Read {
                    unread: entry.before.unread,
                },
                MailEdit::Action {
                    action: MailAction::Flag { .. },
                } => MailAction::Flag {
                    flagged: entry.before.flagged,
                },
                _ => MailAction::Restore {
                    snapshot: entry.before.clone(),
                },
            };
            if completed && matches!(action, MailAction::Restore { .. }) {
                let outlook: bool = tx.query_row(
                    "SELECT provider='outlook' FROM accounts WHERE id=?1",
                    [&message.account_id],
                    |r| r.get(0),
                )?;
                if outlook && entry.before.memberships.len() != 1 {
                    return Err(
                        "The original folder is unavailable. Sync folders before trying Undo."
                            .into(),
                    );
                }
            }
            let baseline = active
                .as_ref()
                .map(|pending| serde_json::from_str::<QueuedMail>(&pending.data))
                .transpose()?;
            if let Some(baseline) = baseline
                .as_ref()
                .filter(|work| same_lane(&entry.edit, &entry.before, &work.before))
            {
                // Returning to the unsent baseline removes work, including a prior inverse.
                restore_action(&tx, baseline)?;
                tx.execute(
                    "DELETE FROM mail_actions WHERE id=?1",
                    [&baseline.operation],
                )?;
            } else if active.is_some() || completed {
                // Coalescing retains the actual remote baseline across several Undo steps.
                self.queue_mail_in(
                    &tx,
                    &format!("undo-{operation}-{index}"),
                    message.clone(),
                    action,
                    ReadWrite::Manual,
                )?;
            } else {
                let work = QueuedMail {
                    operation: String::new(),
                    message: message.clone(),
                    action,
                    before: entry.before.clone(),
                };
                restore_action(&tx, &work)?;
            }
            if matches!(
                entry.edit,
                MailEdit::Action {
                    action: MailAction::Read { .. }
                }
            ) {
                tx.execute(
                    "UPDATE messages SET keep_unread=?2,unread=?3 WHERE id=?1",
                    params![message.id, entry.hold, entry.before.unread],
                )?;
                read_membership(&tx, &message)?;
            }
            self.project_mail(&message.account_id)?;
        }
        tx.execute("DELETE FROM mail_undo WHERE id=?1", [operation])?;
        tx.commit()?;
        Ok(json!({}))
    }
}
fn is_flag(id: &str) -> bool {
    ["label:UNREAD", "label:STARRED"].contains(&id)
}
fn flags(db: &Connection, id: &str) -> Result<(bool, bool)> {
    Ok(db.query_row(
        "SELECT keep_unread,pinned FROM messages WHERE id=?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?)
}
fn pending(db: &Connection, id: &str, edit: &MailEdit) -> Result<Option<Pending>> {
    let MailEdit::Action { action } = edit else {
        return Ok(None);
    };
    Ok(db.query_row("SELECT id,data,state,attempts FROM mail_actions WHERE message_id=?1 AND state<>'done' AND CASE WHEN json_extract(data,'$.action.kind') IN('read','flag') THEN json_extract(data,'$.action.kind') ELSE 'placement' END=?2",params![id,action.lane().as_str()],|r|Ok(Pending { id:r.get(0)?,data:r.get(1)?,state:r.get(2)?,attempts:r.get(3)? })).optional()?)
}

fn same_lane(edit: &MailEdit, left: &MailSnapshot, right: &MailSnapshot) -> bool {
    match edit {
        MailEdit::Action {
            action: MailAction::Read { .. },
        } => left.unread == right.unread,
        MailEdit::Action {
            action: MailAction::Flag { .. },
        } => left.flagged == right.flagged,
        _ => {
            left.folders == right.folders
                && left
                    .memberships
                    .iter()
                    .filter(|s| !is_flag(s))
                    .eq(right.memberships.iter().filter(|s| !is_flag(s)))
        }
    }
}
