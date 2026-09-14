#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Reject private data and local filesystem metadata in a staged release app."""

from pathlib import Path
import subprocess
import re
import sys

PATTERNS = (
    re.compile(rb"/(?:Users|Volumes|home)/"),
    re.compile(rb"-----BEGIN (?:OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----"),
    re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{30,})"),
)


def check(app):
    if not app.is_dir() or app.is_symlink():
        raise ValueError("Expected a staged app directory")
    count = 0
    for path in [app, *app.rglob("*")]:
        if path.is_symlink():
            raise ValueError("Unexpected symbolic link in release app")
        if not path.is_file():
            continue
        data = path.read_bytes()
        if any(pattern.search(data) for pattern in PATTERNS):
            raise ValueError(f"Private data or local path in {path.relative_to(app)}")
        count += 1
    attributes = subprocess.run(["xattr", "-r", str(app)], capture_output=True, check=True)
    # macOS regenerates this protected, opaque attribute on local files. Archive
    # writers must omit all extended attributes, including this one.
    names = [line.rsplit(b": ", 1)[-1] for line in attributes.stdout.splitlines()]
    if any(name != b"com.apple.provenance" for name in names):
        raise ValueError("Extended filesystem metadata in release app")
    return count


if __name__ == "__main__":
    try:
        count = check(Path(sys.argv[1]))
        print(f"Release package sanitization passed: {count} files.")
    except (OSError, ValueError, IndexError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
