#!/usr/bin/env python3
"""Validate the real packaged app before a release can update AltStore."""
import plistlib
import re
import sys
import zipfile
from pathlib import Path

path, version, build = sys.argv[1:]
with zipfile.ZipFile(path) as archive:
    assert archive.testzip() is None, 'Corrupt archive'
    infos = [p for p in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', p)]
    assert len(infos) == 1, 'Expected exactly one app'
    info = plistlib.loads(archive.read(infos[0]))
    assert info['CFBundleIdentifier'] == 'com.kharrison.guidedassistance'
    assert info['CFBundleShortVersionString'] == version
    assert str(info['CFBundleVersion']) == build
    assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS']
    root = infos[0].removesuffix('Info.plist')
    executable = archive.read(root + info['CFBundleExecutable'])
    assert executable[:4] in (bytes.fromhex('cffaedfe'), bytes.fromhex('cafebabe')), 'Missing Mach-O executable'
    assert len(executable) > 100000
    assert any(p.endswith('.metallib') for p in archive.namelist()), 'MLX Metal library missing'
    assert not any(p.lower().endswith(('.pdf', '.gavault', '.safetensors', '.gguf')) for p in archive.namelist()), 'Private data or weights bundled'
print(f'Validated Guided Assistance {version} ({build}), {Path(path).stat().st_size} bytes.')
