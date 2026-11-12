#!/usr/bin/env python3
"""Builds the release zip: dist/TOARotationHelper-<version>.zip and dist/SHA256SUMS.

The zip holds, under TOARotationHelper/, the TOC, every file the TOC loads, README.md and
LICENSE, in that order. Entries are STORED with a fixed timestamp (2026-01-01 00:00), so
the same sources give the same bytes on every machine. The TOC's ## Version must equal
VERSION, and a carriage return in a source file stops the build.
"""
import hashlib
import sys
import zipfile
from pathlib import Path

FOLDER = "TOARotationHelper"
ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    version = (ROOT / "VERSION").read_text().strip()
    toc_path = ROOT / f"{FOLDER}.toc"
    toc = toc_path.read_text()
    toc_version = ""
    files = []
    for raw in toc.splitlines():
        line = raw.strip()
        if line.lower().startswith("## version:"):
            toc_version = line.split(":", 1)[1].strip()
        elif line and not line.startswith("#"):
            files.append(line.replace("\\", "/"))
    if toc_version != version:
        print(f"TOC version {toc_version!r} is not VERSION {version!r}", file=sys.stderr)
        return 1
    entries = [f"{FOLDER}.toc"] + files + ["README.md", "LICENSE"]
    out_dir = ROOT / "dist"
    out_dir.mkdir(exist_ok=True)
    out = out_dir / f"{FOLDER}-{version}.zip"
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_STORED) as zf:
        for rel in entries:
            data = (ROOT / rel).read_bytes()
            if b"\r" in data:
                print(f"{rel} has a carriage return", file=sys.stderr)
                return 1
            info = zipfile.ZipInfo(f"{FOLDER}/{rel}", date_time=(2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (0o100644) << 16
            zf.writestr(info, data)
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    (out_dir / "SHA256SUMS").write_text(f"{digest}  {out.name}\n")
    print(f"{out.relative_to(ROOT)} {out.stat().st_size} bytes sha256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
