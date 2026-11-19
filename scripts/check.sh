#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 ui/test_generate.py
python3 ui/generate.py --check
python3 scripts/generate-entities.py --check
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --target-dir .build/rust -- -D warnings
cargo test --workspace --target-dir .build/rust
./scripts/build.sh
swift test -c release
test_dir="$(mktemp -d -t squaremail-test)"
trap 'rm -rf "$test_dir"' EXIT
".build/Square Mail.app/Contents/MacOS/SquareMail" --background-ui --data-dir "$test_dir" --self-test --snapshot "$test_dir/native.png"
".build/Square Mail.app/Contents/MacOS/SquareMail" --background-ui --data-dir "$test_dir" --check-calendar

./scripts/check-accounts.sh
./scripts/check-media.sh

./scripts/check-calendar-actions.sh

./scripts/check-controls.sh

./scripts/check-mail-actions.sh

python3 scripts/check-read-hold.py
