#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build --release --workspace --target-dir .build/rust
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/.build/Square Mail.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/SquareMail" "$app_dir/Contents/MacOS/SquareMail.new"
mv -f "$app_dir/Contents/MacOS/SquareMail.new" "$app_dir/Contents/MacOS/SquareMail"
cp macos/Info.plist "$app_dir/Contents/Info.plist"
cp macos/Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.finwarman.squaremail "$app_dir"
echo "$app_dir"
