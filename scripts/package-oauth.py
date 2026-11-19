#!/usr/bin/env python3
"""Package desktop application metadata. Refuse account tokens and endpoint overrides."""
import json,re,sys
from pathlib import Path

source,target=map(Path,sys.argv[1:])
if source.exists():
    raw=source.read_bytes()
    assert len(raw)<=4096
    value=json.loads(raw)
    assert set(value)=={'gmail','outlook','google_desktop_secret'}
    assert re.fullmatch(r'[A-Za-z0-9.-]+\.apps\.googleusercontent\.com',value['gmail'])
    assert re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',value['outlook'])
    assert 1<=len(value['google_desktop_secret'])<=256 and value['google_desktop_secret'].isascii()
    target.write_text(json.dumps(value,separators=(',',':'))+'\n')
elif target.exists():
    target.unlink()
