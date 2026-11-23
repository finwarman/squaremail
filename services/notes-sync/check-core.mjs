import { createHash,randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync,writeFileSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const dir=mkdtempSync(join(tmpdir(),'notes-core-'));
try {
 const invite=randomBytes(32).toString('base64url');const hash=createHash('sha256').update(invite).digest('hex');
 const sql=join(dir,'seed.sql');const secret=join(dir,'invite');
 writeFileSync(sql,`INSERT INTO invites VALUES('${hash}',unixepoch()+3600);`,{mode:0o600});writeFileSync(secret,invite,{mode:0o600});
 const db=spawnSync('npx',['--yes','wrangler@4','d1','execute','squaremail-notes-v1','--local','--config',new URL('./wrangler.jsonc',import.meta.url).pathname,'--file',sql],{encoding:'utf8'});
 if(db.status!==0)throw Error(db.stderr);
 const test=spawnSync('cargo',['test','--release','--workspace','--target-dir','.build/rust','backup_two_device_http','--','--ignored','--nocapture'],{env:{...process.env,SQUAREMAIL_VAULT_ENDPOINT:'http://127.0.0.1:8794/notes-sync/v1',SQUAREMAIL_VAULT_INVITE_FILE:secret},stdio:'inherit'});
 if(test.status!==0)process.exitCode=1;
} finally {rmSync(dir,{recursive:true,force:true});}
