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
