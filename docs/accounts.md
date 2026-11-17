# Accounts and private OAuth setup

Accounts opens the native manager. Add/reconnect opens a system-browser OAuth flow. Choose Gmail/Workspace or Outlook.com/Live/Microsoft 365, then choose the intended browser identity. Each completed identity becomes a separate account. The account picker includes a unified view. Standard folders and discovered account folders read the local cache.

OAuth client configuration and tokens are saved in macOS Keychain. Google client JSON can be imported through Accounts, OAuth setup. Microsoft uses the public desktop Application (client) ID. The registration is reused across accounts. No browser cookies or other applications' tokens are imported.

## Google registration

1. Create a private Google Cloud project. Enable Gmail API and Google Calendar API.
2. Configure Google Auth Platform branding. Use External, Testing for the private preview and add your Google identity as a test user. Accept Google's policy yourself or explicitly authorize it.
3. Create a Desktop app OAuth client and download its JSON.
4. Accounts, OAuth setup, Import Google JSON. Then Add/reconnect, Gmail.
5. Review browser consent for read-only mail, subscribed-calendar listing and calendar events.

Scopes: `gmail.readonly`, `calendar.calendarlist.readonly`, `calendar.events.readonly`, under `https://www.googleapis.com/auth/`. Gmail's restricted scope has public-distribution verification requirements. Testing-mode refresh tokens can expire after seven days. This private setup is not a public OAuth qualification.

References: [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), [Calendar scopes](https://developers.google.com/workspace/calendar/api/auth).

## Microsoft registration

1. In Microsoft Entra, create an app registration for organizational directories **and personal Microsoft accounts**.
2. Add a Public client/native desktop redirect: `http://localhost/callback`.
3. Save the Application (client) ID through Accounts, OAuth setup. No client secret is used.
4. Add/reconnect, Outlook.com/Live/Microsoft 365. Choose the intended personal or work identity.
5. Review delegated `Mail.Read`, `User.Read`, `Calendars.Read` and `offline_access`. Organization-wide admin consent is not required by Square Mail. Tenant policy may require an administrator's separate approval.

The OAuth endpoint uses `common`, PKCE and a dynamic loopback port. Microsoft's localhost matching ignores the port while retaining the registered path. No password, device-code or client-credentials grant is used.

References: [authorization code and PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow), [redirect restrictions](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url).

## Offline and automatic sync

The cached reader opens before networking. One scheduler runs while the app is open, catches up after wake/reconnect and retries failures with persisted backoff. Normal mail/calendar polling targets about a minute after each completed resource round. Backfill, throttling, sleep and OS scheduling can delay that target. Quitting stops sync. No webhook service or quit-time background agent is installed.

Header backfill is paged and resumes after restart. New-mail work is separate from archive backfill. Gmail uses history cursors; Graph uses per-folder delta plus a bounded recent-message refresh. Bodies download when opened and remain cached. An uncached body needs an online connection. Search covers cached headers/previews and downloaded text, not unread remote bodies. It remains full-text/prefix search, without typo tolerance or sender-address indexing.

Gmail text/HTML parts are fetched without requesting binary attachment originals. Text parts have a combined 4 MiB limit. HTML remains passive. Attachment browsing/downloading is separate work.

Calendar caches cover current/next month and the visible range, with at most five actively synced month windows and six retained windows per source. A new window appears as it downloads. Google and secondary Graph calendars use staged, bounded snapshots. Primary Graph calendars use calendarView delta. Closing Calendar releases its view; the disk cache and scheduler remain. See [calendar limits](calendar.md) and [sync design](sync-design.md).

Disconnect offers Keep offline cache or Remove local cache. Both stop account sync and remove saved account tokens; provider data is unchanged. The shared OAuth app registration is kept for other accounts and reconnects.

## Qualification

Gmail and personal Outlook live login, header/body reads, folder discovery and calendar caching were exercised on 17 November 2026. Microsoft 365 browser consent is pending. This is not a daily-driver release qualification. Token refresh/revocation, network transitions, long-run sync memory and provider edge cases need further live checks. Synthetic HTTP fixtures cover page replay, moves/deletions, cursor expiry, throttling state, calendar snapshots, duplicate delta entries and floating dates across DST.

Developer setup can also use the app binary with `--import-client /absolute/google-desktop.json` or `--configure-microsoft CLIENT_ID`. These commands print no secrets. The downloaded Google file is not automatically deleted after import. Keep it outside the repository.
