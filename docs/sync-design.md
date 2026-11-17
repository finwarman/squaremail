# Offline sync

```text
AppKit views -> MailCore application bridge -> Rust commands
                      |                          |
               local serial queue          Store / provider adapters
               body queue (2)               SQLite WAL / pooled HTTP / Keychain
               sync queue (1)
               login queue (1)
```

Cache reads never wait in a provider queue. The window opens with its cached body before networking starts. One app-owned scheduler rotates account/resource jobs. Each operation requests one bounded page, uses a 25-second work budget and 12-second HTTP timeout, and holds no database transaction across HTTP. Browser sign-in has a separate three-minute listener timeout. Queued/cancelled requests retain their cancellation token until the C call exits; each token and response has one owner.

Gmail backfills 20 summaries per page. An independent recent/history cursor follows new mail while the archive fills. Graph backfills folder delta pages and refreshes the latest 100 messages independently. Metadata is disk-backed; the UI retains at most 250 summaries. Bodies are lazy. No thread or timer is retained per account or message. HTTP connections are pooled. Refresh-token locks are per account, with weak registry entries pruned on use.

Gmail history reconciles labels and deletion. Graph uses immutable message IDs and folder-scoped delta links. Opaque continuation URLs must keep their expected provider origin and path. Page mutations and cursor advancement commit together, with a cursor compare-and-swap. Failed/interrupted pages replay. Expired cursors start a rescan while keeping offline data; absent memberships are reconciled only after the scan completes. New-mail updates protect messages discovered during backfill from premature reconciliation.

Read/unread-only metadata refreshes do not rebuild the full-text index. Schema upgrades run once in a writer transaction. Cache-file creation is atomic and does not truncate another request's database. Mail and calendar keys include the account, even when providers reuse remote IDs.

Calendars are cached by source and UTC month. Current/next month and visible grid months are active, at most five windows. Six windows per source are retained on disk. Older inactive windows make no provider requests. Primary Graph calendars use calendarView delta. Google and secondary Graph calendars use provider-expanded, bounded snapshots, with conditional retrieval where available. Snapshot rows stage on disk and replace missing events only after every page arrives. Remote event versions keep overlapping windows consistent. All-day dates remain floating dates; standard Windows/IANA zones handle DST. Legacy custom Outlook zones are not qualified.

Reconnect and manual refresh may retry network failures immediately, while respecting provider throttling and authentication failures. Backoff persists across restart. Background errors update status without modal alerts. Reachability state comes from the network monitor, not from an individual API error. Sleep cancels outstanding work; wake requests catch-up. Cancelling an in-flight blocking HTTP call stops subsequent work and commits, but socket teardown can wait for its bounded timeout.

Automatic sync needs the app running. Push subscriptions, a hosted webhook relay, quit-time sync, notification delivery, composing and remote writes are not implemented. Full-history backfill can take time and should be left running. Live edge-case, freshness and long-run whole-process memory qualification remain separate release gates.
