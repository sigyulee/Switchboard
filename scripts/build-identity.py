#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Assign build numbers and retain private source-to-artifact records."""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], stderr=subprocess.DEVNULL)


def repository_state(root):
    try:
        checkout_root = Path(git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    except subprocess.CalledProcessError:
        checkout_root = None
    if checkout_root == root.resolve():
        commit = git(root, "rev-parse", "--verify", "HEAD").decode().strip()
        common = Path(git(root, "rev-parse", "--git-common-dir").decode().strip())
        storage = (root / common).resolve() / "switchboard-builds"
        dirty = bool(git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all"))
        paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
        paths = sorted({os.fsdecode(p) for p in paths if p})
    else:
        commit, dirty = None, True
        storage = root / ".build/build-identity"
        inputs = ["Sources", "Tests", "scripts", "Installer", "Vendor", "docs", ".github"]
        paths = [str(p.relative_to(root)) for name in inputs for p in (root / name).rglob("*")
                 if p.is_file() or p.is_symlink()]
        paths += [p.name for p in root.iterdir() if p.is_file() and not p.name.startswith(".")]
    digest = hashlib.sha256()
    for name in sorted(set(paths)):
        path = root / name
        digest.update(os.fsencode(name) + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(str(path.stat().st_mode & 0o777).encode() + b"\0")
            digest.update(path.read_bytes())
        else:
            digest.update(b"missing")
        digest.update(b"\0")
    return {"commit": commit, "dirty": dirty, "source_sha256": digest.hexdigest()}, storage


def read_record(path):
    record = json.loads(path.read_text())
    if not isinstance(record, dict) or not re.fullmatch(r"[1-9][0-9]*", str(record.get("build", ""))):
        raise ValueError("Invalid build record")
    if not isinstance(record.get("release"), str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", record["release"]):
        raise ValueError("Invalid release version in build record")
    if record.get("configuration") not in {"release", "debug"} or type(record.get("dirty")) is not bool:
        raise ValueError("Invalid build configuration record")
    if record.get("commit") is not None and not re.fullmatch(r"[0-9a-f]{40}", str(record["commit"])):
        raise ValueError("Invalid source commit in build record")
    if not re.fullmatch(r"[0-9a-f]{64}", str(record.get("source_sha256", ""))):
        raise ValueError("Invalid source fingerprint in build record")
    return record


def reserve(root, version, configuration, explicit=None):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Release version must contain three numeric components")
    state, storage = repository_state(root)
    if configuration == "release" and state["commit"] and state["dirty"]:
        raise ValueError("Commit source changes before creating a release build; use debug for a dirty preview")
    if state["commit"] is None and explicit is None:
        raise ValueError("Source archives require an explicit SWITCHBOARD_BUILD_NUMBER")
    storage.mkdir(parents=True, exist_ok=True)
    with (storage / "number.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        reservations = storage / "reservations"
        reservations.mkdir(exist_ok=True)
        highest = max((int(p.stem) for p in reservations.glob("*.json") if p.stem.isdecimal()), default=0)
        previous = root / "build/Switchboard.app/Contents/Info.plist"
        if previous.exists():
            previous_version = str(plistlib.loads(previous.read_bytes()).get("CFBundleVersion", "0"))
            if re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", previous_version):
                highest = max(highest, int(previous_version.split(".")[0]))
        if explicit is not None and not re.fullmatch(r"[1-9][0-9]*", explicit):
            raise ValueError("Build number must be a positive integer")
        number = int(explicit) if explicit is not None else highest + 1
        if number <= highest:
            raise ValueError("Build number must exceed every existing reservation and previous bundle")
        record = {"release": version, "build": str(number), "configuration": configuration,
                  "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), **state}
        path = reservations / f"{number}.json"
        with path.open("x") as output:
            json.dump(record, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        return path


def bundle_digest(app):
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            content = b"link\0" + os.fsencode(os.readlink(path))
        elif path.is_file():
            content = path.read_bytes()
        else:
            continue
        digest.update(os.fsencode(str(path.relative_to(app))) + b"\0" + content + b"\0")
    return digest.hexdigest()


def validate_completed(record, app, require_release=False):
    if require_release and (record.get("configuration") != "release" or record.get("dirty") is not False
                            or not re.fullmatch(r"[0-9a-f]{40}", record.get("commit") or "")):
        raise ValueError("Installation requires a clean committed release build")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (record["release"], record["build"]):
        raise ValueError("Artifact version does not match its build record")
    if require_release and info.get("SwitchboardPreview") is not False:
        raise ValueError("A preview bundle cannot replace the installed app")
    if "channel" in record and info.get("SwitchboardReleaseChannel", "stable") != record["channel"]:
        raise ValueError("Artifact release channel does not match its build record")
    executable = hashlib.sha256((app / "Contents/MacOS/Switchboard").read_bytes()).hexdigest()
    if executable != record["executable_sha256"] or bundle_digest(app) != record["bundle_sha256"]:
        raise ValueError("Artifact contents do not match their recorded checksums")


def complete(root, record_path, app):
    record = read_record(record_path)
    state, storage = repository_state(root)
    if record_path.resolve() != (storage / "reservations" / f"{record['build']}.json").resolve():
        raise ValueError("Build reservation does not belong to this checkout")
    if any(record[key] != state[key] for key in state):
        raise ValueError("Source changed during the build; artifact was not registered")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (record["release"], record["build"]):
        raise ValueError("Bundle identity does not match the reserved build")
    records = storage / "completed"
    records.mkdir(exist_ok=True)
    target_record = records / f"{record['build']}.json"
    if target_record.exists():
        raise ValueError("This build has already been registered")
    artifact_root = storage / "artifacts" / f"{record['release']}-{record['build']}"
    artifact_root.mkdir(parents=True, exist_ok=False)
    retained = artifact_root / "Switchboard.app"
    try:
        shutil.copytree(app, retained, symlinks=True)
        checksum = bundle_digest(app)
        if bundle_digest(retained) != checksum:
            raise ValueError("Retained bundle does not match the build")
        result = {**record, "channel": info.get("SwitchboardReleaseChannel", "stable"), "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "executable_sha256": hashlib.sha256((retained / "Contents/MacOS/Switchboard").read_bytes()).hexdigest(),
                  "bundle_sha256": checksum, "artifact": str(retained.resolve())}
        with target_record.open("x") as output:
            json.dump(result, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        # A pointer for local tooling; completed records and artifacts remain immutable.
        pointer = root / "build/current-build.json"
        temporary = pointer.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(result, indent=2) + "\n")
        temporary.replace(pointer)
    except BaseException:
        if not target_record.exists():
            shutil.rmtree(artifact_root)
        raise
    return target_record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build")
    build.add_argument("configuration", choices=["debug", "release"])
    prepare = commands.add_parser("reserve")
    prepare.add_argument("version")
    prepare.add_argument("configuration", choices=["debug", "release"])
    prepare.add_argument("--number")
    field = commands.add_parser("number")
    field.add_argument("record", type=Path)
    finish = commands.add_parser("complete")
    finish.add_argument("record", type=Path)
    finish.add_argument("app", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        if args.command == "build":
            _, storage = repository_state(root)
            storage.mkdir(parents=True, exist_ok=True)
            with (storage / "package.lock").open("a+b") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                env = {**os.environ, "SWITCHBOARD_PACKAGE_LOCK_HELD": "1"}
                return subprocess.call(["bash", str(root / "scripts/build-app.sh"), args.configuration], env=env)
        elif args.command == "reserve":
            print(reserve(root, args.version, args.configuration, args.number))
        elif args.command == "number":
            print(read_record(args.record)["build"])
        elif args.command == "complete":
            print(complete(root, args.record, args.app))
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Build identity: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
