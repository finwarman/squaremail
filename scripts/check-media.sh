#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d -t squaremail-media)"
trap 'rm -rf "$fixture_dir"' EXIT
python3 scripts/media-fixture.py "$fixture_dir/message.eml"
".build/Square Mail.app/Contents/MacOS/SquareMail" --data-dir "$fixture_dir" --check-media "$fixture_dir/message.eml"
