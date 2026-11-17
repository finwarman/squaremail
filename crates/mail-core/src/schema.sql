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
CREATE TRIGGER IF NOT EXISTS message_update AFTER UPDATE ON messages BEGIN
    INSERT INTO message_search(message_search,rowid,subject,sender,preview,text)
    VALUES('delete',old.rowid,old.subject,old.sender,old.preview,old.text);
    INSERT INTO message_search(rowid,subject,sender,preview,text)
    VALUES(new.rowid,new.subject,new.sender,new.preview,new.text);
END;
