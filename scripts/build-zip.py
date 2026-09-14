#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Package the recorded app without extended attributes or host filesystem metadata."""

import importlib.util
import json
from pathlib import Path
import stat
import sys
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    identity = load("build_identity", "build-identity.py")
    validation = load("package_check", "check-package.py")
    record = json.loads((ROOT / "build/current-build.json").read_text())
    app = Path(record["artifact"])
    identity.validate_completed(record, app, require_release=True)
    validation.check(app)
    channel = record.get("channel", "stable")
    if channel not in ("beta", "stable"):
        raise ValueError("Invalid release channel")
    output = ROOT / "build" / f"Switchboard-{record['release']}-{channel}-{record['build']}-arm64.zip"
    try:
        with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in [app, *sorted(app.rglob("*"))]:
                relative = path.relative_to(app.parent).as_posix()
                item = zipfile.ZipInfo(relative + ("/" if path.is_dir() else ""))
                item.create_system = 3
                mode = stat.S_IFDIR | 0o755 if path.is_dir() else stat.S_IFREG | (0o755 if path.stat().st_mode & 0o111 else 0o644)
                item.external_attr = mode << 16
                item.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(item, b"" if path.is_dir() else path.read_bytes())
        identity.validate_completed(record, app, require_release=True)
        with zipfile.ZipFile(output) as archive:
            if archive.testzip() is not None or any(item.extra or item.comment for item in archive.infolist()):
                raise ValueError("Archive validation failed")
    except FileExistsError:
        raise
    except BaseException:
        output.unlink(missing_ok=True)
        raise
    print(output)


if __name__ == "__main__":
    main()
