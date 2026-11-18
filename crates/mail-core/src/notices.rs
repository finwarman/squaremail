use crate::{Result, model::*, store::Store};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub(crate) const NOTICE_LIMIT: i64 = 50;
pub(crate) const PLAN_LIMIT: i64 = 32;
pub(crate) const HISTORY_SECONDS: i64 = 14 * 86400;
pub(crate) const LATE_SECONDS: i64 = 15 * 60;
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum NoticeDelivery {
    Quiet,
    Desktop,
}
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum NoticeAction {
    Read,
    Clear,
}
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum NoticeChannel {
    Mail,
    Calendar,
}
impl NoticeChannel {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Mail => "mail",
            Self::Calendar => "calendar",
        }
    }
}
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Toggle {
    On,
    Off,
}
impl Toggle {
    pub(crate) fn enabled(self) -> bool {
        matches!(self, Self::On)
    }
}
#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Arrival {
    New,
    Existing,
}
#[derive(Clone, Copy)]
pub(crate) enum EventBaseline {
    Known,
    Initial,
}
#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum NoticeKind {
    Mail,
    Reminder,
    CalendarUpdate,
}
impl NoticeKind {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Mail => "mail",
            Self::Reminder => "reminder",
            Self::CalendarUpdate => "calendar_update",
        }
    }
}

pub(crate) fn poll(store: &Store, delivery: NoticeDelivery) -> Result<Value> {
    let now = chrono::Utc::now().timestamp();
    store.prepare_notices(now)?;
    store.collect_reminders(now)?;
    store.notice_batch(delivery, now)
}

pub(crate) fn reminder_times(
    account: &Account,
    event: &CalendarEvent,
    raw: &Value,
    defaults: &Value,
    zone: &str,
) -> Vec<i64> {
    let google = account.provider == Provider::Gmail;
    let mut start = event.start;
    if event.all_day {
        let zone = if google {
            zone
        } else {
            raw["originalStartTimeZone"].as_str().unwrap_or(zone)
        };
        let tz = zone.parse::<chrono_tz::Tz>().or_else(|_| {
            zone.parse::<windows_timezones::WindowsTimezone>()
                .map(Into::into)
        });
        if let (Ok(tz), Some(day)) = (tz, &event.start_day) {
            use chrono::TimeZone;
            if let Ok(day) = chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d")
                && let Some(time) = day
                    .and_hms_opt(0, 0, 0)
                    .and_then(|d| tz.from_local_datetime(&d).earliest())
            {
                start = time.timestamp();
            }
        }
    }
    let mut times = if google {
        let reminders = &raw["reminders"];
        let overrides = if reminders["useDefault"] == true {
            defaults
        } else {
            &reminders["overrides"]
        };
        overrides
            .as_array()
            .into_iter()
            .flatten()
            .filter(|r| r["method"] == "popup")
            .filter_map(|r| r["minutes"].as_i64())
            .filter(|m| (0..=40320).contains(m))
            .take(5)
            .map(|m| start - m * 60)
            .collect::<Vec<_>>()
    } else if raw["isReminderOn"] == true {
        raw["reminderMinutesBeforeStart"]
            .as_i64()
            .filter(|m| (0..=40320).contains(m))
            .map(|m| vec![start - m * 60])
            .unwrap_or_default()
    } else {
        vec![]
    };
    times.sort();
    times.dedup();
    times
}
