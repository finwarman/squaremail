#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build --release --workspace --target-dir .build/rust
bin_dir="$(swift build -c release --show-bin-path)"
core_hash="$(shasum -a 256 .build/rust/release/libsquaremail_core.a | cut -d ' ' -f 1)"
# SwiftPM does not track the archive passed through -L/-l as a link input.
if [[ ! -f .build/rust-link.sha256 || "$(cat .build/rust-link.sha256)" != "$core_hash" ]]; then
  rm -f -- "$bin_dir/SquareMail"
fi
swift build -c release
printf '%s\n' "$core_hash" > .build/rust-link.sha256
app_dir="$PWD/.build/Square Mail.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/SquareMail" "$app_dir/Contents/MacOS/SquareMail.new"
mv -f "$app_dir/Contents/MacOS/SquareMail.new" "$app_dir/Contents/MacOS/SquareMail"
cp macos/Info.plist "$app_dir/Contents/Info.plist"
cp macos/Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
python3 scripts/package-oauth.py local-oauth.json "$app_dir/Contents/Resources/OAuthClients.json"
python3 scripts/package-notes.py "$app_dir"
if [[ "${SQUAREMAIL_ADHOC:-0}" == "1" ]]; then
  codesign --force --sign - --identifier com.finwarman.squaremail.notes "$app_dir/Contents/Helpers/Square Notes.app"
  codesign --force --sign - --identifier com.finwarman.squaremail "$app_dir"
else
  python3 scripts/credential-helper.py "$app_dir/Contents/Helpers/SquareMailCredentials"
  python3 "${F1NB0_SIGNER:-$HOME/f1nb0-launcher/scripts/sign.py}" "$app_dir"
fi
echo "$app_dir"
