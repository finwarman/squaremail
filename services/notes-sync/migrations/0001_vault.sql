PRAGMA foreign_keys=ON;
CREATE TABLE invites (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL);
CREATE TABLE vaults (
 id TEXT PRIMARY KEY, auth_hash TEXT NOT NULL, header TEXT NOT NULL,
 invite TEXT NOT NULL UNIQUE REFERENCES invites(hash), sequence INTEGER NOT NULL DEFAULT 0,
 created INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE objects (
 vault TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE, id TEXT NOT NULL,
 revision TEXT NOT NULL, sequence INTEGER NOT NULL, blob TEXT NOT NULL, bytes INTEGER NOT NULL,
 updated INTEGER NOT NULL DEFAULT (unixepoch()), PRIMARY KEY(vault,id)
);
CREATE INDEX object_changes ON objects(vault,sequence);
CREATE TABLE versions (
 serial INTEGER PRIMARY KEY, vault TEXT NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
 id TEXT NOT NULL, revision TEXT NOT NULL, blob TEXT NOT NULL, bytes INTEGER NOT NULL,
 created INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX version_history ON versions(vault,id,serial DESC);
CREATE TRIGGER object_insert AFTER INSERT ON objects BEGIN
 SELECT CASE WHEN (SELECT count(*) FROM objects WHERE vault=NEW.vault)>2000 THEN RAISE(ABORT,'object_quota') END;
 SELECT CASE WHEN (SELECT sum(bytes) FROM objects WHERE vault=NEW.vault)>33554432 THEN RAISE(ABORT,'storage_quota') END;
 UPDATE vaults SET sequence=NEW.sequence WHERE id=NEW.vault;
END;
CREATE TRIGGER object_update AFTER UPDATE ON objects BEGIN
 INSERT INTO versions(vault,id,revision,blob,bytes) VALUES(OLD.vault,OLD.id,OLD.revision,OLD.blob,OLD.bytes);
 DELETE FROM versions WHERE vault=NEW.vault AND serial IN (
  SELECT serial FROM (
   SELECT serial,row_number() OVER(ORDER BY serial DESC) AS position,sum(bytes) OVER(ORDER BY serial DESC) AS total
   FROM versions WHERE vault=NEW.vault
  ) WHERE position>50 OR total>8388608
 );
 SELECT CASE WHEN (SELECT sum(bytes) FROM objects WHERE vault=NEW.vault)>33554432 THEN RAISE(ABORT,'storage_quota') END;
 UPDATE vaults SET sequence=NEW.sequence WHERE id=NEW.vault;
END;
CREATE TABLE rate_limits (key TEXT PRIMARY KEY, count INTEGER NOT NULL, expires INTEGER NOT NULL);

