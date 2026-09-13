#!/usr/bin/env python3
"""Generate our original vector audio-device icon without third-party artwork."""

from pathlib import Path
import sys


def make_pdf() -> bytes:
    # A blue audio waveform on a white 64-point canvas, drawn as vector strokes.
    commands = ["1 1 1 rg 0 0 64 64 re f", "0.10 0.43 0.91 RG 4 w 1 J"]
    for x, half_height in [(12, 5), (22, 13), (32, 23), (42, 13), (52, 5)]:
        commands.append(f"{x} {32-half_height} m {x} {32+half_height} l S")
    content = "\n".join(commands).encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64 64] /Contents 4 0 R /Resources << >> >>",
        f"<< /Length {len(content)} >>\nstream\n".encode() + content + b"\nendstream",
    ]
    result = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, obj in enumerate(objects, start=1):
        offsets.append(len(result))
        result.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(result)
    result.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        result.extend(f"{offset:010d} 00000 n \n".encode())
    result.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(result)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: make-driver-icon.py OUTPUT.pdf")
    Path(sys.argv[1]).write_bytes(make_pdf())
