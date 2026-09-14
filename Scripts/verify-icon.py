#!/usr/bin/env python3
"""Validate our icon sources and Apple's compiled bundle; requests no account data."""
import argparse
import collections
import json
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET


def validate_compiled_layout(items):
    counts = dict(collections.Counter(item.get("AssetType", "metadata") for item in items))
    stacks = [item for item in items if item.get("AssetType") == "IconImageStack"]
    assert stacks, "Missing layered icon stack"
    for item in items:
        if item.get("AssetType") == "Icon Image":
            assert item["PixelWidth"] == item["PixelHeight"], "Non-square compiled icon"
        if item.get("AssetType") == "IconGroup":
            assert item["Name"] == "AppIcon/Ring", "Split foreground material groups returned"
            assert item["LayerCount"] == 1 and len(item["Layers"]) == 1, "Ring must be one artwork layer"
            assert item["Layers"][0]["AssetType"] == "Vector", "Ring vector missing"
    for stack in stacks:
        assert stack["CanvasWidth"] == stack["CanvasHeight"], "Non-square layered canvas"
        assert stack["LayerCount"] == 2, "Expected separate backplate plus one foreground plane"
        # assetutil lists variants of the same group together inside each stack.
        foreground = [layer for layer in stack["Layers"] if layer.get("AssetType") == "IconGroup"]
        background = [layer for layer in stack["Layers"] if layer.get("AssetType") != "IconGroup"]
        assert len(background) == 1, "Separate glass backplate missing"
        assert foreground and all(layer["Name"] == "AppIcon/Ring" for layer in foreground), "Split foreground material groups returned"
        assert all(layer.get("LayerHasSpecular", False) for layer in foreground), "Foreground glass highlights missing"
        appearances = [layer.get("Appearance", "default") for layer in foreground]
        assert len(appearances) == len(set(appearances)), "Multiple foreground planes in one appearance"
    assert counts.get("IconGroup", 0) >= 1, "Missing foreground material group"
    assert counts.get("Vector", 0) == 1, "Expected one complete foreground vector"
    return counts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--require-layered", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = root / "Assets/AppIcon.icon"
    document = json.loads((source / "icon.json").read_text())
    groups = document["groups"]
    assert len(groups) == 1 and groups[0]["name"] == "Ring", "Expected one shared foreground material group"
    group = groups[0]
    assert group["layers"] == [{"image-name": "Ring.svg", "name": "Ring"}], "Ring must be one artwork layer"
    assert group["translucency"]["enabled"]
    assert group["specular"] is True, "Shared foreground glass is disabled"
    svg = ET.parse(source / "Assets/Ring.svg").getroot()
    assert svg.attrib["viewBox"] == "0 0 1024 1024"
    assert svg.attrib["width"] == svg.attrib["height"] == "1024"
    assert len(svg) == 1 and svg[0].tag.endswith("}path"), "Expected a single open-ring silhouette"
    assert svg[0].attrib["fill"] == "#c3cbd6" and "stroke" not in svg[0].attrib, "Expected monochrome filled ring"
    resources = args.app / "Contents/Resources"
    assert (resources / "AppIcon.icns").read_bytes()[:4] == b"icns", "Invalid legacy ICNS"
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    car = resources / "Assets.car"
    counts = {}
    if car.exists():
        assert info.get("CFBundleIconName") == "AppIcon"
        result = subprocess.run(["/usr/bin/assetutil", "--info", str(car)], check=True, capture_output=True, text=True)
        counts = validate_compiled_layout(json.loads(result.stdout))
    elif args.require_layered:
        raise SystemExit("Missing layered Assets.car")
    print(json.dumps({"sourceLayers": 1, "foregroundGroups": 1, "layered": car.exists(), "legacyICNS": True, "compiledAssets": counts}, sort_keys=True))


if __name__ == "__main__":
    main()
