const HTTP = Object.freeze({ ok: 200, created: 201, bad: 400, unauthorized: 401, forbidden: 403, missing: 404, conflict: 409, large: 413, throttled: 429, unavailable: 503 });
const LIMIT = Object.freeze({ body: 1_410_000, blob: 1_400_000, page: 50, header: 2048, requests: 300, vaults: 5 });
const ID = /^[a-f0-9]{32}$/;
const OBJECT = /^[a-f0-9]{64}$/;
const TOKEN = /^[A-Za-z0-9_-]{43}$/;
const BLOB = /^[A-Za-z0-9+/]+={0,2}$/;
const PREFIX = '/notes-sync/v1';
const encoder = new TextEncoder();

function reply(value, status = HTTP.ok, extra = {}) {
 return Response.json(value, { status, headers: { 'Cache-Control': 'private, no-store', 'Content-Security-Policy': "default-src 'none'", 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'X-Robots-Tag': 'noindex, nofollow', ...extra } });
}
async function hash(value) {
 const bytes = await crypto.subtle.digest('SHA-256', encoder.encode(value));
 return Array.from(new Uint8Array(bytes), x => x.toString(16).padStart(2, '0')).join('');
}
async function body(request, limit = LIMIT.body) {
 if (Number(request.headers.get('Content-Length')) > limit) throw HTTP.large;
 const reader = request.body?.getReader();
 if (!reader) throw HTTP.bad;
 let size = 0; const chunks = [];
 while (true) {
  const { done, value } = await reader.read(); if (done) break;
  size += value.length;
  if (size > limit) { await reader.cancel(); throw HTTP.large; }
  chunks.push(value);
 }
 const bytes = new Uint8Array(size); let at = 0;
 for (const part of chunks) { bytes.set(part, at); at += part.length; }
 try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { throw HTTP.bad; }
}
function validHeader(header) {
 if (!header || Object.keys(header).sort().join(',') !== 'kdf,salt,version,wrapped' || header.version !== 1 || header.kdf !== 'argon2id-v19-m65536-t3-p1' || !BLOB.test(header.salt ?? '') || !BLOB.test(header.wrapped ?? '')) return false;
 return header.salt.length === 24 && header.wrapped.length === 96 && JSON.stringify(header).length <= LIMIT.header;
}
async function rate(request, db) {
 const minute = Math.floor(Date.now() / 60000);
 const ip = request.headers.get('CF-Connecting-IP') ?? 'local';
 const key = await hash(`notes-rate:${minute}:${ip}`);
 const value = await db.prepare('INSERT INTO rate_limits(key,count,expires) VALUES(?1,1,?2) ON CONFLICT(key) DO UPDATE SET count=count+1 RETURNING count').bind(key, minute * 60 + 120).first();
 if (value.count > LIMIT.requests) throw HTTP.throttled;
 if (value.count % 64 === 1) await db.prepare('DELETE FROM rate_limits WHERE expires<?1').bind(Math.floor(Date.now() / 1000)).run();
}
async function create(request, db) {
 const input = await body(request, 8192);
 if (!ID.test(input.id) || !TOKEN.test(input.auth) || !TOKEN.test(input.invite) || !validHeader(input.header)) throw HTTP.bad;
 const auth = await hash(`notes-auth:${input.id}:${input.auth}`);
 const existing = await db.prepare('SELECT auth_hash,header FROM vaults WHERE id=?1').bind(input.id).first();
 if (existing) {
  if (existing.auth_hash !== auth || existing.header !== JSON.stringify(input.header)) throw HTTP.conflict;
  return reply({ id: input.id }, HTTP.created);
 }
 const invite = await hash(input.invite);
 const row = await db.prepare('INSERT INTO vaults(id,auth_hash,header,invite) SELECT ?1,?2,?3,hash FROM invites WHERE hash=?4 AND expires>unixepoch() AND NOT EXISTS(SELECT 1 FROM vaults WHERE invite=?4) AND (SELECT count(*) FROM vaults)<?5 RETURNING id').bind(input.id, auth, JSON.stringify(input.header), invite, LIMIT.vaults).first();
 if (!row) throw HTTP.forbidden;
 return reply(row, HTTP.created);
}
async function authenticate(request, db) {
 const value = request.headers.get('Authorization')?.match(/^Bearer ([a-f0-9]{32})\.([A-Za-z0-9_-]{43})$/);
 if (!value) throw HTTP.unauthorized;
 const auth = await hash(`notes-auth:${value[1]}:${value[2]}`);
 const vault = await db.prepare('SELECT id,header,sequence FROM vaults WHERE id=?1 AND auth_hash=?2').bind(value[1], auth).first();
 if (!vault) throw HTTP.unauthorized;
 return vault;
}
async function object(request, db, vault, id, url) {
 if (!OBJECT.test(id)) throw HTTP.bad;
 if (request.method === 'GET') {
  const version = url.searchParams.get('version');
  if (version && !ID.test(version)) throw HTTP.bad;
  const row = version
   ? await db.prepare('SELECT id,revision,blob FROM versions WHERE vault=?1 AND id=?2 AND revision=?3 ORDER BY serial DESC LIMIT 1').bind(vault.id, id, version).first()
   : await db.prepare('SELECT id,revision,blob FROM objects WHERE vault=?1 AND id=?2').bind(vault.id, id).first();
  if (!row) throw HTTP.missing;
  return reply(row);
 }
 if (request.method !== 'PUT') throw HTTP.missing;
 const input = await body(request);
 const base = request.headers.get('If-Match');
 if ((!base && request.headers.get('If-None-Match') !== '*') || (base && !ID.test(base))) throw HTTP.bad;
 if (!ID.test(input.revision) || typeof input.blob !== 'string' || input.blob.length < 60 || input.blob.length % 4 !== 0 || input.blob.length > LIMIT.blob || !BLOB.test(input.blob)) throw HTTP.bad;
 const existing = await db.prepare('SELECT revision,blob FROM objects WHERE vault=?1 AND id=?2').bind(vault.id, id).first();
 // A lost successful PUT is acknowledged, never added to history twice.
 if (existing?.revision === input.revision) {
  if (existing.blob !== input.blob) throw HTTP.conflict;
  return reply({ id, revision: input.revision });
 }
 const row = await db.prepare(`INSERT INTO objects(vault,id,revision,sequence,blob,bytes)
  SELECT ?1,?2,?3,sequence+1,?4,?5 FROM vaults WHERE id=?1
  AND (?6 IS NOT NULL OR NOT EXISTS(SELECT 1 FROM objects WHERE vault=?1 AND id=?2))
  AND (?6 IS NULL OR EXISTS(SELECT 1 FROM objects WHERE vault=?1 AND id=?2 AND revision=?6))
  ON CONFLICT(vault,id) DO UPDATE SET revision=excluded.revision,sequence=excluded.sequence,blob=excluded.blob,bytes=excluded.bytes,updated=unixepoch()
  WHERE objects.revision=?6 RETURNING id,revision`).bind(vault.id, id, input.revision, input.blob, input.blob.length, base).first();
 if (!row) throw HTTP.conflict;
 return reply(row);
}
export default {
 async fetch(request, env) {
  try {
   const url = new URL(request.url);
   if (!url.pathname.startsWith(PREFIX + '/')) return reply({ error: 'Not found' }, HTTP.missing);
   const origin = request.headers.get('Origin');
   if (origin && origin !== 'https://f1nb0.dev') throw HTTP.forbidden;
   await rate(request, env.DB);
   if (url.pathname === PREFIX + '/vaults' && request.method === 'POST') return await create(request, env.DB);
   const vault = await authenticate(request, env.DB);
   if (url.pathname === PREFIX + '/vault' && request.method === 'GET') return reply({ id: vault.id, header: JSON.parse(vault.header), sequence: vault.sequence });
   if (url.pathname === PREFIX + '/changes' && request.method === 'GET') {
    const after = Number(url.searchParams.get('after') ?? 0);
    if (!Number.isSafeInteger(after) || after < 0) throw HTTP.bad;
    const { results } = await env.DB.prepare('SELECT id,revision,sequence FROM objects WHERE vault=?1 AND sequence>?2 ORDER BY sequence LIMIT ?3').bind(vault.id, after, LIMIT.page + 1).all();
    return reply({ items: results.slice(0, LIMIT.page), more: results.length > LIMIT.page });
   }
   const history = url.pathname.match(new RegExp(`^${PREFIX}/history/([a-f0-9]{64})$`));
   if (history && request.method === 'GET') {
    const { results } = await env.DB.prepare('SELECT revision,created FROM versions WHERE vault=?1 AND id=?2 ORDER BY serial DESC LIMIT 50').bind(vault.id, history[1]).all();
    return reply({ items: results });
   }
   const item = url.pathname.match(new RegExp(`^${PREFIX}/objects/([a-f0-9]{64})$`));
   if (item) return await object(request, env.DB, vault, item[1], url);
   throw HTTP.missing;
  } catch (error) {
   const status = Number.isInteger(error) ? error : String(error).includes('_quota') ? HTTP.large : HTTP.unavailable;
   return reply({ error: status === HTTP.conflict ? 'A newer version exists' : status === HTTP.large ? 'Backup storage or note limit reached' : status === HTTP.unauthorized ? 'Sign in to your backup account' : status === HTTP.throttled ? 'Try again later' : 'Request unavailable' }, status, status === HTTP.throttled ? { 'Retry-After': '60' } : {});
  }
 }
};
