# Contracts

| ID | Contract | Proof |
| --- | --- | --- |
| INV-MAIL-account-isolation | Provider IDs collide safely across accounts. | store contract tests |
| INV-MAIL-restart | Imported mail and full-text results survive reopening. | store contract tests |
| INV-MAIL-upsert | Header refresh preserves an already cached body. | store contract tests |
| INV-MAIL-bounded-list | A list returns only a bounded page, without bodies. | store contract tests |
| INV-MAIL-query-literal | User search text cannot become SQL or FTS syntax. | store contract tests |
| INV-MAIL-plain-text | MIME text and HTML alternatives remain separate. | MIME tests |
| INV-MAIL-html-passive | Cached HTML excludes scripts, forms and remote resources. | HTML tests and native policy self-test |
| INV-MAIL-oauth-state | OAuth callback state must match the pending login. | OAuth callback tests |
| INV-MAIL-main-thread | Database and provider calls run off the AppKit main thread. | bridge precondition and native self-test |
| INV-MAIL-latest-selection | Stale body responses cannot replace a newer selection. | native controller generation guard |
| INV-CLASSIC-bounded-surfaces | Resizing and repainting reuse eight bevel layers, without panel bitmaps. | ClassicKit surface lifecycle test |
| INV-MAIL-idle-html | A hidden HTML renderer is released after five idle seconds and can reopen safely. | native reader self-test |
| INV-MAIL-row-reuse | Revisiting the same rows does not allocate more row views after warm-up. | native reader self-test and 1,000-switch heap probe |
| INV-MAIL-header-window | Older/Newer navigation retains only the current page, at most 250 summaries. | generated 512-message native paging probe |
| INV-CALENDAR-bounded-grid | Period/date changes reuse 42 native date targets. | ClassicKit calendar range/lifecycle test |
| INV-CALENDAR-lazy-release | Calendar views are absent during mail startup and released on returning to Mail. | native calendar probe |

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
| INV-MAIL-copy-text | The native plain reader preserves displayed/copy text and scrolls long bodies. | private-pasteboard native account probe |

The native reader defaults to text and creates WebKit only on first HTML use. Tokens live in Keychain. Mail cache is local plaintext with user-only permissions. Provider access is read-only.

The plain reader uses AppKit TextKit 1, with noncontiguous layout above 64 KiB. A long-paragraph workload exposed large TextKit 2 graphics surfaces. The native text path preserves selection, copy and scrolling. Measurement details remain in `docs/performance.md`.
