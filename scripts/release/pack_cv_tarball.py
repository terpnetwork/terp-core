#!/usr/bin/env python3
"""Deterministic Cosmovisor tarball: one member `terpd`.

Portable (macOS BSD tar has no GNU --mtime/--owner). Same ELF + SOURCE_DATE_EPOCH
→ same sha256. Convention matches make_release_bundle.sh (epoch = tag commit %ct).

  tar: USTAR, sorted members, mtime=epoch, uid=gid=0, empty uname/gname, mode 0755
  gzip: level 9, mtime=0, no filename
"""
from __future__ import annotations

import gzip
import io
import sys
import tarfile


def pack(src: str, dest: str, epoch: int) -> None:
    with open(src, "rb") as f:
        data = f.read()
    tar_buf = io.BytesIO()
    with tarfile.open(fileobj=tar_buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        info = tarfile.TarInfo(name="terpd")
        info.size = len(data)
        info.mtime = int(epoch)
        info.uid = 0
        info.gid = 0
        info.uname = ""
        info.gname = ""
        info.mode = 0o755
        info.type = tarfile.REGTYPE
        tf.addfile(info, io.BytesIO(data))
    raw = tar_buf.getvalue()
    with open(dest, "wb") as out:
        with gzip.GzipFile(
            filename="", mode="wb", fileobj=out, mtime=0, compresslevel=9
        ) as gz:
            gz.write(raw)


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: pack_cv_tarball.py <src-elf> <dest.tar.gz> <SOURCE_DATE_EPOCH>", file=sys.stderr)
        return 2
    pack(sys.argv[1], sys.argv[2], int(sys.argv[3]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
