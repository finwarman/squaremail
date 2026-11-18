# Notifications

The toolbar bell opens a native history panel. It holds at most 50 entries for 14 days, across accounts. Entries include new inbox mail, calendar changes, reminders and edit results. Read state and deduplication survive restart. Double-click an entry to open its message or event. Pending create failures open the pending-edits panel.

The account picker scopes the New mail and Calendar reminders preferences. Mark all read and Clear history apply to the whole history. Clearing history retains a bounded deduplication ledger, so sync replay does not immediately recreate dismissed entries.

New-mail alerts apply to newly cached unread Inbox messages received since the account's notification baseline, within the last day. Existing mail and initial archive backfill are suppressed. Calendar changes wait for an initial source baseline. Reminders use Google popup/default reminders or Outlook reminder settings. Provider-expanded occurrences and source time zones determine reminder times; email reminders do not become duplicate desktop alerts.

macOS banners are off until Enable macOS alerts is selected and system permission is granted. The bell works without that permission. Each poll submits at most three recent mail/change banners and trims delivered Square Mail alerts to 50. Submission is claimed before contacting macOS to prevent replay after a crash; a crash during that small interval can lose a banner, while its bell entry remains.

One app-owned worker polls local data every 30 seconds and after sync changes, coalescing bursts to at most one poll per second. It schedules at most 32 reminders within the next 24 hours using UserNotifications. Changed, removed, disabled or disconnected events are removed from the pending OS plan on the next refresh. Recently missed reminders, up to 15 minutes late, enter the bell on wake. The history does not create one timer or task per account, message or event.

Scheduled local reminders can fire after the app quits. They reflect the last cache snapshot; remote changes require reopening/syncing the app. New-mail detection and new scheduling require the app running. There is no background mail agent or push relay. Focus modes, system notification settings and OS scheduling affect delivery.

Bounds: 50 history entries, a deduplication ledger trimmed to 5,000 keys and 30 days on each poll, 32 future OS requests and five popup reminders per occurrence. Display strings and query results are bounded. Mail/calendar data remains plaintext in the user-only local cache. Tokens never enter notification payloads.

The offline native fixture verifies the panel data, read/clear persistence and cached editor. SQLite contracts cover replay, history/plan bounds, initial mail suppression and removed reminders. Desktop permission/delivery, live provider freshness and long-run OS service memory remain qualification work.

Reference: [Apple local notifications](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app).
