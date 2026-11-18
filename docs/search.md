# Local mail search

Search uses SQLite FTS5 over cached subject, sender display name, sender email address, preview and downloaded text. Schema4 rebuilds the existing index once, inside a transaction. Address/header updates, body downloads and deletions update the index with their source rows. Existing bodies, pins, folders, local drafts and queued changes remain intact. No provider search request or additional search service is used. Selecting a result uses the normal lazy body-loading path.

The account picker selects one account or All accounts. This folder searches the current system/custom folder. All folders searches across folders while retaining the chosen account scope. With an empty query, the current folder stays visible. Clicking an account-specific folder selects its owner account. The clear × button cancels the pending query and restores the list without changing scope or Fuzzy preferences. Calendar search can also be cleared.

Literal/prefix matching runs first. Multiple whitespace-separated parts use AND; punctuation stays in quoted FTS phrases. SQL/FTS operators are treated as data. If there are no literal matches in the chosen scope and Fuzzy is on, the engine tries bounded one-edit corrections using indexed dictionary terms. Results show Approximate matches. A literal match on another account does not suppress scoped fallback. Existing literal matches retain priority on later pages. Results keep pin/date/ID ordering and return at most 250 headers without bodies.

One-edit matching covers letter insertion, deletion, replacement and adjacent swaps. Latin replacement/insertion letters are supported; deletion/swapping also works with Unicode characters. Common diacritics normalize for dictionary lookup. Numeric identifiers, words shorter than 4 or longer than 32 characters, multiple errors in a single component and arbitrary substrings are outside the fuzzy guarantee. Corrections are bounded, so they are not exhaustive spelling suggestions.

## Bounds

Queries allow 12 whitespace-separated parts and 1 KiB UTF-8. Up to 6 eligible components are expanded, with at most 2,048 generated forms per component, 8 indexed matches per component and 24 alternatives per part. The FTS5 vocabulary uses equality seeks, not scans over stored bodies. There is no in-memory corpus or separate body copy. The UI keeps its 140 ms debounce, cancellation tickets and latest-query guards. Search reads share one SQLite snapshot.

## Coverage and limits

Older headers backfill gradually. Full older message bodies currently download only when opened. Search cannot find text that has not been cached. Optional bounded body backfill is tracked separately. Search syntax such as from:, dates and attachment-content queries is not implemented.

Synthetic contracts cover schema3 migration/reopen, sender-only changes, body indexing, deletion, literal precedence, account/custom-folder isolation, Unicode, query bounds and stable paging. Hidden native probes cover address/typo search, scope/Fuzzy switches, clear and unified results across three accounts.

The release 100,000-message/10-account fixture measured scoped/unified email-typo p95 8.66/8.82ms, scoped/unified body-typo 22.44/60.65ms, and scoped/unified selective literal 0.051/0.035ms. Timings exclude the bridge, UI, debounce and network. Broad literal searches can take longer. [Measured data](benchmarks/2026-11-18-sender-fuzzy-search.json). No new memory/startup/power/leak qualification is claimed.

Reference: [SQLite FTS5 and indexed vocabulary queries](https://www.sqlite.org/fts5.html#the_fts5vocab_virtual_table_module).
