# Calendar

Calendar is a native month/week/day view backed by the account cache. Demo mode uses separate sample data. Google and personal Outlook live caches have been exercised; Microsoft 365 consent remains pending.

- Today, previous/next and mini-calendar navigation.
- Per-account calendar source toggles, visible-event search and selected-day agenda.
- `⌘3` opens Calendar; `⌘4` returns to Mail.
- Cached months remain readable offline. New months download while online.

ClassicKit's date grid stays independent of mail/providers. It reuses 42 native hit targets. Source and agenda tables reuse cells. The calendar and sidebar are created on opening, reused during rapid toggles and released after five idle seconds in Mail. Hidden HTML uses the five-second idle release.

The scheduler watches current/next month and the visible grid months, at most five active windows per source. Six recently viewed month windows are retained on disk. Provider snapshots stage on disk and reconcile only after their final page. Primary Graph calendars use calendarView delta; Google and secondary Graph calendars use bounded, provider-expanded windows with conditional retrieval where available. Server versions prevent older snapshots overwriting newer occurrences.

Timed events use UTC instants. All-day events preserve calendar dates, including standard Windows/IANA zones across DST. The provider expands recurrence and exceptions within the requested window. There is no local unbounded recurrence graph.

Current limits: at most 2,000 loaded events per visible range, 1,000 source records and 2,000 account folders. Source filtering/search currently applies to loaded visible events. Dense-calendar pagination and filtering before the limit remain unfinished. The fixed-height week/day grid shows 24 hours and the first all-day bar; the agenda includes all loaded events overlapping the selected day. Legacy custom Outlook time zones, dense schedules, recurring-series edits/deletions and VoiceOver still need live qualification.

The editor supports personal-event creation and occurrence editing, with a bounded offline queue and separate write consent. A native bell and opt-in OS reminders are implemented. Invitations/attendee editing, series-wide edits, drag/resizing, push subscriptions and sync after quitting remain unfinished. Live polling targets about a minute after a resource round completes, with backoff and wake/reconnect catch-up. Initial backfill, provider limits, sleep and OS scheduling can delay that target.

The disconnected synthetic native probe covers three account selections, nested folders, unified search, 30,000 cached headers, 12 calendar sources, a bounded dense-event load and repeated view release. See [performance](performance.md), [sync design](sync-design.md) and [account setup](accounts.md).

Rapid toggles reuse one view pair for five seconds. Later reopenings restore the last bounded event snapshot before querying SQLite. Period changes do not wait for the network. Today has a navy date/header and a shaded week/day column. A new uncached date range still needs provider sync.

See [calendar editing](calendar-editing.md) for metadata preservation, write consent, conflicts and limits. See [notifications](notifications.md) for the bounded bell, baseline suppression and scheduled reminders. Live provider write and OS delivery qualification remain under2108/2103.
