# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise build reservations and immutable artifact records using temporary Git repos."""

from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("build_identity", ROOT / "scripts/build-identity.py")
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class BuildIdentityChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="switchboard-build-identity-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.command("init", "-q")
        self.command("config", "user.name", "Build fixture")
        self.command("config", "user.email", "fixture@example.invalid")
        (self.root / ".gitignore").write_text("build/\n.build/\n")
        (self.root / "source.txt").write_text("original source\n")
        self.command("add", ".")
        self.command("-c", "commit.gpgsign=false", "commit", "-qm", "Fixture source")

    def command(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], stderr=subprocess.STDOUT)

    def bundle(self, number, version="1.1.0"):
        app = self.root / "build/Switchboard.app"
        (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
        (app / "Contents/MacOS/Switchboard").write_bytes(b"test executable")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": version, "CFBundleVersion": number, "SwitchboardPreview": False,
        }))
        return app

    def test_numbers_advance_past_legacy_bundle_and_failed_reservations(self):
        self.bundle("1.1.0")
        first = identity.reserve(self.root, "1.1.0", "release")
        second = identity.reserve(self.root, "1.1.0", "release")
        self.assertEqual(identity.read_record(first)["build"], "2")
        self.assertEqual(identity.read_record(second)["build"], "3")
        self.assertNotEqual(first, second)

    def test_concurrent_reservations_are_unique(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            paths = list(pool.map(lambda _: identity.reserve(self.root, "1.1.0", "release"), range(8)))
        self.assertEqual({identity.read_record(p)["build"] for p in paths}, set(map(str, range(1, 9))))

    def test_dirty_release_is_rejected_and_preview_is_recorded_honestly(self):
        (self.root / "source.txt").write_text("uncommitted change\n")
        with self.assertRaisesRegex(ValueError, "Commit source"):
            identity.reserve(self.root, "1.1.0", "release")
        preview = identity.read_record(identity.reserve(self.root, "1.1.0", "debug"))
        self.assertTrue(preview["dirty"])
        self.assertEqual(preview["commit"], self.command("rev-parse", "HEAD").decode().strip())

    def test_build_numbers_cannot_be_reused_or_malformed(self):
        identity.reserve(self.root, "1.1.0", "release", "10")
        for value in ["10", "9", "0", "-1", "2.1", "abc"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                identity.reserve(self.root, "1.1.0", "release", value)
        with self.assertRaises(ValueError):
            identity.reserve(self.root, "1.1", "release")

    def test_persisted_release_cannot_escape_artifact_storage(self):
        reservation = identity.reserve(self.root, "1.1.0", "release")
        record = json.loads(reservation.read_text())
        record["release"] = "../escape"
        reservation.write_text(json.dumps(record))
        app = self.bundle("1", version="../escape")
        with self.assertRaisesRegex(ValueError, "Invalid release"):
            identity.complete(self.root, reservation, app)

    def test_completed_build_retains_artifact_and_does_not_replace_history(self):
        reservation = identity.reserve(self.root, "1.1.0", "release")
        app = self.bundle("1")
        completed = identity.complete(self.root, reservation, app)
        original = completed.read_bytes()
        record = json.loads(original)
        retained = self.root / record["artifact"]
        self.assertEqual(identity.bundle_digest(retained), record["bundle_sha256"])
        self.assertEqual(record["commit"], self.command("rev-parse", "HEAD").decode().strip())
        self.assertFalse(record["dirty"])
        with self.assertRaisesRegex(ValueError, "already been registered"):
            identity.complete(self.root, reservation, app)
        self.assertEqual(completed.read_bytes(), original)
        (app / "Contents/MacOS/Switchboard").write_bytes(b"a later build")
        self.assertEqual((retained / "Contents/MacOS/Switchboard").read_bytes(), b"test executable")

    def test_source_or_bundle_identity_changes_block_registration(self):
        reservation = identity.reserve(self.root, "1.1.0", "release")
        app = self.bundle("999")
        with self.assertRaisesRegex(ValueError, "Bundle identity"):
            identity.complete(self.root, reservation, app)
        self.bundle("1")
        (self.root / "source.txt").write_text("changed while compiling\n")
        with self.assertRaisesRegex(ValueError, "Source changed"):
            identity.complete(self.root, reservation, app)

    def test_installation_validation_rejects_preview_and_changed_resources(self):
        reservation = identity.reserve(self.root, "1.1.0", "release")
        app = self.bundle("1")
        record = identity.read_record(identity.complete(self.root, reservation, app))
        identity.validate_completed(record, app, require_release=True)
        for invalid in [{**record, "configuration": "debug"}, {**record, "dirty": True},
                        {**record, "commit": None}]:
            with self.subTest(record=invalid), self.assertRaisesRegex(ValueError, "clean committed release"):
                identity.validate_completed(invalid, app, require_release=True)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        info["SwitchboardPreview"] = True
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "preview bundle"):
            identity.validate_completed(record, app, require_release=True)
        self.bundle("1")
        (app / "Contents/unexpected-resource.txt").write_text("a different bundle with the same executable")
        with self.assertRaisesRegex(ValueError, "checksums"):
            identity.validate_completed(record, app, require_release=True)

    def test_source_archives_need_an_explicit_number(self):
        with tempfile.TemporaryDirectory(prefix="switchboard-source-archive-") as directory:
            root = Path(directory)
            (root / "VERSION").write_text("1.1.0\n")
            with self.assertRaisesRegex(ValueError, "explicit"):
                identity.reserve(root, "1.1.0", "release")
            record = identity.read_record(identity.reserve(root, "1.1.0", "release", "15"))
            self.assertEqual(record["build"], "15")
            self.assertIsNone(record["commit"])

    def test_archive_inside_another_checkout_does_not_inherit_its_commit(self):
        archive = self.root / "archive"
        archive.mkdir()
        (archive / "VERSION").write_text("1.1.0\n")
        reservation = identity.reserve(archive, "1.1.0", "release", "15")
        record = identity.read_record(reservation)
        self.assertIsNone(record["commit"])
        (archive / "VERSION").write_text("1.1.1\n")
        self.assertNotEqual(identity.repository_state(archive)[0]["source_sha256"], record["source_sha256"])

    def test_retained_build_survives_removing_its_worktree(self):
        worktree = self.root / "build/worktree"
        self.command("worktree", "add", "--detach", str(worktree), "HEAD")
        reservation = identity.reserve(worktree, "1.1.0", "release")
        app = worktree / "build/Switchboard.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/Switchboard").write_bytes(b"worktree executable")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "1",
        }))
        record = identity.read_record(identity.complete(worktree, reservation, app))
        artifact = Path(record["artifact"])
        self.assertTrue(artifact.is_absolute(), "The shared record has an ambiguous checkout-relative path")
        self.command("worktree", "remove", "--force", str(worktree))
        self.assertEqual((artifact / "Contents/MacOS/Switchboard").read_bytes(), b"worktree executable")


if __name__ == "__main__":
    unittest.main()
