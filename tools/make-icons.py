#!/usr/bin/env python3
"""Draws the synoterm app icon once and emits every format the package needs.

The geometry below is the single source of truth: it is rasterised to PNG at
every DSM icon size and also written out as an SVG (for docs, the web UI and
anyone who wants to re-cut it).

Design: a dark rounded "terminal window" with a bright `>_` prompt. Shapes are
defined in unit space (0..1) and rasterised with a signed-distance field, so
edges stay smooth at 16 px without needing Pillow, cairosvg, rsvg or a browser
— a release build must work on a bare NAS.

    tools/make-icons.py <outdir>        # icon_{16,24,32,48,64,72,128,256}.png + icon.svg
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZES = (16, 24, 32, 48, 64, 72, 128, 256)

# ----------------------------------------------------------------- palette --
BG_TOP = (30, 44, 60)  # #1e2c3c
BG_BOTTOM = (13, 20, 28)  # #0d141c
BORDER = (74, 100, 128)  # #4a6480
GLYPH_TOP = (150, 242, 255)  # #96f2ff
GLYPH_BOTTOM = (47, 176, 226)  # #2fb0e2

# ---------------------------------------------------------------- geometry --
# All values are fractions of the icon edge, so the same numbers drive the PNG
# rasteriser and the SVG (which uses a 1024 unit viewBox).
PLATE = {"cx": 0.5, "cy": 0.5, "half": 0.478, "radius": 0.222, "border": 0.012}
CHEVRON = [(0.285, 0.295), (0.472, 0.500), (0.285, 0.705)]
CHEVRON_WIDTH = 0.098  # stroke width (diameter of the round-capped capsule)
CURSOR = {"x0": 0.545, "x1": 0.725, "y0": 0.612, "y1": 0.700}


# ------------------------------------------------------------------- utils --
def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return low if value < low else high if value > high else value


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def sdf_round_rect(px, py, cx, cy, hx, hy, radius) -> float:
    qx = abs(px - cx) - (hx - radius)
    qy = abs(py - cy) - (hy - radius)
    ax, ay = max(qx, 0.0), max(qy, 0.0)
    return math.hypot(ax, ay) + min(max(qx, qy), 0.0) - radius


def sdf_segment(px, py, ax, ay, bx, by) -> float:
    dx, dy = bx - ax, by - ay
    length_sq = dx * dx + dy * dy
    if length_sq == 0.0:
        return math.hypot(px - ax, py - ay)
    t = clamp(((px - ax) * dx + (py - ay) * dy) / length_sq)
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def coverage(distance: float, aa: float) -> float:
    """Anti-aliased coverage from a signed distance, in unit space."""
    return clamp(0.5 - distance / aa)


# ---------------------------------------------------------------- rasterise --
def pixel(size: int, x: int, y: int) -> tuple:
    px = (x + 0.5) / size
    py = (y + 0.5) / size
    aa = 1.0 / size  # one device pixel in unit space

    plate = sdf_round_rect(px, py, PLATE["cx"], PLATE["cy"], PLATE["half"], PLATE["half"], PLATE["radius"])
    plate_cov = coverage(plate, aa)
    if plate_cov <= 0.0:
        return (0, 0, 0, 0)

    # Body gradient plus a hairline border just inside the plate edge.
    body = mix(BG_TOP, BG_BOTTOM, clamp((py - 0.05) / 0.9))
    inner = sdf_round_rect(
        px,
        py,
        PLATE["cx"],
        PLATE["cy"],
        PLATE["half"] - PLATE["border"],
        PLATE["half"] - PLATE["border"],
        PLATE["radius"] - PLATE["border"],
    )
    border_cov = clamp(plate_cov - coverage(inner, aa))
    color = mix(body, BORDER, border_cov * 0.9)

    # The prompt: two round-capped capsules (a chevron) and a cursor bar.
    half_width = CHEVRON_WIDTH / 2.0
    chevron = min(
        sdf_segment(px, py, *CHEVRON[0], *CHEVRON[1]),
        sdf_segment(px, py, *CHEVRON[1], *CHEVRON[2]),
    ) - half_width
    glyph_cov = coverage(chevron, aa)

    bar_radius = (CURSOR["y1"] - CURSOR["y0"]) / 2.0
    bar = sdf_round_rect(
        px,
        py,
        (CURSOR["x0"] + CURSOR["x1"]) / 2.0,
        (CURSOR["y0"] + CURSOR["y1"]) / 2.0,
        (CURSOR["x1"] - CURSOR["x0"]) / 2.0,
        bar_radius,
        bar_radius,
    )
    glyph_cov = max(glyph_cov, coverage(bar, aa))

    if glyph_cov > 0.0:
        accent = mix(GLYPH_TOP, GLYPH_BOTTOM, clamp((px + py - 0.55) / 0.9))
        color = mix(color, accent, glyph_cov)

    alpha = round(plate_cov * 255)
    return (color[0], color[1], color[2], alpha)


# -------------------------------------------------------------------- png --
def chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def render_png(size: int) -> bytes:
    rows = []
    for y in range(size):
        row = bytearray([0])  # filter type 0
        for x in range(size):
            row.extend(pixel(size, x, y))
        rows.append(bytes(row))
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
        + chunk(b"IEND", b"")
    )


# -------------------------------------------------------------------- svg --
def render_svg() -> str:
    unit = 1024

    def pt(value: float) -> str:
        return f"{value * unit:.1f}"

    def rgb(color) -> str:
        return "#%02x%02x%02x" % color

    half = PLATE["half"] * unit
    radius = PLATE["radius"] * unit
    border = PLATE["border"] * unit
    chevron_points = " ".join(f"{pt(x)},{pt(y)}" for x, y in CHEVRON)
    bar_w = (CURSOR["x1"] - CURSOR["x0"]) * unit
    bar_h = (CURSOR["y1"] - CURSOR["y0"]) * unit
    # No intrinsic width/height: the consumer decides the size (favicon, README,
    # DSM), which keeps the same file usable at 16 px and 512 px.
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {unit} {unit}" role="img" aria-label="synoterm">
  <title>synoterm</title>
  <defs>
    <linearGradient id="plate" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{rgb(BG_TOP)}"/>
      <stop offset="1" stop-color="{rgb(BG_BOTTOM)}"/>
    </linearGradient>
    <linearGradient id="prompt" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{rgb(GLYPH_TOP)}"/>
      <stop offset="1" stop-color="{rgb(GLYPH_BOTTOM)}"/>
    </linearGradient>
  </defs>
  <rect x="{unit / 2 - half:.1f}" y="{unit / 2 - half:.1f}" width="{half * 2:.1f}" height="{half * 2:.1f}"
        rx="{radius:.1f}" ry="{radius:.1f}" fill="url(#plate)"/>
  <rect x="{unit / 2 - half + border / 2:.1f}" y="{unit / 2 - half + border / 2:.1f}"
        width="{half * 2 - border:.1f}" height="{half * 2 - border:.1f}"
        rx="{radius - border / 2:.1f}" ry="{radius - border / 2:.1f}"
        fill="none" stroke="{rgb(BORDER)}" stroke-opacity="0.9" stroke-width="{border:.1f}"/>
  <polyline points="{chevron_points}" fill="none" stroke="url(#prompt)"
            stroke-width="{CHEVRON_WIDTH * unit:.1f}" stroke-linecap="round" stroke-linejoin="round"/>
  <rect x="{pt(CURSOR['x0'])}" y="{pt(CURSOR['y0'])}" width="{bar_w:.1f}" height="{bar_h:.1f}"
        rx="{bar_h / 2:.1f}" ry="{bar_h / 2:.1f}" fill="url(#prompt)"/>
</svg>
"""


def main(argv) -> int:
    if len(argv) != 2:
        print("usage: make-icons.py <output-dir>", file=sys.stderr)
        return 2
    out = Path(argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        (out / f"icon_{size}.png").write_bytes(render_png(size))
    (out / "icon.svg").write_text(render_svg(), encoding="utf-8")
    print(f"wrote {len(SIZES)} icons + icon.svg to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
