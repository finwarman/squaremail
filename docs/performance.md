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
