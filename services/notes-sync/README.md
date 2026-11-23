# Private Notes service

Separate Worker and D1 for opt-in client-encrypted Notes. The public app catalog carries no account data. See [protocol and limits](../../docs/notes-backup.md).

`wrangler.jsonc` names the personal preview deployment. Deployment requires the owner's Cloudflare credentials. Apply migrations before deploying. Do not reuse another application's database.

Local qualification uses `wrangler dev --local --config services/notes-sync/wrangler.jsonc --port 8794`. Then run `node services/notes-sync/check.mjs` and `node services/notes-sync/check-core.mjs`. The API check resets its LOCAL fixture database. Never point it at hosted data.

`node services/notes-sync/check-hosted.mjs` explicitly creates a temporary invitation and synthetic vault against the named personal service. It tests the Rust two-device engine, then removes only its generated vault/invitation. It never reads a user's Notes directory or real Keychain.

The account key authenticates requests; the server stores only its hash. Note IDs are opaque, payloads encrypted on the Mac, conditional writes atomic in D1. Invites are one-use and expire. Current/history quotas and the invite-only five-account preview cap bound storage. Rate limits are per hashed IP/minute. This remains preview software without an independent security audit, account recovery service or deletion/rotation UI.

Owner provisioning: `node services/notes-sync/invite.mjs /private/path/invitation.txt` saves a one-use, seven-day invitation as a user-only file. It never prints the code. For this Mac, use Application Support/Square Mail/NotesBackupInvitation.txt so the setup panel can read it. Do not package invitations in releases.
