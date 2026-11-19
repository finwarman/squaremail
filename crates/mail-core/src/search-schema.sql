DROP TRIGGER IF EXISTS message_insert;
DROP TRIGGER IF EXISTS message_update;
DROP TRIGGER IF EXISTS message_delete;
DROP TABLE IF EXISTS message_vocabulary;
DROP TABLE message_search;
DROP VIEW IF EXISTS message_search_content;
CREATE VIEW message_search_content AS SELECT rowid,
    squaremail_header_text(subject) AS subject,
    squaremail_header_text(sender) AS sender,
    sender_address,
    squaremail_header_text(preview) AS preview,
    text FROM messages;
CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
    subject,sender,sender_address,preview,text,content=message_search_content,content_rowid=rowid,tokenize='unicode61'
);
CREATE TRIGGER IF NOT EXISTS message_insert AFTER INSERT ON messages BEGIN
    INSERT INTO message_search(rowid,subject,sender,sender_address,preview,text)
    VALUES(new.rowid,squaremail_header_text(new.subject),squaremail_header_text(new.sender),new.sender_address,squaremail_header_text(new.preview),new.text);
END;
CREATE TRIGGER IF NOT EXISTS message_delete AFTER DELETE ON messages BEGIN
    INSERT INTO message_search(message_search,rowid,subject,sender,sender_address,preview,text)
    VALUES('delete',old.rowid,squaremail_header_text(old.subject),squaremail_header_text(old.sender),old.sender_address,squaremail_header_text(old.preview),old.text);
END;
CREATE TRIGGER IF NOT EXISTS message_update AFTER UPDATE ON messages
WHEN old.subject IS NOT new.subject OR old.sender IS NOT new.sender OR old.sender_address IS NOT new.sender_address OR old.preview IS NOT new.preview OR old.text IS NOT new.text BEGIN
    INSERT INTO message_search(message_search,rowid,subject,sender,sender_address,preview,text)
    VALUES('delete',old.rowid,squaremail_header_text(old.subject),squaremail_header_text(old.sender),old.sender_address,squaremail_header_text(old.preview),old.text);
    INSERT INTO message_search(rowid,subject,sender,sender_address,preview,text)
    VALUES(new.rowid,squaremail_header_text(new.subject),squaremail_header_text(new.sender),new.sender_address,squaremail_header_text(new.preview),new.text);
END;

CREATE VIRTUAL TABLE IF NOT EXISTS message_vocabulary USING fts5vocab(message_search,'row');

INSERT INTO message_search(message_search) VALUES('rebuild');
