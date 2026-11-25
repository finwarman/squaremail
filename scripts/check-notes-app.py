#!/usr/bin/env python3
"""Run the real Notes bundle against isolated files, without foreground windows."""
import plistlib
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = root / '.build/Square Mail.app/Contents/Helpers/Square Notes.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.finwarman.squaremail.notes'
assert info['CFBundleExecutable'] == 'SquareNotes'
assert not info.get('LSUIElement', False) and not info.get('LSBackgroundOnly', False)
assert not (app / 'Contents/Helpers').exists()
assert not (app / 'Contents/Resources/OAuthClients.json').exists()
with tempfile.TemporaryDirectory(prefix='square-notes-check-') as directory:
    subprocess.run([str(app / 'Contents/MacOS/SquareNotes'), '--background-ui', '--data-dir', directory,
                    '--check-notes-app'], check=True, timeout=90)
    assert not (Path(directory) / 'mail.sqlite').exists()
