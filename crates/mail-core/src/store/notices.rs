use super::*;
use crate::{
    calendar::{EventDetail, PendingWrite},
    notices::*,
};
use serde_json::{Value, json};

impl Store {
    pub(crate) fn prepare_notices(&self, now: i64) -> Result<()> {
        let tx = self.write_tx()?;
        tx.execute("INSERT OR IGNORE INTO notice_calendars SELECT c.account_id,c.id FROM calendar_sources c WHERE NOT EXISTS(SELECT 1 FROM notice_settings s WHERE s.account_id=c.account_id) AND EXISTS(SELECT 1 FROM calendar_events e WHERE e.account_id=c.account_id AND e.calendar_id=c.id)",[])?;
        tx.execute("INSERT OR IGNORE INTO notice_settings(account_id,since) SELECT id,?1 FROM accounts WHERE provider<>'local'",[now])?;
        tx.execute("DELETE FROM notices WHERE occurred<?1 OR rowid NOT IN(SELECT rowid FROM notices ORDER BY occurred DESC,rowid DESC LIMIT ?2)",params![now-HISTORY_SECONDS,NOTICE_LIMIT])?;
        tx.execute("DELETE FROM notice_seen WHERE created<?1 OR rowid NOT IN(SELECT rowid FROM notice_seen ORDER BY created DESC,rowid DESC LIMIT 5000)",[now-30*86400])?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn notice_setting(
        &self,
        account: Option<&str>,
        channel: NoticeChannel,
        toggle: Toggle,
    ) -> Result<()> {
        let field = channel.as_str();
        self.connection.execute(
            &format!("UPDATE notice_settings SET {field}=?2 WHERE (?1 IS NULL OR account_id=?1)"),
            params![account, toggle.enabled()],
        )?;
        Ok(())
    }
    pub(crate) fn notice_action(&self, action: NoticeAction, id: Option<&str>) -> Result<()> {
        let sql = match action {
            NoticeAction::Read => "UPDATE notices SET unread=0 WHERE (?1 IS NULL OR id=?1)",
            NoticeAction::Clear => "DELETE FROM notices WHERE (?1 IS NULL OR id=?1)",
        };
        self.connection.execute(sql, [id])?;
        Ok(())
    }
    pub(crate) fn notice_batch(&self, delivery: NoticeDelivery, now: i64) -> Result<Value> {
        let tx = self.write_tx()?;
        let mut stmt=tx.prepare("SELECT id,account_id,kind,target,calendar_id,title,detail,occurred,unread,delivered FROM notices ORDER BY occurred DESC,rowid DESC LIMIT 50")?;
        let items=stmt.query_map([],|r|Ok(json!({"id":r.get::<_,String>(0)?,"account":r.get::<_,String>(1)?,"kind":r.get::<_,String>(2)?,"target":r.get::<_,String>(3)?,"calendar":r.get::<_,Option<String>>(4)?,"title":r.get::<_,String>(5)?,"detail":r.get::<_,String>(6)?,"occurred":r.get::<_,i64>(7)?,"unread":r.get::<_,bool>(8)?,"delivered":r.get::<_,bool>(9)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
        drop(stmt);
        let banners = if matches!(delivery, NoticeDelivery::Desktop) {
            let mut eligible=tx.prepare("SELECT n.id FROM notices n JOIN notice_settings s USING(account_id) WHERE NOT EXISTS(SELECT 1 FROM account_paused p WHERE p.account_id=n.account_id) AND ((n.kind='mail' AND s.mail=1) OR (n.kind<>'mail' AND s.calendar=1))")?;
            let eligible = eligible
                .query_map([], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<std::collections::BTreeSet<_>>>()?;
            items
                .iter()
                .filter(|v| {
                    eligible.contains(v["id"].as_str().unwrap_or(""))
                        && v["delivered"] == false
                        && v["occurred"].as_i64().unwrap_or(0) >= now - 60
                        && v["kind"] != NoticeKind::Reminder.as_str()
                })
                .take(3)
                .cloned()
                .collect::<Vec<_>>()
        } else {
            vec![]
        };
        // Claim before OS submission. A crash may lose a banner, but cannot replay it at restart.
        if matches!(delivery, NoticeDelivery::Desktop) {
            tx.execute("UPDATE notices SET delivered=1 WHERE delivered=0", [])?;
        }
        let mut stmt =
            tx.prepare("SELECT account_id,mail,calendar FROM notice_settings ORDER BY account_id")?;
        let settings=stmt.query_map([],|r|Ok(json!({"account":r.get::<_,String>(0)?,"mail":r.get::<_,bool>(1)?,"calendar":r.get::<_,bool>(2)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
        drop(stmt);
        let plan = reminder_plan(&tx, now)?;
        tx.commit()?;
        Ok(json!({"items":items,"banners":banners,"planned":plan,"settings":settings}))
    }
    pub(crate) fn collect_reminders(&self, now: i64) -> Result<()> {
        let tx = self.write_tx()?;
        let values = reminders(&tx, now - LATE_SECONDS, now)?;
        for (account, calendar, id, title, due) in values {
            let key =
                crate::mime::message_id("reminder", &format!("{account}\0{calendar}\0{id}\0{due}"));
            insert_notice(
                &tx,
                &key,
                &account,
                NoticeKind::Reminder,
                &id,
                Some(&calendar),
                &title,
                "Calendar reminder",
                due,
            )?;
        }
        trim_notices(&tx)?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn event_write_alert(&self, write: &PendingWrite, error: &str) -> Result<()> {
        let change = &write.change;
        insert_notice(
            &self.connection,
            &crate::mime::message_id("write-error", &change.operation),
            &change.key.account,
            NoticeKind::CalendarUpdate,
            change.key.id.as_deref().unwrap_or(""),
            Some(&change.key.calendar),
            &change.draft.title,
            &format!("Calendar change needs review: {error}"),
            chrono::Utc::now().timestamp(),
        )?;
        trim_notices(&self.connection)
    }
    pub(crate) fn write_notice(&self, write: &PendingWrite, detail: &EventDetail) -> Result<()> {
        insert_notice(
            &self.connection,
            &crate::mime::message_id("write", &write.change.operation),
            &detail.key.account,
            NoticeKind::CalendarUpdate,
            detail.key.id.as_deref().unwrap_or(""),
            Some(&detail.key.calendar),
            &detail.draft.title,
            "Calendar change synced",
            chrono::Utc::now().timestamp(),
        )?;
        trim_notices(&self.connection)
    }
}
type ReminderRow = (String, String, String, String, i64);
fn reminders(tx: &Connection, start: i64, end: i64) -> Result<Vec<ReminderRow>> {
    let mut stmt=tx.prepare("SELECT e.account_id,e.calendar_id,e.id,e.title,r.due FROM event_reminders r JOIN calendar_events e USING(account_id,calendar_id,window,id) JOIN notice_settings s USING(account_id) WHERE r.due>?1 AND r.due<=?2 AND r.due>=s.since AND s.calendar=1 AND NOT EXISTS(SELECT 1 FROM account_paused p WHERE p.account_id=e.account_id) GROUP BY e.account_id,e.calendar_id,e.id,r.due ORDER BY r.due LIMIT 64")?;
    Ok(stmt
        .query_map(params![start, end], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })?
        .collect::<rusqlite::Result<_>>()?)
}
fn reminder_plan(tx: &Connection, now: i64) -> Result<Value> {
    let values = reminders(tx, now, now + 86400)?;
    Ok(json!(values.into_iter().take(PLAN_LIMIT as usize).map(|(account,calendar,id,title,due)|json!({"id":crate::mime::message_id("reminder",&format!("{account}\0{calendar}\0{id}\0{due}")),"account":account,"calendar":calendar,"target":id,"title":title,"due":due})).collect::<Vec<_>>()))
}
fn trim_notices(tx: &Connection) -> Result<()> {
    tx.execute("DELETE FROM notices WHERE rowid NOT IN(SELECT rowid FROM notices ORDER BY occurred DESC,rowid DESC LIMIT ?1)",[NOTICE_LIMIT])?;
    Ok(())
}
#[allow(clippy::too_many_arguments)]
fn insert_notice(
    tx: &Connection,
    id: &str,
    account: &str,
    kind: NoticeKind,
    target: &str,
    calendar: Option<&str>,
    title: &str,
    detail: &str,
    occurred: i64,
) -> Result<()> {
    let changed = tx.execute(
        "INSERT OR IGNORE INTO notice_seen VALUES(?1,?2)",
        params![id, occurred],
    )?;
    if changed == 0 {
        return Ok(());
    }
    tx.execute("INSERT OR IGNORE INTO notices(id,account_id,kind,target,calendar_id,title,detail,occurred) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",params![id,account,kind.as_str(),target,calendar,title.chars().take(2048).collect::<String>(),detail.chars().take(1024).collect::<String>(),occurred])?;
    Ok(())
}

pub(super) fn observe_mail(tx: &Connection, message: &Message, arrival: Arrival) -> Result<()> {
    if matches!(arrival, Arrival::Existing) || !message.unread {
        return Ok(());
    }
    let now = chrono::Utc::now().timestamp();
    let eligible:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM notice_settings s WHERE s.account_id=?1 AND s.mail=1 AND ?2>=s.since AND ?2>=?3 AND EXISTS(SELECT 1 FROM folders f WHERE f.message_id=?4 AND f.folder='inbox'))",params![message.account_id,message.timestamp,now-86400,message.id],|r|r.get(0))?;
    if eligible {
        insert_notice(
            tx,
            &crate::mime::message_id("mail-notice", &message.id),
            &message.account_id,
            NoticeKind::Mail,
            &message.id,
            None,
            &message.subject,
            &message.sender,
            now,
        )?;
        trim_notices(tx)?;
    }
    Ok(())
}

#[cfg(test)]
impl Store {
    pub(crate) fn seed_action_notices(&self, account: &str) {
        let now = chrono::Utc::now().timestamp();
        self.prepare_notices(now - 100).unwrap();
        for i in 0..60 {
            insert_notice(
                &self.connection,
                &format!("fixture-notice-{i}"),
                account,
                if i % 2 == 0 {
                    NoticeKind::Reminder
                } else {
                    NoticeKind::Mail
                },
                "event",
                Some("primary"),
                &format!("Synthetic alert {i}"),
                "Offline fixture",
                now - i,
            )
            .unwrap();
        }
        trim_notices(&self.connection).unwrap();
    }
}

pub(super) fn observe_event(
    tx: &Connection,
    event: &CalendarEvent,
    baseline: EventBaseline,
) -> Result<()> {
    if matches!(baseline, EventBaseline::Initial) || event.version <= 0 {
        return Ok(());
    }
    let eligible:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM notice_settings WHERE account_id=?1 AND calendar=1 AND ?2>=since)",params![event.account_id,event.version/1000],|r|r.get(0))?;
    if !eligible {
        return Ok(());
    }
    let id = crate::mime::message_id(
        "calendar-update",
        &format!(
            "{}\0{}\0{}\0{}",
            event.account_id, event.calendar_id, event.id, event.version
        ),
    );
    insert_notice(
        tx,
        &id,
        &event.account_id,
        NoticeKind::CalendarUpdate,
        &event.id,
        Some(&event.calendar_id),
        &event.title,
        "Calendar event updated",
        chrono::Utc::now().timestamp(),
    )?;
    trim_notices(tx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notices::{NoticeAction, NoticeDelivery};
    fn account(store: &Store) {
        store
            .save_account(&Account {
                id: "fixture".into(),
                email: "fin@example.test".into(),
                provider: Provider::Gmail,
            })
            .unwrap();
    }
    #[test]
    fn notices_are_bounded_and_deduped() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mail.sqlite");
        let store = Store::open(path.to_str().unwrap()).unwrap();
        account(&store);
        let now = chrono::Utc::now().timestamp();
        store.prepare_notices(now - 100).unwrap();
        for i in 0..80 {
            insert_notice(
                &store.connection,
                &format!("notice-{i}"),
                "fixture",
                NoticeKind::Mail,
                "message",
                None,
                "New mail",
                "Sender",
                now + i,
            )
            .unwrap();
            trim_notices(&store.connection).unwrap();
        }
        let value = store
            .notice_batch(NoticeDelivery::Desktop, now + 80)
            .unwrap();
        assert_eq!(value["items"].as_array().unwrap().len(), 50);
        assert_eq!(value["banners"].as_array().unwrap().len(), 3);
        store
            .pause_account("fixture", DisconnectMode::KeepCache)
            .unwrap();
        insert_notice(
            &store.connection,
            "paused-notice",
            "fixture",
            NoticeKind::Mail,
            "message",
            None,
            "New mail",
            "Sender",
            now + 81,
        )
        .unwrap();
        assert!(
            store
                .notice_batch(NoticeDelivery::Desktop, now + 81)
                .unwrap()["banners"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        store.notice_action(NoticeAction::Clear, None).unwrap();
        drop(store);
        let store = Store::open(path.to_str().unwrap()).unwrap();
        insert_notice(
            &store.connection,
            "notice-79",
            "fixture",
            NoticeKind::Mail,
            "message",
            None,
            "New mail",
            "Sender",
            now + 79,
        )
        .unwrap();
        assert!(
            store
                .notice_batch(NoticeDelivery::Desktop, now + 80)
                .unwrap()["items"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn backfill_does_not_alert() {
        let store = Store::open(":memory:").unwrap();
        account(&store);
        let now = chrono::Utc::now().timestamp();
        store.prepare_notices(now).unwrap();
        let mut mail = crate::mime::parse(
            b"From: Ada <ada@example.test>\r\nSubject: Hello\r\n\r\nBody",
            "fixture",
            "old",
        )
        .unwrap();
        mail.unread = true;
        mail.timestamp = now - 3600;
        store.save(&mail, Folder::Inbox).unwrap();
        observe_mail(&store.connection, &mail, Arrival::New).unwrap();
        assert!(
            store.notice_batch(NoticeDelivery::Quiet, now).unwrap()["items"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        mail.timestamp = now;
        observe_mail(&store.connection, &mail, Arrival::New).unwrap();
        observe_mail(&store.connection, &mail, Arrival::New).unwrap();
        assert_eq!(
            store.notice_batch(NoticeDelivery::Quiet, now).unwrap()["items"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
    #[test]
    fn reminder_plan_cancels_removed() {
        let store = Store::open(":memory:").unwrap();
        account(&store);
        let now = chrono::Utc::now().timestamp();
        store.prepare_notices(now - 100).unwrap();
        store
            .connection
            .execute(
                "INSERT INTO calendar_sources VALUES('fixture','calendar','Calendar','#000000',1)",
                [],
            )
            .unwrap();
        for i in 0..40 {
            let due = now + 60 + i;
            store.connection.execute("INSERT INTO calendar_events(account_id,calendar_id,window,id,title,start,end,all_day,location) VALUES('fixture','calendar',0,?1,'Meeting',?2,?3,0,'')",params![format!("event-{i}"),due+600,due+3600]).unwrap();
            store
                .connection
                .execute(
                    "INSERT INTO event_reminders VALUES('fixture','calendar',0,?1,?2)",
                    params![format!("event-{i}"), due],
                )
                .unwrap();
        }
        assert_eq!(
            store.notice_batch(NoticeDelivery::Quiet, now).unwrap()["planned"]
                .as_array()
                .unwrap()
                .len(),
            32
        );
        store.collect_reminders(now + 100).unwrap();
        store.collect_reminders(now + 100).unwrap();
        assert_eq!(
            store
                .notice_batch(NoticeDelivery::Quiet, now + 100)
                .unwrap()["items"]
                .as_array()
                .unwrap()
                .len(),
            40
        );
        store
            .connection
            .execute("DELETE FROM calendar_events", [])
            .unwrap();
        assert!(
            store.notice_batch(NoticeDelivery::Quiet, now).unwrap()["planned"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
}
