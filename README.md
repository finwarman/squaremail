# Square Mail

A native macOS email reader with a reusable Visual Basic-era UI system.

![Square Mail native reader](docs/images/squaremail.png)

The interface uses Swift and AppKit. The mail engine uses Rust. Lists, scrolling, selection, focus, text editing and window management stay native. WebKit is created only when an HTML body is requested. There is no browser application shell.

## Run

macOS 14+, Apple command-line developer tools, Rust and Swift are required. Development is currently qualified on Apple Silicon only.

```sh
./scripts/build.sh
open ".build/Square Mail.app"
```

The build creates a local ad-hoc-signed app. Xcode is not required to run the finished app. Distribution signing and notarization are not configured.

## Current reader

- Local demo mailbox, separate from personal mail.
- Import `.eml`, including MIME text/HTML alternatives and encoded headers.
- Persistent SQLite WAL cache with FTS5 prefix search.
- Native reusable rows with bounded pages and a draggable reading-pane divider.
- Side by side toolbar toggle and View menu choices for a reading pane below or on the right. The choice survives restart; the right-pane list shows sender, date, subject and preview.
- Older/Newer paging retains at most 250 message headers.
- Keyboard navigation, copy, text selection, search with ⌘F, sync with ⌘R, text/HTML with ⌘1/⌘2.
- Gmail and Microsoft Graph mail readers, browser OAuth with PKCE and state validation, Keychain tokens and refresh.
- Multiple Gmail/Outlook accounts, a unified inbox, discovered folders and resumable header backfill. Bodies download on opening and remain available offline.
- Automatic bounded mail/calendar sync while open, with wake/reconnect catch-up and persisted retries.
- Passive HTML with scripts and direct web requests blocked. Load images opts in for the current message; Hide images or changing messages resets access.
- Native image/PDF/DOCX/XLSX thumbnails and separate document previews, downloaded on request with bounded disk caching.
- Five-second idle release of the HTML renderer after returning to text.
- Native bell history with a 50-entry limit, per-account preferences and opt-in macOS alerts/reminders.
- Provider-aware calendar creation/editing with separate write consent, bounded offline queue, local drafts and conditional patches.
- Lazy native calendar UI with today highlights, month/week/day, source filters, search and agenda. One warm view pair is kept for five seconds; a bounded event snapshot survives view release. Demo mode remains separate from provider data.

See [account setup](docs/accounts.md), [architecture](docs/architecture.md), [contracts](docs/invariants.md), [performance](docs/performance.md) and [roadmap](docs/roadmap.md).

Open Calendar from its toolbar button or ⌘3. Return to Mail with ⌘4. Calendar caches, sync, editing and notifications are wired up. See [editing and write consent](docs/calendar-editing.md) and [notification behaviour](docs/notifications.md). See [calendar UI](docs/calendar.md) and [media previews and limits](docs/attachments.md).

![Square Mail calendar with sample events](docs/images/calendar.png)

## Limits

This is a reader prototype. Gmail and personal Outlook live sign-in/cache reads were exercised; Microsoft 365 consent and broader live qualification remain pending. It does not send mail. Calendar writes require separate consent; native alerts require macOS permission. New write/delivery paths have synthetic qualification; live provider and OS qualification remain pending. Header backfill is gradual, and provider reconciliation is still being qualified. Search covers downloaded headers, previews and text, not uncached provider bodies. Calendar views cap loaded events at 2,000, and account folder/source lists have explicit bounds. Dense-calendar pagination remains unfinished. Remote images are blocked by default. Media previews cap downloads at 8 MiB and support limited formats. Office packages with external relationships, macros or embedded objects are blocked. HTML formatting is simplified. There is no claim of performance parity with any other client.

Mail is stored as plaintext in `~/Library/Application Support/Square Mail/`, with user-only filesystem permissions. Tokens are stored separately in macOS Keychain. No telemetry is configured.

## UI system

`ClassicKit` is an independent Swift package product. It has no mail or Rust dependency. It provides the palette, Tahoma-first font selection, raised/inset borders, original pixel icons, buttons, title bars and native table cells. Coordinates use integral logical points; macOS draws at the display's backing scale, including 2× Retina. OS-owned sheets retain macOS styling.

Visual references: [visualbasic.world](https://visualbasic.world/), [Double Dragon Outlook Bar](https://github.com/Planet-Source-Code/vlad-vissoultchev-double-dragon-outlook-bar-control-photoshop-style-color-picker-now-witho__1-36529), and [Philip Naparan's inventory system](https://github.com/Planet-Source-Code/philip-v-naparan-a-complete-inventory-and-account-receivable-system-updated__1-62781). Their code, icons and fonts are not copied. Tahoma is used only when installed on the user's Mac.

## Check

```sh
./scripts/check.sh
```

The native integration probe starts a temporary demo mailbox and exercises the actual AppKit controller, Rust bridge, SQLite search and body reader. It uses hidden, non-activating windows and never signs in or contacts a provider. [Control checks](docs/ui-testing.md) also cover unsaved-edit prompts, local calendar drafts, menu actions and close. Provider live qualification remains a separate release gate.

`scripts/profile.py` measures native selection through body layout and draw submission, startup, and process-family footprint. It can run a 1,000-switch stress test and include WebKit helpers. See [the performance method](docs/performance.md) before comparing numbers.

Original project code is MIT licensed. The project starts private under `finwarman/squaremail`, with public release planned after the release gates are met.

The original app icon uses editable geometry in `assets/icon.json`. SVG/PNG previews are in `assets/`; the app bundles `macos/Resources/AppIcon.icns`. Run `scripts/make-icon.sh` after editing the source.
