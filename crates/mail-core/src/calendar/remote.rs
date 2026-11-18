use super::*;
use crate::network::{self, HttpError, Reply};

#[derive(Clone, Copy, PartialEq)]
pub(super) enum SourceAccess {
    ReadOnly,
    Write,
}

pub(super) struct Remote<'a> {
    account: &'a Account,
    token: &'a str,
    context: &'a Context<'a>,
    root: String,
}
impl<'a> Remote<'a> {
    pub(super) fn new(account: &'a Account, token: &'a str, context: &'a Context<'a>) -> Self {
        Self {
            account,
            token,
            context,
            root: if account.provider == Provider::Gmail {
                GOOGLE_ROOT
            } else {
                GRAPH_ROOT
            }
            .into(),
        }
    }
    fn path(&self, key: &EventKey) -> Result<String> {
        if key.account != self.account.id
            || key.calendar.is_empty()
            || key.calendar.len() > 2048
            || key
                .id
                .as_ref()
                .is_some_and(|id| id.is_empty() || id.len() > 2048)
        {
            return Err("Invalid calendar identity".into());
        }
        let encode =
            |s: &str| url::form_urlencoded::byte_serialize(s.as_bytes()).collect::<String>();
        let mut path = format!("{}/calendars/{}/events", self.root, encode(&key.calendar));
        if let Some(id) = &key.id {
            path.push('/');
            path += &encode(id);
        }
        Ok(path)
    }
    fn request(&self, request: reqwest::blocking::RequestBuilder) -> Result<Reply> {
        self.context.send(
            request
                .bearer_auth(self.token)
                .header("Prefer", "IdType=\"ImmutableId\", outlook.timezone=\"UTC\""),
        )
    }
    fn source(&self, key: &EventKey) -> Result<Value> {
        self.path(key)?;
        let id = url::form_urlencoded::byte_serialize(key.calendar.as_bytes()).collect::<String>();
        let path = if self.account.provider == Provider::Gmail {
            format!("{}/users/me/calendarList/{id}", self.root)
        } else {
            format!("{}/calendars/{id}", self.root)
        };
        Ok(self.request(network::client()?.get(path))?.value)
    }
    pub(super) fn detail(&self, key: &EventKey) -> Result<EventDetail> {
        let source = self.source(key)?;
        let google = self.account.provider == Provider::Gmail;
        let source_writable = if google {
            matches!(source["accessRole"].as_str(), Some("writer" | "owner"))
        } else {
            source["canEdit"].as_bool() == Some(true)
        };
        let Some(_) = key.id else {
            let now = chrono::Utc::now().timestamp();
            return Ok(EventDetail {
                key: key.clone(),
                revision: "new".into(),
                draft: EventDraft {
                    title: String::new(),
                    location: String::new(),
                    time: EventTime::Timed {
                        start: now,
                        end: now + 3600,
                        zone: "UTC".into(),
                    },
                    reminder: Reminder::Preserve,
                },
                organizer: String::new(),
                participants: vec![],
                participant_count: 0,
                conference: String::new(),
                notes: String::new(),
                recurring: false,
                writable: source_writable,
                raw: json!({}),
            });
        };
        let reply = self.request(network::client()?.get(self.path(key)?))?;
        Self::decode(
            self.account,
            key,
            reply,
            if source_writable {
                SourceAccess::Write
            } else {
                SourceAccess::ReadOnly
            },
        )
    }
    pub(super) fn decode(
        account: &Account,
        key: &EventKey,
        reply: Reply,
        source_access: SourceAccess,
    ) -> Result<EventDetail> {
        let raw = reply.value;
        if serde_json::to_vec(&raw)?.len() > DETAIL_LIMIT {
            return Err("Event details exceed the 256 KiB editor limit".into());
        }
        let event = parsed_event(account, key, &raw)?;
        if key.id.as_deref() != Some(&event.id) {
            return Err("Provider returned a different event identity".into());
        }
        let google = account.provider == Provider::Gmail;
        let revision = raw[if google { "etag" } else { "@odata.etag" }]
            .as_str()
            .map(String::from)
            .or(reply.etag)
            .ok_or("Provider omitted the event revision; editing is blocked")?;
        let list = raw["attendees"].as_array();
        let participant_count = list.map(Vec::len).unwrap_or(0);
        let participants = list
            .into_iter()
            .flatten()
            .take(50)
            .map(|v| {
                let identity = if google { v } else { &v["emailAddress"] };
                let name = label(identity, account.provider);
                let status = if google {
                    v["responseStatus"].as_str()
                } else {
                    v["status"]["response"].as_str()
                }
                .unwrap_or("unknown");
                format!("{name} ({status})")
            })
            .collect();
        let organizer = label(
            if google {
                &raw["organizer"]
            } else {
                &raw["organizer"]["emailAddress"]
            },
            account.provider,
        );
        let owns_event = if google {
            raw["organizer"]["self"].as_bool() == Some(true)
                || participant_count == 0
                || raw["guestsCanModify"].as_bool() == Some(true)
        } else {
            raw["isOrganizer"].as_bool() == Some(true) || participant_count == 0
        };
        let special = google
            && raw["eventType"]
                .as_str()
                .is_some_and(|kind| kind != "default");
        let notes = if google {
            raw["description"].as_str()
        } else {
            raw["bodyPreview"].as_str()
        }
        .unwrap_or("")
        .chars()
        .take(8192)
        .collect();
        let conference = if google {
            raw["hangoutLink"].as_str().or_else(|| {
                raw["conferenceData"]["entryPoints"]
                    .as_array()?
                    .iter()
                    .find(|p| p["entryPointType"] == "video")?["uri"]
                    .as_str()
            })
        } else {
            raw["onlineMeeting"]["joinUrl"].as_str()
        }
        .unwrap_or("")
        .chars()
        .take(2048)
        .collect();
        let time = if event.all_day {
            EventTime::AllDay {
                start: event.start_day.ok_or("All-day start missing")?,
                end: event.end_day.ok_or("All-day end missing")?,
                zone: zone_name(&raw, account.provider),
            }
        } else {
            EventTime::Timed {
                start: event.start,
                end: event.end,
                zone: zone_name(&raw, account.provider),
            }
        };
        Ok(EventDetail {
            key: key.clone(),
            revision,
            draft: EventDraft {
                title: event.title,
                location: event.location,
                time,
                reminder: Reminder::Preserve,
            },
            organizer,
            participants,
            participant_count,
            conference,
            notes,
            recurring: raw["recurringEventId"].is_string()
                || raw["recurrence"].is_object()
                || raw["recurrence"].is_array()
                || raw["seriesMasterId"].is_string(),
            writable: source_access == SourceAccess::Write
                && owns_event
                && !special
                && raw["locked"].as_bool() != Some(true)
                && raw["isCancelled"].as_bool() != Some(true)
                && raw["status"] != "cancelled",
            raw,
        })
    }
    pub(super) fn save(&self, write: &PendingWrite) -> Result<EventDetail> {
        let change = &write.change;
        let fresh = self.detail(&change.key)?;
        if !fresh.writable {
            return Err(Box::new(HttpError {
                status: 403,
                retry: 0,
            }));
        }
        let client = network::client()?;
        let google = self.account.provider == Provider::Gmail;
        let mut url = url::Url::parse(&self.path(&change.key)?)?;
        if google {
            url.query_pairs_mut().extend_pairs([
                (
                    "sendUpdates",
                    if change.updates == GuestUpdates::Notify {
                        "all"
                    } else {
                        "none"
                    },
                ),
                ("conferenceDataVersion", "1"),
                ("supportsAttachments", "true"),
            ]);
        }
        if let Some(base) = &write.base {
            let patch = draft::patch(self.account.provider, change, base)?;
            if patch.as_object().is_none_or(|p| p.is_empty()) {
                return Ok(fresh);
            }
            if fresh.revision != base.revision {
                // A lost success response can be acknowledged without replaying a meeting update.
                let applied = change.draft.title == fresh.draft.title
                    && change.draft.location == fresh.draft.location
                    && change.draft.time == fresh.draft.time
                    && reminder_matches(&change.draft.reminder, &fresh.raw, self.account.provider);
                if write.attempts > 0 && applied {
                    return Ok(fresh);
                }
                return Err(Box::new(HttpError {
                    status: 412,
                    retry: 0,
                }));
            }
            self.request(
                client
                    .patch(url)
                    .header("If-Match", &base.revision)
                    .json(&patch),
            )?;
        } else {
            let payload = draft::create(self.account.provider, change)?;
            match self.request(client.post(url).json(&payload)) {
                Ok(reply) => {
                    let mut key = change.key.clone();
                    key.id = reply.value["id"].as_str().map(String::from);
                    if key.id.is_none() {
                        return Err("Provider omitted the created event ID".into());
                    }
                    return self.detail(&key);
                }
                Err(error) if google && network::is_status(error.as_ref(), 409) => {
                    let mut key = change.key.clone();
                    key.id = payload["id"].as_str().map(String::from);
                    let detail = self.detail(&key)?;
                    if detail.raw["extendedProperties"]["private"]["squaremailOperation"]
                        == change.operation
                    {
                        return Ok(detail);
                    }
                    return Err(error);
                }
                Err(error) => return Err(error),
            }
        }
        self.detail(&change.key)
    }
    #[cfg(test)]
    pub(super) fn fixture(account: &'a Account, context: &'a Context<'a>, root: String) -> Self {
        Self {
            account,
            token: "fixture",
            context,
            root,
        }
    }
}
fn reminder_matches(reminder: &Reminder, raw: &Value, provider: Provider) -> bool {
    let google = provider == Provider::Gmail;
    match reminder {
        Reminder::Preserve => true,
        Reminder::Off if google => {
            raw["reminders"]["useDefault"] == false
                && raw["reminders"]["overrides"]
                    .as_array()
                    .is_some_and(Vec::is_empty)
        }
        Reminder::Off => raw["isReminderOn"] == false,
        Reminder::Minutes { minutes } if google => {
            raw["reminders"]["useDefault"] == false
                && raw["reminders"]["overrides"] == json!([{"method":"popup","minutes":minutes}])
        }
        Reminder::Minutes { minutes } => {
            raw["isReminderOn"] == true && raw["reminderMinutesBeforeStart"] == *minutes
        }
    }
}
fn label(value: &Value, provider: Provider) -> String {
    let google = provider == Provider::Gmail;
    let name = value[if google { "displayName" } else { "name" }]
        .as_str()
        .filter(|s| !s.trim().is_empty());
    if let Some(name) = name {
        return name.chars().take(512).collect();
    }
    let email = value[if google { "email" } else { "address" }]
        .as_str()
        .unwrap_or("");
    if email.ends_with(".calendar.google.com") {
        return "Calendar resource".into();
    }
    email.chars().take(512).collect()
}
fn zone_name(raw: &Value, provider: Provider) -> String {
    let google = provider == Provider::Gmail;
    let zone = if google {
        raw["start"]["timeZone"].as_str()
    } else {
        raw["originalStartTimeZone"].as_str()
    }
    .unwrap_or("UTC");
    if zone.parse::<chrono_tz::Tz>().is_ok() {
        return zone.into();
    }
    zone.parse::<windows_timezones::WindowsTimezone>()
        .map(|z| {
            let tz: chrono_tz::Tz = z.into();
            tz.name().into()
        })
        .unwrap_or_else(|_| "UTC".into())
}
