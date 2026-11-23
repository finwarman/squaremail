# Encrypted Notes backup

Notes stay ordinary local Markdown files. The optional private preview at f1nb0.dev uploads encrypted copies. Mail, calendars, OAuth tokens and attachments are excluded.

In Notes, choose **Encrypted backup…**. Create an account with a private invitation and a vault passphrase. Save the displayed account key and passphrase together in your password manager, then confirm before enabling backup. Standard native secure fields support password-manager entry; automatic 1Password matching has not been qualified. No secret belongs in chat or the public download catalog.

A second Mac needs both values under **Restore account**. Remember this device stores the unlocked vault key in a separate Keychain item. Lock forgets that key on this device and stops background work. Disconnect forgets its backup account while keeping local notes and encrypted server copies. Neither action revokes other devices. There is no passphrase reset, rotation, device revocation or account deletion interface yet. Losing both the saved key and every configured device can prevent account recovery. Losing the passphrase and every unlocked key prevents decryption.

The panel checks saved setup before offering account creation. Complete any macOS Keychain prompt to continue. A failed lookup offers **Check again** and keeps existing configuration intact. Editing and local search remain usable while access is pending.

The app checks online changes every 30 seconds, in batches of at most four notes. Local saves wake the same worker. Offline, sleep and locked states stop its work. Requests have deadlines; errors retain local edits and retry after a minute. Editing never awaits upload. Concurrent edits produce a separate conflict note. Choose **Load this note’s history** and **Restore as copy** to recover an older server version without overwriting the current note.

The personal preview allows 2,000 notes and 32 MiB of current encrypted storage. Older versions share a separate 8 MiB budget with at most 50 entries across the account. Deleted local files are restored from the server; deletion/tombstone sync is not implemented. Keep an independent backup. This is a sync/version service, not an availability guarantee.

The Rust core uses a random 256-bit vault key, Argon2id v19 (64 MiB, three passes, one lane) to wrap it, and XChaCha20-Poly1305 with random nonces. Authenticated data binds account, opaque object and revision. HMAC-SHA256 derives opaque file identities. The host sees encrypted content, wrapped keys, sizes, object identifiers and update times. It never receives the vault passphrase or plaintext note paths, titles or bodies. Local Markdown, local history and sync metadata remain plaintext under user-only permissions.

Authentication uses a random account key over HTTPS, separate from the encryption key. The backend stores its authentication hash. Conditional writes prevent stale replacement; replayed successful uploads are acknowledged. This implementation has synthetic two-device, corruption, isolation, quota and offline-conflict checks. It has not had an independent security audit and does not protect against all rollback attacks by a compromised server.
