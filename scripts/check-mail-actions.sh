#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d -t squaremail-mail-actions)"
trap 'rm -rf "$fixture_dir"' EXIT
SQUAREMAIL_MAIL_ACTIONS_DB="$fixture_dir/mail.sqlite" cargo test --release --workspace --target-dir .build/rust seed_mail_actions_fixture -- --ignored --nocapture
".build/Square Mail.app/Contents/MacOS/SquareMail" --background-ui --data-dir "$fixture_dir" --check-mail-actions

SQUAREMAIL_ACTION_NAV_DB="$fixture_dir/navigation.sqlite" cargo test --release --workspace --target-dir .build/rust seed_action_nav_fixture -- --ignored --nocapture
mkdir "$fixture_dir/navigation"
mv "$fixture_dir/navigation.sqlite" "$fixture_dir/navigation/mail.sqlite"
".build/Square Mail.app/Contents/MacOS/SquareMail" --background-ui --data-dir "$fixture_dir/navigation" --check-action-nav
