# Architecture

```text
AppKit application
  MailController       view state, request generations, keyboard actions
       |
  MailCore             typed async JSON bridge, local and network work queues
       |
  squaremail-core      request dispatch and mail use cases
       |           |
  Store              provider adapters
       |                 |
  SQLite / FTS5      OAuth / HTTP / macOS Keychain

ClassicKit             reusable AppKit components, independent of mail
ReaderView             native NSTextView; lazy passive WKWebView for HTML
```

The UI calls the mail application API. It does not query SQLite, HTTP or Keychain. The bridge owns JSON encoding and C string lifetimes. Rust catches panics before crossing the ABI. Each request owns a connection with a busy timeout; provider I/O holds no database transaction. Local work has a dedicated queue. Body downloads, background sync, browser sign-in and explicit media requests have separate bounded queues. Cancellation tokens live until their C call returns. A slow provider does not occupy the local queue.

The list returns summaries only and caps each page at 250 rows. Body loading is separate. Both table cells and row views have reuse identifiers. Debounced search runs on the local queue. Request revisions prevent stale list and body responses replacing newer user selections. Cached header/body replacement happens together, without an intermediate loading redraw. One scheduler advances bounded, resumable provider pages. New-mail work runs separately from archive backfill. Page mutations and cursor checkpoints share a transaction. Account folders and calendar windows live in the disk cache. See [sync design](sync-design.md).

OAuth uses the system browser, random 256-bit state, PKCE S256, an ephemeral IPv4 loopback listener and a three-minute timeout. Credentials and refresh tokens are Keychain-only. Default sign-in requests read-only scopes. The event editor has a separate, account-checked calendar-write consent flow. Calendar edits use a bounded durable queue and minimal conditional provider patches. Mail changes and sending have separate consent controls, bounded queues and native compose UI. SQLite projections, drafts and outbox snapshots are disk-backed; provider adapters handle MIME/threading and conditional calendar patches. See mail-actions.md.

HTML is a passive document. The Rust boundary sanitizes it. The renderer adds a restrictive CSP, disables JavaScript and blocks WebKit subresources. Explicit HTTP(S) link clicks open in the system browser. File URLs, scripts and automatic navigation are rejected. Returning to text schedules HTML renderer release after five idle seconds. Opening HTML cancels that release. Approved image resources use opaque per-message custom-scheme URLs. WebKit receives resized local PNGs through a capability map, never a remote URL or provider token. Selection changes clear the map and cancel work. Media metadata lives in SQLite; file bytes and previews live in a bounded disk cache. Image I/O downsampling and Quick Look run outside the UI I/O path. Native document previews are lazy-created and explicitly closed. See [media limits](attachments.md).

Solid panel backgrounds and bevels use reusable Core Animation geometry. They do not allocate a Retina bitmap for each nested rectangle. Native drawing remains available for snapshot capture. The initial window opens with its first cached body populated and without the default window animation. Rust responses decode directly into a typed Swift envelope instead of passing through a second JSON encoding.

The title bar is custom drawn in a square, borderless native NSWindow. Native window drag, zoom and resize remain in AppKit. Native OS sheets and menus keep system behavior. Integral logical coordinates become two physical pixels on a Retina screen. Typography is native Tahoma when available, with Verdana and Arial fallbacks.

Notifications use a bounded SQLite history and reminder plan. One native worker reads the application API and schedules UserNotifications. Views never query provider HTTP, SQLite or Keychain. Event detail reads and writes use a separate bounded queue; raw provider JSON remains outside the view model. See [editing](calendar-editing.md) and [notifications](notifications.md).

## Local workspaces

Mail and detached Calendar share the existing application controller, core and sync coordinator. The existing calendar view moves between containers. Its clock stops when hidden; close releases it. Window menu opens Mail, Calendar or Notes. Notes is lazy and uses native TextKit source editing, native Undo/find and debounced autosave.

Notes commands use a file service before opening SQLite. Files live beside the cache under `Notes`, with daily files at `Daily/YYYY-MM-DD.md`. The H1 is an editable title. Saves check a SHA256 revision, preserve up to50 recovery copies and atomically replace files. Each document is limited to1MiB; metadata listing stops at2,000 notes and reads only the first4KiB per file. One coalesced directory watcher uses at most two descriptors and stops on close. No remote notes sync, vault picker, Markdown preview or full-vault text index is included. Other editors can open the Markdown folder. Simultaneous writes from unrelated processes are not a filesystem transaction.

Compose suggestions query existing sender FTS columns and bounded recent Sent/outbox recipient metadata for the chosen sending account. They debounce for120ms, return at most10 addresses and never fetch provider contacts or mail bodies. One non-key panel serves To, CC and BCC, with explicit names/addresses, keyboard selection and cancellation guards. Coverage follows cached mail, not a complete provider address book.
