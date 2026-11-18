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

OAuth uses the system browser, random 256-bit state, PKCE S256, an ephemeral IPv4 loopback listener and a three-minute timeout. Credentials and refresh tokens are Keychain-only. Google and Microsoft request read-only scopes. There are no provider write endpoints.

HTML is a passive document. The Rust boundary sanitizes it. The renderer adds a restrictive CSP, disables JavaScript and blocks WebKit subresources. Explicit HTTP(S) link clicks open in the system browser. File URLs, scripts and automatic navigation are rejected. Returning to text schedules HTML renderer release after five idle seconds. Opening HTML cancels that release. Approved image resources use opaque per-message custom-scheme URLs. WebKit receives resized local PNGs through a capability map, never a remote URL or provider token. Selection changes clear the map and cancel work. Media metadata lives in SQLite; file bytes and previews live in a bounded disk cache. Image I/O downsampling and Quick Look run outside the UI I/O path. Native document previews are lazy-created and explicitly closed. See [media limits](attachments.md).

Solid panel backgrounds and bevels use reusable Core Animation geometry. They do not allocate a Retina bitmap for each nested rectangle. Native drawing remains available for snapshot capture. The initial window opens with its first cached body populated and without the default window animation. Rust responses decode directly into a typed Swift envelope instead of passing through a second JSON encoding.

The title bar is custom drawn in a square, borderless native NSWindow. Native window drag, zoom and resize remain in AppKit. Native OS sheets and menus keep system behavior. Integral logical coordinates become two physical pixels on a Retina screen. Typography is native Tahoma when available, with Verdana and Arial fallbacks.
