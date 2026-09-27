#!/usr/bin/env python3
"""Validate our icon sources and Apple's compiled bundle; requests no account data."""
import argparse
import collections
import json
import math
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

PARTS = ["AppIcon/Track", "AppIcon/Arc"]  # compiled planes, bottom to top
# The arc is its stroke's filled outline: outer arc, round end cap, inner arc back, round start cap.
ARC_OUTLINE = re.compile(r"M ([\d.]+) ([\d.]+) A ([\d.]+) \3 0 1 1 ([\d.]+) ([\d.]+) A ([\d.]+) \6 0 0 1 [\d.]+ [\d.]+ "
                         r"A ([\d.]+) \7 0 1 0 ([\d.]+) ([\d.]+) A \6 \6 0 0 1 \1 \2 Z")


def validate_compiled_layout(items):
    counts = dict(collections.Counter(item.get("AssetType", "metadata") for item in items))
    stacks = [item for item in items if item.get("AssetType") == "IconImageStack"]
    assert stacks, "Missing layered icon stack"
    for item in items:
        if item.get("AssetType") == "Icon Image":
            assert item["PixelWidth"] == item["PixelHeight"], "Non-square compiled icon"
        if item.get("AssetType") == "IconGroup":
            assert item["Name"] in PARTS, "Unexpected foreground material group"
            assert item["LayerCount"] == 1 and len(item["Layers"]) == 1, "Each gauge part must be one artwork layer"
            assert item["Layers"][0]["AssetType"] == "Vector", "Gauge vector missing"
    for stack in stacks:
        assert stack["CanvasWidth"] == stack["CanvasHeight"], "Non-square layered canvas"
        assert stack["LayerCount"] == 3, "Expected a glass backplate, the track and the arc"
        # assetutil lists each group's appearance variants together, bottom plane first.
        foreground = [layer for layer in stack["Layers"] if layer.get("AssetType") == "IconGroup"]
        background = [layer for layer in stack["Layers"] if layer.get("AssetType") != "IconGroup"]
        assert len(background) == 1, "Separate glass backplate missing"
        assert all(layer["Name"] in PARTS for layer in foreground), "Unexpected foreground material group"
        assert all(layer.get("LayerHasSpecular", False) for layer in foreground), "Foreground glass highlights missing"
        names = [layer["Name"] for layer in foreground]
        planes = [name for index, name in enumerate(names) if index == 0 or names[index - 1] != name]
        assert planes == PARTS, "The arc must sit above its track"
        for part in PARTS:
            appearances = [layer.get("Appearance", "default") for layer in foreground if layer["Name"] == part]
            assert len(appearances) == len(set(appearances)), "Multiple planes of one part in one appearance"
    assert counts.get("IconGroup", 0) >= 2, "Missing foreground material groups"
    assert counts.get("Vector", 0) == 2, "Expected one arc vector and one track vector"
    return counts


def single_element(path, tag):
    svg = ET.parse(path).getroot()
    assert svg.attrib["viewBox"] == "0 0 1024 1024"
    assert svg.attrib["width"] == svg.attrib["height"] == "1024"
    assert len(svg) == 1 and svg[0].tag.endswith("}" + tag), f"Expected one {tag} in {path.name}"
    return svg[0]


def arc_geometry(path_data):
    """Returns the arc's outer start, centre-line radius, width and sweep in degrees."""
    match = ARC_OUTLINE.fullmatch(path_data)
    assert match, "Arc must be one round-capped circular band"
    x0, y0, outer, x1, y1, cap, inner, x3, y3 = map(float, match.groups())
    assert outer - inner == 2 * cap, "Arc caps must be as round as the band is wide"
    assert (x3, y3) == (x0, y0 + outer - inner), "Arc band must start square to its centre"
    sweep = (math.degrees(math.atan2(y1 - 512, x1 - 512)) + 90) % 360
    return (x0, y0), (outer + inner) / 2, outer - inner, sweep


def filled_artwork(path):
    # A layer colour override paints the artwork's fill. On a stroke-only shape, Apple's
    # generated legacy ICNS fills the whole path: an arc became a solid wedge.
    for element in list(ET.parse(path).getroot()):
        assert element.attrib.get("fill", "black") != "none" and "stroke" not in element.attrib, \
            f"{path.name}: a colour override needs filled artwork, not a stroke"


def validate_sources(source):
    document = json.loads((source / "icon.json").read_text())
    groups = document["groups"]
    assert [group["name"] for group in groups] == ["Arc", "Track"], "Expected the arc above its track"
    arc, track = groups
    assert [layer["image-name"] for layer in arc["layers"]] == ["Arc.svg"], "The arc must be one artwork layer"
    assert [layer["image-name"] for layer in track["layers"]] == ["Track.svg"], "The track must be one artwork layer"
    assert all(group["specular"] is True for group in groups), "Foreground glass is disabled"
    assert arc["translucency"]["enabled"], "Arc glass translucency is disabled"
    # The clear-glass look in every appearance: Dark Mode repeats the default colours.
    for fills in (document["fill-specializations"], arc["layers"][0]["fill-specializations"]):
        assert len(fills) == 2 and "appearance" not in fills[0] and fills[1].get("appearance") == "dark", "Default and Dark fills required"
        assert fills[0]["value"] == fills[1]["value"], "Dark Mode must keep the clear-glass colours"
    for group in groups:
        for layer in group["layers"]:
            if "fill" in layer or "fill-specializations" in layer:
                filled_artwork(source / "Assets" / layer["image-name"])
    ring = single_element(source / "Assets/Track.svg", "circle")
    assert {key: ring.attrib[key] for key in ["cx", "cy", "fill"]} == {"cx": "512", "cy": "512", "fill": "none"}, "Track must be a centred ring"
    band = single_element(source / "Assets/Arc.svg", "path")
    start, radius, width, sweep = arc_geometry(band.attrib["d"])
    assert radius == float(ring.attrib["r"]) and width == float(ring.attrib["stroke-width"]), "Arc must ride on its track"
    assert start == (512.0, 512.0 - radius - width / 2), "Arc must start at twelve o'clock"
    assert 180 < sweep < 330, "Arc must read as a partly used allowance"
    return ring, band


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--require-layered", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    validate_sources(root / "Assets/AppIcon.icon")
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
    print(json.dumps({"sourceLayers": 2, "foregroundGroups": 2, "layered": car.exists(), "legacyICNS": True, "compiledAssets": counts}, sort_keys=True))


if __name__ == "__main__":
    main()
