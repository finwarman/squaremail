#!/usr/bin/env python3
"""Two native processes share one disconnected synthetic cache."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="squaremail-read-hold-") as directory:
    env = dict(os.environ, SQUAREMAIL_MAIL_ACTIONS_DB=str(Path(directory) / "mail.sqlite"))
    candidates = [path for path in (root / ".build/rust/release/deps").glob("squaremail_core-*") if path.is_file() and not path.suffix and os.access(path, os.X_OK)]
    if not candidates:
        raise RuntimeError("Build release test fixtures before this probe")
    binary = max(candidates, key=lambda path: path.stat().st_mtime)
    subprocess.run([str(binary), "seed_mail_actions_fixture", "--ignored", "--nocapture"], cwd=root, env=env, check=True)
    for probe in ("create", "reopen"):
        subprocess.run([str(root / ".build/Square Mail.app/Contents/MacOS/SquareMail"), "--background-ui", "--data-dir", directory, "--check-read-hold", probe], cwd=root, check=True, timeout=90)
