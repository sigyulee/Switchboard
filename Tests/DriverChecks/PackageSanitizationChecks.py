# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("package_check", Path(__file__).resolve().parents[2] / "scripts/check-package.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageSanitizationChecks(unittest.TestCase):
    def test_clean_payload_and_private_data(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / "App.app"
            app.mkdir()
            payload = app / "executable"
            payload.write_bytes(b"clean payload")
            subprocess.run(["xattr", "-cr", str(app)], check=True)
            self.assertEqual(module.check(app), 1)
            subprocess.run(["xattr", "-w", "com.switchboard.test", "private", str(payload)], check=True)
            with self.assertRaises(ValueError):
                module.check(app)
            subprocess.run(["xattr", "-cr", str(app)], check=True)
            for data in (b"/" + b"Users/tester/private", b"ghp_" + b"x" * 40,
                         b"-----BEGIN PRIVATE KEY-----"):
                payload.write_bytes(data)
                with self.assertRaises(ValueError):
                    module.check(app)

    def test_symlink_cannot_import_external_files(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / "App.app"
            app.mkdir()
            (app / "external").symlink_to(Path(root))
            with self.assertRaises(ValueError):
                module.check(app)


if __name__ == "__main__":
    unittest.main()
