#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d -t squaremail-workspaces)"
trap 'rm -rf "$fixture_dir"' EXIT
SQUAREMAIL_MAIL_ACTIONS_DB="$fixture_dir/mail.sqlite" cargo test --release --workspace --target-dir .build/rust seed_mail_actions_fixture -- --ignored --nocapture
".build/Square Mail.app/Contents/MacOS/SquareMail" --background-ui --data-dir "$fixture_dir" --check-workspaces
