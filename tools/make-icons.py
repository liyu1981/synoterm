#!/usr/bin/env python3
"""Generates the DSM package icons (a ">_" terminal mark) as PNGs.

Kept dependency-free so that a release build works on a bare NAS/CI runner
without Pillow. Run via tools/build-spk.sh.
"""
import struct
import sys
import zlib
from pathlib import Path

SIZES = (16, 24, 32, 48, 64, 72, 128, 256)
BG = (24, 34, 45, 255)
FG = (97, 218, 251, 255)
TRANSPARENT = (0, 0, 0, 0)


def chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def inside_rounded(x: float, y: float, radius: float) -> bool:
    if x < 0 or x > 1 or y < 0 or y > 1:
        return False
    cx = min(max(x, radius), 1 - radius)
    cy = min(max(y, radius), 1 - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius**2


def pixel(size: int, x: int, y: int) -> tuple:
    # Normalised coordinates, with a small margin so DSM can round corners.
    nx = (x + 0.5) / size
    ny = (y + 0.5) / size
    if not inside_rounded(nx, ny, 0.18):
        return TRANSPARENT

    # Chevron ">"
    ax, ay = 0.30, 0.34
    bx, by = 0.52, 0.50
    cx, cy = 0.30, 0.66
    thickness = 0.075

    def dist_to_segment(px, py, x1, y1, x2, y2):
        dx, dy = x2 - x1, y2 - y1
        length_sq = dx * dx + dy * dy
        t = ((px - x1) * dx + (py - y1) * dy) / length_sq
        t = max(0.0, min(1.0, t))
        qx, qy = x1 + t * dx, y1 + t * dy
        return ((px - qx) ** 2 + (py - qy) ** 2) ** 0.5

    chevron = min(
        dist_to_segment(nx, ny, ax, ay, bx, by),
        dist_to_segment(nx, ny, bx, by, cx, cy),
    )
    if chevron <= thickness:
        return FG

    # Underscore "_"
    if 0.56 <= nx <= 0.74 and 0.62 <= ny <= 0.70:
        return FG

    return BG


def render(size: int) -> bytes:
    rows = []
    for y in range(size):
        row = bytearray([0])  # PNG filter type 0
        for x in range(size):
            row.extend(pixel(size, x, y))
        rows.append(bytes(row))
    raw = b"".join(rows)

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: make-icons.py <output-dir>", file=sys.stderr)
        return 2
    out = Path(argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        (out / f"icon_{size}.png").write_bytes(render(size))
    print(f"wrote {len(SIZES)} icons to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
