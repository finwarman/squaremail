PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
PRAGMA synchronous=NORMAL;

CREATE TABLE IF NOT EXISTS accounts (
    id TEXT PRIMARY KEY, email TEXT NOT NULL, provider TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), remote_id TEXT NOT NULL,
    sender TEXT NOT NULL, sender_address TEXT NOT NULL, recipient TEXT NOT NULL,
    subject TEXT NOT NULL, preview TEXT NOT NULL, timestamp INTEGER NOT NULL,
    unread INTEGER NOT NULL, starred INTEGER NOT NULL, has_attachments INTEGER NOT NULL,
    text TEXT, html TEXT, UNIQUE(account_id,remote_id)
);
CREATE INDEX IF NOT EXISTS messages_date ON messages(timestamp DESC,id);
CREATE INDEX IF NOT EXISTS messages_account_date ON messages(account_id,timestamp DESC,id);
CREATE TABLE IF NOT EXISTS folders (
    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    folder TEXT NOT NULL, PRIMARY KEY(message_id,folder)
);
CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
    subject,sender,preview,text,content=messages,content_rowid=rowid,tokenize='unicode61'
);
CREATE TRIGGER IF NOT EXISTS message_insert AFTER INSERT ON messages BEGIN
    INSERT INTO message_search(rowid,subject,sender,preview,text)
    VALUES(new.rowid,new.subject,new.sender,new.preview,new.text);
END;
CREATE TRIGGER IF NOT EXISTS message_delete AFTER DELETE ON messages BEGIN
    INSERT INTO message_search(message_search,rowid,subject,sender,preview,text)
    VALUES('delete',old.rowid,old.subject,old.sender,old.preview,old.text);
END;
CREATE TRIGGER IF NOT EXISTS message_update AFTER UPDATE ON messages
WHEN old.subject IS NOT new.subject OR old.sender IS NOT new.sender OR old.preview IS NOT new.preview OR old.text IS NOT new.text BEGIN
    INSERT INTO message_search(message_search,rowid,subject,sender,preview,text)
    VALUES('delete',old.rowid,old.subject,old.sender,old.preview,old.text);
    INSERT INTO message_search(rowid,subject,sender,preview,text)
    VALUES(new.rowid,new.subject,new.sender,new.preview,new.text);
END;

CREATE TABLE IF NOT EXISTS mail_folders (
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    id TEXT NOT NULL, name TEXT NOT NULL, parent_id TEXT, system TEXT,
    PRIMARY KEY(account_id,id)
);
CREATE TABLE IF NOT EXISTS mail_membership (
    account_id TEXT NOT NULL, remote_id TEXT NOT NULL, folder_id TEXT NOT NULL,
    PRIMARY KEY(account_id,remote_id,folder_id),
    FOREIGN KEY(account_id,remote_id) REFERENCES messages(account_id,remote_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS membership_folder ON mail_membership(account_id,folder_id,remote_id);
CREATE TABLE IF NOT EXISTS calendar_sources (
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    id TEXT NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL, is_primary INTEGER NOT NULL,
    PRIMARY KEY(account_id,id)
);
CREATE TABLE IF NOT EXISTS calendar_events (
    account_id TEXT NOT NULL, calendar_id TEXT NOT NULL, window INTEGER NOT NULL,
    id TEXT NOT NULL, title TEXT NOT NULL, start INTEGER NOT NULL, end INTEGER NOT NULL,
    all_day INTEGER NOT NULL, start_day TEXT, end_day TEXT, location TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(account_id,calendar_id,window,id),
    FOREIGN KEY(account_id,calendar_id) REFERENCES calendar_sources(account_id,id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS events_range ON calendar_events(start,end);
CREATE TABLE IF NOT EXISTS sync_jobs (
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind TEXT NOT NULL, resource TEXT NOT NULL, window INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT '{}', next_due INTEGER NOT NULL DEFAULT 0,
    last_success INTEGER, last_attempt INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0, error TEXT, retry_class TEXT NOT NULL DEFAULT '', viewed_at INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(account_id,kind,resource,window)
);
CREATE TABLE IF NOT EXISTS sync_seen (
    account_id TEXT NOT NULL, resource TEXT NOT NULL, window INTEGER NOT NULL,
    remote_id TEXT NOT NULL, PRIMARY KEY(account_id,resource,window,remote_id)
);
CREATE TABLE IF NOT EXISTS event_stage (
    account_id TEXT NOT NULL, calendar_id TEXT NOT NULL, window INTEGER NOT NULL,
    id TEXT NOT NULL, data TEXT NOT NULL,
    PRIMARY KEY(account_id,calendar_id,window,id)
);
CREATE TABLE IF NOT EXISTS account_paused (
    account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS message_media (
    message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    manifest TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS event_details (
    account_id TEXT NOT NULL, calendar_id TEXT NOT NULL, id TEXT NOT NULL,
    data TEXT NOT NULL, touched INTEGER NOT NULL,
    PRIMARY KEY(account_id,calendar_id,id),
    FOREIGN KEY(account_id,calendar_id) REFERENCES calendar_sources(account_id,id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS event_writes (
    operation TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    calendar_id TEXT NOT NULL, data TEXT NOT NULL, state TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0, next_due INTEGER NOT NULL DEFAULT 0,
    error TEXT, created INTEGER NOT NULL, result_id TEXT
);
CREATE INDEX IF NOT EXISTS event_writes_due ON event_writes(state,next_due);
CREATE TABLE IF NOT EXISTS event_reminders (
    account_id TEXT NOT NULL, calendar_id TEXT NOT NULL, window INTEGER NOT NULL, id TEXT NOT NULL,
    due INTEGER NOT NULL,
    PRIMARY KEY(account_id,calendar_id,window,id,due),
    FOREIGN KEY(account_id,calendar_id,window,id) REFERENCES calendar_events(account_id,calendar_id,window,id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS event_reminders_due ON event_reminders(due);
CREATE TABLE IF NOT EXISTS notice_settings (
    account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    since INTEGER NOT NULL, mail INTEGER NOT NULL DEFAULT 1, calendar INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS notices (
    id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind TEXT NOT NULL, target TEXT NOT NULL, calendar_id TEXT,
    title TEXT NOT NULL, detail TEXT NOT NULL, occurred INTEGER NOT NULL,
    unread INTEGER NOT NULL DEFAULT 1, delivered INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS notices_date ON notices(occurred DESC);
CREATE TABLE IF NOT EXISTS notice_seen (
    id TEXT PRIMARY KEY, created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS notice_calendars (
    account_id TEXT NOT NULL, calendar_id TEXT NOT NULL,
    PRIMARY KEY(account_id,calendar_id),
    FOREIGN KEY(account_id,calendar_id) REFERENCES calendar_sources(account_id,id) ON DELETE CASCADE
);
