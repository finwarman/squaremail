# Square Mail

Read README.md and docs/invariants.md before changing behavior.

- Keep ClassicKit independent of mail, persistence, providers and Rust.
- AppKit owns UI events and native controls. The Rust application API owns mail operations.
- UI code never queries SQLite, provider HTTP or Keychain directly.
- Keep I/O off the AppKit thread. Keep provider work separate from local queries.
- Keep lists bounded and body loading lazy. Preserve request-generation guards.
- Provider access is read-only until sending and state writes are explicitly designed and authorized.
- HTML must remain passive. Preserve sanitization, CSP, disabled scripts, nonpersistent storage and blocked subresources.
- Keep source, comments and replies short. No em dashes. Prefer enums over boolean parameters.
- Run scripts/check.sh for code changes. Use the release mailbox benchmark for query/storage changes.
- Do not commit credentials, real mail, Windows fonts, reference-project assets or local caches.
- Never send external messages, PR/issue comments, reviews, reactions or status updates on Fin's behalf. Prepare drafts locally.
