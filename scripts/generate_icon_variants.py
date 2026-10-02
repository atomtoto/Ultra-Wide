#!/usr/bin/env python3
"""Derive alternate Icon Composer documents and settings previews from the main icon.

Run on macOS with Xcode installed after changing the original icon artwork.
"""
import copy
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "UltraWide"
SOURCE = APP / "UltraWide.icon"
PALETTES = {
    "Amber": [(0.30, 0.12, 0.05), (1.0, 0.57, 0.12)],
    "Aurora": [(0.05, 0.20, 0.25), (0.16, 0.78, 0.59)],
    "Graphite": [(0.08, 0.09, 0.12), (0.37, 0.41, 0.48)],
}


def color(rgb, alpha=1):
    return "extended-srgb:" + ",".join(f"{v:.5f}" for v in (*rgb, alpha))


def main():
    source = json.loads((SOURCE / "icon.json").read_text())
    for name, colors in PALETTES.items():
        destination = APP / f"UltraWide{name}.icon"
        shutil.copytree(SOURCE / "Assets", destination / "Assets", dirs_exist_ok=True)
        document = copy.deepcopy(source)
        document["fill"] = {"linear-gradient": [color(c) for c in colors]}
        for group in document["groups"]:
            for layer in group["layers"]:
                if layer.get("image-name") == "Ellipse 1.svg":
                    layer["fill"] = {"solid": color(tuple(0.55 + channel * 0.45 for channel in colors[1]))}
                if layer.get("image-name") == "Ellipse 2.svg":
                    layer["fill"] = {"solid": color(tuple(0.12 + channel * 0.65 for channel in colors[1]))}
                if layer.get("image-name") == "Rectangle 5.svg":
                    layer["fill"] = {"linear-gradient": [color(colors[1], 0.43), color(colors[1], 0.40)]}
        (destination / "icon.json").write_text(json.dumps(document, indent=2) + "\n")

    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    ictool = developer.parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
    catalog = APP / "Assets.xcassets"
    catalog.mkdir(exist_ok=True)
    (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    for suffix in ["", *PALETTES]:
        name = f"UltraWide{suffix}"
        image_set = catalog / f"{name}Preview.imageset"
        image_set.mkdir(exist_ok=True)
        subprocess.run([str(ictool), str(APP / f"{name}.icon"), "--export-image",
                        "--output-file", str(image_set / "preview.png"), "--platform", "iOS",
                        "--rendition", "Default", "--width", "256", "--height", "256", "--scale", "1"], check=True)
        (image_set / "Contents.json").write_text(json.dumps({
            "images": [{"filename": "preview.png", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1}
        }, indent=2) + "\n")


if __name__ == "__main__":
    main()
