#!/usr/bin/env python3
"""Generate legacy AppIcon PNG set from a 1024x1024 master icon."""
from __future__ import annotations

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "assets" / "TequilaDash-icon-master.png"
OUT = ROOT / "Resources"
BRAND = ROOT / "docs" / "brand" / "icon.png"

SIZES = {
    "AppIcon29x29.png": 29,
    "AppIcon29x29@2x.png": 58,
    "AppIcon29x29@3x.png": 87,
    "AppIcon40x40.png": 40,
    "AppIcon40x40@2x.png": 80,
    "AppIcon40x40@3x.png": 120,
    "AppIcon50x50.png": 50,
    "AppIcon50x50@2x.png": 100,
    "AppIcon57x57.png": 57,
    "AppIcon57x57@2x.png": 114,
    "AppIcon57x57@3x.png": 171,
    "AppIcon60x60.png": 60,
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon72x72.png": 72,
    "AppIcon72x72@2x.png": 144,
    "AppIcon76x76.png": 76,
    "AppIcon76x76@2x.png": 152,
}


def main() -> None:
    if not MASTER.exists():
        raise SystemExit(f"Missing master icon: {MASTER}")
    master = Image.open(MASTER).convert("RGBA")
    OUT.mkdir(parents=True, exist_ok=True)
    for name, px in SIZES.items():
        img = master.resize((px, px), Image.Resampling.LANCZOS)
        target = OUT / name
        img.save(target, format="PNG", optimize=True)
        print(f"wrote {name} ({px}px, {target.stat().st_size} bytes)")
    BRAND.parent.mkdir(parents=True, exist_ok=True)
    brand = master.resize((180, 180), Image.Resampling.LANCZOS)
    brand.save(BRAND, format="PNG", optimize=True)
    print(f"wrote {BRAND.relative_to(ROOT)} (180px, {BRAND.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
