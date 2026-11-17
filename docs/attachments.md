# Attachment plan

Attachments and linked-file previews are not implemented yet. Calendar UI comes first.

Keep attachment metadata in SQLite: account/message/attachment IDs, filename, MIME type, size, content ID, local cache state and thumbnail path. Store file bytes and thumbnails on disk, with byte/count limits and eviction. The UI holds metadata and visible thumbnails only.

Fetch originals on explicit open, save or offline pin. Stream them to a temporary file, then publish the completed cache entry. Generate small image thumbnails and PDF first-page thumbnails off the UI thread. Use native Quick Look for file previews. Cancel superseded work and release previews when closed.

An attachment API does not guarantee a separate tiny preview. Gmail exposes [attachment retrieval](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get). For ordinary image/PDF attachments, plan to generate a thumbnail after downloading the file. Apple's [Quick Look Thumbnailing](https://developer.apple.com/documentation/quicklookthumbnailing) is a candidate to qualify.

OneDrive/SharePoint URLs are linked-file references. Preserve their independent access permissions. Discover file metadata, preview availability and content on explicit user action. Microsoft Graph supports [DriveItem thumbnails](https://learn.microsoft.com/en-us/graph/api/driveitem-list-thumbnails?view=graph-rest-1.0), with separate file permissions. A cloud link can change or lose access without the email changing, so cache validation needs its own version/expiry state.

Do not fetch every URL in an email or assume a mail-read token grants drive access. Inline CID images, embedded attachments, external images and linked cloud files need separate policies. Real-provider permissions, malformed files, large PDFs, helper-process memory and offline behavior remain qualification work.
