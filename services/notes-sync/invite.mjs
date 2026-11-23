import { createHash, randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

// Owner-only provisioning. The invitation itself never enters SQL or console output.
const output = process.argv[2];
if (!output) throw Error('Provide a private output filename');
const directory = mkdtempSync(join(tmpdir(), 'notes-invite-'));
try {
 const code = randomBytes(32).toString('base64url');
 const hash = createHash('sha256').update(code).digest('hex');
 const file = join(directory, 'invite.sql');
 writeFileSync(file, `INSERT INTO invites VALUES('${hash}',unixepoch()+604800);`, { mode: 0o600 });
 const result = spawnSync('npx', ['--yes', 'wrangler@4', 'd1', 'execute', 'squaremail-notes-v1', '--remote', '--config', new URL('./wrangler.jsonc', import.meta.url).pathname, '--file', file], { encoding: 'utf8' });
 if (result.status !== 0) throw Error(result.stderr);
 writeFileSync(resolve(output), code, { mode: 0o600, flag: 'wx' });
 console.log('Saved a private one-use invitation. It expires in seven days.');
} finally { rmSync(directory, { recursive: true, force: true }); }
