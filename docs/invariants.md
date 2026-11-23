# Contracts

| ID | Contract | Proof |
| --- | --- | --- |
| INV-MAIL-offline-actions | Unstarted actions coalesce by read/flag/placement, persist with their projections, and survive sync replay without hard deletion. | SQLite contracts and native action probe |
| INV-MAIL-draft-revision | Bounded drafts retain their text across restart; stale revisions cannot overwrite or queue them. | SQLite draft/outbox contracts |
| INV-MAIL-send-uncertain | An interrupted or ambiguously accepted send cannot be automatically retried. | synthetic HTTP send and crash-lease contracts |
| INV-MAIL-reply-metadata | Reply-all respects Reply-To, removes self/duplicates and excludes BCC; provider threading is preserved. | MIME/provider fixtures and native compose probe |
| INV-MAIL-read-dwell | A ready unread body in the active visible reader starts one cancellable2second delay. Keep/manual-unread persists per email until explicit Mark read, including across restarts and provider refreshes; hidden/loading/other views cancel. Local queued writes preserve body/scroll and never auto-advance the Unread list. | timer lifetime/selection contracts and hidden offline dwell/override/refresh probe |
| INV-MAIL-pin | Pins are local and indexed; provider header updates retain them. | SQLite pin/query contract |
| INV-MAIL-spacing | Compact spacing removes long invisible layout padding while preserving structured indentation, short language joiners, quotes and separators; stored mail stays unchanged. | MessageText and native reader probes |
| INV-MAIL-readable-links | Shortened links retain full original targets for copy/click, make no hover request and reject active/local schemes. | MessageText and private-pasteboard native probes |
| INV-CALENDAR-clock | Clock replacement cancels its previous task and does not change the selected date; leaving Calendar stops the clock. The right agenda shows a nonselectable Now divider only for today and progress for ongoing events without losing event selection. | hidden native calendar/action probes |
| INV-MAIL-account-isolation | Provider IDs collide safely across accounts. | store contract tests |
| INV-MAIL-restart | Imported mail and full-text results survive reopening. | store contract tests |
| INV-MAIL-upsert | Header refresh preserves an already cached body. | store contract tests |
| INV-MAIL-bounded-list | A list returns only a bounded page, without bodies. | store contract tests |
| INV-MAIL-query-literal | User search text cannot become SQL or FTS syntax. | store contract tests |
| INV-SEARCH-scope | Fuzzy fallback and all-folder searches retain account/custom-folder scope, literal precedence, stable order and bounded header-only pages. | SQLite contracts and hidden account probe |
| INV-SEARCH-index | Schema5 indexes decoded subjects/sender names/previews and raw addresses/bodies atomically; updates/deletions keep it current without losing raw fields, drafts or queued work. Queries and flag/pin changes perform no decoding. | schema3/schema4 migration, decoder parity and index lifecycle contracts |
| INV-SEARCH-bounds | Input, dictionary probes and expansions are bounded; fuzzy search does not load body text into application memory. | bound/query-plan contracts and100k release benchmark |
| INV-READER-controls | Rendering/spacing/link toggles remain visible as labelled icon controls, with tooltips and current pressed/disabled states. | hidden layout/control probes |
| INV-READER-header-entities | Displayed subjects, sender names and previews decode recognized entities once, without parsing HTML or changing raw mail, addresses or targets. Work is bounded. | MessageText contracts and hidden header/row probe |
| INV-READER-preview | Row previews flatten newlines with separators without changing stored content. | MessageText contracts and native renders |
| INV-MAIL-plain-text | MIME text and HTML alternatives remain separate. | MIME tests |
| INV-MAIL-html-passive | Cached HTML excludes scripts, forms and remote resources. | HTML tests and native policy self-test |
| INV-AUTH-stable-helper | Only the certificate-pinned reader may call the stable credential helper; changed reader builds reuse credential access without UI or widening token ACLs. | signed changed-reader and rejected-caller synthetic Keychain probe in f1nb0-launcher/scripts/check.sh |
| INV-MAIL-oauth-state | OAuth callback state must match the pending login. | OAuth callback tests |
| INV-MAIL-main-thread | Database and provider calls run off the AppKit main thread. | bridge precondition and native self-test |
| INV-MAIL-latest-selection | Stale body responses cannot replace a newer selection. | native controller generation guard |
| INV-CLASSIC-bounded-surfaces | Resizing and repainting reuse eight bevel layers, without panel bitmaps. | ClassicKit surface lifecycle test |
| INV-MAIL-idle-html | A hidden HTML renderer is released after five idle seconds and can reopen safely. | native reader self-test |
| INV-MAIL-row-reuse | Revisiting the same rows does not allocate more row views after warm-up. | native reader self-test and 1,000-switch heap probe |
| INV-MAIL-header-window | Older/Newer navigation retains only the current page, at most 250 summaries. | generated 512-message native paging probe |
| INV-CALENDAR-bounded-grid | Period/date changes reuse 42 native date targets. | ClassicKit calendar range/lifecycle test |
| INV-CALENDAR-month-regions | Month dates, event rows and overflow counts occupy separate regions, including short cells and dense days. | Month geometry contract and hidden dense renders |
| INV-CALENDAR-agenda-layout | Calendar agenda resizing/orientation preserves selected date/event, cached marks and separate Mail layout; cold reopening retains calendar proportions. No layout action loads events. | hidden agenda resize/orientation/selection and release/reopen probes |
| INV-CALENDAR-lazy-release | Calendar views are absent during mail startup, reused during rapid toggles and released after five idle seconds in Mail. | native calendar probe |

| INV-SYNC-batch-feedback | Progress spans due pages/lanes, manual refresh wakes only idle waits, retries/offline/pause stop busy feedback, and stale workers cannot change replacements. | scheduler fixture, queue-readiness contract and hidden native action probe |
| INV-SYNC-catalog-round | Completed catalog markers cannot prune the next round before its final page. | Outlook multi-page HTTP/catalog regression |
| INV-MAIL-trash-catalog | Missing Outlook folder maps still permit reversible Trash moves; no hard-delete request is issued. | synthetic missing-catalog HTTP/action contract |
| INV-STORAGE-wal-writers | Current-schema readers can open during an active writer; write transactions reserve the writer before reading, preventing WAL snapshot-upgrade failures. | concurrent open/write contracts |
| INV-SYNC-page-checkpoint | Page changes and cursor advance commit together; stale cursor updates roll back. | real SQLite cursor/replay test |
| INV-SYNC-snapshot | An interrupted calendar snapshot preserves the previous offline window. | staged snapshot/restart test |
| INV-SYNC-recent-mail | New-mail work does not wait for archive backfill or erase its reconciliation markers. | synthetic Gmail HTTP history test |
| INV-SYNC-throttle | Refresh does not bypass a persisted provider throttle. | retry-state test |
| INV-SYNC-delta-order | Duplicate Graph resources preserve their final change and sparse updates. | Graph page/HTTP fixtures |
| INV-SYNC-offline-accounts | Account switching, nested folders and unified search remain bounded offline. | disconnected 30,000-header native probe |
| INV-SYNC-disconnect | Disconnected accounts cannot commit provider pages; retained caches remain readable. | SQLite disconnect/snapshot test |
| INV-CALENDAR-floating-dates | All-day dates survive time-zone and DST conversion. | Google/Graph date fixtures |
| INV-CALENDAR-window-cache | Calendar source caches retain at most six month windows. | window eviction test |
| INV-MAIL-reading-layout | Divider and window resizing fill both viewports; changing orientation preserves the selected message and bounded page. | native reader resize/layout probe |
| INV-UI-action-scope | Message actions remain in the selected reader, with current enabled/label states in narrow overflow menus; global navigation does not retarget them. | ClassicKit overflow and hidden native layout/action probes |
| INV-UI-progress | Unknown totals stay indeterminate; known totals clamp safely. Idle sync retains a muted static track. Idle/hidden/inactive/sleeping progress has no animation work. Cancellation and stale results cannot restore previous selection progress. | ClassicKit progress and hidden reader/media action probes |
| INV-UI-appearance | Classic is default. Saved appearance applies before constructing views on restart; text/selection contrast remains readable in both palettes. Classic auxiliary panels retain a light native appearance under a dark host. | palette contrast and hidden appearance-menu probes |
| INV-MEDIA-opt-in | Default HTML makes no image request; approved resources are scoped to the selected message and cleared on selection change. | native image-delivery probe and sanitizer contracts |
| INV-MEDIA-bounds | File downloads, image references, pixels and disk cache have explicit bounds. | cache/URL contracts and native downsampling probe |
| INV-MEDIA-office | Office previews reject external relationships, XML document types, macros and excessive expansion. | XML contracts and native Office fixtures |
| INV-MAIL-copy-text | The native plain reader preserves displayed/copy text and scrolls long bodies. | private-pasteboard native account probe |

| INV-CALENDAR-edit-metadata | An edit changes only selected fields, preserving attendee, recurrence, conferencing and unknown provider fields. | provider patch and native editor contracts |
| INV-CALENDAR-edit-conflict | Changed revisions block writes; lost successful edits are acknowledged without repeating them. | synthetic conditional HTTP fixtures |
| INV-CALENDAR-edit-queue | Pending edits, payloads, detail caches and completed receipts are bounded and survive restart. | real SQLite edit queue contracts |
| INV-CALENDAR-local-draft | Local drafts survive restart, remain bounded and follow the selected account; queuing removes the draft atomically. | SQLite draft contracts |
| INV-UI-editor-close | Unsaved calendar fields require a close choice; cancellation and failed saves restore usable controls. | hidden native control probe |
| INV-UI-background-check | Integration windows remain hidden and non-activating; scripted dialogs never request real provider or OS permission. | hidden native control probe |
| INV-NOTICE-bounded | History and future OS reminder plans remain bounded. | SQLite/native notification probes |
| INV-NOTICE-replay | Baselines suppress old mail; read/clear state and deduplication survive restart. | SQLite replay/native probes |
| INV-NOTICE-permission | The bell works without permission; system permission is requested only on explicit enable. | native action boundary and offline probe |

The native reader defaults to text and creates WebKit only on first HTML use. Tokens live in Keychain. Mail cache is local plaintext with user-only permissions. Mail changes/sending require separate consent and queued user actions. Enabled automatic reading queues read status after a visible dwell. Calendar writes require their own consent and a user-queued edit.

The plain reader uses AppKit TextKit 1, with noncontiguous layout above 64 KiB. A long-paragraph workload exposed large TextKit 2 graphics surfaces. The native text path preserves selection, copy and scrolling. Measurement details remain in `docs/performance.md`.

| INV-UI-cursor-sparkles | Decoration defaults off, uses bounded particles/lifetime, passes events through, respects Reduce Motion and stops timers while idle/hidden. Disable/destruction releases event/notification observers. | shared model, repaint-expiry and native lifecycle tests |

| INV-SYNC-body-backfill | One missing body per account step, with a 3-second cooldown and recent resources first. Pause, disconnect and cancellation reject stale saves. Bodies/indexes/checkpoints commit together; failures defer without inventing cached content. No attachment/image prefetch or UI network wait. | synthetic provider GETs, offline restart/search, priority/cooldown/pause rollback and native setting probe |
| INV-OAUTH-release-config | Fresh installs use bounded signed desktop metadata; existing overrides win, Keychain errors stay visible, and account tokens/endpoints cannot enter the release resource. Normal sign-in shows no developer fields. | Rust config/precedence contracts, packaging gate and native setup qualification |

| INV-MAIL-action-selection | Successful placement actions advance in current visible order, with previous-row/page fallback. New arrivals do not select the head; newer selection/scope wins. Failed/cancelled actions keep selection. Unread automatic-read clearing stays separate. | hidden260message offline repeated-action and navigation probe |

| INV-MAIL-queued-feedback | Queueing closes compose before focusing the outbox on the correct send/account. Refresh retains the selected error/status. Bounded accepted receipts omit bodies and cannot be retried as pending sends. | native queued-focus/refresh probe and receipt bound contract |

| INV-MAIL-outbox-signin | Outbox sign-in names its account/access, survives refresh/reopen, shares one cancellable task with the toolbar, and recovers on completion/error/cancel without changing queued mail or accepted-send status. No extra polling. | hidden sign-in banner/control and cancellation probes |

| INV-MAIL-bulk-undo | Up to100 selected headers change atomically across accounts. One bounded undo entry restores unstarted lane work or queues its inverse after success. In-flight/changed messages reject the entire undo. No hard deletes or send undo. | real SQLite rollback/coalescing/restart and synthetic provider inverse contracts; hidden native range/Delete/responder probes |
| INV-UI-list-selection | Shift/Command selection stays within the bounded page. Delete acts only through the list responder, mixed-account Move is disabled, multi-selection cannot start body reads/dwell/Reply, and refresh/orientation retain selected IDs. | hidden native bulk/action-navigation probe |
| INV-UI-compose-save | Shared rectangular caption/actions retain native editing and close choices. Autosave captures a versioned snapshot without moving focus or disabling typing; completion cannot mark newer edits saved. | hidden concurrent-edit/autosave/resize/close probe |

| INV-MAIL-trash-visibility | Trash is excluded from normal folders and smart Unread/Starred scopes, including literal/fuzzy queries, without removing stars or unrelated memberships. Explicit Trash and All cached mail remain searchable; Undo restores visibility. | real SQLite smart-folder/replay and hidden Starred bulk Delete/Undo probes |
| INV-UI-action-feedback | Local writes immediately dim affected rows and show Saving; completion/failure clears pending state. Completed sends are optional history with no Retry/Cancel, separate from an empty queue. | hidden native pending-row and accepted-history probes |
