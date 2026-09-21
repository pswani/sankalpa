#!/usr/bin/env python3
"""Draws the Sankalpa app icon: a saffron field with a white eight-petal mandala.

Written as a script with no image-library dependency so the icon is reproducible from source
rather than being an opaque binary checked into the repo.
"""
import math
import struct
import sys
import zlib

SIZE = 1024
SUPERSAMPLE = 3          # rendered at 3x and averaged down, which is the anti-aliasing
TOP = (0xE8, 0xA2, 0x4E)
BOTTOM = (0x9E, 0x50, 0x0E)
MARK = (0xFF, 0xFF, 0xFF)

PETAL_INNER = 0.30       # fractions of the half-width
PETAL_OUTER = 0.74
PETAL_HALF_ANGLE = 0.255 # radians at the petal's widest point
OUTER_RING = (0.845, 0.875)
INNER_RING = (0.345, 0.375)
CENTRE = 0.105
SECTOR = math.pi / 4     # eight petals


def mark_coverage(nx: float, ny: float) -> float:
    """1 inside the white mark, 0 outside, for one supersample."""
    radius = math.hypot(nx, ny)

    if radius <= CENTRE:
        return 1.0
    if OUTER_RING[0] <= radius <= OUTER_RING[1]:
        return 1.0
    if INNER_RING[0] <= radius <= INNER_RING[1]:
        return 1.0
    if not (PETAL_INNER <= radius <= PETAL_OUTER):
        return 0.0

    # Fold the angle into a single petal's sector, so eight petals cost the same as one.
    angle = math.atan2(ny, nx)
    folded = ((angle + SECTOR / 2) % SECTOR) - SECTOR / 2

    # A leaf: widest in the middle of its radial span, tapering to points at both ends.
    span = (radius - PETAL_INNER) / (PETAL_OUTER - PETAL_INNER)
    half_width = PETAL_HALF_ANGLE * math.sin(math.pi * span) ** 0.62
    return 1.0 if abs(folded) <= half_width else 0.0


def render() -> bytes:
    rows = []
    half = SIZE / 2
    step = 1.0 / SUPERSAMPLE
    weight = 1.0 / (SUPERSAMPLE * SUPERSAMPLE)

    for y in range(SIZE):
        row = bytearray()
        # The background gradient only depends on the row.
        blend = y / (SIZE - 1)
        background = tuple(
            round(TOP[channel] + (BOTTOM[channel] - TOP[channel]) * blend)
            for channel in range(3)
        )
        for x in range(SIZE):
            coverage = 0.0
            for sy in range(SUPERSAMPLE):
                ny = (y + (sy + 0.5) * step - half) / half
                for sx in range(SUPERSAMPLE):
                    nx = (x + (sx + 0.5) * step - half) / half
                    coverage += mark_coverage(nx, ny)
            coverage *= weight
            row += bytes(
                round(background[channel] + (MARK[channel] - background[channel]) * coverage)
                for channel in range(3)
            )
        rows.append(bytes(row))
    return b"".join(b"\x00" + row for row in rows)


def png(raw: bytes) -> bytes:
    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)   # 8-bit truecolour
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


if __name__ == "__main__":
    destination = sys.argv[1]
    with open(destination, "wb") as handle:
        handle.write(png(render()))
    print(f"wrote {destination}")
