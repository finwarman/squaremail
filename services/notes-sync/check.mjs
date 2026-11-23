import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const endpoint='http://127.0.0.1:8794/notes-sync/v1';
const config=new URL('./wrangler.jsonc',import.meta.url).pathname;
const random=(n=32)=>randomBytes(n).toString('base64url');
const id=()=>randomBytes(16).toString('hex');
const object=()=>randomBytes(32).toString('hex');
function sql(source) {
 const dir=mkdtempSync(join(tmpdir(),'notes-db-'));
 try {
  const file=join(dir,'fixture.sql');writeFileSync(file,source,{mode:0o600});
  const result=spawnSync('npx',['--yes','wrangler@4','d1','execute','squaremail-notes-v1','--local','--config',config,'--file',file],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
 } finally { rmSync(dir,{recursive:true,force:true}); }
}
const invite=random(),otherInvite=random();
const hash=x=>createHash('sha256').update(x).digest('hex');
sql(`DELETE FROM vaults;DELETE FROM invites;DELETE FROM rate_limits;INSERT INTO invites VALUES('${hash(invite)}',unixepoch()+3600),('${hash(otherInvite)}',unixepoch()+3600);`);
const a={id:id(),auth:random()},b={id:id(),auth:random()};
const header={version:1,kdf:'argon2id-v19-m65536-t3-p1',salt:randomBytes(16).toString('base64'),wrapped:randomBytes(72).toString('base64')};
async function request(path,{account,method='GET',json,headers={}}={}) {
 const response=await fetch(endpoint+path,{method,headers:{...account?{Authorization:`Bearer ${account.id}.${account.auth}`}:{},'Content-Type':'application/json',...headers},body:json?JSON.stringify(json):undefined});
 return {status:response.status,body:await response.json()};
}
assert.equal((await request('/changes')).status,401);
assert.equal((await request('/vaults',{method:'POST',json:{...a,invite:random(),header}})).status,403);
assert.equal((await request('/vaults',{method:'POST',json:{...a,invite,header},headers:{Origin:'https://other.test'}})).status,403);
assert.equal((await request('/vaults',{method:'POST',json:{...a,invite,header}})).status,201);
assert.equal((await request('/vaults',{method:'POST',json:{...a,invite,header}})).status,201);
assert.equal((await request('/vaults',{method:'POST',json:{...b,invite,header}})).status,403);
assert.equal((await request('/vaults',{method:'POST',json:{...b,invite:otherInvite,header}})).status,201);
const key=object();let revision=id();
const blob=randomBytes(160).toString('base64');
const put=(account,revision,base,body=blob)=>request('/objects/'+key,{account,method:'PUT',headers:base?{'If-Match':base}:{'If-None-Match':'*'},json:{revision,blob:body}});
assert.equal((await put(a,revision)).status,200);
assert.equal((await request('/objects/'+key,{account:b})).status,404);
assert.equal((await request('/changes',{account:b})).body.items.length,0);
assert.equal((await put(a,id(),id())).status,409);
assert.equal((await request('/objects/'+key,{account:a})).body.revision,revision);
const before=(await request('/vault',{account:a})).body.sequence;
assert.equal((await put(a,revision)).status,200);
assert.equal((await request('/vault',{account:a})).body.sequence,before);
const first=revision;
for(let n=0;n<55;n++) {const next=id();assert.equal((await put(a,next,revision)).status,200);revision=next;}
const history=(await request('/history/'+key,{account:a})).body.items;
assert.equal(history.length,50);
assert.equal((await request('/objects/'+key+'?version='+history[0].revision,{account:a})).status,200);
assert.equal((await request('/objects/'+key+'?version='+first,{account:a})).status,404);
assert.equal((await request('/objects/'+key+'?version='+history[0].revision,{account:b})).status,404);
assert.equal((await request('/changes?after=-1',{account:a})).status,400);
assert.equal((await request('/changes',{account:{...a,auth:random()}})).status,401);
assert.equal((await put(a,id(),revision,'X'.repeat(1_400_001))).status,400);
assert.equal((await request('/objects/'+object(),{account:a,method:'PUT',headers:{'If-None-Match':'*'},json:{revision:id(),blob}})).status,200);
// History is bounded by bytes as well as entry count. Replacements roll back at quota.
const large=randomBytes(750_000).toString('base64');
for(let n=0;n<12;n++) {const next=id();assert.equal((await put(a,next,revision,large)).status,200);revision=next;}
assert.ok((await request('/history/'+key,{account:a})).body.items.length<=8);
for(let n=0;n<32;n++) {
 const response=await request('/objects/'+object(),{account:a,method:'PUT',headers:{'If-None-Match':'*'},json:{revision:id(),blob:large}});
 assert.equal(response.status,200);
}
const sequence=(await request('/vault',{account:a})).body.sequence;
assert.equal((await request('/objects/'+object(),{account:a,method:'PUT',headers:{'If-None-Match':'*'},json:{revision:id(),blob:large}})).status,413);
assert.equal((await request('/vault',{account:a})).body.sequence,sequence);
console.log('Private Notes API verified: authentication, one-use invites, account isolation, conditional writes, lost-response replay and bounded history. Generated data only.');
