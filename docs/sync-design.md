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

Automatic sync needs the app running. Push subscriptions, a hosted webhook relay and quit-time sync are not implemented. Calendar edits alternate with sync pages through a bounded durable queue. Bell history and opt-in native alerts/reminders are implemented; see [notifications](notifications.md). Full-history backfill can take time and should be left running. Live edge-case, freshness and long-run whole-process memory qualification remain separate release gates.

Mail actions and sends use the existing worker, alternating with calendar writes and sync pages. Pending local projections survive page replay. Unstarted action snapshots rebase onto fresh server state before cancellation, and confirmed Gmail hard-deletion tombstones clear retained pending copies once the operation is resolved. Native draft autosave uses edit versions, not body comparisons per keystroke. See [mail actions and outbox limits](mail-actions.md).

## Refresh feedback

Refresh is the single manual check action (also Command-R). It wakes the scheduler delay immediately without cancelling an active provider request. Repeated requests coalesce. Provider throttles still apply. Normal mail/calendar rounds become due about 60 seconds after completion; folder/calendar discovery repeats after 15 minutes. The worker checks due work every five idle seconds.

The button reads Checking… or Syncing… while busy. One segmented indeterminate bar stays visible across the batch and page pauses, then hides when no due work remains. Checks shorter than 200 ms do not show the bar. Fast empty automatic polls do not change the button. There is no invented percentage for unknown provider totals. A dedicated footer shows the last operation/account and processed step count, independently of reader/search status. Completion, offline, sleep and retry states have distinct text; full detail is available on hover. A completed check means no work is due now, not that all historical mail has been downloaded.

Each successful step reports whether any provider/mail/calendar lane has due work. An idle provider lane cannot hide ready queued writes. Future retries, disconnected accounts and uncertain sends do not keep the indicator spinning. Manual Refresh interrupts only the idle delay. Generation checks prevent a cancelled worker from changing its replacement. Hidden/inactive progress has no animation.

A completed Outlook catalog checkpoint starts a fresh traversal on its next round. Intermediate pages retain the prior cache and collect seen IDs; only the final calendar page reconciles absent folders/sources. Synthetic HTTP regression covers the old finished-marker/partial-traversal combination.

Current-schema connections skip schema DDL. WAL readers can open while another connection writes. Application write transactions use BEGIN IMMEDIATE before reading their snapshot, so another writer cannot make that snapshot stale before its first write. Waiting stays in the background bridge; read-only search snapshots remain deferred. No network request runs inside these transactions.


## Progressive offline bodies

Header discovery already traverses Gmail and Graph folders with durable cursors. The bounded list is a view, not a cache limit. Body backfill is enabled by default and can be paused under Tools > Cache older mail for offline search. The setting survives restarts and applies to newly connected accounts. Pausing keeps downloaded bodies and their search index.

The existing worker fetches one missing body per account step, with a 20-second cooldown. Ready catalog, recent-mail, folder and calendar jobs run first. Manual Refresh does not reset this cooldown. Accounts share one network worker; bodies are held only for the current request and released after storage. An indexed missing-body queue chooses newest uncached messages across all folders, progressing to older mail. Completed body storage is the durable checkpoint, so restart needs no in-memory message list or offset scan.

Bodies and sanitized HTML go to disk and SQLite FTS indexes the text in the same local transaction. No attachments, remote images or document previews are prefetched. Gmail may request a separate MIME text part when the provider stores it behind an attachment ID. Background responses are capped at 8 MiB and each returned text/HTML body at 4 MiB. Existing request deadlines, cancellation, consent and provider backoff remain. This can take days of open-app time for a large mailbox.

HTTP 400/404/413 and oversized bodies are deferred for a day. Repeated non-HTTP failures defer that item after three failed attempts; authentication, throttling and other HTTP failures retain normal retry behavior. Deferred metadata remains searchable, with bodies available for an explicit reader fetch. A pause or disconnect during a download rejects its save. Backfill updates only body fields, retaining read/unread holds, flags and moves. A body sync refreshes an active mail search, without reloading Calendar, notifications or the current body. Progress reports cached bodies against currently cached headers; counts can grow during discovery.

Schema 7 adds the missing-body index, retry timestamps and one saved preference. It does not rebuild FTS. No live provider request was used as agent qualification.
