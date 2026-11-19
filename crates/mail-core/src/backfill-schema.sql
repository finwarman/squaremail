CREATE TABLE IF NOT EXISTS backfill_settings (
    id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL
);
INSERT OR IGNORE INTO backfill_settings VALUES(1,1);
CREATE INDEX IF NOT EXISTS messages_missing_body ON messages(account_id,timestamp DESC,id DESC) WHERE text IS NULL;
CREATE TABLE IF NOT EXISTS body_deferred (
    message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    retry_after INTEGER NOT NULL
);
