# Native UI checks

`scripts/check.sh` runs native integration probes with `--background-ui`. Windows are constructed and laid out but never ordered on screen. The application uses accessory activation policy and does not activate itself. Only generated, disconnected accounts are used.

`scripts/check-controls.sh` dispatches native buttons and View menu actions, checks toggle states, file/account/about dialog presentation, editor close choices, repeated clicks, local draft restore, failed-save recovery and the title-bar quit action. Dialogs use scripted responses in this mode. Notification preference/history checks use SQLite; no OS permission request or provider write occurs.

These checks exercise application state and native action bindings. They do not qualify visible sheet placement, focus, keyboard navigation, accessibility or window-manager behavior. Earlier visual checks cover the editor and bell before the later draft/close changes.

An isolated macOS VM with an in-guest test driver is the planned place for visible regression checks. No VM is configured. A host virtual monitor alone does not isolate keyboard focus. Performance baselines remain separate, scheduled on hardware with Fin. Routine probes must not take over the host desktop.

`scripts/check-mail-actions.sh` uses disconnected generated mail. It dispatches toolbar/context actions, tests draft autosave/close/send-review cancellation and recovery, reply-all/forward fields, local pins, Trash behavior, reader spacing and clock replacement. It never grants consent or contacts a real provider. `--mail-evidence-dir /absolute/path` optionally saves offscreen synthetic native renders; these do not qualify interactive focus or OS sheets.

The reader self-test checks readable link attributes, click callbacks without opening a browser, original/readable toggles, full targets on a private pasteboard and stale formatting rejection. MessageText tests cover labelled email/Markdown links, wrapped URLs, Unicode padding and text preservation. User-provided tracking links remain outside the repository.

Reader action checks cover global/message ownership, narrow overflow states, no overlapping buttons/headers, cancelled body loads and Retry. Synthetic sync states verify navigation does not re-enable an active Sync button. Appearance choices remain pending until restart and background probes never save personal preferences. Classic/Pink renders use generated mail. Progress lifecycle and palette contrast are separate from whole-app performance qualification.

`--host-dark` in background probes simulates a dark app appearance without changing macOS settings. Calendar/composer fixtures verify and capture light native form controls on classic surfaces, including the read-only calendar label. No real mail/calendar contents are captured.

Search probes use the disconnected30,000-header/three-account fixture. They check sender-address indexing, fuzzy/literal feedback, nested-folder isolation, All folders scope, clear and unified typo results. Reader checks verify visible32-point icon controls, labels/tooltips, non-overlap, Safe Links copy/click preservation and multiline preview formatting. Migration contracts include retained local drafts and queued work.

Programmatic query changes update both the text field and its active field editor. Clear is checked while the search field is focused. Selected results scroll into view; stale responses compare the full search scope/mode snapshot before updating the UI.

The mail-action probe also drives a disconnected scripted sync worker through multiple pages, completion, immediate manual wake, retry and pause/replacement. It checks delayed visible progress, retained progress across pages, Refresh labels and recovery. These probes perform no provider reads or writes.
