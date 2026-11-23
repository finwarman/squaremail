import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Only generated fixtures reach the hosted service. Cleanup names one generated vault.
const directory = mkdtempSync(join(tmpdir(), 'notes-hosted-'));
const config = new URL('./wrangler.jsonc', import.meta.url).pathname;
function execute(source) {
 const file = join(directory, 'fixture.sql'); writeFileSync(file, source, { mode: 0o600 });
 const result = spawnSync('npx', ['--yes', 'wrangler@4', 'd1', 'execute', 'squaremail-notes-v1', '--remote', '--config', config, '--file', file], { encoding: 'utf8' });
 assert.equal(result.status, 0, result.stderr);
}
const invite = randomBytes(32).toString('base64url');
const hash = createHash('sha256').update(invite).digest('hex');
const secret = join(directory, 'invite'); const resultFile = join(directory, 'result');
try {
 writeFileSync(secret, invite, { mode: 0o600 });
 execute(`INSERT INTO invites VALUES('${hash}',unixepoch()+3600);`);
 const result = spawnSync('cargo', ['test', '--release', '--workspace', '--target-dir', '.build/rust', 'backup_two_device_http', '--', '--ignored', '--nocapture'], {
  env: { ...process.env, SQUAREMAIL_VAULT_HOSTED: '1', SQUAREMAIL_VAULT_ENDPOINT: 'https://f1nb0.dev/notes-sync/v1', SQUAREMAIL_VAULT_INVITE_FILE: secret, SQUAREMAIL_VAULT_RESULT_FILE: resultFile }, stdio: 'inherit'
 });
 assert.equal(result.status, 0, 'Hosted synthetic two-device test failed');
} finally {
 try {
  if (existsSync(resultFile)) {
   const id = readFileSync(resultFile, 'utf8'); assert.match(id, /^[a-f0-9]{32}$/);
   execute(`DELETE FROM vaults WHERE id='${id}' AND invite='${hash}';DELETE FROM invites WHERE hash='${hash}' AND NOT EXISTS(SELECT 1 FROM vaults WHERE invite='${hash}');`);
  } else {
   execute(`DELETE FROM vaults WHERE invite='${hash}';DELETE FROM invites WHERE hash='${hash}';`);
  }
 } finally { rmSync(directory, { recursive: true, force: true }); }
}
