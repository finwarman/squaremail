use super::*;
use chrono::{TimeZone, Utc};

pub(super) fn validate(draft: &EventDraft) -> Result<()> {
    if draft.title.trim().is_empty() || draft.title.len() > 2048 || draft.location.len() > 4096 {
        return Err("An event needs a title under 2 KiB and a location under 4 KiB".into());
    }
    match &draft.time {
        EventTime::Timed { start, end, zone } => {
            if end
                .checked_sub(*start)
                .is_none_or(|span| span <= 0 || span > 366 * 86400)
                || chrono::DateTime::from_timestamp(*start, 0).is_none()
                || chrono::DateTime::from_timestamp(*end, 0).is_none()
            {
                return Err("Invalid event time range".into());
            }
            zone.parse::<chrono_tz::Tz>()
                .map_err(|_| "Choose a standard IANA time zone")?;
        }
        EventTime::AllDay { start, end, zone } => {
            zone.parse::<chrono_tz::Tz>()?;
            let start = chrono::NaiveDate::parse_from_str(start, "%Y-%m-%d")?;
            let end = chrono::NaiveDate::parse_from_str(end, "%Y-%m-%d")?;
            if end <= start || end - start > chrono::Duration::days(366) {
                return Err("All-day end date must follow start, within a year".into());
            }
        }
    }
    if let Reminder::Minutes { minutes } = draft.reminder
        && !(0..=40320).contains(&minutes)
    {
        return Err("Reminder must be between zero and 28 days before the event".into());
    }
    Ok(())
}
fn times(provider: Provider, time: &EventTime) -> Result<(Value, Value)> {
    let google = provider == Provider::Gmail;
    Ok(match time {
        EventTime::AllDay {
            start,
            end,
            zone: _,
        } if google => (json!({"date":start}), json!({"date":end})),
        EventTime::AllDay { start, end, zone } => (
            json!({"dateTime":format!("{start}T00:00:00"),"timeZone":zone}),
            json!({"dateTime":format!("{end}T00:00:00"),"timeZone":zone}),
        ),
        EventTime::Timed { start, end, zone } => {
            let tz = zone.parse::<chrono_tz::Tz>()?;
            let stamp = |time| -> Result<Value> {
                let date = Utc
                    .timestamp_opt(time, 0)
                    .single()
                    .ok_or("Invalid event time")?;
                if google {
                    Ok(json!({"dateTime":date.with_timezone(&tz).to_rfc3339(),"timeZone":zone}))
                } else {
                    Ok(
                        json!({"dateTime":date.with_timezone(&tz).format("%Y-%m-%dT%H:%M:%S").to_string(),"timeZone":zone}),
                    )
                }
            };
            (stamp(*start)?, stamp(*end)?)
        }
    })
}
fn fields(provider: Provider, draft: &EventDraft) -> Result<Value> {
    let google = provider == Provider::Gmail;
    let (start, end) = times(provider, &draft.time)?;
    let mut value = if google {
        json!({"summary":draft.title,"location":draft.location,"start":start,"end":end})
    } else {
        json!({"subject":draft.title,"location":{"displayName":draft.location},"start":start,"end":end,"isAllDay":matches!(draft.time,EventTime::AllDay{..})})
    };
    match draft.reminder {
        Reminder::Preserve => {}
        Reminder::Off if google => value["reminders"] = json!({"useDefault":false,"overrides":[]}),
        Reminder::Off => value["isReminderOn"] = json!(false),
        Reminder::Minutes { minutes } if google => {
            value["reminders"] =
                json!({"useDefault":false,"overrides":[{"method":"popup","minutes":minutes}]})
        }
        Reminder::Minutes { minutes } => {
            value["isReminderOn"] = json!(true);
            value["reminderMinutesBeforeStart"] = json!(minutes);
        }
    }
    Ok(value)
}
pub(super) fn create(provider: Provider, change: &EventChange) -> Result<Value> {
    let mut value = fields(provider, &change.draft)?;
    if provider == Provider::Gmail {
        value["id"] = json!(crate::mime::message_id(
            "calendar-operation",
            &change.operation
        ));
        value["extendedProperties"] = json!({"private":{"squaremailOperation":change.operation}});
    } else {
        value["transactionId"] = json!(change.operation);
    }
    Ok(value)
}
pub(super) fn patch(provider: Provider, change: &EventChange, base: &EventDetail) -> Result<Value> {
    if !base.writable {
        return Err("This event is read-only or you are not its organiser".into());
    }
    if base.participant_count > 0 && change.updates != GuestUpdates::Notify {
        return Err("Saving this meeting requires explicit attendee-update approval".into());
    }
    let fields = fields(provider, &change.draft)?;
    let google = provider == Provider::Gmail;
    let mut patch = json!({});
    if change.draft.title != base.draft.title {
        let key = if google { "summary" } else { "subject" };
        patch[key] = fields[key].clone();
    }
    if change.draft.location != base.draft.location {
        let mut location = if google {
            Value::Null
        } else {
            base.raw["location"].clone()
        };
        if let Some(object) = location.as_object_mut() {
            object.insert("displayName".into(), json!(change.draft.location));
        } else {
            location = fields["location"].clone();
        }
        patch["location"] = location;
    }
    if change.draft.time != base.draft.time {
        patch["start"] = fields["start"].clone();
        patch["end"] = fields["end"].clone();
        if !google {
            patch["isAllDay"] = fields["isAllDay"].clone();
        }
    }
    if change.draft.reminder != Reminder::Preserve && change.draft.reminder != base.draft.reminder {
        for key in ["reminders", "isReminderOn", "reminderMinutesBeforeStart"] {
            if fields.get(key).is_some() {
                patch[key] = fields[key].clone();
            }
        }
    }
    // Never replace attendee arrays, recurrence, descriptions/meeting blobs or unknown fields.
    Ok(patch)
}
