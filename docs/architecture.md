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

The UI calls the mail application API. It does not query SQLite, HTTP or Keychain. The bridge owns JSON encoding and C string lifetimes. Rust catches panics before crossing the ABI. Each request owns a connection with a busy timeout; provider I/O holds no database transaction. Local work has a dedicated queue. Network work has a separate bounded queue, so a slow provider does not block local navigation.

The list returns summaries only and caps each page at 250 rows. Body loading is separate. Table cells are reused by AppKit. Debounced search runs on the local queue. Request revisions prevent stale list and body responses replacing newer user selections. Provider sync has bounded header workers and a fixed first-sync limit.

OAuth uses the system browser, random 256-bit state, PKCE S256, an ephemeral IPv4 loopback listener and a three-minute timeout. Credentials and refresh tokens are Keychain-only. Google and Microsoft request read-only scopes. There are no provider write endpoints.

HTML is a passive document. The Rust boundary sanitizes it. The renderer adds a restrictive CSP, disables JavaScript and blocks WebKit subresources. Explicit HTTP(S) link clicks open in the system browser. File URLs, scripts and automatic navigation are rejected. Inline attachments and external images are not rendered in this version.

The title bar is custom drawn in a square, borderless native NSWindow. Native window drag, zoom and resize remain in AppKit. Native OS sheets and menus keep system behavior. Integral logical coordinates become two physical pixels on a Retina screen. Typography is native Tahoma when available, with Verdana and Arial fallbacks.
