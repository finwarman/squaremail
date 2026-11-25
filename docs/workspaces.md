# Workspaces and notes

The Mail, Calendar and Notes tabs keep their own selection and search. **Open in window** moves Calendar or Notes into a separate window. **Dock to tabs** moves the same workspace back. Notes keeps its text, selection and Undo history during the move. Calendar keeps its date, query and agenda layout. Mail already owns the main window.

Opening an already detached workspace focuses its window. Window menu entries offer the same actions. Closing Mail leaves detached workspaces open; Quit asks about unsaved edits. Reopen Mail from Window or the Dock. Independent message tabs/windows and date-linked task boards remain planned.

## Notes as an app

**Window → Open Notes app…** or **Open Notes app ↗** in Notes opens Square Notes with its own Dock icon and Command-Tab entry. Its title-bar minimise button and Command-M minimise only Notes. Clicking its Dock icon reopens the window. Use the Dock's **Options → Keep in Dock** to pin it. Closing its last window leaves the app running; Command-Q quits it with the same unsaved-note prompt. Mail stays independent.

The companion reuses the native editor, shared Classic/Pink appearance and the same local Markdown files. It starts no Mail or Calendar views or provider schedulers. Opening it from Mail saves or prompts about the current note before closing that editor and opening the saved file. Undo history remains within each process; use the existing tab/window mode when retaining that live Undo history matters. Both modes remain available.

Only one Square app owns encrypted Notes sync at a time. The other shows that sync is managed elsewhere, while local edits/search remain available. Ownership transfers within the normal 30-second check after the owner quits. macOS may ask once for the separate Notes app to access the existing Notes Keychain item. Mail tokens remain outside the companion. Updates ship Notes inside Square Mail; the launcher asks both apps to close safely and reopens whichever were running.

## Notes

**Notes** or **Command-5** opens Markdown notes. **Today** opens the daily file. Calendar's **Daily note** opens the selected date. **New note** creates a free note. Edit the first `# heading` to rename its displayed title while keeping the daily filename. Heading, checkbox and link buttons insert Markdown source. Native Undo, Redo, Find and Command-S work in the editor. Command-Shift-F searches all notes; Command-F finds within the current note.

**Search all notes** searches titles, filenames and full Markdown content locally. Indexing runs in small batches while Notes is open. The count below the list shows pending work. Results arrive as files become indexed; typing and saves remain usable. Changed, renamed and removed files invalidate old terms. A recursive OS event stream detects in-place edits without polling. Hiding Notes pauses indexing; returning resumes pending work. No network access is needed to search.

The index covers the Notes root and Daily folder, up to 2,000 files and 1 MiB per note. Results contain at most 200 summaries. It stores searchable terms without another full copy of every body. Index and Markdown files are local plaintext, protected by user-only permissions. Oversized, invalid UTF-8 or undownloaded cloud files stay on disk and are marked unavailable. Indexing never downloads placeholders. Folder selection, arbitrary nested vaults and Markdown preview remain planned.

Notes autosave after a typing pause. A changed external file blocks replacement and keeps editor text. **Save copy** preserves both versions; **Reload** asks before discarding unsaved text. **Open folder** exposes ordinary UTF-8 `.md` files under Application Support/Square Mail/Notes. Up to 50 earlier saved contents remain in its hidden `.history` folder. Keep an independent backup.

Optional [encrypted backup](notes-backup.md) preserves offline editing, conflict copies and server history. A password manager can hold the passphrase and concealed recovery account key together. Routine sync uses Keychain, with no password-manager process or network dependency for editing/search. The private server receives encrypted Markdown, not the local search index.

## Recipient suggestions

Type two characters in To, CC or BCC. Suggestions come from senders and recent Sent/outbox recipients cached for the selected From account. The full destination address appears below its name. Use Up/Down and Enter or click to choose; Escape dismisses. Tab accepts and moves to the next field. Choosing a suggestion never sends mail.

Suggestions work offline and follow cache coverage. No provider Contacts permission or network lookup is used. Other recipient tokens remain unchanged. Existing addresses are not completed in the middle.

## Calendar visibility

The sidebar groups calendars by the connected account's domain, then its email address. Shared calendars remain under the account that supplies them. Calendar swatches match event colours. Collapse an account with its arrow; collapse does not hide its events.

All/None changes the full calendar selection. Each calendar's visible options button or right-click menu offers Show only this calendar, plus account-level show/hide. These choices apply immediately to events already on this Mac and persist across restarts. They do not unsubscribe, change provider settings or pause sync.

Apple lists accounts separately and uses calendar colours with visibility checkboxes: [account list](https://support.apple.com/guide/calendar/add-or-delete-calendar-accounts-icl4308d6701/mac), [visibility](https://support.apple.com/en-gb/guide/calendar/icl1006/mac). Google uses per-calendar menus and colours: [calendar controls](https://support.google.com/calendar/answer/37095?hl=en). Domain grouping and visible All/None controls are Square Mail's choices for a mixed-provider list.
