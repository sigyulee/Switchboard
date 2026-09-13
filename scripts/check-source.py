#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Validate source files and pinned license material."""

import hashlib
import json
import os
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
PUBLIC_DIRECTORIES = ("Sources", "Tests", "Installer", "scripts", "docs", ".github")
PUBLIC_ROOT_FILES = (
    "CONTRIBUTING.md", "LICENSE", "NOTICE.md", "VERSION",
    "README.md", "SECURITY.md", "Package.swift", ".gitignore", ".gitattributes", ".swift-format", ".editorconfig",
)
TEXT_SUFFIXES = {
    ".c", ".h", ".swift", ".py", ".sh", ".md", ".txt", ".json", ".toml",
    ".yml", ".yaml", ".plist", ".xcstrings", ".strings", ".stringsdict", ".patch",
}
AGPL_SHA256 = "0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0"
BLACKHOLE_REPOSITORY = "https://github.com/ExistentialAudio/BlackHole"
BLACKHOLE_FILES = {"BlackHole.c", "BlackHole.plist", "LICENSE"}
PERSONAL_PATH = re.compile(
    r"(?<![\w])/(?:Users|home|Volumes)/[^/\s\"'`<>]+"
    r"|(?<![\w])[A-Za-z]:[\\/]+Users[\\/]+[^\\/\s\"'`<>]+"
)
CONFLICT_MARKER = re.compile(r"^(?:<{7} |={7}$|>{7} )", re.MULTILINE)


def read_public_file(path):
    """Do not follow source symlinks into private or external directories."""
    relative = path.relative_to(ROOT)
    current = ROOT
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError(f"{relative}: public input must not be a symbolic link")
    return path.read_bytes()


def public_files():
    for name in PUBLIC_ROOT_FILES:
        yield ROOT / name
    for name in PUBLIC_DIRECTORIES:
        directory = ROOT / name
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError(f"{name}: expected a public source directory")
        for current, directories, files in os.walk(directory, followlinks=False):
            # Hidden directories contain local state, not public inputs. Never
            # descend into them, even when they occur under a source directory.
            directories[:] = sorted(d for d in directories if not d.startswith("."))
            for child in directories:
                if (Path(current) / child).is_symlink():
                    raise ValueError(f"{name}: symbolic source directories are unsupported")
            for filename in sorted(files):
                path = Path(current) / filename
                if not filename.startswith(".") and path.suffix in TEXT_SUFFIXES:
                    yield path


def check_public_sources():
    count = 0
    for path in public_files():
        content = read_public_file(path)
        relative = path.relative_to(ROOT)
        text = content.decode("utf-8")
        match = PERSONAL_PATH.search(text)
        if match:
            line = text.count("\n", 0, match.start()) + 1
            # Report the location without copying a personal path into CI logs.
            raise ValueError(f"{relative}:{line}: personal absolute path in public input")
        if CONFLICT_MARKER.search(text):
            raise ValueError(f"{relative}: unresolved merge conflict marker")
        if path.suffix == ".py":
            compile(content, str(relative), "exec")
        if path.suffix in {".json", ".xcstrings"} or path.name == ".swift-format":
            json.loads(text)
        count += 1
    return count


def check_licenses():
    if hashlib.sha256(read_public_file(ROOT / "LICENSE")).hexdigest() != AGPL_SHA256:
        raise ValueError("LICENSE: the complete AGPLv3 text has changed")
    notice = read_public_file(ROOT / "NOTICE.md").decode("utf-8")
    if "AGPL-3.0-only" not in notice:
        raise ValueError("NOTICE.md: missing original-code AGPL-3.0-only declaration")

    vendor = ROOT / "Vendor" / "BlackHole"
    lock = json.loads(read_public_file(vendor / "source-lock.json"))
    if not isinstance(lock, dict) or lock.get("repository") != BLACKHOLE_REPOSITORY:
        raise ValueError("BlackHole source-lock.json: unexpected upstream repository")
    commit = lock.get("commit")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("BlackHole source-lock.json: commit must be a full Git SHA")
    files = lock.get("files")
    if not isinstance(files, dict) or set(files) != BLACKHOLE_FILES:
        raise ValueError("BlackHole source-lock.json: expected source, plist, and GPL license hashes")
    for name, expected in files.items():
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError(f"BlackHole source-lock.json: invalid SHA-256 for {name}")
        actual = hashlib.sha256(read_public_file(vendor / name)).hexdigest()
        if actual != expected:
            raise ValueError(f"Vendor/BlackHole/{name}: checksum differs from source-lock.json")
    upstream = read_public_file(vendor / "UPSTREAM.md").decode("utf-8")
    if commit not in upstream or BLACKHOLE_REPOSITORY not in upstream or commit not in notice:
        raise ValueError("BlackHole provenance notices must identify the source-lock.json commit")
    license_text = read_public_file(vendor / "LICENSE").decode("utf-8")
    if "GNU GENERAL PUBLIC LICENSE" not in license_text or "Version 3, 29 June 2007" not in license_text:
        raise ValueError("Vendor/BlackHole/LICENSE: missing upstream GPLv3 license")


def main():
    try:
        count = check_public_sources()
        check_licenses()
    except (OSError, UnicodeError, ValueError, SyntaxError) as error:
        print(f"Source validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Source validation passed: {count} public text files; AGPL and BlackHole checksums intact.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
