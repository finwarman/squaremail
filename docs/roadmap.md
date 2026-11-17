# Release gates

The first milestone is a local reader with a reusable classic UI. The full email client remains a separate, unfinished milestone.

Before a private daily-driver release:

- Qualify real Gmail, Google Workspace, Outlook.com and Microsoft 365 OAuth registrations, consent, refresh, revocation and offline failures.
- Add Gmail history and Graph delta sync, pagination, throttling, retries, cancellation and folder reconciliation. Full sync must survive interrupted downloads and token expiry.
- Prove account and folder isolation with provider HTTP contract fixtures. Cover concurrent refresh and large/malformed MIME bodies.
- Support attachment listing, safe saving and CID images. Decide explicit per-message external-image permissions.
- Add account disconnect, Keychain deletion and cache removal.
- Qualify borderless window resizing, VoiceOver, keyboard-only use, multiple displays and non-Retina scaling.
- Profile startup, list/search latency and whole-process-tree memory with a large mailbox. Compare against a named client on the same machine and workload.
- Add local draft composition, then separately design OAuth write scopes, sending, idempotency and an outbox. Current builds are read-only.
- Configure signing, hardened runtime, notarization, update delivery, crash handling and an Intel build if needed.

Before opening the source:

- Keep `finwarman/squaremail` private until Fin explicitly requests public release.
- Review dependencies and licenses. Keep Windows fonts, reference-project assets, real mail, local OAuth configuration and performance inputs out of Git.
- Document contribution rules, supported platforms, security reporting and a reproducible build.
