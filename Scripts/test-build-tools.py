#!/usr/bin/env python3
"""Account-free regression checks for release guardrails."""
import copy
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("verify_icon", ROOT / "Scripts/verify-icon.py")
VERIFY_ICON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY_ICON)


class IconPlaneTests(unittest.TestCase):
    def setUp(self):
        self.vectors = [{"AssetType": "Vector", "Name": "AppIcon_Assets/Track"}, {"AssetType": "Vector", "Name": "AppIcon_Assets/Arc"}]
        self.groups = [{"AssetType": "IconGroup", "Name": "AppIcon/Track", "LayerCount": 1, "Layers": [self.vectors[0]]},
                       {"AssetType": "IconGroup", "Name": "AppIcon/Arc", "LayerCount": 1, "Layers": [self.vectors[1]]}]
        plane = lambda name: {"AssetType": "IconGroup", "Name": name, "Appearance": "NSAppearanceNameAqua", "LayerHasSpecular": True}
        self.stack = {"AssetType": "IconImageStack", "CanvasWidth": 1024, "CanvasHeight": 1024, "LayerCount": 3,
                      "Layers": [{"Name": "AppIcon_Assets/Gradient-1"}, plane("AppIcon/Track"), plane("AppIcon/Arc")]}
        self.items = self.vectors + self.groups + [self.stack]

    def test_glass_arc_above_its_track_passes(self):
        self.assertEqual(VERIFY_ICON.validate_compiled_layout(self.items)["Vector"], 2)

    def test_unexpected_material_group_is_rejected(self):
        self.groups[1]["Name"] = "AppIcon/Needle"
        with self.assertRaisesRegex(AssertionError, "Unexpected foreground"):
            VERIFY_ICON.validate_compiled_layout(self.items)

    def test_split_artwork_inside_a_part_is_rejected(self):
        self.groups[1]["Layers"].append(copy.deepcopy(self.vectors[1]))
        self.groups[1]["LayerCount"] = 2
        with self.assertRaisesRegex(AssertionError, "one artwork layer"):
            VERIFY_ICON.validate_compiled_layout(self.items)

    def test_missing_foreground_glass_is_rejected(self):
        self.stack["Layers"][2]["LayerHasSpecular"] = False
        with self.assertRaisesRegex(AssertionError, "glass highlights missing"):
            VERIFY_ICON.validate_compiled_layout(self.items)

    def test_duplicate_plane_in_one_appearance_is_rejected(self):
        self.stack["Layers"].append(copy.deepcopy(self.stack["Layers"][2]))
        with self.assertRaisesRegex(AssertionError, "Multiple planes"):
            VERIFY_ICON.validate_compiled_layout(self.items)

    def test_arc_below_its_track_is_rejected(self):
        self.stack["Layers"][1:] = reversed(self.stack["Layers"][1:])
        with self.assertRaisesRegex(AssertionError, "above its track"):
            VERIFY_ICON.validate_compiled_layout(self.items)


class GaugeArtworkTests(unittest.TestCase):
    def setUp(self):
        self.source = ROOT / "Assets/AppIcon.icon"
        self.ring, self.arc = VERIFY_ICON.validate_sources(self.source)

    def test_arc_rides_its_track_from_twelve_oclock(self):
        start, radius, width, sweep = VERIFY_ICON.arc_geometry(self.arc.attrib["d"])
        self.assertEqual((radius, width), (float(self.ring.attrib["r"]), float(self.ring.attrib["stroke-width"])))
        self.assertEqual(start, (512.0, 512.0 - radius - width / 2))
        self.assertAlmostEqual(sweep, 252, delta=1)

    def test_legacy_and_layered_gauge_match(self):
        legacy = ET.parse(ROOT / "Assets/AppIcon.svg").getroot()
        circle = legacy.find("{http://www.w3.org/2000/svg}circle")
        path = legacy.find("{http://www.w3.org/2000/svg}path")
        for key in ["cx", "cy", "r", "stroke-width"]:
            self.assertEqual(circle.attrib[key], self.ring.attrib[key])
        self.assertEqual(path.attrib["d"], self.arc.attrib["d"])

    def test_clear_glass_colours_in_default_and_dark(self):
        import json
        document = json.loads((self.source / "icon.json").read_text())
        for fills in (document["fill-specializations"], document["groups"][0]["layers"][0]["fill-specializations"]):
            self.assertEqual(fills[0]["value"], fills[1]["value"])
            red, green, blue = (float(value) for value in fills[0]["value"]["automatic-gradient"].split(":")[1].split(",")[:3])
            self.assertLess(max(red, green, blue) - min(red, green, blue), 0.02, "Clear glass stays neutral grey")
        legacy = ET.parse(ROOT / "Assets/AppIcon.svg").getroot()
        stops = [stop.attrib["stop-color"] for stop in legacy.iter("{http://www.w3.org/2000/svg}stop")]
        self.assertEqual(stops, ["#4f4f51", "#454547", "#d7d6d9", "#c2c2c4"])

    def test_coloured_stroke_artwork_is_rejected(self):
        # Apple's generated legacy ICNS fills a recoloured stroke's whole path: a solid wedge.
        stroke = ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
                  '<path d="M 512 236 A 276 276 0 1 1 249.5 597.3" fill="none" stroke="#ffffff" stroke-width="104"/></svg>')
        with tempfile.TemporaryDirectory(prefix="allowance-icon-") as directory:
            copy_root = Path(directory) / "AppIcon.icon"
            shutil.copytree(self.source, copy_root)
            (copy_root / "Assets/Arc.svg").write_text(stroke)
            with self.assertRaisesRegex(AssertionError, "needs filled artwork"):
                VERIFY_ICON.validate_sources(copy_root)

    def test_sources_rejecting_a_dark_mode_colour_change(self):
        import json
        original = (self.source / "icon.json").read_text()
        document = json.loads(original)
        document["fill-specializations"][1]["value"] = {"automatic-gradient": "extended-srgb:0.05,0.05,0.05,1"}
        with tempfile.TemporaryDirectory(prefix="allowance-icon-") as directory:
            copy_root = Path(directory) / "AppIcon.icon"
            shutil.copytree(self.source, copy_root)
            (copy_root / "icon.json").write_text(json.dumps(document))
            with self.assertRaisesRegex(AssertionError, "Dark Mode must keep"):
                VERIFY_ICON.validate_sources(copy_root)


class BuildToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="allowance-tools-")
        self.root = Path(self.temporary.name)
        self.app = self.root / "Allowance.app"
        (self.app / "Contents/Resources").mkdir(parents=True)
        shutil.copy2(ROOT / "Info.plist", self.app / "Contents/Info.plist")
        (self.app / "Contents/Resources/AppIcon.icns").write_bytes(b"icns" + (8).to_bytes(4, "big"))

    def tearDown(self):
        self.temporary.cleanup()

    def test_required_notarization_fails_before_packaging_without_profile(self):
        env = dict(os.environ, REQUIRE_NOTARIZATION="1")
        env.pop("NOTARY_PROFILE", None)
        out = self.root / "release"
        result = subprocess.run(["bash", str(ROOT / "Scripts/package.sh"), str(self.app), str(out)], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NOTARY_PROFILE is required", result.stderr)
        self.assertFalse(out.exists())

    def test_layered_validation_rejects_flat_only_bundle(self):
        result = subprocess.run(["python3", str(ROOT / "Scripts/verify-icon.py"), str(self.app), "--require-layered"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing layered Assets.car", result.stderr)

    def test_packaging_rejects_misnamed_bundle(self):
        misnamed = self.root / "Release.app"
        self.app.rename(misnamed)
        out = self.root / "release"
        result = subprocess.run(["bash", str(ROOT / "Scripts/package.sh"), str(misnamed), str(out)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release bundle must be named Allowance.app", result.stderr)
        self.assertFalse(out.exists())

    def test_unknown_icon_style_is_rejected(self):
        env = dict(os.environ, ALLOWANCE_ICON_STYLE="unexpected")
        result = subprocess.run(["bash", str(ROOT / "Scripts/build-icons.sh"), str(self.app), str(self.root / "scratch")], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown icon style", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
