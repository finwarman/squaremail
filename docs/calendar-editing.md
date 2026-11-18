# Calendar creation and editing

New event and Edit event are in the Calendar agenda header. Double-click an agenda row to edit it. The editor supports title, location, timed/all-day dates, IANA time zones and reminder changes. All-day end dates are exclusive. It shows organiser, attendee responses, meeting link and provider notes. Display names take precedence over generated Google calendar addresses.

Gmail/Google Workspace use the Google Calendar API. Outlook.com/Live and Microsoft365 use the same Microsoft Graph delegated adapter. Mail access stays read-only. Enable calendar editing opens a separate browser consent step for the selected account. It requests Google calendar.events or Microsoft Calendars.ReadWrite, alongside existing read access. Choosing a different account is rejected before replacing credentials. Existing read-only sign-ins keep working.

The editor retrieves full available event details on demand. Up to 100 detail records, each with at most 256 KiB of provider JSON, remain on disk. Cached details open offline. Refresh details fetches the current revision. A new calendar needs its permissions cached once before offline creation. Read-only sources, locked/special Google event types and meetings without organiser/modification rights are blocked.

Saving queues one durable operation, at most 50 pending edits. It does not wait for provider I/O on the UI thread. The scheduler alternates one edit with a mail/calendar sync page. Disconnected accounts keep their queued operations paused. Pending changes shows status and errors; discard removes the local operation and does not undo a remote save.

Save draft keeps an incomplete form on this Mac without write consent or provider I/O. At most 20 local drafts, each at most 320 KiB, are retained. Drafts / pending reopens or deletes them. Queuing a draft removes its local copy atomically. Saved drafts retain the original revision and provider metadata for conflict checks. They remain separate from mail composition, which is not implemented.

Closing or replacing a changed editor, quitting, and disconnecting an account offer Save draft, Discard changes or Keep editing. Refresh asks before replacing changed fields. Repeated clicks cannot start duplicate saves or consent prompts. Failed saves leave fields editable with an error. A saved local draft survives discarding later unsaved changes.

Edits fetch the current resource, compare its revision and send If-Match with a minimal PATCH. Unchanged fields are omitted. Attendee arrays, recurrence, body/online-meeting blobs, conference signatures, extended properties and unknown fields are not rewritten. Editing a location changes that location; Graph may recalculate its related locations property. Editing an expanded recurring event changes that occurrence, preserving the series.

Existing meetings require selecting the attendee-update checkbox. Google sends updates to attendees when approved; Graph applies its meeting-update rules. The application does not expose attendee-list editing or invitation composition in this milestone. Agent verification uses synthetic HTTP only and never sends a real meeting update.

Google creates use a deterministic event ID and an operation marker. Graph creates use transactionId. Retries keep those identifiers. A lost edit response is acknowledged without replay when the current revision already contains the requested values. Conflicts stop for review. Authentication/validation failures stop; transient failures back off, with at most three ordinary attempts before an uncertain state. Throttling respects Retry-After. A crash leaves a short lease before recovery. Uncertain operations require checking the provider before replacing them.

Completed receipts retain the most recent 200 operations. Each queued payload has an explicit size limit. One write worker and one bounded network queue handle editing. Local mailbox queries use a separate queue. Blocking HTTP cancellation waits for the existing bounded socket timeout; no transaction spans a request.

Limits: creation is for personal events, without attendee or recurrence creation. Series-wide editing, RSVP changes, rich description editing, attendee changes and drag/resizing remain future work. Cached pending edits are not drawn as successful provider events before acknowledgement. Legacy custom time zones and live permission/conflict/idempotency behaviour still need qualification, especially Microsoft365. The app is an ad-hoc-signed private preview.

References: [Google PATCH semantics](https://developers.google.com/workspace/calendar/api/v3/reference/events/patch), [Google conditional updates](https://developers.google.com/workspace/calendar/api/guides/version-resources), [Graph updates and meeting bodies](https://learn.microsoft.com/en-us/graph/api/event-update?view=graph-rest-1.0), [Graph creation and transactionId](https://learn.microsoft.com/en-us/graph/api/calendar-post-events?view=graph-rest-1.0).
