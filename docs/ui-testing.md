# Native UI checks

`scripts/check.sh` runs native integration probes with `--background-ui`. Windows are constructed and laid out but never ordered on screen. The application uses accessory activation policy and does not activate itself. Only generated, disconnected accounts are used.

`scripts/check-controls.sh` dispatches native buttons and View menu actions, checks toggle states, file/account/about dialog presentation, editor close choices, repeated clicks, local draft restore, failed-save recovery and the title-bar quit action. Dialogs use scripted responses in this mode. Notification preference/history checks use SQLite; no OS permission request or provider write occurs.

These checks exercise application state and native action bindings. They do not qualify visible sheet placement, focus, keyboard navigation, accessibility or window-manager behavior. Earlier visual checks cover the editor and bell before the later draft/close changes.

An isolated macOS VM with an in-guest test driver is the planned place for visible regression checks. No VM is configured. A host virtual monitor alone does not isolate keyboard focus. Performance baselines remain separate, scheduled on hardware with Fin. Routine probes must not take over the host desktop.
