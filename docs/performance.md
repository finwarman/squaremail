# Performance

Performance against other email clients is not qualified.

The design uses AppKit table reuse, bounded pages, separate body reads, background Rust I/O, SQLite WAL and an FTS5 index. It does not instantiate WebKit during text-only startup. There are no UI transition animations.

Measure release builds. Debug memory and startup numbers are not release evidence. Record Mac model, OS version, mailbox size, warm/cold state, display scale and the complete process tree. WebKit's web-content and networking processes must be included for HTML measurements. Application RSS alone is not whole-app footprint.

Useful budgets to qualify, rather than promises:

| Operation | Target |
| --- | --- |
| Warm start to populated cached inbox | under 300 ms |
| Cached message selection | under 16 ms |
| Visible-page local query | under 16 ms |
| Search result after debounce | under 50 ms for selective queries |
| UI thread | no provider or database I/O |

The native self-test probes actual controller/bridge/cache behavior. Rust contract tests use real SQLite and MIME parsing. Live OAuth, provider latency, mailbox-scale behavior and long-run memory need separate qualification.

## First measurements, 17 November 2026

Apple M5 Max, 64 GB RAM, macOS 26.6, arm64 release build, 1400 × 920-point window at 2×. Other applications were running. These are synthetic and short-run measurements, not a daily-use qualification or a comparison with WhatsApp.

| Measurement | Result |
| --- | --- |
| 100,000-message cached inbox page, p95 | 0.31 ms |
| Selective FTS search, p95 | 0.14 ms |
| Search matching all messages, p95 | 69.91 ms |
| Cached body via Swift/Rust bridge, p95 across three runs | 0.91–1.25 ms |
| In-process initialization to cached inbox, three warm-cache runs | 367–457 ms |
| Text-only maximum RSS, without screenshot capture | 197–198 MiB |
| Text-only peak footprint reported by `/usr/bin/time -l` | 316–317 MiB |
| Text-only footprint after three seconds, `footprint` | 126 MB |

The 100,000-message probe uses a generated 42 MB SQLite cache, an existing connection, 30 timed repetitions and pages of 250 summaries. It excludes bridge decoding and UI drawing. The body probe includes opening a connection and JSON decoding but excludes text layout and screen presentation. Its demo inbox contains 40 rows. Initialization timing starts inside `main.swift`, after dynamic loading, and ends once the cached list is populated. It does not measure first photon or cold disk launch.

No WebKit renderer was created in the text-only probe. The steady footprint report attributes about 81 MB to IOSurface and 10 MB to CoreAnimation. Initial memory peaks exceed the intended low-memory goal and remain a profiling task. An HTML session additionally creates WebKit helper processes; whole-process-tree HTML memory is not qualified. Screenshot capture causes additional transient allocations and is excluded from the text-only baseline.

Run `scripts/benchmark.sh` to repeat the core and bridge probes. Raw local evidence is retained in the project recovery folder. The benchmark generates disposable mail and never contacts a provider.

## Optimisation pass

The final comparison alternated three baseline and three updated release runs. It used the same generated mailbox, 64 cached messages with bodies from 8 KiB to 1 MiB. Each run selected 200 messages through the real controller at 30 Hz, including scrolling, decoding, text layout and native draw submission. Medians across the runs:

| Measurement | Baseline | Updated |
| --- | --- | --- |
| In-process first cached body drawn/submitted | 228 ms | 188 ms |
| Launcher-observed ready file, including LaunchServices | 624 ms | 531 ms |
| Steady text process footprint after mixed-message navigation | 161 MiB | 91 MiB |
| Sequential selection to draw submission, p95 | 23.7 ms | 21.2 ms |

Launcher figures above are rounded and should be read from the accompanying JSON when reproducing a comparison. App startup excludes a cold OS cache and network sign-in. Draw submission is a CPU-side boundary, not a physical screen presentation measurement. Other applications were running; timings vary with system load. Short-message-only runs reached about 55 MiB steady footprint. Do not compare that smaller workload with the mixed-message baseline as a percentage reduction.

Switching between already-visible 8 KiB messages measured 11.0–16.1 ms p95 across three runs. The sequential mixed-body runs measured 12.3–21.8 ms p95, with a largest observed switch of 67.5 ms. The under-16-ms target is not met for every workload.

The changes replace solid panel bitmaps with reusable GPU geometry, reuse table row views, decode Rust JSON directly into the Swift response type, update cached header/body together and open the first window after its initial cached body is ready. Explicit window opening animation is disabled. Older/Newer navigation replaces a 250-header window instead of accumulating every visited page.

A pre-fix heap trace retained 1,009 row views. The corrected 1,000-switch run created 10. Its process-footprint checkpoints were 45, 90, 111 and 84 MiB at 0, 100, 500 and 1,000 switches. The final heap contained about 10.9 MB of live allocations. Allocator caches and graphics resources still change the OS footprint; this finite probe is not a proof that the whole app is leak-free.

HTML is measured separately. One active short-message run totalled about 137 MiB across the app plus WebContent, GPU and Networking helpers. Returning to text released the WKWebView after five seconds. After the idle interval, the app and an OS-retained GPU helper totalled about 94 MiB. The native self-test verifies that HTML can reopen after release. Helper attribution uses macOS responsibility information in the diagnostic script only; the app uses public APIs.

## Multi-account cache and search

A second release probe generated 100,000 short messages across ten synthetic Gmail/Outlook accounts and Inbox/Sent/Archive memberships. It makes no provider calls. These timings use an existing SQLite connection and exclude UI drawing:

| Query | p95 |
| --- | --- |
| Account inbox page | 0.39 ms |
| Unified inbox page | 0.42 ms |
| Account/folder selective search | 0.14 ms |
| Unified selective search | 0.14 ms |
| Account-wide broad match | 21.91 ms |
| Account/folder broad match | 18.45 ms |
| Unified broad match | 68.26 ms |

The synthetic corpus is smaller than a real full-body mail archive. Real provider sync, arbitrary nested folders, cold-storage search, sender-address indexing and typo tolerance remain separate qualification work. Existing FTS5 search is literal full-text/prefix search over subject, sender display name, preview and cached text. Write triggers index arrivals and body updates incrementally.

## Calendar UI

The local sample calendar is lazy-created. One release run measured 90 ms from opening Calendar to draw submission and 11.2 ms p95 over 30 month transitions. Process footprint was 50 MiB before opening, 70 MiB active and 61 MiB two seconds after closing. A separate external sample after reopening measured 72 MiB for the process family, with no WebKit helpers.

The native probe confirms that calendar and sidebar views are released over 20 open/close cycles. Allocator and graphics caches can remain after view release. These measurements use 13 sample events, warm OS caches and no provider work; they do not qualify live sync, dense calendars or long-run memory. See [the calendar evidence](benchmarks/2026-11-17-calendar.json). Add `--calendar` to the profiling command to repeat this workload.


## Account and sync milestone

The disconnected native fixture has 30,000 headers across three accounts, 300 cached 8 KiB bodies, 12 calendar sources and 2,100 generated events. The view loads at most 2,000 events. Native checks exercise account/folder isolation, unified search, plain-text selection/copy/scrolling and calendar release without provider access.

A long-paragraph body workload exposed TextKit 2 paragraph graphics surfaces. Its process footprint was about 245 MiB. Switching the native reader to TextKit 1 measured 56 MiB on the same fixture. The first TextKit 1 run measured cached switching at 17.2 ms p95. Three runs with noncontiguous layout enabled for every body measured 56.2–56.6 MiB and 18.8–19.1 ms p95. This trades memory for some layout time and still misses the 16 ms target. The current reader enables noncontiguous layout only above 64 KiB and uses explicit decoder keys; an unlocked-display rerun of those final edits remains pending. A later run overlapped checks and a locked display, so it is excluded.

The dense-calendar diagnostic measured 97 ms first open, 61.6 ms month-navigation p95, 70 MiB external family footprint and 56 MiB after closing. These were before the final source-color/formatter caching edits. They include database loading, unlike the earlier 13-event sample. Dense-calendar navigation needs further work; the two workloads are not comparable.

The final Rust-only 100,000-message probe measured an inbox page at 0.22 ms p95, selective search at 0.09 ms and an all-message match at 65.8 ms. Across ten accounts, account/unified inbox pages measured 0.23/0.24 ms, selective search 0.04/0.03 ms, broad account/folder matches 12.3/11.7 ms and a broad unified match 46.3 ms. These exclude Swift decoding, UI drawing and provider work. Full-body archives can cost more.

[Compact account evidence](benchmarks/2026-11-17-accounts.json) records the workload and limits. No finite probe proves leak freedom. Automatic sync and HTML need separate long-run process-family profiling.

## Images, documents and cached calendar toggles

An 18 November release run used the same M5 Max, 64 GB, macOS 26.6 and 2× window. The disconnected fixture contains 30,000 headers, 12 calendars and 2,100 events, with at most 2,000 loaded. One prepared event snapshot survives view release; one warm view pair is retained for five idle seconds in Mail.

| Measurement | Result |
| --- | --- |
| First dense-calendar open, including local query | 184 ms |
| Rapid calendar reopen, p95 over ten toggles | 28.5 ms |
| Month navigation, p95 over thirty transitions | 36.5 ms |
| Main process footprint before / active / five seconds after Calendar | 48.8 / 80.8 / 70.9 MiB |
| Active calendar attributed process family | 123.5 MiB |
| HTML image and document-thumbnail attributed process family | 155.8 MiB |

The media fixture uses a generated 3,200×2,400 PNG and small PDF/DOCX/XLSX documents. It verifies all four thumbnails and keeps one resized HTML image and a PDF thumbnail active. It does not contact a provider. Its diagnostic startup includes import and preview validation, so it is excluded from normal startup comparisons. Full document windows were visually checked separately.

These are single uncontended runs with warm OS caches and other apps running. Timing ends at native draw submission. Family attribution now includes Metal/Safari helpers as well as WebKit, so older WebKit-only measurements are not directly comparable. Calendar had three non-WebKit helpers; media had seven helpers, including three WebKit processes. Shared Quick Look daemon memory can fall outside the attributed family. These samples do not measure peak memory or prove leak freedom.

The current Rust-only 100,000-message probe measured inbox paging at 0.37 ms p95, selective search at 0.21 ms and an all-message match at 103.7 ms. Across ten accounts, account/unified inbox pages were 0.39/0.36 ms, selective search 0.06/0.05 ms, broad account/folder matches 18.6/16.5 ms and broad unified search 69.3 ms. Broad matches remain slower than the selective-query target. These timings exclude bridge decoding, UI and provider work.

[Compact media/calendar evidence](benchmarks/2026-11-18-media-calendar.json) records the workload and limits. Add `--calendar` or `--media-fixture /absolute/path/to/generated.eml` to the profiling command. `scripts/media-fixture.py` creates the offline media input.

## Calendar editing and bell history

The editor and notification service are created on demand. Provider JSON remains on disk in a bounded detail cache; it is not loaded with every calendar row. The bell retains 50 entries, and one worker coalesces local polling. Edits have a separate serial network queue and bounded durable storage.

An uncontended synthetic editor/bell snapshot measured 81.2 MiB across the app and one attributed helper, with no WebKit process. It predates the final notification navigation/policy fixes and later draft/control changes. It excludes live sync, desktop delivery and shared OS services outside that family. Diagnostic startup includes fixture validation and panel creation, so its startup fields are not normal launch timings. Native functional checks observed cached editor opening around 88–149 ms; those checks are not a p95 latency qualification.

The release 100,000-message probe measured inbox paging at 0.26 ms p95, selective search at 0.13 ms and a broad match at 69.4 ms. Ten-account inbox pages measured 0.28/0.30 ms for account/unified queries. Broad unified search was 55.6 ms. The small cached-reader bridge probe measured 1.01 ms p95; its one warm in-process readiness sample was 464 ms. These are different workloads, not a before/after comparison.

[Compact editing/notification evidence](benchmarks/2026-11-18-calendar-notifications.json) records the limits. `scripts/check-calendar-actions.sh` exercises cached editing, notification-to-mail navigation and bell read/clear state without consent, provider writes or OS alerts. `scripts/profile.py --calendar-actions` measures the generated action fixture. Foreground GUI qualification should move to an isolated macOS guest before routine use; a virtual monitor alone does not isolate host focus. Fin requested non-disruptive testing on 18 November.

Routine native checks now use hidden, non-activating windows. These timings are functional diagnostics, not replacements for visible draw/latency benchmarks. [Control checks and remaining visual gates](ui-testing.md) describe the boundary. No new host GUI profile was run after Fin's request.

## Reproduce

`scripts/profile.py` launches uniquely identified disposable copies of the app, uses a supplied local cache, samples process-family footprint and terminates only its own app. Use generated data:

```sh
mkdir -p artifacts/profile-data
SQUAREMAIL_PROFILE_DB="$PWD/artifacts/profile-data/mail.sqlite" cargo test --release --target-dir .build/rust seed_reader_benchmark -- --ignored --nocapture
python3 scripts/profile.py --app ".build/Square Mail.app/Contents/MacOS/SquareMail" --data artifacts/profile-data --output artifacts/profile-run --runs 3
```

Add `--visible-only`, `--stress`, `--html` or `--html-idle` for the other workloads. `--heap` saves a heap summary. Use `SQUAREMAIL_PROFILE_COUNT=512` while seeding and run the app with `--check-paging` to verify bounded Older/Newer navigation. The probes prohibit uncached provider body fetching. The compact evidence is [2026-11-17.json](benchmarks/2026-11-17.json); raw traces and preserved baseline bundles stay in the local recovery folder.

## Offline mail actions and compose

The mail-action cache projection commits before provider work. Lists retain their250-row bound; local pins have date/account indexes. Draft/outbox lists load summaries. Only one compose body is held by the UI, with version-based dirty tracking and one debounced autosave task. The existing scheduler handles bounded actions/sends without per-message workers. Calendar time updates use one minute-boundary task while Calendar is active.

The18November release core benchmark with100,000 generated messages measured inbox p95 0.316ms and selective search0.126ms. Multi-account scoped/unified inbox p95 was0.569/0.379ms; selective queries0.136/0.105ms. Broad queries ranged16.6-70.8ms. The synthetic SQLite file was63,516,672bytes, including reply headers and pin indexes. Measurements exclude bridge/UI/network work and are not a cross-client comparison.

Full hidden functional checks passed, with synthetic provider HTTP for reversible actions, reply threading, Graph202 acceptance and ambiguous-send stopping. No final visible startup/draw/whole-process-family memory or long-run power qualification was run. Earlier memory profiles do not cover this feature. See [compact evidence](benchmarks/2026-11-18-mail-actions.json), [mail limits](mail-actions.md) and [hidden test boundaries](ui-testing.md).

## Reader links, 18 November 2026

The native text formatter runs on one actor and lazily reuses its detector. A generated334,800-byte newsletter took29.17ms median and33.44ms p95 across30 release runs. This includes normalization and document construction, excludes AppKit layout/draw/network, and is not an email-switch benchmark. Links cap at128 per body. No new memory, power or leak claim is made. [Compact evidence](benchmarks/2026-11-18-reader-links.json).

Reproduce with `SQUAREMAIL_TEXT_PROFILE=1 swift test -c release --filter ReaderTextTests.testLargeBodyBounds`. The regular test checks bounds without a timing threshold.

## Reader actions, progress and palettes, 18 November 2026

Reader/global action bars reuse their native controls. Secondary actions use a temporary native overflow menu; resizing changes frames and visibility. Both palettes share fixed color tables, bevel layers and icon geometry. Theme selection applies at restart, with no observer per row. Progress uses small segmented native drawing, with150ms ticks only for visible active indeterminate work. It stops during idle, hide, app inactivity, minimization or sleep. Known image totals do not animate. No additional WebKit instance or provider polling loop is created.

Full hidden checks and Classic/Pink generated-mail renders passed. These changes have no new whole-app startup, memory, switching, power or leak qualification. Provider backfill totals remain unknown and display indeterminate progress.

## Sender and fuzzy search, 18 November 2026

The100,000-message/10-account release probe uses unique sender addresses and current FTS fields. Scoped/unified email-typo p95 is8.66/8.82ms; broad body-typo22.44/60.65ms; scoped/unified selective literal0.051/0.035ms. Broad literal matching ranges13.1-93.6ms across the fixtures. Inbox headers remain below0.6ms p95. These are SQLite query timings, excluding bridge, UI, debounce and network. The initial single-account run overlapped Swift tests, so compare it cautiously. [Measured data](benchmarks/2026-11-18-sender-fuzzy-search.json).

Fuzzy fallback uses bounded dictionary equality probes and returns header-only pages. It does not load a corpus into memory. No new whole-app startup, memory, draw/switch, power or leak qualification was run. Schema4 requires a one-time transactional rebuild of cached search fields.

## Local workspaces and suggestions,23November2026

The existing100,000-message/ten-account release fixture now also probes account-scoped recipient suggestions. Across30 warm-connection repetitions, specific-address p95 was0.653ms, a common name15.479ms and no hit0.845ms. This initial run overlapped other functional checks. It excludes the120ms typing debounce, bridge, drawing and provider work. Broad/fuzzy search timings in the concurrent run varied substantially, so it is not a regression comparison.

Notes create no editor or filesystem watcher at Mail startup. An open Notes workspace holds one body, up to2,000 bounded metadata entries and two coalesced directory watchers. Detached Calendar reuses the existing calendar view and sync coordinator. No new whole-app startup, memory, power or leak qualification is claimed. Hidden functional checks and Classic/Pink renders cover controls, focus, save conflicts, window close and local visibility changes.
