# Harf brand

## The mark

The mark is the Arabic letter **ح** — the first letter of حرف, "letter" — in
its isolated form. It is one character of the thing the app is about, and it
survives being 16 pixels wide, which the wordmark does not.

The app icon sets that letter in teal on a near-black rounded tile. The menu
bar glyph is the bare letter, drawn as a template image so macOS tints it for
the current appearance and inverts it under selection. The logo lockup puts
the tile beside "Harf" and حرف, separated by a hairline rule, with the dot of
the ف carrying the accent colour.

| File | Use |
| --- | --- |
| `harf-icon.svg` | 1024pt master; the source `Resources/AppIcon.icns` is rasterised from |
| `harf-menubar.svg` | the status item glyph, for documentation and the web |
| `harf-lockup-dark.svg` | the lockup for dark pages |
| `harf-lockup-light.svg` | the lockup for light pages |

Both lockups are **transparent**. The name says which ground the file is for,
not one it paints: `-dark` carries light ink for a dark page, `-light` carries
Ink for a light one, and each takes the colour of whatever it is placed on.
That is what lets the `<picture>` in the root README sit on GitHub's own
`#0d1117` and `#ffffff` without a rectangle of our own showing around it. The
mark's tile stays near-black in both, because it is the app icon rather than a
shape that reacts to the page; in the dark file it gets a hairline white edge
at 12% so it does not dissolve into a page darker than `#0B0E13`.

The running app does not read any of these. Its menu bar glyph is
`Sources/DodomaAppKit/MenuBarGlyph.swift`, generated from the same outlines as
drawing code, so the app needs no second resource bundle to carry one letter.

## Palette

| Name | Hex | Use |
| --- | --- | --- |
| Canvas | `#0B0E13` | the icon tile, and dark grounds |
| Teal | `#5BC2AB` | the letter on the tile; the accent on dark grounds |
| Deep teal | `#387A6C` | the accent on light grounds, where Teal is too pale to read |
| Paper | `#F3F7F5` | light grounds |
| Ink | `#10161A` | text on light grounds |

Teal on Canvas and Ink on Paper both clear WCAG AA for large text; Teal on
Paper does not, which is why Deep teal exists.

## Clear space and minimum size

- Keep clear space around the lockup equal to the height of the H — the
  lockup's own files already carry that much padding, so the rule matters when
  it is placed rather than when it is exported.
- The lockup is not used below **64pt** tall. Below that the hairline rule
  disappears, the ف dot merges into the letter above it, and the whole thing
  reads as a smudge.
- Below 64pt the mark stands alone: the tile at icon sizes, the bare letter at
  menu bar sizes.
- Do not recolour the letter, set it in another face by hand, stretch either
  axis, or put the tile on a ground close to `#0B0E13` without the glow and
  the hairline edge that separate the two.
- Do not paint a rectangle behind a lockup to give it "its own" ground. If a
  page needs one, the page owns it.

## Regenerating

Everything is generated from one font file by two commands, wrapped as:

```
make brand BRAND_FONT=/path/to/thmanyahsans-Bold.otf
```

which runs `Tools/build-brand.py` (the SVGs and the generated Swift) and then
`Tools/build-icon.swift` (the `.icns`, rasterised from `harf-icon.svg` by
AppKit). `BRAND_FONT` defaults to `Tools/data/fonts/thmanyahsans-Bold.otf`.
Output is deterministic: the same font and arguments produce byte-identical
files, so a regeneration that changes nothing shows up as an empty diff.

To retrace the identity in another face, point `BRAND_FONT` at it and rerun.
Nothing downstream is hand-edited.

## Licence

The default face is **Thmanyah Sans Bold**. Its licence permits using the
letterforms in a logo and forbids redistributing the font software, so:

- no font file — `.otf`, `.ttf`, `.woff`, `.woff2` — is committed to this
  repository or bundled into the app, and `Tests/DodomaAppTests/BrandPackagingTests.swift`
  fails the build if one appears under `docs/brand/`, `Resources/` or `Sources/`;
- `Tools/data/` is gitignored, and that is where the generator expects to find
  the face;
- only outlines are committed, which is what the licence allows.

Because the font cannot be fetched by a script, the committed outputs are the
source of truth. A checkout without the font still builds the app with its
icon; it simply cannot regenerate the artwork.

**IBM Plex Sans Arabic Bold** is the alternative face, under the SIL Open Font
Licence 1.1. It may be redistributed, but is not needed at runtime either:
everything ships as outlines regardless of which face drew them.
