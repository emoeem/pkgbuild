#!/usr/bin/env python3
# test fixture harness for audit-mpv-full-baseline.py
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / "scripts/audit-mpv-full-baseline.py"

AUR = """depends=(\n    'ffmpeg'\n    'jack'\n    'lua52')\n
-Dgpl='true' -Dpipewire='enabled' -Djavascript='enabled'\n"""
EMO = """depends=(\n    'ffmpeg'\n    'pipewire-jack'\n    'lua52')\n
-Dgpl=true -Dpipewire=enabled -Djavascript=enabled\n"""
UPSTREAM = """option('gpl', type: 'boolean', value: true)\noption('pipewire', type: 'feature', value: 'auto')\noption('javascript', type: 'feature', value: 'auto')\noption('newfeature', type: 'feature', value: 'auto')\n"""

with tempfile.TemporaryDirectory() as td:
    t = Path(td)
    (t / 'aur').write_text(AUR)
    (t / 'emo').write_text(EMO)
    (t / 'upstream').write_text(UPSTREAM)
    p = subprocess.run([
        'python', str(AUDIT), '--package', str(t / 'emo'),
        '--aur-pkgbuild', str(t / 'aur'), '--upstream-options', str(t / 'upstream')
    ], text=True, capture_output=True)
    assert p.returncode != 0, p.stdout + p.stderr
    assert 'newfeature' in p.stdout + p.stderr
print('mpv-full baseline audit regression test passed')
