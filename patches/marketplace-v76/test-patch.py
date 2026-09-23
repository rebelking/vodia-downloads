#!/usr/bin/env python3
"""Usage: python3 test-patch.py /path/to/unpatched/app/fixture"""
from pathlib import Path
import hashlib
import shutil
import tempfile
import sys
import patch

def digest(root):
    return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}

source=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='vodia-v76-tests-') as tmp:
    root=Path(tmp)/'app'
    shutil.copytree(source,root)
    patch.main(root)
    first=digest(root)
    patch.main(root)
    assert first==digest(root), 'Reapplying .76 changed source'
    print('PASS idempotent staged patch')
    shutil.rmtree(root)
    shutil.copytree(source,root)
    ui=root/'ui/msp-guided-app.html'
    ui.write_text(ui.read_text().replace('  function updatePlanButton(){','  function unknownLayout(){'))
    before=digest(root)
    try:
        patch.main(root)
        raise AssertionError('Unexpected source layout accepted')
    except ValueError:
        pass
    assert digest(root)==before, 'Layout rejection wrote source'
    print('PASS unknown layout rejected without writing source')
