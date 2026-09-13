#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Verify pinned BlackHole inputs and apply the locked patches to a build copy."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "Vendor" / "BlackHole"


def checked_hash(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("invalid SHA-256 in driver lock")
    return value


def verified_bytes(path, expected):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != checked_hash(expected):
        raise ValueError(f"checksum mismatch: {path.name}")
    return data


def prepare_source(vendor):
    source_lock = json.loads((vendor / "source-lock.json").read_text())
    if source_lock.get("repository") != "https://github.com/ExistentialAudio/BlackHole":
        raise ValueError("unexpected BlackHole repository")
    if re.fullmatch(r"[0-9a-f]{40}", source_lock.get("commit", "")) is None:
        raise ValueError("invalid BlackHole commit")
    files = source_lock.get("files")
    if not isinstance(files, dict) or set(files) != {"BlackHole.c", "BlackHole.plist", "LICENSE"}:
        raise ValueError("unexpected BlackHole input files")
    inputs = {name: verified_bytes(vendor / name, digest) for name, digest in files.items()}

    patch_lock = json.loads((vendor / "patches" / "patch-lock.json").read_text())
    if checked_hash(patch_lock["source_sha256"]) != files["BlackHole.c"]:
        raise ValueError("patch source does not match the pinned BlackHole source")
    expected_output = checked_hash(patch_lock["prepared_sha256"])
    patches = patch_lock["patches"]
    if not isinstance(patches, list) or not patches:
        raise ValueError("driver patch list must not be empty")
    patch_inputs = []
    names = set()
    for entry in patches:
        name = entry["file"]
        if not isinstance(name, str) or re.fullmatch(r"[a-zA-Z0-9_-]+\.patch", name) is None:
            raise ValueError("invalid driver patch filename")
        if name in names:
            raise ValueError("duplicate driver patch")
        names.add(name)
        patch_inputs.append(verified_bytes(vendor / "patches" / name, entry["sha256"]))

    with tempfile.TemporaryDirectory(prefix="switchboard-driver-source-") as directory:
        prepared = Path(directory) / "BlackHole.c"
        prepared.write_bytes(inputs["BlackHole.c"])
        for patch in patch_inputs:
            # The explicit original file confines patch writes to this temporary
            # copy. Hash the result as well; offsets or unexpected edits fail shut.
            result = subprocess.run(["patch", "-s", "-f", "-F", "0", str(prepared)],
                                    input=patch, capture_output=True, check=False)
            if result.returncode != 0:
                raise ValueError("locked driver patch did not apply: "
                                 + result.stderr.decode(errors="replace").strip())
        return verified_bytes(prepared, expected_output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, nargs="?", help="prepared BlackHole.c destination")
    parser.add_argument("--check", action="store_true", help="verify without writing build output")
    args = parser.parse_args()
    if args.check == (args.output is not None):
        parser.error("choose one output path or --check")
    try:
        if args.output is not None and VENDOR in args.output.resolve().parents:
            raise ValueError("prepared output must be outside the pinned vendor directory")
        prepared = prepare_source(VENDOR)
        if args.output is not None:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=args.output.parent,
                                                 prefix=".driver-source-", delete=False) as output:
                    temporary = Path(output.name)
                    output.write(prepared)
                os.replace(temporary, args.output)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
        print("Driver source and patches verified: " + hashlib.sha256(prepared).hexdigest())
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Driver preparation failed: {error}\n")


if __name__ == "__main__":
    main()
