# Message images and attachment previews

Remote content stays blocked by default. In HTML mode, Load images fetches supported image references for this message. Hide images clears access. Moving to another message or restarting resets approval, even when files remain cached. Scripts, forms, frames, fonts and direct WebKit web requests remain blocked. Explicit link clicks still open the system browser.

The app discovers fresh HTML through the provider when an older sanitized cache has no image references. Gmail, Outlook and imported MIME attachments have separate account/message/asset IDs. CID references can use known inline attachments. HTML images are replaced with opaque, per-message local resource URLs. WebKit receives normalized PNGs only. Fixed table widths/heights and cell spacing are overridden to reduce newsletter gaps when content is blocked; original newsletter styling is not preserved.

Newly sanitized blocked HTML keeps a small Image blocked marker, with no image URL or sender-specified geometry. Older caches that already removed image tags cannot reconstruct their positions. Plain-text gaps can instead come from invisible preheader padding; Compact spacing handles that separately.

## Bounds

- At most 12 image references per message and 32 attachment metadata entries.
- At most 8 MiB per downloaded file. Listing does not issue binary attachment retrieval requests. Provider message responses can include small inline parts.
- Public HTTPS image URLs only, with no credentials, cookies or referrer. Redirects, custom ports and private/reserved destinations are rejected. DNS addresses are checked and pinned to the connection. DNS has one bounded worker and a three-second wait; image HTTP has a ten-second timeout.
- One media download queue and one native thumbnail worker. Selection changes cancel subsequent work and discard stale results. In-flight blocking work can finish at its deadline.
- Images above 40 million source pixels are rejected. Image I/O downsamples the first frame to 1,024 pixels for email images or 320 pixels for thumbnails. Animations do not run.
- The per-mailbox disk cache targets 128 MiB and 512 files, evicting cached files as the budget fills. In-flight writes can briefly exceed the target. Visible table cells hold small thumbnails; originals are not retained in UI memory.
- Disconnect with Remove local cache also removes this account's media files.

## Attachments

Attachments lists metadata. Load preview downloads a supported file and generates its thumbnail. PDF, DOCX and XLSX also offer Open preview in a lazy native Quick Look window. Closing the window, changing messages or leaving the reader closes its preview view. Quick Look thumbnail requests have a ten-second timeout and cancellation. macOS helper caches can remain after the view closes.

DOCX/XLSX packages are limited to 2,048 entries and 32 MiB expanded content. External relationships, encrypted packages, XML document types, macros and embedded objects are blocked. This includes otherwise ordinary Office files containing external hyperlinks. Legacy DOC/XLS and macro-enabled formats are unsupported. Native preview fidelity and complex real documents need further qualification. No WordCraft/ArtCraft engine is bundled; it remains a possible fallback.

Gmail and personal Outlook metadata discovery were exercised. An Outlook attachment was downloaded and thumbnailed. Generated native fixtures cover raster downsampling, PDF/DOCX/XLSX thumbnails, local image delivery and permission reset. Long-run helper memory, malformed documents and Microsoft365 remain release qualification work.

Fetching a remote image can disclose the open and IP address to its server. These controls do not remove tracking from an approved request. Files are local plaintext with user-only permissions.

## Deferred

OneDrive/SharePoint/Google Drive URLs remain links. They are not downloaded automatically and mail-read consent does not imply drive access. Linked-file metadata, thumbnails and independent permissions remain work under2098. Attachment saving, offline pinning, additional formats and per-sender image rules are not implemented.

References: [Gmail attachments](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get), [Graph attachments](https://learn.microsoft.com/en-us/graph/api/attachment-get?view=graph-rest-1.0), [Image I/O](https://developer.apple.com/documentation/imageio), [Quick Look UI](https://developer.apple.com/documentation/quicklookui/).
