# Release gates

The first milestone is a local reader with a reusable classic UI. The full email client remains a separate, unfinished milestone.

Before a private daily-driver release:

- Complete Microsoft 365 live consent and qualify Gmail/Workspace, Outlook.com and Microsoft 365 refresh, revocation and offline failures. Gmail and personal Outlook sign-in/cache reads have been exercised.
- Qualify the implemented Gmail history, Graph delta, staged calendar snapshots, retries, cancellation and folder reconciliation against live changes, interrupted backfill and token expiry. Synthetic HTTP/SQLite fixtures cover replay and isolation.
- Qualify sync freshness, wake/reconnect catch-up, concurrent refresh and long-run whole-process memory. Polling runs while the app is open; there is no push relay or quit-time agent.
- Qualify implemented native alerts/reminders and bounded bell history with real macOS permission/delivery and long-run service memory.
- Qualify implemented personal event creation, occurrence edits, write consent, conditional patches and offline retries against live Google/Outlook.com/Microsoft365. Add attendee/RSVP and recurring-series editing later.
- Add dense-calendar pagination and filtering before the current 2,000-event limit. Qualify recurrence, time zones and large/malformed MIME bodies with real providers.
- Qualify implemented per-message image permissions, attachment metadata, CID images and native image/PDF/DOCX/XLSX previews. Add safe saving, offline pinning and independently authorised cloud-link previews.
- Qualify implemented account disconnect, Keychain deletion and optional local-cache removal with live reconnects.
- Qualify borderless window resizing, VoiceOver, keyboard-only use, multiple displays and non-Retina scaling.
- Profile startup, list/search latency and whole-process-tree memory with a large mailbox. Compare against a named client on the same machine and workload.
- Qualify implemented mail actions, read/flag/pin, plain-text reply/reply-all/forward, local drafts/outbox, separate write/send consent and uncertain-send recovery against live providers. No real send was performed during agent qualification. Add attachments, rich text, aliases, cross-device draft sync and bulk selection later.
- Permanent deletion remains unimplemented. Keep default Delete mapped to Trash. A future permanent-delete action needs separate design and confirmation.
- Design provider rules and local sweeps separately. Provider rules have different capabilities; local rules run only while Square Mail is syncing.
- Configure signing, hardened runtime, notarization, update delivery, crash handling and an Intel build if needed.

Before opening the source:

- Keep `finwarman/squaremail` private until Fin explicitly requests public release.
- Review dependencies and licenses. Keep Windows fonts, reference-project assets, real mail, local OAuth configuration and performance inputs out of Git.
- Document contribution rules, supported platforms, security reporting and a reproducible build.

Theme design is tracked separately. Classic remains default; an optional pink hierarchy theme and later WordCraft renderer reuse are described in [design direction](design.md). No WordCraft source or build cache changes.

Tracked next: signed versioned updates with rollback and draft-safe restart; reviewed unsubscribe using provider/list headers before website fallback; tabbed and pop-out Mail/Calendar with notes, date-linked tasks and optional kanban; classic segmented sync progress with indefinite unknown totals and determinate known totals. None is included in the reader-link milestone.
