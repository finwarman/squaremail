mod calendar;
mod demo;
mod header_text;
mod mailops;
mod media;
mod mime;
mod model;
mod network;
mod notes;
mod notices;
mod oauth;
mod providers;
mod store;

use model::*;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::ffi::{CStr, CString, c_char};
use std::io::Read;
use store::{MailScope, Store};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
const MAX_MAIL_BYTES: u64 = 25 * 1024 * 1024;

fn sync_cycle(store: &Store, context: &network::Context<'_>) -> Result<Value> {
    static TURN: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let turn = TURN.fetch_add(1, std::sync::atomic::Ordering::Relaxed) % 3;
    if turn == 0
        && let Some(reply) = mailops::sync_work(store, context)?
    {
        return Ok(reply);
    }
    if turn == 1
        && let Some(reply) = calendar::sync_write(store, context)?
    {
        return Ok(reply);
    }
    let page = providers::sync_next(store, context)?;
    if page["worked"].as_bool() == Some(true) {
        return Ok(page);
    }
    // An idle provider lane must not hide ready mail/calendar writes.
    if turn != 0
        && let Some(reply) = mailops::sync_work(store, context)?
    {
        return Ok(reply);
    }
    if turn != 1
        && let Some(reply) = calendar::sync_write(store, context)?
    {
        return Ok(reply);
    }
    Ok(page)
}

fn dispatch(request: Request, context: &network::Context<'_>) -> Result<Value> {
    match &request.command {
        Command::Notes => return Ok(serde_json::to_value(notes::list(&request.database)?)?),
        Command::OpenNote { id } => {
            return Ok(serde_json::to_value(notes::open(&request.database, id)?)?);
        }
        Command::NewNote { day } => {
            return Ok(serde_json::to_value(notes::new(
                &request.database,
                day.as_deref(),
            )?)?);
        }
        Command::SaveNote { id, text, revision } => {
            return Ok(serde_json::to_value(notes::save(
                &request.database,
                id,
                text,
                revision.as_deref(),
            )?)?);
        }
        _ => {}
    }
    let store = Store::open(&request.database)?;
    match request.command {
        Command::Notes
        | Command::OpenNote { .. }
        | Command::NewNote { .. }
        | Command::SaveNote { .. } => unreachable!("Notes use their file service"),
        Command::Contacts { account, query } => {
            Ok(serde_json::to_value(store.contacts(&account, &query)?)?)
        }
        Command::BodyBackfill { mode } => Ok(json!({"mode":store.backfill_mode(mode)?})),
        Command::MoveFolders { account } => Ok(serde_json::to_value(mailops::move_folders(
            &store, &account,
        )?)?),
        Command::BatchMail {
            operation,
            ids,
            edit,
        } => mailops::batch(&store, &operation, &ids, edit),
        Command::UndoMail { operation } => store.undo_mail(&operation),
        Command::QueueMail {
            operation,
            id,
            action,
        } => mailops::queue(&store, &operation, &id, action),
        Command::PinMail { id, pinned } => {
            store.pin_mail(&id, pinned.into())?;
            Ok(json!({}))
        }
        Command::ReadMail {
            operation,
            id,
            choice,
        } => mailops::read_mail(&store, &operation, &id, choice),
        Command::Compose {
            account,
            original,
            kind,
            mode,
        } => mailops::compose(&store, &account, original.as_deref(), kind, mode, context),
        Command::SaveMailDraft { draft } => mailops::save_draft(&store, &draft),
        Command::MailDraft { id } => Ok(serde_json::to_value(store.mail_draft(&id)?)?),
        Command::MailWorkspace => store.mail_workspace(),
        Command::DeleteMailDraft { id, revision } => {
            store.delete_mail_draft(&id, revision)?;
            Ok(json!({}))
        }
        Command::SendMail { id, revision } => mailops::queue_send(&store, &id, revision),
        Command::MailWork { id, kind, choice } => {
            store.mail_work_choice(&id, kind, choice)?;
            Ok(json!({}))
        }
        Command::MailConsent { account, access } => {
            let account = store
                .accounts()?
                .into_iter()
                .find(|a| a.id == account)
                .ok_or("Account not found")?;
            oauth::mail_consent(&account, access, context)?;
            store.resume_mail_work(&account.id)?;
            store.resume_account(&account)?;
            Ok(json!({}))
        }
        Command::ClientConfig { provider } => Ok(oauth::client_config(provider)),
        Command::ExportClients { path } => {
            oauth::export_clients(&path)?;
            Ok(json!({}))
        }
        Command::Configure {
            provider,
            client_id,
            client_secret,
        } => {
            oauth::configure(provider, &client_id, client_secret.as_deref())?;
            Ok(json!({}))
        }
        Command::ImportClient { path } => {
            oauth::import_client(&path)?;
            Ok(json!({}))
        }
        Command::Accounts => {
            for account in store
                .accounts()?
                .iter()
                .filter(|a| a.provider != Provider::Local)
            {
                if store.connected(&account.id)? {
                    store.ensure_job(&account.id, JobKind::Catalog, "", 0)?;
                    store.ensure_job(&account.id, JobKind::RecentMail, "", 0)?;
                    store.ensure_backfill(&account.id)?;
                    if account.provider == Provider::Gmail {
                        store.ensure_job(&account.id, JobKind::Mail, "", 0)?;
                    }
                }
            }
            let values = store
                .accounts()?
                .into_iter()
                .map(|account| -> Result<Value> {
                    let mut value = serde_json::to_value(&account)?;
                    value["connected"] =
                        json!(account.provider != Provider::Local && store.connected(&account.id)?);
                    Ok(value)
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(json!(values))
        }
        Command::Folders { account } => Ok(serde_json::to_value(store.folders(&account)?)?),
        Command::Calendars => Ok(serde_json::to_value(store.calendars()?)?),
        Command::Events {
            start,
            end,
            offset,
            limit,
        } => Ok(serde_json::to_value(
            store.events(start, end, offset, limit)?,
        )?),
        Command::CalendarWindows { months } => {
            store.set_windows(&months)?;
            Ok(json!({}))
        }
        Command::CalendarWindow { month } => {
            store.calendar_window(month)?;
            Ok(json!({}))
        }
        Command::RefreshAccount { account } => {
            let account = store
                .accounts()?
                .into_iter()
                .find(|a| a.id == account)
                .ok_or("Account not found")?;
            if !store.connected(&account.id)? {
                return Err("Account is disconnected".into());
            }
            oauth::verify_refresh(&account, context)?;
            Ok(json!({}))
        }
        Command::SyncNext => {
            let mut reply = sync_cycle(&store, context)?;
            let now = chrono::Utc::now().timestamp();
            reply["more"] = json!(store.sync_ready(now)?);
            reply["wait_ms"] = json!(store.sync_wait(now)?);
            Ok(reply)
        }
        Command::EventDetail { key, mode } => calendar::detail(&store, &key, mode, context),
        Command::QueueEvent { change } => calendar::queue(&store, change),
        Command::SaveEventDraft { change } => calendar::save_draft(&store, change),
        Command::EventWrites => store.event_writes(),
        Command::DiscardEvent { operation } => {
            store.discard_event(&operation)?;
            Ok(json!({}))
        }
        Command::CalendarConsent { account } => {
            let account = store
                .accounts()?
                .into_iter()
                .find(|a| a.id == account)
                .ok_or("Account not found")?;
            oauth::calendar_consent(&account, context)?;
            store.resume_account(&account)?;
            Ok(json!({}))
        }
        Command::Notices { delivery } => notices::poll(&store, delivery),
        Command::NoticeAction { action, id } => {
            store.notice_action(action, id.as_deref())?;
            Ok(json!({}))
        }
        Command::NoticeSetting {
            account,
            channel,
            toggle,
        } => {
            store.notice_setting(account.as_deref(), channel, toggle)?;
            Ok(json!({}))
        }
        Command::SyncNow => {
            store.sync_now()?;
            Ok(json!({}))
        }
        Command::SyncStatus => store.job_status(),
        Command::Disconnect { account, mode } => {
            store.pause_account(&account, mode)?;
            let cache = if matches!(mode, DisconnectMode::RemoveCache) {
                media::remove_cache(&request.database, &account)
            } else {
                Ok(())
            };
            let credentials = oauth::disconnect(&account);
            cache?;
            credentials?;
            Ok(json!({}))
        }
        Command::SeedDemo => {
            demo::seed(&store)?;
            Ok(json!({"seeded": true}))
        }
        Command::SearchMail {
            account,
            folder,
            folder_id,
            query,
            mode,
            offset,
            limit,
        } => Ok(serde_json::to_value(store.search_folder(
            MailScope {
                account: account.as_deref(),
                folder,
                remote: folder_id.as_deref(),
            },
            &query,
            mode,
            offset,
            limit,
        )?)?),
        Command::List {
            account,
            folder,
            folder_id,
            query,
            offset,
            limit,
        } => {
            let rows = if let Some(remote) = folder_id {
                store.list_folder(
                    account.as_deref(),
                    folder,
                    Some(&remote),
                    &query,
                    offset,
                    limit,
                )?
            } else {
                store.list(account.as_deref(), folder, &query, offset, limit)?
            };
            Ok(serde_json::to_value(rows)?)
        }
        Command::Message { id, mode } => {
            let mut message = store.message(&id)?;
            if message.text.is_none() && matches!(mode, BodyMode::Fetch) {
                let account = store
                    .accounts()?
                    .into_iter()
                    .find(|a| a.id == message.account_id)
                    .ok_or("Account not found")?;
                if !store.connected(&account.id)? {
                    return Err("Account is disconnected. Cached messages remain readable.".into());
                }
                let (text, html) = providers::body(&account, &message.remote_id, context)?;
                context.check()?;
                store.save_body(&id, &text, &mime::clean_html(&html))?;
                message = store.message(&id)?;
            }
            Ok(serde_json::to_value(message)?)
        }
        Command::Media { id, mode } => {
            Ok(json!({"manifest":media::manifest(&store,&id,mode,context)?}))
        }
        Command::MediaFile { id, asset, preview } => {
            media::file(&store, &request.database, &id, &asset, preview, context)
        }
        Command::Import { path } => {
            let mut raw = Vec::new();
            std::fs::File::open(path)?
                .take(MAX_MAIL_BYTES + 1)
                .read_to_end(&mut raw)?;
            if raw.len() as u64 > MAX_MAIL_BYTES {
                return Err("Email exceeds the 25 MiB import limit".into());
            }
            let account = Account {
                id: "local".into(),
                email: "Imported mail".into(),
                provider: Provider::Local,
            };
            store.save_account(&account)?;
            let remote = format!("{:x}", Sha256::digest(&raw));
            let message = mime::parse(&raw, &account.id, &remote)?;
            store.save(&message, Folder::Inbox)?;
            media::import_media(&store, &request.database, &message, &raw)?;
            Ok(serde_json::to_value(message)?)
        }
        Command::Connect {
            provider,
            client_id,
            client_secret,
        } => {
            let account = oauth::connect(provider, &client_id, client_secret.as_deref(), context)?;
            store.resume_account(&account)?;
            let mut value = serde_json::to_value(account)?;
            value["connected"] = json!(true);
            Ok(value)
        }
    }
}

/// Accepts a UTF-8 JSON request. Never lets a Rust panic unwind through Swift.
///
/// # Safety
/// `request` must be null or a valid NUL-terminated C string for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn squaremail_call(request: *const c_char) -> *mut c_char {
    unsafe { squaremail_call_cancelable(request, std::ptr::null()) }
}

/// # Safety
/// `request` is a valid C string; `token` is null or remains alive throughout this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn squaremail_call_cancelable(
    request: *const c_char,
    token: *const network::CancelToken,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| -> Result<Value> {
        if request.is_null() {
            return Err("Empty request".into());
        }
        let input = unsafe { CStr::from_ptr(request) }.to_str()?;
        let request: Request = serde_json::from_str(input)?;
        let seconds = if matches!(
            request.command,
            Command::Connect { .. } | Command::CalendarConsent { .. } | Command::MailConsent { .. }
        ) {
            210
        } else {
            25
        };
        let context = network::Context::new(unsafe { token.as_ref() }, seconds);
        context.check()?;
        dispatch(request, &context)
    });
    let response = match result {
        Ok(Ok(data)) => json!({"ok": data}),
        Ok(Err(error)) => json!({"error": error.to_string()}),
        Err(_) => json!({"error": "Mail core failed safely"}),
    };
    CString::new(response.to_string())
        .expect("JSON has no literal NUL")
        .into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn squaremail_token_new() -> *mut network::CancelToken {
    Box::into_raw(Box::default())
}

/// # Safety
/// `token` must be null or a live token returned by `squaremail_token_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn squaremail_token_cancel(token: *const network::CancelToken) {
    if let Some(token) = unsafe { token.as_ref() } {
        token.cancel();
    }
}

/// # Safety
/// The token must no longer be in use and must not already have been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn squaremail_token_free(token: *mut network::CancelToken) {
    if !token.is_null() {
        drop(unsafe { Box::from_raw(token) });
    }
}

/// # Safety
/// `response` must be null or an unreleased pointer returned by `squaremail_call`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn squaremail_free(response: *mut c_char) {
    if !response.is_null() {
        drop(unsafe { CString::from_raw(response) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_rejects_bad_requests() {
        for raw in [
            "{}",
            "not json",
            "{\"database\":\":memory:\",\"command\":\"unknown\"}",
        ] {
            let request = CString::new(raw).unwrap();
            let result = unsafe { squaremail_call(request.as_ptr()) };
            let value: Value =
                serde_json::from_str(unsafe { CStr::from_ptr(result) }.to_str().unwrap()).unwrap();
            assert!(value.get("error").is_some());
            unsafe { squaremail_free(result) };
        }
    }
}
