#!/usr/bin/env python3
"""Convert the retained generated icon to Apple's standard iconset and ICNS."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
source = root / 'assets/brand/ulecture-icon.png'
iconset = root / 'assets/brand/ULecture.iconset'
iconset.mkdir(parents=True, exist_ok=True)
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = size * scale
        filename = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
        subprocess.run(['sips', '-z', str(pixels), str(pixels), str(source), '--out', str(iconset / filename)], check=True, stdout=subprocess.DEVNULL)
destination = root / 'app/Resources/ULecture.icns'
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(destination)], check=True)
print(destination.relative_to(root))
