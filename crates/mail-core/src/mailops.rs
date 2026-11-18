use crate::{
    Result, mime,
    model::*,
    network::{self, Context},
    oauth,
    providers::writes::MailRemote,
    store::Store,
};
use serde_json::{Value, json};

#[cfg(test)]
mod tests;
const BODY_LIMIT: usize = 1024 * 1024;
const QUOTE_LIMIT: usize = 256 * 1024;

fn account(store: &Store, id: &str) -> Result<Account> {
    store
        .accounts()?
        .into_iter()
        .find(|a| a.id == id && a.provider != Provider::Local)
        .ok_or_else(|| "Choose a provider account first".into())
}
const GMAIL_NON_MOVE: &[&str] = &[
    "label:SENT",
    "label:DRAFT",
    "label:UNREAD",
    "label:STARRED",
    "label:IMPORTANT",
    "label:CHAT",
];
pub(crate) fn move_folders(store: &Store, id: &str) -> Result<Vec<MailFolder>> {
    let account = account(store, id)?;
    Ok(store
        .folders(id)?
        .into_iter()
        .filter(|f| {
            ![
                Some(Folder::Sent.as_str()),
                Some(Folder::Drafts.as_str()),
                Some(Folder::Unread.as_str()),
                Some(Folder::Starred.as_str()),
            ]
            .contains(&f.system.as_deref())
                && (account.provider != Provider::Gmail || !GMAIL_NON_MOVE.contains(&f.id.as_str()))
        })
        .collect())
}
pub(crate) fn queue(
    store: &Store,
    operation: &str,
    id: &str,
    mut action: MailAction,
) -> Result<Value> {
    valid_id(operation)?;
    let message = store.action_message(id)?;
    let account = account(store, &message.account_id)?;
    if let MailAction::Move {
        destination,
        source,
    } = &mut action
    {
        let all = store.folders(&account.id)?;
        if source
            .as_deref()
            .is_some_and(|s| !all.iter().any(|f| f.id == s))
        {
            return Err("Move source must belong to this account".into());
        }
        let folders = move_folders(store, &account.id)?;
        let target = folders
            .iter()
            .find(|f| f.id == *destination)
            .ok_or("Choose a regular folder, Inbox or Trash in this account")?;
        if account.provider == Provider::Gmail && !destination.starts_with("label:") {
            return Err("Invalid Gmail destination".into());
        }
        if account.provider == Provider::Gmail
            && source
                .as_deref()
                .is_some_and(|s| GMAIL_NON_MOVE.contains(&s))
        {
            *source = None;
        }
        if target.system.as_deref() == Some(Folder::Trash.as_str()) || destination == "label:TRASH"
        {
            action = MailAction::Trash;
        }
    }
    store.queue_mail(operation, message, action)?;
    Ok(json!({}))
}
pub(crate) fn compose(
    store: &Store,
    account_id: &str,
    original: Option<&str>,
    kind: ComposeKind,
    mode: BodyMode,
    context: &Context<'_>,
) -> Result<Value> {
    let account = account(store, account_id)?;
    let mut draft = MailDraft {
        id: operation_id(),
        account: account.id.clone(),
        kind,
        original: original.map(String::from),
        to: Vec::new(),
        cc: Vec::new(),
        bcc: Vec::new(),
        subject: String::new(),
        text: String::new(),
        headers: None,
        revision: 0,
    };
    let mut attachment_warning = false;
    let mut needs_headers = false;
    if kind != ComposeKind::New {
        let message = store.message(original.ok_or("Select an original message")?)?;
        if message.account_id != account.id {
            return Err("Reply account must match the original message".into());
        }
        let mut headers = store.reply_headers(&message.id)?;
        if headers.as_ref().is_none_or(|h| {
            h.message_id.is_empty() || (account.provider == Provider::Gmail && h.thread.is_empty())
        }) && matches!(mode, BodyMode::Fetch)
            && store.connected(&account.id)?
        {
            let remote =
                MailRemote::new(&account, oauth::access_token(&account, context)?, context);
            let value = remote.headers(&message)?;
            store.save_headers(&message.id, &value)?;
            headers = Some(value);
        }
        needs_headers = headers.as_ref().is_none_or(|h| {
            h.message_id.is_empty() || (account.provider == Provider::Gmail && h.thread.is_empty())
        });
        if kind != ComposeKind::Forward {
            let from = headers
                .as_ref()
                .filter(|h| !h.reply_to.is_empty())
                .map(|h| h.reply_to.clone())
                .unwrap_or_else(|| vec![message.sender_address.clone()]);
            draft.to = from;
            if kind == ComposeKind::ReplyAll {
                let fallback = ReplyHeaders {
                    to: mime::addresses(&message.recipient),
                    ..Default::default()
                };
                let value = headers.as_ref().unwrap_or(&fallback);
                draft.to.extend(value.to.clone());
                draft.cc = value.cc.clone();
            }
            deduplicate(&mut draft, &account.email);
            draft.subject = if message.subject.to_ascii_lowercase().starts_with("re:") {
                message.subject.clone()
            } else {
                format!("Re: {}", message.subject)
            };
        } else {
            draft.subject = format!("Fwd: {}", message.subject);
            attachment_warning = message.has_attachments;
        }
        let original = message.text.as_deref().ok_or(
            "Open this message online once to cache its body before replying or forwarding",
        )?;
        let clipped: String = original
            .chars()
            .scan(0, |bytes, c| {
                *bytes += c.len_utf8();
                (*bytes <= QUOTE_LIMIT).then_some(c)
            })
            .collect();
        let quote = clipped
            .lines()
            .map(|s| format!("> {s}"))
            .collect::<Vec<_>>()
            .join("\n");
        draft.text = format!(
            "\n\n-------- Original message --------\nFrom: {} <{}>\nTo: {}\nSubject: {}\n\n{}{}",
            message.sender,
            message.sender_address,
            message.recipient,
            message.subject,
            quote,
            if original.len() > QUOTE_LIMIT {
                "\n[Quoted text truncated]"
            } else {
                ""
            }
        );
        draft.headers = headers;
    }
    Ok(
        json!({"draft":draft,"needs_headers":needs_headers,"attachments_omitted":attachment_warning}),
    )
}
fn deduplicate(draft: &mut MailDraft, own: &str) {
    let mut seen = std::collections::HashSet::new();
    seen.insert(own.to_ascii_lowercase());
    for list in [&mut draft.to, &mut draft.cc] {
        list.retain(|a| !a.is_empty() && seen.insert(a.to_ascii_lowercase()));
    }
}
pub(crate) fn save_draft(store: &Store, draft: &MailDraft) -> Result<Value> {
    account(store, &draft.account)?;
    validate_draft(draft)?;
    if let Some(id) = &draft.original
        && let Ok(message) = store.action_message(id)
        && message.account_id != draft.account
    {
        return Err("Draft and original account do not match".into());
    }
    Ok(json!({"revision":store.save_mail_draft(draft)?}))
}
fn validate_draft(draft: &MailDraft) -> Result<()> {
    valid_id(&draft.id)?;
    if draft.text.len() > BODY_LIMIT
        || draft.subject.len() > 2048
        || draft.to.len() + draft.cc.len() + draft.bcc.len() > 100
        || draft
            .to
            .iter()
            .chain(&draft.cc)
            .chain(&draft.bcc)
            .any(|a| a.len() > 320)
    {
        return Err("Draft exceeds the body, header or recipient limit".into());
    }
    Ok(())
}
pub(crate) fn queue_send(store: &Store, id: &str, revision: i64) -> Result<Value> {
    let mut draft = store.mail_draft(id)?;
    if draft.revision != revision {
        return Err("Draft changed. Save and review it before sending".into());
    }
    let account = account(store, &draft.account)?;
    validate_draft(&draft)?;
    for address in draft.to.iter().chain(&draft.cc).chain(&draft.bcc) {
        valid_address(address)?;
    }
    if draft.to.is_empty() && draft.cc.is_empty() && draft.bcc.is_empty() {
        return Err("Add at least one recipient".into());
    }
    if draft.subject.len() > 400 || draft.subject.contains(['\r', '\n', '\0']) {
        return Err("Subject must be a single line, at most 400 UTF-8 bytes".into());
    }
    valid_address(&account.email)?;
    if matches!(draft.kind, ComposeKind::Reply | ComposeKind::ReplyAll) {
        // Thread headers come from our cache, never from editable compose fields.
        let original = draft
            .original
            .as_deref()
            .ok_or("Reply original is missing")?;
        if store.action_message(original).map_err(|_|"Original message is no longer cached. Keep this draft and compose a new message.")?.account_id != account.id {
            return Err("Reply account mismatch".into());
        }
        draft.headers = Some(
            store
                .reply_headers(original)?
                .ok_or("Reply metadata is not cached. Open a fresh reply while online first")?,
        );
        if account.provider == Provider::Gmail
            && draft
                .headers
                .as_ref()
                .is_none_or(|h| h.message_id.is_empty() || h.thread.is_empty())
        {
            return Err(
                "Gmail reply headers are incomplete. Refresh the original metadata first".into(),
            );
        }
    }
    store.queue_send(&draft)?;
    Ok(json!({}))
}
fn valid_id(id: &str) -> Result<()> {
    if !(16..=80).contains(&id.len()) || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return Err("Invalid operation ID".into());
    }
    Ok(())
}
fn valid_address(address: &str) -> Result<()> {
    let parts = address.split('@').collect::<Vec<_>>();
    if parts.len() != 2
        || parts.iter().any(|s| s.is_empty())
        || address.len() > 254
        || !address.is_ascii()
        || address
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || "<>,;:\"\\()".contains(c))
    {
        return Err("Recipients must be plain email addresses, separated by commas".into());
    }
    Ok(())
}
fn operation_id() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 16];
    rand::rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
pub(crate) fn sync_work(store: &Store, context: &Context<'_>) -> Result<Option<Value>> {
    static WORKER: std::sync::Mutex<()> = std::sync::Mutex::new(());
    static TURN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    let Ok(_guard) = WORKER.try_lock() else {
        return Ok(None);
    };
    let outbox = TURN.fetch_xor(true, std::sync::atomic::Ordering::Relaxed);
    let kinds = if outbox {
        [MailWorkKind::Outbox, MailWorkKind::Action]
    } else {
        [MailWorkKind::Action, MailWorkKind::Outbox]
    };
    for kind in kinds {
        let Some(work) = store.next_mail_work(kind)? else {
            continue;
        };
        let account = account(store, &work.account)?;
        let access = if matches!(kind, MailWorkKind::Action) {
            MailAccess::Changes
        } else {
            MailAccess::Send
        };
        match oauth::mail_allowed(&account, access) {
            Ok(true) => {}
            _ => {
                store.mark_mail_work(
                    kind,
                    &work.id,
                    MailWorkState::Blocked,
                    Some("Enable mail changes/sending for this account from Drafts / outbox"),
                    0,
                )?;
                return Ok(Some(
                    json!({"worked":true,"account_id":account.id,"kind":"mail","error":"Additional mail consent is required"}),
                ));
            }
        }
        if !store.claim_mail_work(kind, &work.id)? {
            continue;
        }
        let result = (|| -> Result<()> {
            let token = oauth::access_token(&account, context)?;
            let remote = MailRemote::new(&account, token, context);
            execute_work(store, kind, &work, &account, &remote, context)
        })();
        let error = finish_work(store, kind, &work, result)?;
        return Ok(Some(
            json!({"worked":true,"account_id":account.id,"kind":"mail","error":error}),
        ));
    }
    Ok(None)
}

fn execute_work(
    store: &Store,
    kind: MailWorkKind,
    work: &MailWork,
    account: &Account,
    remote: &MailRemote<'_>,
    context: &Context<'_>,
) -> Result<()> {
    context.check()?;
    if !store.connected(&account.id)? {
        return Err("Account disconnected before the queued operation started".into());
    }
    if matches!(kind, MailWorkKind::Action) {
        let queued: QueuedMail = serde_json::from_str(&work.data)?;
        remote.action(&queued, &store.folders(&account.id)?)?;
    } else {
        let draft: MailDraft = serde_json::from_str(&work.data)?;
        let mut remote_id = work.remote.clone();
        if account.provider == Provider::Outlook {
            if remote_id.is_none() {
                store.send_phase(&work.id, MailSendPhase::Creating)?;
                let original = if matches!(draft.kind, ComposeKind::Reply | ComposeKind::ReplyAll) {
                    draft
                        .original
                        .as_deref()
                        .map(|id| store.action_message(id))
                        .transpose()?
                } else {
                    None
                };
                let id = remote.create_draft(&draft, original.as_ref())?;
                store.mail_work_remote(&work.id, &id)?;
                remote_id = Some(id);
                store.send_phase(&work.id, MailSendPhase::Prepared)?;
            }
            remote.update_draft(
                remote_id.as_deref().ok_or("Provider draft missing")?,
                &draft,
            )?;
        }
        context.check()?;
        if !store.connected(&account.id)? {
            return Err("Account disconnected before sending".into());
        }
        store.send_phase(&work.id, MailSendPhase::Sending)?;
        remote.send(&draft, &account.email, remote_id.as_deref())?;
    }
    Ok(())
}
fn finish_work(
    store: &Store,
    kind: MailWorkKind,
    work: &MailWork,
    result: Result<()>,
) -> Result<Option<String>> {
    let error = match result {
        Ok(()) => {
            store.mark_mail_work(kind, &work.id, MailWorkState::Done, None, 0)?;
            None
        }
        Err(error) => {
            let http = error.downcast_ref::<network::HttpError>();
            let phase = if matches!(kind, MailWorkKind::Outbox) {
                store.mail_phase(&work.id)?
            } else {
                MailSendPhase::Ready
            };
            let ambiguous = matches!(kind, MailWorkKind::Outbox)
                && matches!(phase, MailSendPhase::Creating | MailSendPhase::Sending)
                && http.is_none_or(|h| h.status >= 500);
            let state = if ambiguous {
                MailWorkState::Uncertain
            } else if http.is_some_and(|h| h.status == 429) {
                MailWorkState::Retry
            } else if http.is_some_and(|h| (400..500).contains(&h.status)) || work.attempts >= 2 {
                MailWorkState::Blocked
            } else {
                MailWorkState::Retry
            };
            if !ambiguous && matches!(kind, MailWorkKind::Outbox) {
                store.send_phase(
                    &work.id,
                    if store.mail_remote(&work.id)?.is_some() {
                        MailSendPhase::Prepared
                    } else {
                        MailSendPhase::Ready
                    },
                )?;
            }
            let message = if ambiguous {
                "Send outcome unknown. Check Sent and provider Drafts before creating another send."
                    .to_string()
            } else {
                error.to_string()
            };
            store.mark_mail_work(
                kind,
                &work.id,
                state,
                Some(&message),
                http.map(|h| h.retry)
                    .unwrap_or(0)
                    .max(15 * (work.attempts + 1)),
            )?;
            Some(message)
        }
    };
    Ok(error)
}
