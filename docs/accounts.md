# Connect an account

Live sign-in requires OAuth app registrations owned by the developer. No shared client IDs or secrets are committed. This path is implemented but has not been qualified against a real account.

## Gmail

1. Create a Google Cloud project and enable Gmail API.
2. Configure the OAuth consent screen. During private development, add your Gmail account as a test user.
3. Create a **Desktop app** OAuth client.
4. Open **Accounts**, select Gmail, and enter that client ID. Enter its desktop client secret if Google requires it.
5. Complete consent in the browser, then choose Sync.

The client requests `https://www.googleapis.com/auth/gmail.readonly`. Desktop OAuth supports a dynamic loopback port. Public distribution with this restricted scope requires Google's applicable verification process. External testing-mode refresh tokens can be short-lived, so repeated sign-in may be needed.

References: [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), [message listing](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list).

## Outlook / Microsoft 365

1. Create a Microsoft Entra app registration that permits the intended organizational and personal accounts.
2. Add a **Mobile and desktop applications** platform and register `http://localhost/callback`.
3. Enable public-client flows as required by that registration.
4. Open **Accounts**, select Outlook, and enter the Application (client) ID. Leave client secret empty.
5. Complete browser consent, then choose Sync.

Scopes are `offline_access`, `https://graph.microsoft.com/Mail.Read`, and `https://graph.microsoft.com/User.Read`. Tenant policy can require administrator consent. The loopback listener uses a dynamic port; Microsoft's localhost redirect matching ignores that port while retaining the registered path.

References: [authorization code and PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow), [redirect URI restrictions](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url), [message listing](https://learn.microsoft.com/en-us/graph/api/user-list-messages?view=graph-rest-1.0).

## Cache behavior

Choose a folder, then Sync. Each sync refreshes its latest 200 headers. A body downloads when opened and is cached locally. Sync is manual. Other folders need their own sync. The unread and starred views reflect provider flags, with no write-back. All cached mail includes only messages previously fetched by this app.

No accounts are accessed automatically from Apple Mail, browser cookies or another application's credentials. The demo never contacts either provider.
