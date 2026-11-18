use super::*;
use crate::network::{Context, HttpError, Reply};
use chrono::{Datelike, TimeZone, Utc};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use url::Url;

const CALENDAR_ROOT: &str = "https://www.googleapis.com/calendar/v3";
const MAIL_PAGE: usize = 20;
const EVENT_PAGE: usize = 100;
const POLL_SECONDS: i64 = 60;
const CATALOG_SECONDS: i64 = 900;
const MAX_PENDING: usize = 4000;

struct Remote<'a> {
    client: reqwest::blocking::Client,
    token: String,
    context: &'a Context<'a>,
    gmail: String,
    graph: String,
    calendar: String,
}
impl Remote<'_> {
    fn get(&self, root: &str, path: &str, etag: Option<&str>) -> Result<Reply> {
        let url = if path.starts_with("http") {
            Url::parse(path)?
        } else {
            Url::parse(&format!("{root}{path}"))?
        };
        let base = Url::parse(root)?;
        if url.origin() != base.origin()
            || !url.path().starts_with(base.path())
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err("Provider returned an unsafe pagination URL".into());
        }
        let mut request = self.client.get(url).bearer_auth(&self.token).header(
            "Prefer",
            "IdType=\"ImmutableId\", outlook.timezone=\"UTC\", odata.maxpagesize=100",
        );
        if let Some(tag) = etag {
            request = request.header("If-None-Match", tag);
        }
        self.context.send(request)
    }
}

pub(crate) fn sync_next(store: &Store, context: &Context<'_>) -> Result<Value> {
    // One process worker owns page advancement; UI reads use their own connection.
    static WORKER: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let Ok(_guard) = WORKER.try_lock() else {
        return Ok(json!({"worked":false}));
    };
    let now = Utc::now().timestamp();
    let Some(job) = store.next_job(now)? else {
        return Ok(json!({"worked":false}));
    };
    let account = store
        .accounts()?
        .into_iter()
        .find(|a| a.id == job.account_id)
        .ok_or("Account not found")?;
    if account.provider == Provider::Local {
        return Ok(json!({"worked":false}));
    }
    store.mark_attempt(&job, now)?;
    let result = (|| -> Result<()> {
        let remote = Remote {
            client: network::client()?,
            token: oauth::access_token(&account, context)?,
            context,
            gmail: GMAIL_ROOT.into(),
            graph: GRAPH_ROOT.into(),
            calendar: CALENDAR_ROOT.into(),
        };
        step(store, &account, &job, &remote)
    })();
    if let Err(error) = result {
        context.check()?;
        if network::is_status(error.as_ref(), 401) {
            oauth::invalidate(&account)?;
            store.fail_job(
                &job,
                now,
                "Renewing the saved sign-in after HTTP 401",
                15,
                RetryClass::Network,
            )?;
            return Ok(json!({"worked":true,"account_id":job.account_id,"kind":job.kind}));
        }
        let delay = if let Some(http) = error.downcast_ref::<HttpError>() {
            if matches!(http.status, 401 | 403) {
                900
            } else {
                http.retry.max(backoff(job.failures))
            }
        } else {
            backoff(job.failures)
        };
        let class = match error.downcast_ref::<HttpError>() {
            Some(http) if matches!(http.status, 401 | 403) => RetryClass::Auth,
            Some(http) if http.status == 429 || http.retry > 0 => RetryClass::Throttled,
            _ => RetryClass::Network,
        };
        store.fail_job(&job, now, &error.to_string(), delay, class)?;
        return Ok(
            json!({"worked":true,"account_id":job.account_id,"kind":job.kind,"error":error.to_string(),"retry_after":delay}),
        );
    }
    Ok(json!({"worked":true,"account_id":job.account_id,"kind":job.kind}))
}
fn backoff(failures: i64) -> i64 {
    (15_i64 * (1_i64 << failures.clamp(0, 8))).min(3600)
}
fn step(store: &Store, account: &Account, job: &SyncJob, remote: &Remote<'_>) -> Result<()> {
    match job.kind {
        JobKind::Catalog => catalog(store, account, job, remote),
        JobKind::RecentMail if account.provider == Provider::Gmail => {
            gmail_mail(store, account, job, remote)
        }
        JobKind::RecentMail => graph_recent(store, account, job, remote),
        JobKind::Mail if account.provider == Provider::Gmail => {
            gmail_mail(store, account, job, remote)
        }
        JobKind::Mail => graph_mail(store, account, job, remote),
        JobKind::Calendar => calendar_events(store, account, job, remote),
    }
}
fn encoded(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes()).collect()
}
fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value[key].as_str().filter(|s| !s.is_empty())
}
fn array<'a>(value: &'a Value, key: &str) -> Result<&'a Vec<Value>> {
    value[key]
        .as_array()
        .ok_or_else(|| format!("Provider omitted {key}").into())
}
fn next_value(value: &Value, key: &str) -> Value {
    text(value, key).map_or(Value::Null, |s| json!(s))
}

fn catalog(store: &Store, account: &Account, job: &SyncJob, remote: &Remote<'_>) -> Result<()> {
    let mut state = job.state.clone();
    let phase = text(&state, "phase").unwrap_or("folders").to_string();
    let mut folders = Vec::new();
    let mut sources = Vec::new();
    if phase == "folders" {
        if account.provider == Provider::Gmail {
            let value = remote.get(&remote.gmail, "/labels", None)?.value;
            for label in array(&value, "labels")? {
                let id = text(label, "id").ok_or("Label ID missing")?;
                folders.push(MailFolder {
                    account_id: account.id.clone(),
                    id: format!("label:{id}"),
                    name: string(label, "name"),
                    parent_id: None,
                    system: None,
                });
            }
            state = json!({"phase":"calendars"});
        } else {
            if state["systems"].is_null() {
                let mut systems = serde_json::Map::new();
                for (known, system) in [
                    ("inbox", Folder::Inbox),
                    ("sentitems", Folder::Sent),
                    ("drafts", Folder::Drafts),
                    ("archive", Folder::Archive),
                    ("deleteditems", Folder::Trash),
                ] {
                    let result = remote.get(
                        &remote.graph,
                        &format!("/mailFolders/{known}?$select=id"),
                        None,
                    );
                    match result {
                        Ok(reply) => {
                            systems.insert(string(&reply.value, "id"), json!(system.as_str()));
                        }
                        Err(e) if network::is_status(e.as_ref(), 404) => {}
                        Err(e) => return Err(e),
                    }
                }
                state["systems"] = Value::Object(systems);
            }
            let parent = text(&state, "parent").map(String::from);
            let path = text(&state, "next").map(String::from).unwrap_or_else(|| {
                parent
                    .as_ref()
                    .map_or("/mailFolders?$top=100".into(), |id| {
                        format!("/mailFolders/{}/childFolders?$top=100", encoded(id))
                    })
            });
            let value = remote.get(&remote.graph, &path, None)?.value;
            let mut pending: Vec<String> =
                serde_json::from_value(state["pending"].clone()).unwrap_or_default();
            for folder in array(&value, "value")? {
                let id = text(folder, "id").ok_or("Folder ID missing")?;
                folders.push(MailFolder {
                    account_id: account.id.clone(),
                    id: id.into(),
                    name: string(folder, "displayName"),
                    parent_id: parent.clone(),
                    system: state["systems"][id].as_str().map(String::from),
                });
                if folder["childFolderCount"].as_i64().unwrap_or(0) > 0
                    && !pending.iter().any(|p| p == id)
                {
                    pending.push(id.into());
                }
            }
            if pending.len() > MAX_PENDING {
                return Err("Folder hierarchy exceeds the bounded catalog queue".into());
            }
            state["next"] = next_value(&value, "@odata.nextLink");
            if state["next"].is_null() {
                if pending.is_empty() {
                    state = json!({"phase":"calendars"});
                } else {
                    state["parent"] = json!(pending.remove(0));
                }
            }
            if text(&state, "phase").unwrap_or("folders") == "folders" {
                state["pending"] = json!(pending);
            }
        }
    } else {
        let value = if account.provider == Provider::Gmail {
            let path = text(&state, "next").map_or(
                "/users/me/calendarList?maxResults=100".into(),
                |token| {
                    format!(
                        "/users/me/calendarList?maxResults=100&pageToken={}",
                        encoded(token)
                    )
                },
            );
            remote.get(&remote.calendar, &path, None)?.value
        } else {
            remote
                .get(
                    &remote.graph,
                    text(&state, "next").unwrap_or("/calendars?$top=100"),
                    None,
                )?
                .value
        };
        let key = if account.provider == Provider::Gmail {
            "items"
        } else {
            "value"
        };
        for source in array(&value, key)? {
            let id = text(source, "id").ok_or("Calendar ID missing")?;
            if source["deleted"].as_bool() == Some(true) {
                continue;
            }
            let google = account.provider == Provider::Gmail;
            sources.push(CalendarSource {
                account_id: account.id.clone(),
                id: id.into(),
                name: string(source, if google { "summary" } else { "name" }),
                color: if google {
                    text(source, "backgroundColor").unwrap_or("#2C68AD").into()
                } else {
                    "#77589B".into()
                },
                is_primary: source[if google {
                    "primary"
                } else {
                    "isDefaultCalendar"
                }]
                .as_bool()
                .unwrap_or(false),
            });
        }
        state["next"] = next_value(
            &value,
            if account.provider == Provider::Gmail {
                "nextPageToken"
            } else {
                "@odata.nextLink"
            },
        );
        if state["next"].is_null() {
            state = json!({"finish_catalog":true});
        }
    }
    remote.context.check()?;
    let done = state["finish_catalog"].as_bool() == Some(true);
    store.apply_catalog(
        job,
        &folders,
        &sources,
        &state,
        if done { CATALOG_SECONDS } else { 0 },
    )
}

fn gmail_mail(store: &Store, account: &Account, job: &SyncJob, remote: &Remote<'_>) -> Result<()> {
    let mut state = job.state.clone();
    if let Some(object) = state.as_object_mut() {
        object.remove("scan_done");
    }
    if state["history"].is_null() && state["base"].is_null() {
        let profile = remote.get(&remote.gmail, "/profile", None)?.value;
        state =
            json!({"base":text(&profile,"historyId").ok_or("History ID missing")?,"scanning":true});
    }
    let mut ids: Vec<String> = serde_json::from_value(state["pending"].clone()).unwrap_or_default();
    if ids.is_empty() {
        let path = if state["scanning"].as_bool() == Some(true) {
            let mut path = format!("/messages?maxResults={MAIL_PAGE}&includeSpamTrash=true");
            if let Some(next) = text(&state, "next") {
                path += &format!("&pageToken={}", encoded(next));
            }
            path
        } else {
            let mut path = format!(
                "/history?maxResults={MAIL_PAGE}&startHistoryId={}",
                encoded(text(&state, "history").ok_or("History cursor missing")?)
            );
            if let Some(next) = text(&state, "next") {
                path += &format!("&pageToken={}", encoded(next));
            }
            path
        };
        let reply = match remote.get(&remote.gmail, &path, None) {
            Ok(value) => value.value,
            Err(e) if network::is_status(e.as_ref(), 404) => return store.reset_job(job),
            Err(e) => return Err(e),
        };
        let mut changed = BTreeSet::new();
        if state["scanning"].as_bool() == Some(true) {
            for item in reply["messages"].as_array().into_iter().flatten() {
                if let Some(id) = text(item, "id") {
                    changed.insert(id.to_string());
                }
            }
        } else {
            for record in reply["history"].as_array().into_iter().flatten() {
                for key in [
                    "messages",
                    "messagesAdded",
                    "messagesDeleted",
                    "labelsAdded",
                    "labelsRemoved",
                ] {
                    for item in record[key].as_array().into_iter().flatten() {
                        if let Some(id) = text(item, "id").or_else(|| text(&item["message"], "id"))
                        {
                            changed.insert(id.to_string());
                        }
                    }
                }
            }
            state["latest"] = next_value(&reply, "historyId");
        }
        ids = changed.into_iter().collect();
        if ids.len() > MAX_PENDING {
            return Err("History page exceeds the bounded change queue".into());
        }
        state["next"] =
            if job.kind == JobKind::RecentMail && state["scanning"].as_bool() == Some(true) {
                Value::Null
            } else {
                next_value(&reply, "nextPageToken")
            };
    }
    let rest = ids.split_off(ids.len().min(MAIL_PAGE));
    let mut changes = Vec::new();
    let mut removed = Vec::new();
    for id in ids {
        let path = format!(
            "/messages/{}?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=To",
            encoded(&id)
        );
        match remote.get(&remote.gmail, &path, None) {
            Ok(reply) => {
                let message = gmail_message(&reply.value, account)?;
                let labels = reply.value["labelIds"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .map(|s| format!("label:{s}"))
                    .collect();
                changes.push((message, labels));
            }
            Err(e) if network::is_status(e.as_ref(), 404) => removed.push(id),
            Err(e) => return Err(e),
        }
    }
    state["pending"] = json!(rest);
    let done = rest.is_empty() && state["next"].is_null();
    if done {
        if state["scanning"].as_bool() == Some(true) {
            state = if job.kind == JobKind::RecentMail {
                json!({"history":state["base"]})
            } else {
                json!({"history":state["base"],"scan_done":true})
            };
        } else {
            state = json!({"history":text(&state,"latest").ok_or("History response omitted final cursor")?});
        }
    }
    remote.context.check()?;
    store.apply_mail(
        job,
        &changes,
        &removed,
        &state,
        if done && job.state["scanning"].as_bool() != Some(true) {
            POLL_SECONDS
        } else {
            0
        },
    )
}

fn merge_graph_page(items: &[Value]) -> Result<Vec<Value>> {
    let mut merged = std::collections::BTreeMap::<String, Value>::new();
    for item in items {
        let id = text(item, "id")
            .ok_or("Graph resource ID missing")?
            .to_string();
        let Some(previous) = merged.get_mut(&id) else {
            merged.insert(id, item.clone());
            continue;
        };
        if item.get("@removed").is_some() || previous.get("@removed").is_some() {
            *previous = item.clone();
            continue;
        }
        let previous = previous.as_object_mut().ok_or("Invalid Graph resource")?;
        for (key, value) in item.as_object().ok_or("Invalid Graph resource")? {
            previous.insert(key.clone(), value.clone());
        }
    }
    Ok(merged.into_values().collect())
}

fn graph_recent(
    store: &Store,
    account: &Account,
    job: &SyncJob,
    remote: &Remote<'_>,
) -> Result<()> {
    let value=remote.get(&remote.graph,"/messages?$top=100&$orderby=receivedDateTime%20desc&$select=id,subject,from,toRecipients,receivedDateTime,isRead,flag,hasAttachments,bodyPreview,parentFolderId",None)?.value;
    let mut changes = Vec::new();
    for item in array(&value, "value")? {
        let parent = text(item, "parentFolderId").ok_or("Message folder missing")?;
        changes.push((outlook_message(item, account)?, vec![parent.into()]));
    }
    remote.context.check()?;
    store.apply_mail(job, &changes, &[], &json!({}), POLL_SECONDS)
}

fn graph_mail(store: &Store, account: &Account, job: &SyncJob, remote: &Remote<'_>) -> Result<()> {
    let scanning = job.state["cursor"].is_null();
    let path=text(&job.state,"next").or_else(||text(&job.state,"cursor")).map(String::from)
        .unwrap_or_else(||format!("/mailFolders/{}/messages/delta?$top=100&$orderby=receivedDateTime%20desc&$select=id,subject,from,toRecipients,receivedDateTime,isRead,flag,hasAttachments,bodyPreview",encoded(&job.resource)));
    let value = match remote.get(&remote.graph, &path, None) {
        Ok(reply) => reply.value,
        Err(e) if network::is_status(e.as_ref(), 410) => return store.reset_job(job),
        Err(e) => return Err(e),
    };
    let mut changes = Vec::new();
    let mut removed = Vec::new();
    for item in &merge_graph_page(array(&value, "value")?)? {
        let id = text(item, "id").ok_or("Message ID missing")?;
        if item.get("@removed").is_some() {
            removed.push(id.into());
            continue;
        }
        // Delta can send sparse updates. Preserve fields absent from the payload.
        let mut message = outlook_message(item, account)?;
        if let Ok(previous) = store.message(&message.id) {
            if item.get("subject").is_none() {
                message.subject = previous.subject;
            }
            if item.get("from").is_none() {
                message.sender = previous.sender;
                message.sender_address = previous.sender_address;
            }
            if item.get("toRecipients").is_none() {
                message.recipient = previous.recipient;
            }
            if item.get("receivedDateTime").is_none() {
                message.timestamp = previous.timestamp;
            }
            if item.get("isRead").is_none() {
                message.unread = previous.unread;
            }
            if item.get("flag").is_none() {
                message.starred = previous.starred;
            }
            if item.get("hasAttachments").is_none() {
                message.has_attachments = previous.has_attachments;
            }
            if item.get("bodyPreview").is_none() {
                message.preview = previous.preview;
            }
        }
        changes.push((message, vec![job.resource.clone()]));
    }
    let next = next_value(&value, "@odata.nextLink");
    let cursor = next_value(&value, "@odata.deltaLink");
    if next.is_null() && cursor.is_null() {
        return Err("Graph omitted its continuation cursor".into());
    }
    let done = next.is_null();
    let state = if done {
        json!({"cursor":cursor,"scan_done":scanning})
    } else {
        json!({"next":next,"cursor":job.state["cursor"],"scanning":scanning})
    };
    remote.context.check()?;
    store.apply_mail(
        job,
        &changes,
        &removed,
        &state,
        if done { POLL_SECONDS } else { 0 },
    )
}

fn calendar_events(
    store: &Store,
    account: &Account,
    job: &SyncJob,
    remote: &Remote<'_>,
) -> Result<()> {
    let start = chrono::DateTime::from_timestamp(job.window, 0).ok_or("Invalid calendar month")?;
    let end = if start.month() == 12 {
        Utc.with_ymd_and_hms(start.year() + 1, 1, 1, 0, 0, 0)
            .single()
    } else {
        Utc.with_ymd_and_hms(start.year(), start.month() + 1, 1, 0, 0, 0)
            .single()
    }
    .ok_or("Invalid calendar range")?;
    let primary = store
        .calendars()?
        .into_iter()
        .find(|c| c.account_id == account.id && c.id == job.resource)
        .ok_or("Calendar no longer exists")?
        .is_primary;
    let delta = account.provider == Provider::Outlook && primary;
    let next = text(&job.state, "next");
    let path = if account.provider == Provider::Gmail {
        let mut path = format!(
            "/calendars/{}/events?singleEvents=true&showDeleted=false&maxResults={EVENT_PAGE}&timeMin={}&timeMax={}",
            encoded(&job.resource),
            encoded(&start.to_rfc3339()),
            encoded(&end.to_rfc3339())
        );
        if let Some(next) = next {
            path += &format!("&pageToken={}", encoded(next));
        }
        path
    } else if let Some(next) = next.or_else(|| {
        if delta {
            text(&job.state, "cursor")
        } else {
            None
        }
    }) {
        next.into()
    } else if delta {
        format!(
            "/calendarView/delta?startDateTime={}&endDateTime={}",
            encoded(&start.to_rfc3339()),
            encoded(&end.to_rfc3339())
        )
    } else {
        format!(
            "/calendars/{}/calendarView?$top={EVENT_PAGE}&startDateTime={}&endDateTime={}",
            encoded(&job.resource),
            encoded(&start.to_rfc3339()),
            encoded(&end.to_rfc3339())
        )
    };
    let root = if account.provider == Provider::Gmail {
        &remote.calendar
    } else {
        &remote.graph
    };
    let etag = if next.is_none() && !delta {
        text(&job.state, "etag")
    } else {
        None
    };
    let reply = match remote.get(root, &path, etag) {
        Ok(reply) => reply,
        Err(e) if network::is_status(e.as_ref(), 410) => return store.reset_job(job),
        Err(e) => return Err(e),
    };
    if reply.value.is_null() {
        remote.context.check()?;
        return store.checkpoint(job, &job.state, POLL_SECONDS);
    }
    let mut events = Vec::new();
    let mut removed = Vec::new();
    let key = if account.provider == Provider::Gmail {
        "items"
    } else {
        "value"
    };
    let items = if account.provider == Provider::Outlook {
        merge_graph_page(array(&reply.value, key)?)?
    } else {
        array(&reply.value, key)?.clone()
    };
    for item in &items {
        if item.get("@removed").is_some()
            || item["status"] == "cancelled"
            || item["isCancelled"].as_bool() == Some(true)
        {
            removed.push(string(item, "id"));
            continue;
        }
        let mut event = parse_event(account, &job.resource, item)?;
        event.reminder_times = crate::notices::reminder_times(
            account,
            &event,
            item,
            &reply.value["defaultReminders"],
            reply.value["timeZone"].as_str().unwrap_or("UTC"),
        );
        events.push(event);
    }
    let next = next_value(
        &reply.value,
        if account.provider == Provider::Gmail {
            "nextPageToken"
        } else {
            "@odata.nextLink"
        },
    );
    let done = next.is_null();
    let cursor = if delta {
        next_value(&reply.value, "@odata.deltaLink")
    } else {
        Value::Null
    };
    if delta && done && cursor.is_null() {
        return Err("Graph omitted calendar delta cursor".into());
    }
    let state = json!({"next":next,"cursor":if done{cursor}else{job.state["cursor"].clone()},"snapshot":!delta || job.state["cursor"].is_null(),
        "etag":if text(&job.state,"next").is_some(){job.state["etag"].clone()}else{reply.etag.or_else(||text(&reply.value,"etag").map(String::from)).map_or(Value::Null,|s|json!(s))}});
    remote.context.check()?;
    store.apply_events(
        job,
        &events,
        &removed,
        &state,
        if done { POLL_SECONDS } else { 0 },
    )
}
pub(crate) fn edit_summary(
    account: &Account,
    key: &crate::calendar::EventKey,
    raw: &Value,
) -> Result<CalendarEvent> {
    let mut event = parse_event(account, &key.calendar, raw)?;
    event.reminder_times = crate::notices::reminder_times(
        account,
        &event,
        raw,
        &Value::Null,
        raw["start"]["timeZone"].as_str().unwrap_or("UTC"),
    );
    Ok(event)
}

fn parse_event(account: &Account, calendar: &str, value: &Value) -> Result<CalendarEvent> {
    let google = account.provider == Provider::Gmail;
    let all_day = if google {
        text(&value["start"], "date").is_some()
    } else {
        value["isAllDay"].as_bool().unwrap_or(false)
    };
    let start_raw = text(
        &value["start"],
        if google && all_day {
            "date"
        } else {
            "dateTime"
        },
    )
    .ok_or("Event start missing")?;
    let end_raw = text(
        &value["end"],
        if google && all_day {
            "date"
        } else {
            "dateTime"
        },
    )
    .ok_or("Event end missing")?;
    fn timestamp(raw: &str, all_day: bool, zone: Option<&str>) -> Result<i64> {
        if all_day {
            return Ok(chrono::NaiveDate::parse_from_str(
                raw.get(..10).ok_or("Invalid all-day date")?,
                "%Y-%m-%d",
            )?
            .and_hms_opt(0, 0, 0)
            .ok_or("Invalid date")?
            .and_utc()
            .timestamp());
        }
        if let Ok(date) = chrono::DateTime::parse_from_rfc3339(raw) {
            return Ok(date.timestamp());
        }
        let naive = chrono::NaiveDateTime::parse_from_str(raw, "%Y-%m-%dT%H:%M:%S%.f")?;
        if let Some(zone) = zone {
            return Ok(zone
                .parse::<chrono_tz::Tz>()?
                .from_local_datetime(&naive)
                .single()
                .ok_or("Ambiguous provider event time")?
                .timestamp());
        }
        // Graph returns UTC without a suffix when Prefer requests UTC.
        Ok(naive.and_utc().timestamp())
    }
    let raw_start = timestamp(
        start_raw,
        google && all_day,
        if google {
            text(&value["start"], "timeZone")
        } else {
            None
        },
    )?;
    let raw_end = timestamp(
        end_raw,
        google && all_day,
        if google {
            text(&value["end"], "timeZone")
        } else {
            None
        },
    )?;
    let (start, end, start_day, end_day) = if all_day && !google {
        fn original_day(
            value: &Value,
            key: &str,
            original: &str,
            timestamp: i64,
        ) -> Result<(i64, String)> {
            let name = text(value, original)
                .or_else(|| text(value, "originalStartTimeZone"))
                .or_else(|| text(&value[key], "timeZone"))
                .unwrap_or("UTC");
            let zone = name
                .parse::<chrono_tz::Tz>()
                .or_else(|_| {
                    name.parse::<windows_timezones::WindowsTimezone>()
                        .map(Into::into)
                })
                .map_err(|_| "Unsupported all-day event time zone")?;
            let date = chrono::DateTime::from_timestamp(timestamp, 0)
                .ok_or("Invalid event time")?
                .with_timezone(&zone)
                .date_naive();
            Ok((
                date.and_hms_opt(0, 0, 0)
                    .ok_or("Invalid all-day date")?
                    .and_utc()
                    .timestamp(),
                date.to_string(),
            ))
        }
        let (start, start_day) = original_day(value, "start", "originalStartTimeZone", raw_start)?;
        let (end, end_day) = original_day(value, "end", "originalEndTimeZone", raw_end)?;
        (start, end, Some(start_day), Some(end_day))
    } else {
        (
            raw_start,
            raw_end,
            all_day.then(|| start_raw.get(..10).unwrap_or("").to_string()),
            all_day.then(|| end_raw.get(..10).unwrap_or("").to_string()),
        )
    };
    if end <= start {
        return Err("Event end must follow its start".into());
    }
    let version = text(
        value,
        if google {
            "updated"
        } else {
            "lastModifiedDateTime"
        },
    )
    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
    .map(|d| d.timestamp_millis())
    .unwrap_or(0);
    Ok(CalendarEvent {
        reminder_times: Vec::new(),
        version,
        account_id: account.id.clone(),
        calendar_id: calendar.into(),
        id: text(value, "id").ok_or("Event ID missing")?.into(),
        title: string(value, if google { "summary" } else { "subject" }),
        start,
        end,
        all_day,
        start_day,
        end_day,
        location: if google {
            string(value, "location")
        } else {
            string(&value["location"], "displayName")
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
        time::{Duration, Instant},
    };
    struct Fixture {
        root: String,
        worker: Option<thread::JoinHandle<()>>,
    }
    impl Fixture {
        fn new(replies: Vec<(&str, u16, Value)>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let root = format!("http://{}", listener.local_addr().unwrap());
            listener.set_nonblocking(true).unwrap();
            let replies: Vec<_> = replies
                .into_iter()
                .map(|(p, s, v)| (p.to_string(), s, v))
                .collect();
            let authority = root.clone();
            let worker = thread::spawn(move || {
                for (path, status, value) in replies {
                    let start = Instant::now();
                    let mut stream = loop {
                        match listener.accept() {
                            Ok((s, _)) => break s,
                            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                assert!(
                                    start.elapsed() < Duration::from_secs(5),
                                    "Expected request {path}"
                                );
                                thread::sleep(Duration::from_millis(2));
                            }
                            Err(e) => panic!("{e}"),
                        }
                    };
                    stream.set_nonblocking(false).unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut data = Vec::new();
                    let mut buf = [0; 1024];
                    while !data.windows(4).any(|w| w == b"\r\n\r\n") {
                        let n = stream.read(&mut buf).unwrap();
                        if n == 0 {
                            break;
                        }
                        data.extend_from_slice(&buf[..n]);
                    }
                    let request = String::from_utf8_lossy(&data);
                    assert!(
                        request.starts_with(&format!("GET {path}")),
                        "Expected {path}, got {}",
                        request.lines().next().unwrap_or("")
                    );
                    assert!(
                        request
                            .to_lowercase()
                            .contains("authorization: bearer fixture")
                    );
                    let raw = value.to_string().replace("$ROOT", &authority);
                    write!(stream,"HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nETag: \"v1\"\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{raw}",raw.len()).unwrap();
                }
            });
            Self {
                root,
                worker: Some(worker),
            }
        }
        fn remote<'a>(&self, context: &'a Context<'a>) -> Remote<'a> {
            Remote {
                client: network::client().unwrap(),
                token: "fixture".into(),
                context,
                gmail: format!("{}/gmail", self.root),
                graph: format!("{}/graph", self.root),
                calendar: format!("{}/calendar", self.root),
            }
        }
        fn finish(mut self) {
            self.worker.take().unwrap().join().unwrap();
        }
    }
    fn account(provider: Provider) -> Account {
        Account {
            id: "a".into(),
            email: "a@example.test".into(),
            provider,
        }
    }
    fn job(store: &Store, kind: JobKind, resource: &str, window: i64) -> SyncJob {
        store.ensure_job("a", kind, resource, window).unwrap();
        SyncJob {
            account_id: "a".into(),
            kind,
            resource: resource.into(),
            window,
            state: json!({}),
            failures: 0,
        }
    }
    fn gmail(id: &str, labels: Value) -> Value {
        json!({"id":id,"internalDate":"1700000000000","labelIds":labels,"payload":{"headers":[{"name":"Subject","value":"Cached notes"},{"name":"From","value":"Ada <ada@example.test>"}]}})
    }
    #[test]
    fn gmail_history_moves_deletes() {
        let store = Store::open(":memory:").unwrap();
        let a = account(Provider::Gmail);
        store.save_account(&a).unwrap();
        let j = job(&store, JobKind::Mail, "", 0);
        let fixture = Fixture::new(vec![
            ("/gmail/profile", 200, json!({"historyId":"10"})),
            (
                "/gmail/messages?",
                200,
                json!({"messages":[{"id":"one"},{"id":"two"}]}),
            ),
            (
                "/gmail/messages/one?",
                200,
                gmail("one", json!(["INBOX", "UNREAD"])),
            ),
            ("/gmail/messages/two?", 200, gmail("two", json!(["INBOX"]))),
        ]);
        let context = Context::new(None, 25);
        step(&store, &a, &j, &fixture.remote(&context)).unwrap();
        fixture.finish();
        assert_eq!(
            store
                .list(Some("a"), Folder::Inbox, "", 0, 250)
                .unwrap()
                .len(),
            2
        );
        let id = crate::mime::message_id("a", "one");
        store.save_body(&id, "Keep me offline", "").unwrap();
        let j = store.test_job(&j);
        let fixture = Fixture::new(vec![
            (
                "/gmail/history?",
                200,
                json!({"historyId":"11","history":[{"labelsRemoved":[{"message":{"id":"one"}}],"messagesDeleted":[{"message":{"id":"two"}}]}]}),
            ),
            (
                "/gmail/messages/one?",
                200,
                gmail("one", json!(["Label_1"])),
            ),
            ("/gmail/messages/two?", 404, json!({})),
        ]);
        step(&store, &a, &j, &fixture.remote(&context)).unwrap();
        fixture.finish();
        assert!(
            store
                .list(Some("a"), Folder::Inbox, "", 0, 250)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            store
                .list_folder(Some("a"), Folder::All, Some("label:Label_1"), "", 0, 250)
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            store.message(&id).unwrap().text.as_deref(),
            Some("Keep me offline")
        );
        assert!(store.message(&crate::mime::message_id("a", "two")).is_err());
        let j = store.test_job(&j);
        assert_eq!(j.state["history"], "11");
        let fixture = Fixture::new(vec![("/gmail/history?", 404, json!({}))]);
        step(&store, &a, &j, &fixture.remote(&context)).unwrap();
        fixture.finish();
        assert_eq!(store.test_job(&j).state, json!({}));
        assert!(store.message(&id).unwrap().text.is_some());
    }
    #[test]
    fn graph_delta_restarts() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cache.sqlite");
        let store = Store::open(path.to_str().unwrap()).unwrap();
        let a = account(Provider::Outlook);
        store.save_account(&a).unwrap();
        let j = job(&store, JobKind::Mail, "inbox-id", 0);
        let fixture = Fixture::new(vec![(
            "/graph/mailFolders/inbox-id/messages/delta?",
            200,
            json!({"value":[{"id":"one","subject":"Cached subject","isRead":false}],"@odata.nextLink":"https://attacker.example/steal"}),
        )]);
        let context = Context::new(None, 25);
        step(&store, &a, &j, &fixture.remote(&context)).unwrap();
        fixture.finish();
        drop(store);
        let store = Store::open(path.to_str().unwrap()).unwrap();
        let j = store.test_job(&j);
        let remote = Remote {
            client: network::client().unwrap(),
            token: "fixture".into(),
            context: &context,
            gmail: GMAIL_ROOT.into(),
            graph: GRAPH_ROOT.into(),
            calendar: CALENDAR_ROOT.into(),
        };
        assert!(
            step(&store, &a, &j, &remote)
                .unwrap_err()
                .to_string()
                .contains("unsafe pagination")
        );
        assert_eq!(
            store
                .list(Some("a"), Folder::All, "", 0, 250)
                .unwrap()
                .len(),
            1
        );
        store.reset_job(&j).unwrap();
        let j = store.test_job(&j);
        let fixture = Fixture::new(vec![(
            "/graph/mailFolders/inbox-id/messages/delta?",
            200,
            json!({"value":[],"@odata.deltaLink":"https://graph.microsoft.com/v1.0/me/delta?opaque"}),
        )]);
        step(&store, &a, &j, &fixture.remote(&context)).unwrap();
        fixture.finish();
        assert!(
            store
                .list_folder(Some("a"), Folder::All, Some("inbox-id"), "", 0, 250)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            store.test_job(&j).state["cursor"],
            "https://graph.microsoft.com/v1.0/me/delta?opaque"
        );
    }
    #[test]
    fn calendar_dates_cancel() {
        let a = account(Provider::Gmail);
        let event=parse_event(&a,"primary",&json!({"id":"all-day","summary":"DST day","start":{"date":"2026-03-29"},"end":{"date":"2026-03-30"}})).unwrap();
        assert!(event.all_day);
        assert_eq!(event.start_day.as_deref(), Some("2026-03-29"));
        let event=parse_event(&account(Provider::Outlook),"primary",&json!({"id":"one","subject":"UTC","start":{"dateTime":"2026-11-17T10:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-11-17T11:00:00.0000000","timeZone":"UTC"}})).unwrap();
        assert_eq!(event.end - event.start, 3600);
        assert!(
            parse_event(
                &a,
                "primary",
                &json!({"id":"bad","start":{"date":"x"},"end":{"date":"y"}})
            )
            .is_err()
        );
        let summer=parse_event(&account(Provider::Outlook),"primary",&json!({"id":"summer","isAllDay":true,"originalStartTimeZone":"GMT Standard Time","originalEndTimeZone":"GMT Standard Time","start":{"dateTime":"2026-07-10T23:00:00","timeZone":"UTC"},"end":{"dateTime":"2026-07-11T23:00:00","timeZone":"UTC"}})).unwrap();
        assert_eq!(summer.start_day.as_deref(), Some("2026-07-11"));
        assert_eq!(summer.end_day.as_deref(), Some("2026-07-12"));
        let token = network::CancelToken::default();
        token.cancel();
        let context = Context::new(Some(&token), 25);
        assert!(
            context
                .send(network::client().unwrap().get("http://127.0.0.1:1"))
                .unwrap_err()
                .to_string()
                .contains("cancelled")
        );
    }
    fn source(store: &Store, account: &Account) -> SyncJob {
        let catalog = job(store, JobKind::Catalog, "", 0);
        let source = CalendarSource {
            account_id: account.id.clone(),
            id: "primary".into(),
            name: "Main".into(),
            color: "#2C68AD".into(),
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
        job(store, JobKind::Calendar, "primary", 1793491200)
    }
    fn google_event(id: &str) -> Value {
        json!({"id":id,"summary":"Cached meeting","start":{"dateTime":"2026-11-17T10:00:00Z"},"end":{"dateTime":"2026-11-17T11:00:00Z"}})
    }
    #[test]
    fn google_calendar_pages_and_304() {
        let store = Store::open(":memory:").unwrap();
        let a = account(Provider::Gmail);
        store.save_account(&a).unwrap();
        let j = source(&store, &a);
        let context = Context::new(None, 25);
        let fixture = Fixture::new(vec![
            (
                "/calendar/calendars/primary/events?",
                200,
                json!({"items":[google_event("one")],"nextPageToken":"two","etag":"v1"}),
            ),
            (
                "/calendar/calendars/primary/events?",
                200,
                json!({"items":[google_event("two")],"etag":"v1"}),
            ),
            ("/calendar/calendars/primary/events?", 304, Value::Null),
        ]);
        let remote = fixture.remote(&context);
        step(&store, &a, &j, &remote).unwrap();
        let j = store.test_job(&j);
        assert_eq!(j.state["next"], "two");
        assert!(
            store
                .events(j.window, j.window + 30 * 86400, 0, 2000)
                .unwrap()
                .is_empty()
        );
        step(&store, &a, &j, &remote).unwrap();
        let j = store.test_job(&j);
        assert_eq!(
            store
                .events(j.window, j.window + 30 * 86400, 0, 2000)
                .unwrap()
                .len(),
            2
        );
        step(&store, &a, &j, &remote).unwrap();
        assert_eq!(
            store
                .events(j.window, j.window + 30 * 86400, 0, 2000)
                .unwrap()
                .len(),
            2
        );
        fixture.finish();
    }
    #[test]
    fn graph_calendar_deletions() {
        let store = Store::open(":memory:").unwrap();
        let a = account(Provider::Outlook);
        store.save_account(&a).unwrap();
        let j = source(&store, &a);
        let context = Context::new(None, 25);
        let event = |id: &str, title: &str| json!({"id":id,"subject":title,"start":{"dateTime":"2026-11-17T10:00:00"},"end":{"dateTime":"2026-11-17T11:00:00"}});
        let fixture = Fixture::new(vec![
            (
                "/graph/calendarView/delta?",
                200,
                json!({"value":[event("one","Before")],"@odata.nextLink":"$ROOT/graph/page-two"}),
            ),
            (
                "/graph/page-two",
                200,
                json!({"value":[event("two","Remove")],"@odata.deltaLink":"$ROOT/graph/changes"}),
            ),
            (
                "/graph/changes",
                200,
                json!({"value":[event("one","After"),{"id":"two","@removed":{"reason":"deleted"}}],"@odata.deltaLink":"$ROOT/graph/changes-next"}),
            ),
        ]);
        let remote = fixture.remote(&context);
        step(&store, &a, &j, &remote).unwrap();
        let j = store.test_job(&j);
        assert!(
            store
                .events(j.window, j.window + 30 * 86400, 0, 2000)
                .unwrap()
                .is_empty()
        );
        step(&store, &a, &j, &remote).unwrap();
        let j = store.test_job(&j);
        assert_eq!(
            store
                .events(j.window, j.window + 30 * 86400, 0, 2000)
                .unwrap()
                .len(),
            2
        );
        step(&store, &a, &j, &remote).unwrap();
        let events = store
            .events(j.window, j.window + 30 * 86400, 0, 2000)
            .unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].title, "After");
        fixture.finish();
    }
    #[test]
    fn new_mail_during_backfill() {
        let store = Store::open(":memory:").unwrap();
        let a = account(Provider::Gmail);
        store.save_account(&a).unwrap();
        let archive = job(&store, JobKind::Mail, "", 0);
        let recent = job(&store, JobKind::RecentMail, "", 0);
        let older =
            crate::mime::parse(b"Subject: Offline archive\r\n\r\nOld body", "a", "older").unwrap();
        store.save(&older, Folder::Inbox).unwrap();
        let context = Context::new(None, 25);
        let fixture = Fixture::new(vec![
            ("/gmail/profile", 200, json!({"historyId":"10"})),
            (
                "/gmail/messages?",
                200,
                json!({"messages":[{"id":"one"}],"nextPageToken":"old-pages"}),
            ),
            ("/gmail/messages/one?", 200, gmail("one", json!(["INBOX"]))),
        ]);
        step(&store, &a, &recent, &fixture.remote(&context)).unwrap();
        fixture.finish();
        let recent = store.test_job(&recent);
        assert_eq!(recent.state["history"], "10");
        assert!(store.message(&older.id).is_ok());
        // Expiring the foreground cursor must not erase archive reconciliation markers.
        let fixture = Fixture::new(vec![("/gmail/history?", 404, json!({}))]);
        step(&store, &a, &recent, &fixture.remote(&context)).unwrap();
        fixture.finish();
        store
            .apply_mail(
                &archive,
                &[(older, vec!["label:INBOX".into()])],
                &[],
                &json!({"scan_done":true,"history":"10"}),
                0,
            )
            .unwrap();
        assert_eq!(
            store
                .list(Some("a"), Folder::Inbox, "", 0, 250)
                .unwrap()
                .len(),
            2
        );
    }
    #[test]
    fn graph_page_final_change() {
        let page = merge_graph_page(&[
            json!({"id":"one","@removed":{"reason":"deleted"}}),
            json!({"id":"one","subject":"Restored"}),
            json!({"id":"one","isRead":true}),
            json!({"id":"two","subject":"Old"}),
            json!({"id":"two","@removed":{"reason":"deleted"}}),
        ])
        .unwrap();
        assert_eq!(page[0]["subject"], "Restored");
        assert_eq!(page[0]["isRead"], true);
        assert!(page[0].get("@removed").is_none());
        assert!(page[1].get("@removed").is_some());
    }
}
