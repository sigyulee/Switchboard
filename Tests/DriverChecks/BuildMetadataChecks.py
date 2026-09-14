# SPDX-License-Identifier: AGPL-3.0-only
"""Run the app builder's actual metadata step against a temporary payload."""

from pathlib import Path
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildMetadataChecks(unittest.TestCase):
    def test_payload_hashes_document_types_and_usage_text(self):
        script = (ROOT / "scripts" / "build-app.sh").read_text()
        blocks = re.findall(r"^python3 .* <<'PY'\n(.*?)^PY$", script, re.MULTILINE | re.DOTALL)
        self.assertEqual(len(blocks), 1, "expected the app's single Python metadata step")
        with tempfile.TemporaryDirectory(prefix="switchboard-metadata-check-") as temporary:
            app = Path(temporary) / "Switchboard.app"
            drivers = app / "Contents" / "Resources" / "Drivers"
            expected_hashes = {}
            for name in ("MIHCaller", "MIHReply", "SwitchboardAgent"):
                file = drivers / (name + ".driver") / "Contents" / "MacOS" / name
                file.parent.mkdir(parents=True)
                file.write_bytes(name.encode())
                expected_hashes[str(file.relative_to(drivers))] = hashlib.sha256(file.read_bytes()).hexdigest()
            result = subprocess.run([sys.executable, "-c", blocks[0], str(app), "debug", "1.1.0",
                                     "25"],
                                    cwd=ROOT, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((drivers / "hashes.json").read_text()), expected_hashes)
            info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
            self.assertEqual(info["CFBundleShortVersionString"], "1.1.0")
            self.assertEqual(info["CFBundleVersion"], "25")
            self.assertEqual(info["SwitchboardReleaseChannel"], (ROOT / "scripts/release-channel.txt").read_text().strip())
            self.assertNotIn("SwitchboardSourceCommit", info)
            declarations = {entry["UTTypeIdentifier"]: entry for entry in info["UTExportedTypeDeclarations"]}
            for identifier, extension in (("com.switchboard.main.session", "switchboard"),
                                          ("com.switchboard.main.recording", "mihrecording")):
                entry = declarations[identifier]
                self.assertEqual(set(entry["UTTypeConformsTo"]), {"public.directory", "com.apple.package"})
                self.assertEqual(entry["UTTypeTagSpecification"]["public.filename-extension"], [extension])
                self.assertTrue(any(identifier in document["LSItemContentTypes"]
                                    and document["LSTypeIsPackage"] for document in info["CFBundleDocumentTypes"]))
            catalog = json.loads((ROOT / "Sources/Switchboard/Resources/InfoPlist.xcstrings").read_text())
            for key, entry in catalog["strings"].items():
                with self.subTest(purpose=key):
                    self.assertEqual(info[key], entry["localizations"]["en"]["stringUnit"]["value"])


if __name__ == "__main__":
    unittest.main()
