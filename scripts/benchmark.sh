#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo test --release --workspace --target-dir .build/rust mailbox_benchmark -- --ignored --nocapture
cargo test --release --workspace --target-dir .build/rust account_search_benchmark -- --ignored --nocapture
./scripts/build.sh
test_dir="$(mktemp -d -t squaremail-perf)"
trap 'rm -rf "$test_dir"' EXIT
/usr/bin/time -l ".build/Square Mail.app/Contents/MacOS/SquareMail" --data-dir "$test_dir" --metrics --quit-after-metrics
