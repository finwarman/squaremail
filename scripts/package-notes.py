#!/usr/bin/env python3
"""Bundle the shared native executable with an independent Notes entry."""
import plistlib
import shutil
import sys
from pathlib import Path

parent = Path(sys.argv[1])
app = parent / 'Contents/Helpers/Square Notes.app'
if app.exists():
    shutil.rmtree(app)
(app / 'Contents/MacOS').mkdir(parents=True)
(app / 'Contents/Resources').mkdir()
shutil.copy2(parent / 'Contents/MacOS/SquareMail', app / 'Contents/MacOS/SquareNotes')
shutil.copy2('macos/Resources/NotesIcon.icns', app / 'Contents/Resources/AppIcon.icns')
info = plistlib.loads((parent / 'Contents/Info.plist').read_bytes())
info.update(CFBundleExecutable='SquareNotes', CFBundleIdentifier='com.finwarman.squaremail.notes',
            CFBundleName='Square Notes', CFBundleDisplayName='Square Notes')
info['CFBundleDocumentTypes'] = [{'CFBundleTypeName': 'Square Notes Markdown',
                                'LSItemContentTypes': ['net.daringfireball.markdown'],
                                'CFBundleTypeRole': 'Editor', 'LSHandlerRank': 'Alternate'}]
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
