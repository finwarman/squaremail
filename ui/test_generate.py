#!/usr/bin/env python3
"""One theme edit must propagate to both standalone adapters."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from generate import ROOT, generate

class SharedThemeTest(unittest.TestCase):
    def test_palette_change_reaches_both(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            source=root/'themes.json'
            swift=root/'Tokens.swift'
            rust=root/'tokens.rs'
            source.write_bytes((ROOT/'themes.json').read_bytes())
            generate(source,swift,rust,False)
            before=swift.read_text(),rust.read_text()
            value=json.loads(source.read_text())
            value['palettes']['pink']['colors']['face']='F1CDEF'
            source.write_text(json.dumps(value))
            digest=generate(source,swift,rust,False)
            for previous,path in zip(before,[swift,rust]):
                self.assertNotEqual(previous,path.read_text())
                self.assertIn('0xF1CDEF',path.read_text())
                self.assertIn(digest,path.read_text())
            self.assertEqual(digest,hashlib.sha256(source.read_bytes()).hexdigest())
            generate(source,swift,rust,True)
            rust.write_text('stale')
            with self.assertRaisesRegex(AssertionError,'Stale generated theme'):
                generate(source,swift,rust,True)

    def test_invalid_source_leaves_adapters(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            source=root/'themes.json'
            swift=root/'Tokens.swift'
            rust=root/'tokens.rs'
            value=json.loads((ROOT/'themes.json').read_text())
            for invalid in ['FFFFFF00','rgb(1,2,3)','hello']:
                value['palettes']['classic']['colors']['face']=invalid
                source.write_text(json.dumps(value))
                with self.assertRaises(AssertionError):
                    generate(source,swift,rust,False)
                self.assertFalse(swift.exists())
                self.assertFalse(rust.exists())

if __name__=='__main__':
    unittest.main()
