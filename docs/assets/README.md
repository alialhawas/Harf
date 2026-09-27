# Blog assets

Used by `../why-we-built-harf.html`. Keep this directory alongside the article
when copying or serving the page. All fonts and illustrations load locally.

## Brand sources

- Hatif logo mark: reused from `voxa-dashboard/public/logos/hatif-logo-mark.svg`.
- Suisse Intl Regular and Medium: reused from the existing Hatif dashboard font
  assets. These remain subject to their existing font license, which covers use
  and not redistribution, so they are gitignored rather than committed. Drop
  `SuisseIntl-Regular.otf` and `SuisseIntl-Medium.otf` into `fonts/` to render
  the page as designed; without them `--heading` falls back to `--sans` and the
  article still reads correctly.
- IBM Plex Sans Arabic Regular and SemiBold: Google Fonts distribution, with
  the SIL Open Font License included in `fonts/IBMPlexSansArabic-OFL.txt`.
- Typography and color roles: the existing `voxa-dashboard/DESIGN-SYSTEM.md`.
  Primary teal is `#499B89`; secondary purple is `#5642CA`. The page uses darker
  teal for text on white and lighter brand shades inside the dark diagrams.

## Illustrations

`harf-architecture.svg` is an original, editable vector diagram of Harf's local
pipeline. The interactive comparison diagram is HTML/CSS in the article.
Both use the isometric blocks, beveled tables, thin outlines, and dashed
connections of the [PlanetScale reference article](https://planetscale.com/blog/the-lifecycle-of-a-sharded-postgres-query).
They illustrate Harf's behavior; the browser does not run Harf's detector.

The article also contains a measured score table and a beveled caret-verification
diagram. `harf-dictionary-demo.js` powers the bilingual smart-dictionary diagram:
readers can inspect observations 1, 9, and 10, or add one observation at a time.
The tenth observation promotes the example word. Its state stays in page memory
and never reads or writes the actual Harf lexicon.

`harf-diagram-animation.js` adds repeat playback to the dictionary, correction
pipeline, and measured score table. Playback runs while each diagram is visible
and the browser tab is active. Pause/play controls are bilingual; choosing a
manual stage pauses that diagram. Reduced-motion preference disables initial
autoplay. Dictionary playback holds the learned state before resetting only the
illustration. Score playback highlights the original measured values without
changing them or running a detector in the browser.

The correction example reveals one physical key at a time, synchronized with
both layout readings and the active application's text. All keys arrive at a
steady pace of 650 ms apart. A 900 ms illustrated
pause follows before comparison. Both repeat playback and the single replay
use this sequence; language changes retain the current captured prefix.

`harf-architecture-flow.js` overlays the overview SVG with moving packets,
progressively drawn connectors, and highlights on each active block. The sample
application text changes only at the replacement step, then the trace follows
the return route to the application. Pause, restart, and stage inspection preserve
the current position across language changes. Playback stops offscreen or in a
hidden tab and starts paused when reduced motion is requested.

Technical explanations and source links are pinned to GitHub revision
`be9943408a2e6b697d0f3aada9a17a783ee42c4a`, rather than the workspace's modified
Swift files. The score trace was reproduced by building that revision and running
`Harf --decide 'hgsghl ugd;l' --lang en` with ABC and Arabic layouts and balanced
aggressiveness. The CLI consults the local lexicon. Reported scores are independently
rounded, and represent detector evidence, not live permission to edit a field.

## Languages

The article supports English and Arabic through the header language switch.
`harf-article-i18n.js` contains the Arabic article and accessible-label translations;
the original English remains in the HTML. Dynamic diagram messages are bilingual
in the article script. `harf-architecture.ar.svg` contains the Arabic diagram labels.

Arabic uses right-to-left layout. Commands, shortcuts, and physical key sequences
retain their original left-to-right order. The article language is independent of
the intended language chosen in the correction demo.

`?lang=en` and `?lang=ar` select a language explicitly. Without that parameter,
the page uses the reader's saved choice when local storage is available, then
defaults to English. An explicit switch updates both the URL and the saved choice.
