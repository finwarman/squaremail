#!/usr/bin/env python3
"""Generate the compact display table from WHATWG entities.json, supplied locally."""
import hashlib,json,re,sys
from pathlib import Path
source=Path(sys.argv[1]).read_bytes()
assert len(source)<=262144
values=json.loads(source)
rows=sorted((k[1:-1],v['characters']) for k,v in values.items() if k.endswith(';'))
assert all(re.fullmatch('[A-Za-z][A-Za-z0-9]*',k) and isinstance(v,str) for k,v in rows)
def quoted(value):
    return '"'+''.join(c if 32<=ord(c)<127 and c not in '\\"' else '\\u{'+format(ord(c),'x')+'}' for c in value)+'"'
path=Path(__file__).resolve().parents[1]/'macos/MessageText/HTMLNames.swift'
current=path.read_text()
start=current.index('    private static let entries:')
body='    private static let entries: [(String, String)] = [\n'+''.join('        ('+quoted(k)+', '+quoted(v)+'),\n' for k,v in rows)+'    ]\n}\n'
current=re.sub(r'Source SHA256: [a-f0-9]+', 'Source SHA256: '+hashlib.sha256(source).hexdigest(),current[:start])+body
path.write_text(current)
