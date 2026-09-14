#!/usr/bin/env python3
"""Validate our icon sources and Apple's compiled bundle; requests no account data."""
import argparse
import collections
import json
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--require-layered", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
source = root / "Assets/AppIcon.icon"
document = json.loads((source / "icon.json").read_text())
groups = document["groups"]
assert [g["name"] for g in groups] == ["Needle", "Allowance", "Track"], "Front-to-back layer order changed"
for group in groups:
    assert group["translucency"]["enabled"]
    assert group["specular"] is False, "Overly strong edge highlights returned"
    for layer in group["layers"]:
        svg = ET.parse(source / "Assets" / layer["image-name"]).getroot()
        assert svg.attrib["viewBox"] == "0 0 1024 1024"
        assert svg.attrib["width"] == svg.attrib["height"] == "1024"
        assert len(svg), "Empty artwork layer"
resources = args.app / "Contents/Resources"
assert (resources / "AppIcon.icns").read_bytes()[:4] == b"icns", "Invalid legacy ICNS"
info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
car = resources / "Assets.car"
counts = {}
if car.exists():
    assert info.get("CFBundleIconName") == "AppIcon"
    result = subprocess.run(["/usr/bin/assetutil", "--info", str(car)], check=True, capture_output=True, text=True)
    items = json.loads(result.stdout)
    counts = dict(collections.Counter(item.get("AssetType", "metadata") for item in items))
    def check_material(value):
        if isinstance(value, dict):
            assert not value.get("LayerHasSpecular", False), "Compiled highlight annotation changed"
            for child in value.values():
                check_material(child)
        elif isinstance(value, list):
            for child in value:
                check_material(child)
    check_material(items)
    for item in items:
        if item.get("AssetType") == "Icon Image":
            assert item["PixelWidth"] == item["PixelHeight"], "Non-square compiled icon"
        if item.get("AssetType") == "IconImageStack":
            assert item["CanvasWidth"] == item["CanvasHeight"], "Non-square layered canvas"
    assert counts.get("IconImageStack", 0) >= 1, "Missing layered icon stack"
    assert counts.get("IconGroup", 0) >= 3, "Missing material groups"
    assert counts.get("Vector", 0) >= 3, "Artwork flattened unexpectedly"
elif args.require_layered:
    raise SystemExit("Missing layered Assets.car")
print(json.dumps({"sourceLayers": 3, "layered": car.exists(), "legacyICNS": True, "compiledAssets": counts}, sort_keys=True))
