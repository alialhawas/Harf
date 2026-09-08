#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Generate Dodoma's offline language models from open word-frequency data.

This is the ONLY part of the project that touches the network, and it only
does so on a developer machine when the raw lists are not already cached in
``Tools/data/`` (gitignored). The Swift app and its tests read exclusively
from the committed outputs under ``Sources/DodomaCore/Resources/``.

Outputs, all deterministic (rerunning over the same cache yields byte
identical files):

  en.words          top 40k normalised English words, lexicographic
  ar.words          top 40k normalised Arabic words, lexicographic
  en.bigrams.json   letter bigram log-probability table + score calibration
  ar.bigrams.json   ditto
  LICENSES.md       attribution for the source corpora

Usage:  uv run Tools/build-ngrams.py  [--force]
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = REPO_ROOT / "Tools" / "data"
OUTPUT_DIR = REPO_ROOT / "Sources" / "DodomaCore" / "Resources"

SOURCES = {
    "en": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt",
    "ar": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ar/ar_50k.txt",
}

WORDLIST_LIMIT = 40_000
DIALECT_FILE = REPO_ROOT / "Tools" / "data" / "ar.dialect.txt"
SMOOTHING_K = 0.5
# Two-letter entries beyond this rank are dropped; see prune_short_noise.
SHORT_WORD_RANK_LIMIT = 5_000

# Calibration of mean log-probability onto 0…1, as percentiles of the cell
# distribution.
#
# The floor is the MEDIAN cell, i.e. what an arbitrary letter pair scores, so a
# text whose average pair is no better than a coin toss over the alphabet maps
# to 0 and one made of very common pairs maps to 1. The obvious alternative —
# the smallest cell in the table — is the log-probability of a bigram that
# never occurs in fifty thousand words (about -21), an outlier three times
# further from real text than real text is from gibberish. Anchoring on it
# squeezes every input into 0.75…0.98 and makes the decision thresholds in
# FixDecision.swift unreachable. Measured on the seed corpus, the percentiles
# below separate real text (0.77…0.90) from wrong-layout text (0.00…0.39).
FLOOR_PERCENTILE = 0.50
CEILING_PERCENTILE = 0.95

EN_ALPHABET = "abcdefghijklmnopqrstuvwxyz'"
EN_WORD_RE = re.compile(r"^[a-z']+$")

# Tatweel, the harakat block and the superscript alef carry no lexical weight
# and are frequently omitted when typing, so they are stripped everywhere.
AR_STRIP = {"ـ", "ٰ"} | {chr(c) for c in range(0x064B, 0x0653)}
AR_FOLD = {
    "أ": "ا",  # أ -> ا
    "إ": "ا",  # إ -> ا
    "آ": "ا",  # آ -> ا
    "ٱ": "ا",  # ٱ -> ا
    "ى": "ي",  # ى -> ي
    "ة": "ه",  # ة -> ه
}
# Arabic letters proper: U+0621..U+063A and U+0641..U+064A. Everything the fold
# above removes is excluded from the final alphabet by construction.
AR_LETTERS = {chr(c) for c in range(0x0621, 0x063B)} | {
    chr(c) for c in range(0x0641, 0x064B)
}


def fetch(language: str, url: str, force: bool) -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = CACHE_DIR / f"{language}_50k.txt"
    if path.exists() and not force:
        print(f"cache hit  {path.relative_to(REPO_ROOT)}")
        return path
    print(f"fetching   {url}")
    with urllib.request.urlopen(url, timeout=60) as response:
        payload = response.read()
    path.write_bytes(payload)
    print(f"cached     {path.relative_to(REPO_ROOT)} ({len(payload)} bytes)")
    return path


def normalise_english(word: str) -> str | None:
    word = word.lower()
    if not EN_WORD_RE.match(word):
        return None
    if len(word) == 1 and word not in ("a", "i"):
        return None
    return word


def normalise_arabic(word: str) -> str | None:
    out = []
    for character in word:
        if character in AR_STRIP:
            continue
        out.append(AR_FOLD.get(character, character))
    normalised = "".join(out)
    if not normalised:
        return None
    if any(character not in AR_LETTERS for character in normalised):
        return None
    return normalised


def add_supplement(
    counts: dict[str, int], path: Path, normalise
) -> dict[str, int]:
    """Merge a hand-curated word list into a frequency table.

    Injected at the median frequency of what is already there rather than at
    the top. These words have to survive `top_words`, but claiming they are as
    common as the most frequent words in the language would distort the bigram
    table that is built from the same counts.

    A word already present keeps its measured count: the supplement is there to
    add what the corpus lacks, not to re-weight what it has.
    """
    if not path.exists():
        return counts
    ranked = sorted(counts.values())
    median = ranked[len(ranked) // 2] if ranked else 1
    added = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        word = line.split("#", 1)[0].strip()
        if not word:
            continue
        normalised = normalise(word)
        if normalised is None:
            print(f"warning: {path.name}: skipping unusable entry {word!r}", file=sys.stderr)
            continue
        if normalised in counts:
            continue
        counts[normalised] = median
        added += 1
    print(f"supplement {path.relative_to(REPO_ROOT)} added {added} words")
    return counts


def load_frequencies(path: Path, normalise) -> dict[str, int]:
    """Aggregated ``normalised word -> summed count``."""
    counts: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        raw, count = parts
        if not count.isdigit():
            continue
        word = normalise(raw)
        if word is None:
            continue
        counts[word] = counts.get(word, 0) + int(count)
    return counts


def prune_short_noise(counts: dict[str, int], rank_limit: int = SHORT_WORD_RANK_LIMIT) -> dict[str, int]:
    """Drops rare two-letter entries.

    Subtitle-derived lists are full of two-letter debris — initials, unit
    abbreviations, OCR residue. Each one is a false "this is a real word"
    signal exactly where the models have the least evidence, and one of them
    was enough to make the segmenter stop mid-region on the canonical sample
    (``mv`` sits at rank 33125 in en_50k). Genuine two-letter words are all
    extremely frequent in both languages, so a rank cut separates them
    cleanly. Longer words are left alone: their length already carries the
    weight in ``dictCoverage``.
    """
    ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    return {
        word: count
        for rank, (word, count) in enumerate(ranked)
        if len(word) > 2 or rank < rank_limit
    }


def top_words(counts: dict[str, int], limit: int) -> list[str]:
    # Frequency descending, lexicographic as the tie break so the cut is stable.
    ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    return sorted(word for word, _ in ranked[:limit])


def alphabet_for(counts: dict[str, int], preset: str | None) -> str:
    if preset is not None:
        return preset
    present = set()
    for word in counts:
        present.update(word)
    return "".join(sorted(present))


def build_bigrams(counts: dict[str, int], alphabet: str) -> dict:
    """Frequency-weighted, add-k smoothed letter bigram model in natural log.

    Index ``n = len(alphabet)`` is the boundary symbol, used both as ``^``
    (row) and as ``$`` (column), so every token scores as ``^word$``.
    """
    index = {character: position for position, character in enumerate(alphabet)}
    size = len(alphabet) + 1
    boundary = size - 1

    observed = [[0 for _ in range(size)] for _ in range(size)]
    for word, count in sorted(counts.items()):
        symbols = [boundary] + [index[character] for character in word] + [boundary]
        for left, right in zip(symbols, symbols[1:]):
            observed[left][right] += count

    log_prob: list[list[float]] = []
    for row in observed:
        total = sum(row) + SMOOTHING_K * size
        log_prob.append(
            [round(math.log((cell + SMOOTHING_K) / total), 4) for cell in row]
        )

    flat = sorted(cell for row in log_prob for cell in row)
    return {
        "alphabet": alphabet,
        "boundary": True,
        "logProb": log_prob,
        "floor": percentile(flat, FLOOR_PERCENTILE),
        "ceiling": percentile(flat, CEILING_PERCENTILE),
    }


def percentile(sorted_values: list[float], fraction: float) -> float:
    """Linear-interpolation percentile over an already sorted list."""
    if len(sorted_values) == 1:
        return sorted_values[0]
    position = fraction * (len(sorted_values) - 1)
    lower = math.floor(position)
    upper = min(lower + 1, len(sorted_values) - 1)
    weight = position - lower
    value = sorted_values[lower] * (1 - weight) + sorted_values[upper] * weight
    return round(value, 4)


def write_words(path: Path, words: list[str]) -> None:
    path.write_text("\n".join(words) + "\n", encoding="utf-8")
    print(f"wrote      {path.relative_to(REPO_ROOT)} ({len(words)} words)")


def write_json(path: Path, payload: dict) -> None:
    text = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    path.write_text(text + "\n", encoding="utf-8")
    print(
        f"wrote      {path.relative_to(REPO_ROOT)} "
        f"({len(payload['alphabet']) + 1}x{len(payload['alphabet']) + 1}, "
        f"floor {payload['floor']}, ceiling {payload['ceiling']})"
    )


LICENSES = """# Bundled data licences

`en.words`, `ar.words`, `en.bigrams.json` and `ar.bigrams.json` are derived
works generated by `Tools/build-ngrams.py` from the FrequencyWords corpus.

## FrequencyWords

- Source: https://github.com/hermitdave/FrequencyWords
- Files used: `content/2018/en/en_50k.txt`, `content/2018/ar/ar_50k.txt`
- Copyright (c) 2016 Hermit Dave
- Licence: MIT

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The FrequencyWords lists are themselves derived from OpenSubtitles
(http://opus.nlpl.eu/OpenSubtitles2018.php).
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--force", action="store_true", help="re-download even when cached"
    )
    arguments = parser.parse_args()

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for language, url in sorted(SOURCES.items()):
        source = fetch(language, url, arguments.force)
        normalise = normalise_english if language == "en" else normalise_arabic
        counts = prune_short_noise(load_frequencies(source, normalise))
        if language == "ar":
            counts = add_supplement(counts, DIALECT_FILE, normalise)
        if not counts:
            print(f"error: {source} produced no usable words", file=sys.stderr)
            return 1

        write_words(OUTPUT_DIR / f"{language}.words", top_words(counts, WORDLIST_LIMIT))
        alphabet = alphabet_for(counts, EN_ALPHABET if language == "en" else None)
        write_json(OUTPUT_DIR / f"{language}.bigrams.json", build_bigrams(counts, alphabet))

    (OUTPUT_DIR / "LICENSES.md").write_text(LICENSES, encoding="utf-8")
    print(f"wrote      {(OUTPUT_DIR / 'LICENSES.md').relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
