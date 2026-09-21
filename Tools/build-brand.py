#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools>=4.50", "uharfbuzz>=0.39"]
# ///
"""Generate every piece of Harf's visual identity from one font file.

The identity is a single Arabic letter — ح, the first letter of حرف — set in
teal on a near-black rounded tile. The same letter, bare, is the menu bar
glyph. The lockup puts the tile beside "Harf" and حرف, with the dot of the ف
carrying the accent colour.

Nothing here is hand-drawn: the letterforms are glyph outlines pulled out of a
real typeface, so switching the face is a parameter rather than a redraw. Pass
``--font`` and every output below is rebuilt consistently.

  docs/brand/harf-icon.svg              1024 master for the .icns
  docs/brand/harf-menubar.svg           18pt template glyph, documentation copy
  docs/brand/harf-lockup-dark.svg       lockup for dark pages, transparent
  docs/brand/harf-lockup-light.svg      lockup for light pages, transparent
  Sources/DodomaAppKit/MenuBarGlyph.swift   the same glyph as drawing code

LICENCE — READ BEFORE ADDING A FONT TO THE REPOSITORY.

The default face is Thmanyah Sans Bold. Its licence permits using the
letterforms in a logo but forbids redistributing the font software, so no
font file may ever be committed, staged or bundled. This script therefore
reads the face from ``Tools/data/fonts/`` — which is gitignored — or from
wherever ``--font`` points, and commits only the resulting outlines. IBM Plex
Sans Arabic Bold (SIL OFL 1.1) is a drop-in alternative if the terms ever
become inconvenient.

Because the font cannot be fetched by a script, the committed outputs are the
source of truth: a checkout without the font still builds the app and still
has its icon. Regenerating is only necessary when the face or the geometry
changes. Output is deterministic — the same font and the same arguments
produce byte-identical files.

Usage:  uv run Tools/build-brand.py [--font <path to .otf/.ttf>]
        make brand
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

import uharfbuzz as hb
from fontTools.misc.transform import Transform
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

REPO_ROOT = Path(__file__).resolve().parent.parent
BRAND_DIR = REPO_ROOT / "docs" / "brand"
SWIFT_OUT = REPO_ROOT / "Sources" / "DodomaAppKit" / "MenuBarGlyph.swift"
DEFAULT_FONT = REPO_ROOT / "Tools" / "data" / "fonts" / "thmanyahsans-Bold.otf"

# The palette, documented in docs/brand/README.md.
CANVAS = "#0B0E13"
TEAL = "#5BC2AB"
DEEP = "#387A6C"
PAPER = "#F3F7F5"
INK = "#10161A"
# The tile's edge in the dark lockup, which has no ground of its own to sit
# against. Faint enough to disappear on the icon's usual near-black, strong
# enough to keep the tile from dissolving into a page that is darker still.
TILE_EDGE = "#FFFFFF"
TILE_EDGE_OPACITY = "0.12"
TILE_EDGE_WIDTH = 1.0

# Apple's macOS icon grid: an 824pt rounded square with a 185pt corner radius,
# centred in a 1024pt canvas. Matching it is what makes the icon sit at the
# same visual size as every other icon in the Dock.
TILE = (100.0, 100.0, 824.0, 824.0)
TILE_RADIUS = 185.0
# The letter fills 58% of the tile's height. Taller reads as cramped at 32pt,
# shorter stops being legible as a letter and starts reading as a squiggle.
LETTER_HEIGHT_RATIO = 0.58
# ...unless that would make it wider than this, which ح, being a wide letter,
# otherwise is.
LETTER_WIDTH_RATIO = 0.72

# The menu bar image is 18pt square because that is the height AppKit gives a
# status item; 12pt of letter inside it leaves the optical margin every other
# menu bar glyph has.
MENUBAR_BOX = 18.0
MENUBAR_LETTER_HEIGHT = 12.0
MENUBAR_LETTER_WIDTH = 15.0

# Lockup geometry, in the units of its own 220pt-tall canvas.
LOCKUP_HEIGHT = 220.0
LOCKUP_PAD = 60.0
LOCKUP_MARK = 140.0
LOCKUP_CAP = 104.0
LOCKUP_MARK_GAP = 44.0
LOCKUP_RULE_GAP = 46.0
LOCKUP_RULE_WIDTH = 3.0
LOCKUP_RULE_TRAIL = 49.0


# MARK: - Outlines
#
# Font units are y-up with the origin on the baseline; SVG is y-down. Arabic
# also needs real shaping — حرف is an initial ح joined to a final ر followed by
# an isolated ف — so the run goes through HarfBuzz before any outline is read.

FLIP = Transform(1, 0, 0, -1, 0, 0)


@dataclass
class Contour:
    """One closed contour, already in final coordinates."""

    ops: list
    bbox: tuple

    @property
    def width(self) -> float:
        return self.bbox[2] - self.bbox[0]

    @property
    def height(self) -> float:
        return self.bbox[3] - self.bbox[1]

    def contains(self, other: "Contour") -> bool:
        a, b = self.bbox, other.bbox
        return a[0] <= b[0] and a[1] <= b[1] and a[2] >= b[2] and a[3] >= b[3]


@dataclass
class Shape:
    contours: list
    bbox: tuple

    @property
    def width(self) -> float:
        return self.bbox[2] - self.bbox[0]

    @property
    def height(self) -> float:
        return self.bbox[3] - self.bbox[1]


class Face:
    """A font file, opened once for shaping and once for outlines."""

    def __init__(self, path: Path):
        self.path = path
        blob = hb.Blob.from_file_path(str(path))
        self._blob = blob
        self._face = hb.Face(blob)
        self._font = hb.Font(self._face)
        self.upem = self._face.upem
        self._tt = TTFont(str(path), lazy=True)
        self._order = self._tt.getGlyphOrder()
        self._glyphs = self._tt.getGlyphSet()

    def raw_contours(self, text: str, rtl: bool) -> list:
        """[(ops, placement)] in font units, y-up, laid out along the baseline."""
        buffer = hb.Buffer()
        buffer.add_str(text)
        if rtl:
            buffer.direction, buffer.script, buffer.language = "rtl", "Arab", "ar"
        else:
            buffer.direction, buffer.script, buffer.language = "ltr", "Latn", "en"
        hb.shape(self._font, buffer, {"kern": True, "liga": True, "calt": True})

        x = y = 0.0
        result = []
        for info, position in zip(buffer.glyph_infos, buffer.glyph_positions):
            name = self._order[info.codepoint]
            recorder = DecomposingRecordingPen(self._glyphs)
            self._glyphs[name].draw(recorder)
            place = Transform().translate(x + position.x_offset, y + position.y_offset)
            for ops in split_contours(recorder.value):
                result.append((ops, place))
            x += position.x_advance
            y += position.y_advance
        return result


def split_contours(recorded: list) -> list:
    """One list of pen operations per closed contour."""
    out, current = [], []
    for operation, arguments in recorded:
        if operation == "moveTo" and current:
            out.append(current)
            current = []
        current.append((operation, arguments))
    if current:
        out.append(current)
    return out


def replay(ops: list, pen) -> None:
    for operation, arguments in ops:
        getattr(pen, operation)(*arguments)


def bbox_of(ops: list, transform: Transform):
    bounds = BoundsPen(None)
    replay(ops, TransformPen(bounds, transform))
    return bounds.bounds


def union(boxes: list):
    boxes = [box for box in boxes if box]
    if not boxes:
        return None
    return (
        min(box[0] for box in boxes),
        min(box[1] for box in boxes),
        max(box[2] for box in boxes),
        max(box[3] for box in boxes),
    )


def to_cubic(ops: list) -> list:
    """Rewrite quadratic segments as cubics, exactly.

    CFF faces (Thmanyah) are already cubic; TrueType ones (IBM Plex) are not,
    and the generated Swift only knows how to draw lines and cubic curves. A
    quadratic is a cubic, so the conversion loses nothing: the control points
    sit two thirds of the way from each end point towards the quadratic's own
    control point. TrueType's implied on-curve points, the midpoints between
    consecutive off-curve points, are reconstructed here as well.
    """
    out = []
    current = None
    start = None
    for operation, arguments in ops:
        if operation == "moveTo":
            current = start = tuple(arguments[0])
            out.append(("moveTo", [current]))
        elif operation == "lineTo":
            current = tuple(arguments[0])
            out.append(("lineTo", [current]))
        elif operation == "curveTo":
            points = [tuple(point) for point in arguments]
            out.append(("curveTo", points))
            current = points[-1]
        elif operation == "qCurveTo":
            points = [None if point is None else tuple(point) for point in arguments]
            if points[-1] is None:
                # A contour made entirely of off-curve points: the start is the
                # midpoint between the last and the first.
                points = points[:-1]
                implied = midpoint(points[-1], points[0])
                current = start = implied
                out.append(("moveTo", [implied]))
                points = points + [implied]
            offcurves, end = points[:-1], points[-1]
            for index, control in enumerate(offcurves):
                on = end if index + 1 == len(offcurves) else midpoint(
                    control, offcurves[index + 1])
                out.append(("curveTo", list(quadratic_as_cubic(current, control, on))))
                current = on
        elif operation == "closePath":
            out.append(("closePath", []))
            current = start
        elif operation == "endPath":
            out.append(("closePath", []))
            current = start
    return out


def midpoint(a: tuple, b: tuple) -> tuple:
    return ((a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0)


def quadratic_as_cubic(p0: tuple, control: tuple, p2: tuple):
    first = (p0[0] + 2.0 / 3.0 * (control[0] - p0[0]),
             p0[1] + 2.0 / 3.0 * (control[1] - p0[1]))
    second = (p2[0] + 2.0 / 3.0 * (control[0] - p2[0]),
              p2[1] + 2.0 / 3.0 * (control[1] - p2[1]))
    return first, second, p2


def shape(face: Face, text: str, rtl: bool, base: Transform = FLIP,
          box: tuple | None = None, scale: float | None = None,
          fit: str = "contain") -> Shape:
    """Outlines for `text`, scaled and centred into `box`.

    `base` is the flip from font space into the destination's space: the SVG
    default here, or the identity when the destination is y-up like Core
    Graphics. `scale` overrides the fit, in which case `box` only centres.
    """
    raw = face.raw_contours(text, rtl)
    tight = union([bbox_of(ops, base.transform(place)) for ops, place in raw])
    if tight is None:
        raise ValueError(f"no outlines for {text!r} in {face.path.name}")

    placement = Transform()
    if box is not None:
        bx, by, bw, bh = box
        width = tight[2] - tight[0]
        height = tight[3] - tight[1]
        if scale is not None:
            factor = scale
        elif fit == "height":
            factor = bh / height
        elif fit == "width":
            factor = bw / width
        else:
            factor = min(bw / width, bh / height)
        placement = (Transform()
                     .translate(bx + bw / 2.0, by + bh / 2.0)
                     .scale(factor, factor)
                     .translate(-(tight[0] + tight[2]) / 2.0,
                                -(tight[1] + tight[3]) / 2.0))
    elif scale is not None:
        placement = Transform().scale(scale, scale)

    total = placement.transform(base)
    contours = []
    for ops, place in raw:
        matrix = total.transform(place)
        recorder = DecomposingRecordingPen(None)
        recorder.value = []
        replay(ops, TransformPen(recorder, matrix))
        converted = to_cubic(recorder.value)
        bounds = bbox_of(ops, matrix)
        if bounds is None:
            continue
        contours.append(Contour(ops=converted, bbox=bounds))
    return Shape(contours=contours, bbox=union([c.bbox for c in contours]))


def dot_contour(shaped: Shape) -> Contour | None:
    """The dot of the ف.

    Counters — the hole inside the ف's loop — are nested inside another
    contour's box, so they are ruled out first; what is left and small is the
    dot, and of those the one nearest the top of the letter.
    """
    free = [c for c in shaped.contours
            if not any(other is not c and other.contains(c)
                       for other in shaped.contours)]
    span = shaped.height or 1.0
    candidates = [c for c in free
                  if c.height < 0.34 * span and c.width < 0.34 * span]
    if not candidates:
        return None
    return max(candidates, key=lambda c: c.bbox[3])


# MARK: - Formatting

def number(value: float, precision: int = 2) -> str:
    """Stable decimal text, so that rerunning the generator changes nothing."""
    rounded = round(value, precision)
    if rounded == 0:
        rounded = 0.0
    text = f"{rounded:.{precision}f}".rstrip("0").rstrip(".")
    return text or "0"


def path_data(contours: list, precision: int = 2) -> str:
    """SVG `d` for a list of contours, in a fixed command vocabulary."""
    out = []
    for contour in contours:
        for operation, arguments in contour.ops:
            if operation == "moveTo":
                out.append("M" + point_text(arguments[0], precision))
            elif operation == "lineTo":
                out.append("L" + point_text(arguments[0], precision))
            elif operation == "curveTo":
                out.append("C" + " ".join(
                    point_text(point, precision) for point in arguments))
            elif operation == "closePath":
                out.append("Z")
    return " ".join(out)


def point_text(point: tuple, precision: int) -> str:
    return f"{number(point[0], precision)} {number(point[1], precision)}"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    print(f"wrote      {path.relative_to(REPO_ROOT)} ({len(text)} bytes)")


def svg_document(view_box: str, width: float, height: float, label: str,
                 defs: str, body: str) -> str:
    head = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_box}" '
            f'width="{number(width)}" height="{number(height)}" role="img" '
            f'aria-label="{label}">\n')
    definitions = f"<defs>{defs}</defs>\n" if defs else ""
    return head + definitions + body + "\n</svg>\n"


# MARK: - Artwork

def letter_scale(face: Face) -> float:
    """The factor that puts ح at 58% of the tile, in font units."""
    natural = shape(face, "ح", rtl=True)
    factor = (LETTER_HEIGHT_RATIO * TILE[3]) / natural.height
    if natural.width * factor > LETTER_WIDTH_RATIO * TILE[3]:
        factor = (LETTER_WIDTH_RATIO * TILE[3]) / natural.width
    return factor


# The gradient is in object bounding box units, so one definition serves both
# the 1024 icon and the 140pt mark inside the lockup.
GLOW_DEF = ('<radialGradient id="harf-glow" cx="50%" cy="48%" r="52%">'
            f'<stop offset="0" stop-color="{TEAL}" stop-opacity="0.26"/>'
            f'<stop offset="0.55" stop-color="{TEAL}" stop-opacity="0.07"/>'
            f'<stop offset="1" stop-color="{TEAL}" stop-opacity="0"/>'
            '</radialGradient>')


def rect_geometry(x: float, y: float, side: float, radius: float) -> str:
    return (f'x="{number(x)}" y="{number(y)}" width="{number(side)}" '
            f'height="{number(side)}" rx="{number(radius)}" '
            f'ry="{number(radius)}"')


def tile_markup(x: float, y: float, side: float, hairline: bool = False) -> str:
    """The rounded tile: canvas, then the glow painted over it.

    The glow goes on a second copy of the rounded rectangle rather than into a
    `<clipPath>`; the rectangle clips it either way, and this is one fewer SVG
    feature for a rasteriser to not implement.

    `hairline` adds a faint light edge, for the lockup that will be placed on
    a dark page whose exact colour is not ours to choose. It is drawn on a
    copy inset by half its own width so that the stroke falls entirely inside
    the tile and the artwork's bounding box is still the tile.
    """
    radius = TILE_RADIUS / TILE[2] * side
    geometry = rect_geometry(x, y, side, radius)
    markup = (f'<rect {geometry} fill="{CANVAS}"/>'
              f'<rect {geometry} fill="url(#harf-glow)"/>')
    if hairline:
        inset = TILE_EDGE_WIDTH / 2.0
        edge = rect_geometry(x + inset, y + inset, side - TILE_EDGE_WIDTH,
                             max(radius - inset, 0.0))
        markup += (f'<rect {edge} fill="none" stroke="{TILE_EDGE}" '
                   f'stroke-opacity="{TILE_EDGE_OPACITY}" '
                   f'stroke-width="{number(TILE_EDGE_WIDTH)}"/>')
    return markup


def icon_svg(face: Face) -> str:
    """The 1024 master.

    No `<filter>` anywhere in here. This file is rasterised by AppKit's SVG
    reader to build the .icns, and that reader does not implement filter
    primitives; a drop shadow declared here would silently come out as a
    missing tile.
    """
    letter = shape(face, "ح", rtl=True, box=TILE, scale=letter_scale(face))
    body = (tile_markup(TILE[0], TILE[1], TILE[2])
            + f'<path d="{path_data(letter.contours)}" fill="{TEAL}"/>')
    return svg_document("0 0 1024 1024", 1024, 1024, "Harf app icon",
                        GLOW_DEF, body)


def menubar_shape(face: Face, base: Transform) -> Shape:
    natural = shape(face, "ح", rtl=True, base=base)
    factor = MENUBAR_LETTER_HEIGHT / natural.height
    if natural.width * factor > MENUBAR_LETTER_WIDTH:
        factor = MENUBAR_LETTER_WIDTH / natural.width
    return shape(face, "ح", rtl=True, base=base,
                 box=(0.0, 0.0, MENUBAR_BOX, MENUBAR_BOX), scale=factor)


def menubar_svg(face: Face) -> str:
    glyph = menubar_shape(face, FLIP)
    body = f'<path d="{path_data(glyph.contours)}" fill="currentColor"/>'
    return svg_document("0 0 18 18", MENUBAR_BOX, MENUBAR_BOX,
                        "Harf menu bar glyph", "", body)


def lockup_svg(face: Face, theme: str) -> str:
    """Mark, wordmark, rule and حرف on one baseline.

    `theme` names the ground the file is *for*, not a ground it paints: both
    lockups are transparent, so each takes the colour of the page it is
    dropped onto. `dark` carries light ink for a dark page — GitHub's is
    #0d1117 — and `light` carries Ink for a light one. Painting our own
    #0B0E13 or #F3F7F5 behind the artwork would put a visible rectangle on
    both of those, the near-white one glaringly so.

    They are two files with literal colours rather than one driven by
    `currentColor` because GitHub renders README artwork through an `<img>`,
    where no stylesheet of ours reaches it; `<picture>` picks between them.
    """
    dark = theme == "dark"
    ink = "#FFFFFF" if dark else INK
    accent = TEAL if dark else DEEP

    top = (LOCKUP_HEIGHT - LOCKUP_MARK) / 2.0
    mark_box = (LOCKUP_PAD, top, LOCKUP_MARK, LOCKUP_MARK)
    mark_scale = letter_scale(face) / TILE[2] * LOCKUP_MARK
    mark_letter = shape(face, "ح", rtl=True, box=mark_box, scale=mark_scale)

    # The Latin and Arabic words are set to the same cap height so neither
    # reads as the caption of the other.
    baseline = (LOCKUP_HEIGHT - LOCKUP_CAP) / 2.0
    cursor = LOCKUP_PAD + LOCKUP_MARK + LOCKUP_MARK_GAP

    latin_natural = shape(face, "Harf", rtl=False)
    latin_scale = LOCKUP_CAP / latin_natural.height
    latin_width = latin_natural.width * latin_scale
    latin = shape(face, "Harf", rtl=False,
                  box=(cursor, baseline, latin_width, LOCKUP_CAP),
                  scale=latin_scale)

    rule_x = cursor + latin_width + LOCKUP_RULE_GAP
    arabic_natural = shape(face, "حرف", rtl=True)
    arabic_scale = LOCKUP_CAP / arabic_natural.height
    arabic_width = arabic_natural.width * arabic_scale
    arabic_x = rule_x + LOCKUP_RULE_WIDTH + LOCKUP_RULE_TRAIL
    arabic = shape(face, "حرف", rtl=True,
                   box=(arabic_x, baseline, arabic_width, LOCKUP_CAP),
                   scale=arabic_scale)
    dot = dot_contour(arabic)
    body = [c for c in arabic.contours if c is not dot]

    width = arabic_x + arabic_width + LOCKUP_PAD
    rule_top = baseline + 16.0
    rule_height = LOCKUP_CAP - 32.0

    markup = (
        # The tile is the same near-black on both grounds, because it is the
        # app icon rather than a shape that reacts to the page. On a dark page
        # the glow and the hairline edge are all that separate the two, which
        # is deliberate: the mark should read as the icon, not as a black
        # rectangle with a border.
        tile_markup(mark_box[0], mark_box[1], LOCKUP_MARK, hairline=dark)
        + f'<path d="{path_data(mark_letter.contours)}" fill="{TEAL}"/>'
        f'<path d="{path_data(latin.contours)}" fill="{ink}"/>'
        f'<rect x="{number(rule_x)}" y="{number(rule_top)}" '
        f'width="{number(LOCKUP_RULE_WIDTH)}" height="{number(rule_height)}" '
        f'rx="{number(LOCKUP_RULE_WIDTH / 2.0)}" fill="{accent}" '
        f'fill-opacity="0.5"/>'
        f'<path d="{path_data(body)}" fill="{ink}"/>'
    )
    if dot is not None:
        markup += f'<path d="{path_data([dot])}" fill="{accent}"/>'

    return svg_document(f"0 0 {number(width)} {number(LOCKUP_HEIGHT)}",
                        width, LOCKUP_HEIGHT, f"Harf logo, for {theme} grounds",
                        GLOW_DEF, markup)


# MARK: - Generated Swift

SWIFT_HEADER = '''// Generated by Tools/build-brand.py from {font}. Do not edit.
//
// The menu bar mark is ح, drawn rather than loaded. A second SwiftPM resource
// bundle would have to be found at runtime inside the packaged .app the way
// CoreResources.swift already finds the language models, and copied in by the
// Makefile the way that one is — real cost, for one small letter. Outlines
// compiled into the binary cannot go missing.
//
// The font it came from is not in this repository and may not be: its licence
// permits the letterform in a logo and forbids redistributing the font
// software. Rerun the generator with `make brand` to change the face.

import AppKit

/// Harf's status item image: the letter ح, as a template so AppKit tints it
/// for the menu bar's appearance and for selection.
enum MenuBarGlyph {{
    /// The point size AppKit gives a status item's image.
    static let size = NSSize(width: {box}, height: {box})

    /// The letter, in a {box}×{box} box whose origin is at the bottom left —
    /// the orientation Core Graphics and an unflipped `NSImage` both use, so
    /// the path needs no transform at draw time.
    static func path() -> NSBezierPath {{
        let path = NSBezierPath()
{commands}
        path.windingRule = .nonZero
        return path
    }}

    static func image() -> NSImage {{
        let image = NSImage(size: size, flipped: false) {{ _ in
            NSColor.black.setFill()
            path().fill()
            return true
        }}
        image.isTemplate = true
        image.accessibilityDescription = "Harf"
        return image
    }}
}}
'''


def swift_point(point: tuple) -> str:
    return f"NSPoint(x: {number(point[0], 3)}, y: {number(point[1], 3)})"


def swift_glyph(face: Face) -> str:
    # The identity base, not the SVG flip: this path is drawn into an
    # unflipped NSImage, whose y axis already runs the same way the font's
    # does. Flipping here would hand back a ح lying on its back.
    glyph = menubar_shape(face, Transform())
    lines = []
    for contour in glyph.contours:
        for operation, arguments in contour.ops:
            if operation == "moveTo":
                lines.append(f"        path.move(to: {swift_point(arguments[0])})")
            elif operation == "lineTo":
                lines.append(f"        path.line(to: {swift_point(arguments[0])})")
            elif operation == "curveTo":
                lines.append(
                    f"        path.curve(to: {swift_point(arguments[2])}, "
                    f"controlPoint1: {swift_point(arguments[0])}, "
                    f"controlPoint2: {swift_point(arguments[1])})")
            elif operation == "closePath":
                lines.append("        path.close()")
    return SWIFT_HEADER.format(font=face.path.name, box=number(MENUBAR_BOX),
                               commands="\n".join(lines))


# MARK: - Entry point

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate Harf's icon, menu bar glyph and lockups.")
    parser.add_argument(
        "--font", type=Path, default=DEFAULT_FONT,
        help=f"the face to trace (default: {DEFAULT_FONT.relative_to(REPO_ROOT)})")
    arguments = parser.parse_args()

    font_path = arguments.font.expanduser()
    if not font_path.is_file():
        print(f"error: no font at {font_path}", file=sys.stderr)
        print("Font files are deliberately absent from this repository; see the "
              "licence note at the top of this script. Put the face in "
              f"{DEFAULT_FONT.parent.relative_to(REPO_ROOT)}/ or pass --font.",
              file=sys.stderr)
        return 1

    face = Face(font_path)
    print(f"face       {font_path.name} ({face.upem} upem)")

    write(BRAND_DIR / "harf-icon.svg", icon_svg(face))
    write(BRAND_DIR / "harf-menubar.svg", menubar_svg(face))
    write(BRAND_DIR / "harf-lockup-dark.svg", lockup_svg(face, "dark"))
    write(BRAND_DIR / "harf-lockup-light.svg", lockup_svg(face, "light"))
    write(SWIFT_OUT, swift_glyph(face))

    print("Now run `swift Tools/build-icon.swift` to rebuild Resources/AppIcon.icns.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
