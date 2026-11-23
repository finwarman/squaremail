# Square Mail

A native macOS mail and calendar client with a Visual Basic-era interface. Swift/AppKit UI, Rust core and local SQLite search. Classic and Pink themes.

[Download the launcher](https://f1nb0.dev/apps/) · [Screenshots](docs/images/) · [Design](docs/design.md)

- Gmail and Outlook.com/Live/Microsoft 365 accounts, folders and a unified inbox.
- Offline reading, fuzzy search, gradual body caching and on-demand attachments.
- Calendars, reminders, drafts, replies and reversible mail actions.
- Separate Calendar windows, local daily Markdown notes and cached recipient suggestions.

Preview software for macOS 14+. Apple Silicon is qualified; broader provider and live write testing remains open. Gmail preview sign-in requires the test audience. Mail is cached locally in plaintext; tokens use Keychain. Remote images are blocked by default.

## Build

Requires Rust, Swift and Apple command-line developer tools.

```sh
SQUAREMAIL_ADHOC=1 ./scripts/build.sh
open ".build/Square Mail.app"
SQUAREMAIL_ADHOC=1 ./scripts/check.sh
```

Source builds need [your own OAuth setup](docs/accounts.md). Ad-hoc signing may prompt for Keychain access. Publisher signing and app registrations are not included.

[Windows and notes](docs/workspaces.md) · [Architecture](docs/architecture.md) · [Contracts](docs/invariants.md) · [Limits and roadmap](docs/roadmap.md) · [Shared theme source](ui/README.md)

MIT licensed. Icons and UI artwork are original; Windows fonts are not bundled.
