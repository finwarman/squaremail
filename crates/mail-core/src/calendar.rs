use crate::{Result, model::*, network::Context, oauth, providers, store::Store};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

mod draft;
mod remote;
#[cfg(test)]
mod tests;

pub(crate) const DETAIL_LIMIT: usize = 256 * 1024;
pub(crate) const QUEUE_LIMIT: usize = 50;
const GOOGLE_ROOT: &str = "https://www.googleapis.com/calendar/v3";
const GRAPH_ROOT: &str = "https://graph.microsoft.com/v1.0/me";

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct EventKey {
    pub(crate) account: String,
    pub(crate) calendar: String,
    pub(crate) id: Option<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum EventTime {
    Timed {
        start: i64,
        end: i64,
        zone: String,
    },
    AllDay {
        start: String,
        end: String,
        zone: String,
    },
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum Reminder {
    Preserve,
    Off,
    Minutes { minutes: i64 },
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct EventDraft {
    pub(crate) title: String,
    pub(crate) location: String,
    pub(crate) time: EventTime,
    pub(crate) reminder: Reminder,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum GuestUpdates {
    Personal,
    Notify,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct EventChange {
    pub(crate) operation: String,
    pub(crate) key: EventKey,
    pub(crate) revision: Option<String>,
    pub(crate) draft: EventDraft,
    pub(crate) updates: GuestUpdates,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct EventDetail {
    pub(crate) key: EventKey,
    pub(crate) revision: String,
    pub(crate) draft: EventDraft,
    pub(crate) organizer: String,
    pub(crate) participants: Vec<String>,
    pub(crate) participant_count: usize,
    pub(crate) conference: String,
    pub(crate) notes: String,
    pub(crate) recurring: bool,
    pub(crate) writable: bool,
    pub(crate) raw: Value,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum WriteState {
    Pending,
    Sending,
    Retry,
    Conflict,
    Failed,
    Done,
    Uncertain,
}
impl WriteState {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Sending => "sending",
            Self::Retry => "retry",
            Self::Conflict => "conflict",
            Self::Failed => "failed",
            Self::Done => "done",
            Self::Uncertain => "uncertain",
        }
    }
}
#[derive(Debug, Deserialize, Serialize)]
pub(crate) struct PendingWrite {
    pub(crate) change: EventChange,
    pub(crate) base: Option<EventDetail>,
    pub(crate) attempts: i64,
}

fn account(store: &Store, key: &EventKey) -> Result<Account> {
    let account = store
        .accounts()?
        .into_iter()
        .find(|a| a.id == key.account)
        .ok_or("Account not found")?;
    if account.provider == Provider::Local {
        return Err("Connect a provider calendar first".into());
    }
    Ok(account)
}
pub(crate) fn detail(
    store: &Store,
    key: &EventKey,
    mode: BodyMode,
    context: &Context<'_>,
) -> Result<Value> {
    if matches!(mode, BodyMode::Cached) {
        return Ok(json!({"detail":store.event_detail(key)?.map(compact)}));
    }
    let account = account(store, key)?;
    if !store.connected(&account.id)? {
        return Err(
            "Account is disconnected. Previously opened event details remain available offline."
                .into(),
        );
    }
    let token = oauth::access_token(&account, context)?;
    let remote = remote::Remote::new(&account, &token, context);
    let value = remote.detail(key)?;
    context.check()?;
    store.save_event_detail(&value)?;
    Ok(json!({"detail":compact(value)}))
}
fn compact(mut detail: EventDetail) -> EventDetail {
    detail.raw = Value::Null;
    detail
}

pub(crate) fn queue(store: &Store, change: EventChange) -> Result<Value> {
    draft::validate(&change.draft)?;
    if change.operation.len() < 16
        || change.operation.len() > 80
        || !change
            .operation
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return Err("Invalid calendar operation ID".into());
    }
    let account = account(store, &change.key)?;
    if !oauth::calendar_writable(&account)? {
        return Err("Enable calendar editing for this account first".into());
    }
    let base = if change.key.id.is_some() {
        let base = store
            .event_detail(&change.key)?
            .ok_or("Open this event online once before editing offline")?;
        if change.revision.as_deref() != Some(&base.revision) {
            return Err("Event changed locally. Reopen it before saving.".into());
        }
        draft::patch(account.provider, &change, &base)?;
        Some(base)
    } else {
        None
    };
    store.queue_event(&PendingWrite {
        change,
        base,
        attempts: 0,
    })?;
    Ok(json!({"queued":true}))
}

pub(crate) fn sync_write(store: &Store, context: &Context<'_>) -> Result<Option<Value>> {
    static WORKER: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let Ok(_guard) = WORKER.try_lock() else {
        return Ok(None);
    };
    let Some(write) = store.next_event_write()? else {
        return Ok(None);
    };
    let account = account(store, &write.change.key)?;
    let operation = &write.change.operation;
    store.mark_event_write(operation, WriteState::Sending, None, 0)?;
    let result = (|| {
        let writable = oauth::calendar_writable(&account).unwrap_or(false);
        if !writable {
            return Err(Box::new(crate::network::HttpError {
                status: 403,
                retry: 0,
            }) as Box<dyn std::error::Error + Send + Sync>);
        }
        let token = oauth::access_token(&account, context)?;
        remote::Remote::new(&account, &token, context).save(&write)
    })();
    match result {
        Ok(detail) => store.finish_event_write(&write, &detail)?,
        Err(error) => {
            let http = error.downcast_ref::<crate::network::HttpError>();
            let state = match http.map(|e| e.status) {
                Some(409 | 412) => WriteState::Conflict,
                Some(400 | 401 | 403 | 404) => WriteState::Failed,
                Some(429) => WriteState::Retry,
                _ if write.attempts >= 2 => WriteState::Uncertain,
                _ => WriteState::Retry,
            };
            let delay = http
                .map(|e| e.retry)
                .unwrap_or(0)
                .max(30 * (1_i64 << write.attempts.min(6)));
            store.mark_event_write(operation, state, Some(&error.to_string()), delay)?;
            if matches!(
                state,
                WriteState::Conflict | WriteState::Failed | WriteState::Uncertain
            ) {
                store.event_write_alert(&write, &error.to_string())?;
            }
        }
    }
    Ok(Some(
        json!({"worked":true,"account_id":account.id,"kind":JobKind::Calendar}),
    ))
}

// Provider parsers stay in the adapter layer; edits publish the same cache representation.
pub(crate) fn parsed_event(
    account: &Account,
    key: &EventKey,
    raw: &Value,
) -> Result<CalendarEvent> {
    providers::edit_summary(account, key, raw)
}
