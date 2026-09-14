#!/usr/bin/env python3
"""Account-free regression checks for release guardrails."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


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
