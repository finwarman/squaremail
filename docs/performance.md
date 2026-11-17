# Performance

There is no comparative performance claim yet.

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

## Reproduce

`scripts/profile.py` launches uniquely identified disposable copies of the app, uses a supplied local cache, samples process-family footprint and terminates only its own app. Use generated data:

```sh
mkdir -p artifacts/profile-data
SQUAREMAIL_PROFILE_DB="$PWD/artifacts/profile-data/mail.sqlite" cargo test --release --target-dir .build/rust seed_reader_benchmark -- --ignored --nocapture
python3 scripts/profile.py --app ".build/Square Mail.app/Contents/MacOS/SquareMail" --data artifacts/profile-data --output artifacts/profile-run --runs 3
```

Add `--visible-only`, `--stress`, `--html` or `--html-idle` for the other workloads. `--heap` saves a heap summary. Use `SQUAREMAIL_PROFILE_COUNT=512` while seeding and run the app with `--check-paging` to verify bounded Older/Newer navigation. The probes prohibit uncached provider body fetching. The compact evidence is [2026-11-17.json](benchmarks/2026-11-17.json); raw traces and preserved baseline bundles stay in the local recovery folder.
