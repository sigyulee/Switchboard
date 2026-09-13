# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise preparation against isolated valid and corrupted vendor inputs."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PreparationChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="switchboard-driver-check-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.vendor = self.root / "Vendor" / "BlackHole"
        shutil.copytree(ROOT / "Vendor" / "BlackHole", self.vendor)
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts" / "prepare-driver.py"
        shutil.copyfile(ROOT / "scripts" / "prepare-driver.py", self.script)
        self.output = self.root / "build" / "BlackHole.c"
        self.output.parent.mkdir()
        self.output.write_bytes(b"existing build output")

    def run_prepare(self, *arguments):
        return subprocess.run([sys.executable, str(self.script), *map(str, arguments)],
                              capture_output=True, text=True, check=False)

    def check_rejected(self, expected):
        result = self.run_prepare(self.output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected, result.stderr)
        self.assertEqual(self.output.read_bytes(), b"existing build output")

    def test_valid_preparation_matches_locked_output_and_preserves_vendor(self):
        before = (self.vendor / "BlackHole.c").read_bytes()
        result = self.run_prepare(self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        lock = json.loads((self.vendor / "patches" / "patch-lock.json").read_text())
        self.assertEqual(hashlib.sha256(self.output.read_bytes()).hexdigest(), lock["prepared_sha256"])
        self.assertEqual((self.vendor / "BlackHole.c").read_bytes(), before)

    def test_check_mode_does_not_write_output(self):
        result = self.run_prepare("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_bytes(), b"existing build output")

    def test_corrupt_upstream_input_preserves_existing_output(self):
        for name in ("BlackHole.c", "BlackHole.plist", "LICENSE"):
            with self.subTest(name=name):
                path = self.vendor / name
                original = path.read_bytes()
                path.write_bytes(original + b"corrupt")
                self.check_rejected("checksum mismatch: " + name)
                path.write_bytes(original)

    def test_corrupt_patch_preserves_existing_output(self):
        patch = self.vendor / "patches" / "0001-property-contracts.patch"
        patch.write_bytes(patch.read_bytes() + b"corrupt")
        self.check_rejected("checksum mismatch: " + patch.name)

    def test_unexpected_prepared_digest_preserves_existing_output(self):
        path = self.vendor / "patches" / "patch-lock.json"
        lock = json.loads(path.read_text())
        lock["prepared_sha256"] = "0" * 64
        path.write_text(json.dumps(lock))
        self.check_rejected("checksum mismatch: BlackHole.c")

    def test_mismatched_patch_source_is_rejected(self):
        path = self.vendor / "patches" / "patch-lock.json"
        lock = json.loads(path.read_text())
        lock["source_sha256"] = "0" * 64
        path.write_text(json.dumps(lock))
        self.check_rejected("patch source does not match")

    def test_patch_path_traversal_is_rejected(self):
        path = self.vendor / "patches" / "patch-lock.json"
        lock = json.loads(path.read_text())
        lock["patches"][0]["file"] = "../../outside.patch"
        path.write_text(json.dumps(lock))
        self.check_rejected("invalid driver patch filename")

    def test_vendor_output_is_rejected(self):
        source = self.vendor / "BlackHole.c"
        before = source.read_bytes()
        result = self.run_prepare(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the pinned vendor directory", result.stderr)
        self.assertEqual(source.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
