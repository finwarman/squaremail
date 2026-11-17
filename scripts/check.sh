#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --target-dir .build/rust -- -D warnings
cargo test --workspace --target-dir .build/rust
./scripts/build.sh
swift test -c release
test_dir="$(mktemp -d -t squaremail-test)"
trap 'rm -rf "$test_dir"' EXIT
".build/Square Mail.app/Contents/MacOS/SquareMail" --data-dir "$test_dir" --self-test --snapshot "$test_dir/native.png"
".build/Square Mail.app/Contents/MacOS/SquareMail" --data-dir "$test_dir" --check-calendar
