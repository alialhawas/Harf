# Dodoma manual verification runbook

Everything in this file needs a live GUI session with the two privacy grants in
place. None of it is reachable from `swift test`, which is why it exists: the
event tap, the accessibility reads, the injector and the panel have no seam that
a headless test can drive.

Work top to bottom. The groups are ordered so that a failure early on explains
the failures after it.

**★ = must-run.** These six rows are the ones the milestone reports singled out
as gates on first use — the destructive path is live in every application by
default, and each of these is a place where "it mostly works" is not good
enough. Rows marked ☠ were flagged as blocking by the report they came from.

Each row cites where it came from: `T2` … `T8` are the task reports in
`.superpowers/sdd/system-instruction-you-are-working-rippling-kazoo/`.

Preconditions for the whole run:

- An English (ABC) **and** an Arabic input source enabled under
  System Settings → Keyboard → Input Sources.
- A scratch second application with a text field, holding something you can
  afford to lose (rows 25 and 26 will damage it).
- A terminal running `make logs` alongside.

The canonical sample used throughout is, with **Caps Lock on**:

```
HC MV; HKH HSMDIH HGDML
```

which must become `اذ ودك انا اسويها اليوم`.

---

## A. Install, signing and permissions

| # | Do | Expect | ★ |
| --- | --- | --- | --- |
| 1 | Run `scripts/make-cert.sh` once, then `make install` (T2.0, T5.1) | A `Dodoma Dev` identity exists; Dodoma appears in the menu bar with no Dock icon. Without the stable identity every rebuild invalidates both grants and the rest of this run is worthless | |
| 2 | First launch on a machine with no grants (M8) | The onboarding window opens **and Dodoma comes to the front** — the only time it is allowed to. It explains the destructive path and names ⌥⌘Z | |
| 3 | In the onboarding window, use each **Grant…** button (M8) | The correct System Settings pane opens. As each grant is given, the row's circle becomes a green checkmark within two seconds, without touching the window | |
| 4 | Press **Done**, then relaunch Dodoma (M8) | The onboarding window does not reappear. Menu → **Onboarding…** brings it back on demand | |
| 5 | Open the menu-bar item (T2.2, T5.2) | The first line reads **Active (capturing)**, and `make logs` shows `[com.ali.dodoma:tap] event tap started` | |
| 6 | Check the startup log (T5.3) | `language models loaded in NNN ms`. If it says `language models failed to load`, stop — nothing will ever be detected | |
| 7 | Revoke Accessibility in System Settings, watch the menu (T6.12) | Within two seconds the status line reads `Needs Accessibility permission`. Restore it; it returns to `Active (capturing)` without a restart | |
| 8 | With a grant revoked, use the menu's **Open Accessibility Settings…** and **Open Input Monitoring Settings…** items in turn (T2.1, T5.2) | Each opens its own System Settings pane — Accessibility and Input Monitoring respectively, not the Privacy & Security root. Re-grant from there and the status line returns to `Active (capturing)` within two seconds, with no relaunch | |

## B. Capture and the typed buffer

| # | Do | Expect | ★ |
| --- | --- | --- | --- |
| 9 | Menu → **Debug Window** (T2.3) | Title is `Dodoma Debug — keystrokes visible`, and opening it does **not** move keyboard focus away from the app you were in | |
| 10 | Type `hello` in TextEdit (T2.4) | Buffer reads `hello`, key count `5`, five `append` rows with the right key codes | |
| 11 | Switch to Arabic and type a few letters, including `ل` + `ا` (T2.5) | The buffer shows the Arabic text correctly, and `لا` is recorded as the produced text of a single key where applicable | |
| 12 | Press Delete several times, past the start of the buffer (T2.6) | The count shrinks to 0 and stays there. No crash, no negative count | |
| 13 | Press Return, then repeat with Tab, Escape and an arrow key (T2.7) | Buffer empties each time; "Last reset" reads `enterKey`, `tabKey`, `escapeKey`, `arrowNav` in turn | |
| 14 | Type text, then press ⌘A (or ⌃A). Then type `SHIFTED` and an ⌥-character (T2.8) | The chord empties the buffer with reason `modifierChord`; ⇧, ⌥ and Caps Lock typing still **appends** | |
| 15 | Type text, ⌘-Tab away and back (T2.9) | Reason `modifierChord` or `appChanged`; "Frontmost" tracks the app you switched to | |
| 16 | Type text, click elsewhere in the document (T2.10) | Reason `mouseDown` | |
| 17 | Type text, switch layout from the input menu, not a shortcut (T2.11) | Reason `inputSourceChanged` | |
| 18 | Type text, wait more than 10 s, type one more character (T2.12) | The buffer holds only the new character; reason `idleTimeout` | |
| 19 | Throughout B, watch what lands on screen (T2.13) | Everything you type appears normally. Dodoma is listen-only until it decides to act | |
| 20 ☠ | **Dead keys and IMEs.** In the U.S. or ABC-Extended layout type **⌥E then E**, then **⌥U then U**. If a Chinese/Japanese IME is installed, compose a candidate (T2.13a) | `é` and `ü`, exactly as without Dodoma; IME composition behaves identically. A lost, doubled or bare-`´` accent is a blocking bug — quit Dodoma and retype to confirm the difference before reporting it. The tap calls `CGEventKeyboardGetUnicodeString` on every keyDown, which is known to be able to perturb the target app's composition state | |

## C. The automatic fix

| # | Do | Expect | ★ |
| --- | --- | --- | --- |
| 21 ☠ | **The canonical fix.** TextEdit, new plain-text document, Caps Lock on, type the sample followed by **one space**, then stop (T5.4, T6.1) | After ~1 s: the text becomes `اذ ودك انا اسويها اليوم ` — *including the trailing space, it is part of the contract*; the input source switches to Arabic; the menu-bar item flashes `⇄ ع/E` for ~1.5 s; the menu gains a disabled `Last fix: HC MV; HKH…IH HGDML → اذ ودك ان…ها اليوم (com.apple.TextEdit) 14:32` line. Keep typing Arabic: the next word arrives in Arabic with no extra space needed | |
| 22 | With the debug window open, look at **Decisions** after row 21 (T5.5) | Region, `cur / alt` around `0.01 / 0.69`, verdict `autoApply`, guards `none`, policy `normal`, single-digit milliseconds, `Result: applied` | |
| 23 ☠ | **No false positives.** Caps Lock off, type several ordinary English sentences and several ordinary Arabic sentences, pausing between them (T5.7) | Nothing is ever rewritten; verdicts read `ignore` | |
| 24 | Type the sample and keep typing without a full second's pause (T5.8) | Nothing fires until you stop | |
| 25 | Type the sample + space, then hold ⇧ (or ⌘) down through the pause (T5.9) | Either the fix lands normally (release within ~450 ms), or the log reads `fix abandoned: a modifier stayed down through every retry` and `nothing was typed, so the buffer is kept as it is` and the text on screen is untouched. Release the modifier: the fix lands ~2 s later with nothing retyped | |
| 26 ☠ | **⌘-Tab during the burst.** Type the sample + space in TextEdit, let the pause elapse, ⌘-Tab to the scratch app the instant the deletes start (T5.10) | The burst stops within a few events; **no Arabic reaches the scratch app**; the log reads `fix failed (frontmostChanged) after deleting N/24 and inserting 0/24`. At most a couple of backspaces may land there before the abort — the notification arrives milliseconds after the switch. TextEdit is left with a partially deleted line. Then repeat, ⌘-Tabbing *during the pause* instead: nothing at all happens in either app, and the log reads `fix abandoned before it started: the frontmost app changed` | |
| 27 ☠ | Immediately after a fix, press ⌘Z in TextEdit one or more times (T5.11) | The document returns to a sane state — TextEdit's own undo sees the injection as ordinary typing, so expect several steps, but no corruption and no crash. While here, confirm the corrected text appears **once**, not twice | |
| 28 | Type the sample, then before the second elapses: click elsewhere / press ⏎ / press ⎋ / switch app (T5.12) | Nothing is rewritten in any of the four cases | |
| 29 | With Dodoma running, disable the Arabic input source, type the sample and pause. Re-enable it and try again (T5.13) | First: `skipped — no English/Arabic layout pair enabled`. Second: fixes normally, with no restart | |

## D. Safety, secure input and per-app policy

| # | Do | Expect | ★ |
| --- | --- | --- | --- |
| 30 | Type the sample in **Terminal**, pause (T6.2) | **No rewrite.** A suggestion card instead; the debug window shows `policy suggestOnly`, verdict `suggest` | |
| 31 | Focus **1Password** (or Bitwarden) and type (T6.3) | The debug window's buffer stays empty. Nothing captured at all, no decisions logged | ★ |
| 32 | Open a **Safari** page with a password field and type into it, **with the debug window open** (T6.4, T2.14) | Either the menu reads `Paused — secure input`, or the debug window shows the buffer dropped with reason `secureInput`. Nothing is ever rewritten. Read this as a check on the debug window too: **the event table must go empty at the drop, not merely the buffer line** — the last-fifty-keys log held the password one character per row until M5's fix-round-2, and `DebugWindowController` shows the newest snapshot when the window is opened, so also close the window, type into the password field, and reopen it: no characters from it may appear | ★ |
| 33 | Run `sudo -v` in Terminal and type while the prompt is up (T6.11) | The menu reads `Paused — secure input`; the buffer stays empty; it clears itself when the prompt closes | ★ |
| 34 | Type the sample into a **web textarea** — Gmail, a GitHub comment — and pause (T6.8) | Either it auto-fixes (caret verified) or it flashes `✕` and the log reads `auto-apply downgraded to a suggestion: <reason>`. Both are correct. **Note which apps do which** — this is the real-world coverage of the accessibility caret read | ★ |
| 35 | **⌘-Tab away immediately after pausing**, while the fix is being evaluated (T6.10) | No text is injected into the new app. The log reads either `fix abandoned: input arrived during the accessibility check` or `the frontmost app changed` | ★ |
| 36 | Repeat row 34 in **VS Code**, **Slack** and **Notes** (T6.9) | Note per app whether it auto-fixes or downgrades | |
| 37 | Menu → **Pause Dodoma**, type, then unpause (T6.5) | Checkmark appears, status line reads `Paused`, the debug buffer stays empty everywhere. Unpausing resumes capture | |
| 38 | Focus TextEdit, menu → **Mode for TextEdit** → **Off**, type. Quit and relaunch Dodoma, reopen the menu (T6.6) | The submenu names TextEdit and Normal is ticked to begin with. After Off, nothing is captured. **Off is still ticked after a relaunch** | |
| 39 | Set TextEdit back to **Normal**, run `defaults read com.ali.dodoma settings` (T6.7) | The blob contains `"com.apple.TextEdit":"normal"` alongside the seeded terminals and password managers | |
| 40 | Open the menu in each state in turn (T6.12) | `Active (capturing)` normally, `Paused` when paused, `Paused — secure input` under a password prompt, `Needs … permission` when a grant is revoked | |

## E. The suggestion card

| # | Do | Expect | ★ |
| --- | --- | --- | --- |
| 41 | Type the sample in Terminal (suggest-only) (T7.1) | The card appears next to the caret, showing the proposed text and the struck-through original | |
| 42 | Press **⇥** (T7.2) | The text is replaced, the input source switches, the card fades out | |
| 43 | Bring up a card, press **Esc** (T7.3) | The card goes; the buffer is **not** reset; the Esc does not reach the application | |
| 44 | Bring up a card, keep typing (T7.4) | The card goes and every keystroke lands in the application | |
| 45 | Click the card; then bring up another and click elsewhere (T7.5) | The click on the card accepts. The click elsewhere dismisses **and reaches the application underneath** | |
| 46 | Bring up a card on a second display, including one above or left of the primary (T7.6) | It is positioned correctly and stays on that display | |
| 47 | Bring up a card over a full-screen application, then switch spaces (T7.7) | It shows over the full-screen app and survives the space switch | |
| 48 | While a card is up, watch the menu bar and keep typing (T7.8) | The card never takes focus: the menu bar does not change and typing continues into the app | |
| 49 | Dismiss a card, retype the same text within a minute; then wait a minute and retype (T7.9) | No second card inside the minute; the card returns after it | |
| 50 | Bring up a card and leave it alone (T7.10) | It disappears after four seconds | |
| 51 | Bring up a card whose proposal is Arabic (T7.11) | It hangs from the caret's right and reads right-to-left | |
| 52 | With a card up, press **⌘⇥** (T7.13) | Applications switch, the card goes away, nothing is rewritten | |
| 53 | With a card up, press **⇧⇥**, **⌃⇥**, **⌥⎋** (T7.14) | Each reaches the application unchanged | |
| 54 | With a card up, **hold ⇥** (T7.15) | No spray of tabs into the application | |
| 55 | **Right-click** the card (T7.16) | It dismisses and the application opens whatever it would normally open | |
| 56 | Card up → type one character → press ⇥ during the caret check (T7.17) | Nothing is applied, and the buffer is still evaluated one second later | |

## F. Undo and the global hot keys

| # | Do | Expect | ★ |
| --- | --- | --- | --- |
| 57 | Auto-fix in TextEdit, then **⌘⌥Z** within 30 s (T8.1) | The original gibberish is back, the layout has switched back, the menu bar flashes ↩, and the Last-fix line ends `(undone)` | |
| 58 | Immediately after row 57, retype the same gibberish (T8.2) | It is **not** auto-fixed for 60 s | |
| 59 | Auto-fix, wait more than 30 s, press ⌘⌥Z (T8.3) | Nothing at all happens — no flash | |
| 60 | Auto-fix, ⌘-Tab away and back, press ⌘⌥Z (T8.4) | Nothing: the app switch withdrew the offer | |
| 61 | Auto-fix, click elsewhere, press ⌘⌥Z (T8.5) | Nothing | |
| 62 | Auto-fix, press Return, press ⌘⌥Z (T8.6) | Nothing at all — the undo was withdrawn | |
| 63 | Auto-fix, type two more words, press ⌘⌥Z **in TextEdit or another app with a readable caret** (T8.6a) | The menu bar flashes ✕ and nothing is deleted. Correct: the correction is no longer the last thing in front of the caret, and a burst counted back from the caret would eat the two new words | |
| 64 | The same in a terminal, or in an app listed under Advanced → skip verification (T8.6b) | Also ✕, nothing deleted. Before this fix, that case deleted the new text plus part of the correction, silently and irrecoverably | |
| 65 | Auto-fix, type a character, delete it again, press ⌘⌥Z (T8.6c) | The undo works — the caret now reads exactly what it read before | |
| 66 | Open the menu with an undoable fix pending, and again with none (T8.7) | **"Undo Last Fix ⌘⌥Z" is enabled only in the first case**, and clicking it does exactly what the shortcut does. This row also answers the open question of whether opening the menu itself fires an activation that withdraws the undo — if the item is *always* greyed out, that is the bug | ★ |
| 67 | Press **⌘⌥P** twice (T8.8) | The icon flashes ⏸ and then ▶; the menu's checkmark, the status line and the settings window's Pause switch all agree | |
| 68 | With a suggestion card on screen, press ⌘⌥Z and ⌘⌥P (T8.9) | Both work; the card is taken down by each | |
| 69 | Hold ⌘⌥Z down briefly (T8.10) | The undo still lands. A pre-flight that gives up leaves the undo on offer for a second press | |
| 70 | In a terminal, accept a suggestion where the accessibility layer exposes no caret text (T8.11, supersedes T7.12) | **It applies.** In M6 this flashed ✕; the M7 ruling changed it, and it is the one behaviour change to watch on first use | |
| 71 | In a field with a live autocomplete selection, accept a suggestion (T8.12) | ✕, nothing deleted | |
| 72 | Click into another window in the middle of a fix being applied — the burst is ~0.3 s, so this is hard to time (T8.13) | The fix completes, the "Last fix" line appears, and the Undo item is greyed out | |
| 73 | Pause with ⌘⌥P, then open the menu (T8.14) | "Undo Last Fix" is greyed out rather than enabled and then refusing | |
| 74 | Auto-fix in an app with no readable caret and press ⌘⌥Z straight away. Then auto-fix again and change the keyboard layout **by hand** before pressing ⌘⌥Z (T8.15) | First: the undo lands. Second: nothing happens — a manual layout switch withdraws the offer, while the fix's own switch does not | |

## G. Settings window, login item, onboarding (M8)

| # | Do | Expect | ★ |
| --- | --- | --- | --- |
| 75 | Menu → **Settings…** | The window opens without the app stealing focus from anything but the menu. Three tabs: General, Applications, Advanced | |
| 76 | General → change **Aggressiveness** | The explanation under the picker changes with the selection. `defaults read com.ali.dodoma settings` shows the new value immediately — there is no Apply button | |
| 77 | General → toggle **Pause**, then open the menu | The menu's Pause checkmark and status line agree with the switch, in both directions. Also check the reverse: toggling from the menu moves the switch in the open window | |
| 78 | General → toggle **Start Dodoma at login** | The switch sticks. `SMAppService` may report *requires approval*, in which case the explanation line and an **Open Login Items Settings…** button appear — approve it there and the line clears within two seconds. Log out and back in to confirm Dodoma starts | |
| 79 | Run from `build/Dodoma.app` rather than `/Applications`, toggle start-at-login, then `make clean` and log out/in | The login item points at a directory that no longer exists. This is why the README says install to /Applications first; the status should read *not found* afterwards and switching it off and on again from the installed copy must fix it | |
| 80 | General → toggle **Debug logging** on, reproduce a fix, `make logs` | The `decision` line appears with `region=<private>` — the switch decides whether the line is emitted, not whether the text in it is readable, and the region stays redacted unless private-data logging has been turned on for the whole system. Toggle it back off: the line stops appearing **even if you had previously run `defaults write com.ali.dodoma debugLogging -bool YES`** — the switch clears that key too | |
| 81 | Applications tab | The `All other apps` row is pinned at the top and reads Normal. Every seeded terminal and password manager is listed with its real name and icon; anything not installed on this machine shows its bundle identifier instead of a blank row | |
| 82 | Applications → change one row's dropdown to **Off**, type the sample in that app | Nothing is captured. The change is live, with no relaunch | |
| 83 | Applications → press the **−** button on a row you added, then reopen the window | The row is gone and that app follows the `All other apps` policy. Do the same to a **seeded** row (say Terminal) and relaunch Dodoma: **the seed comes back**, which is deliberate — deleting the row deletes the record of your decision | |
| 84 | Applications → **+ Add app…**, pick something from /Applications | A row appears for it at the default policy. Cancel the panel: nothing changes | |
| 85 | Advanced tab | The warning text explains what skipping verification gives up. Undo window reads `30 s`; the shortcuts read `⌥⌘Z / ⌥⌘P` — macOS's canonical modifier order, character for character what the menu's own Undo item renders — with a note that rebinding is not yet supported | |
| 86 | Advanced → add an app to the skip list, then re-run row 64 against it | Row 64's outcome must still hold: an undo after further typing is refused. The skip list changes the *fix* path, not the undo's serial check | |
| 87 | Menu → **Onboarding…** with both grants already given | The window opens with two green checkmarks, and closing it does not change anything | |

## H. Diagnostics and teardown

| # | Do | Expect | ★ |
| --- | --- | --- | --- |
| 88 | `defaults write com.ali.dodoma debugLogging -bool YES`, relaunch, `make logs` (T5.14) | The `decision` line appears with `region=<private>`. `make logs` passes `--debug --info`; without those the lines do not appear at all, and even with them the region is redacted. Turn it off afterwards (row 80 is the supported way) | |
| 89 | Menu → **Quit Dodoma** (T2.15) | No hang, and `make logs` shows `event tap stopped`. This is the only end-to-end check of the event-tap teardown path | |
| 90 | `scripts/uninstall.sh`, then reinstall | The app is gone and both grants are reset; reinstalling does not need another `make-cert.sh` run | |

## I. Flip on demand — ⌃⌘F

Preconditions for every row: both input sources enabled, both grants in place,
`make logs` running, and before each selection row put a known string on the
clipboard with `echo canary | pbcopy` so the pasteboard round trip can be checked
with `pbpaste`.

| # | Do | Expect | ★ |
| --- | --- | --- | --- |
| 91 | **TextEdit.** Type `hgsghl `, select it, ⌃⌘F | The selection becomes `السلام ` with no visible backspacing, the input source switches to Arabic, the menu flashes `⇄` and gains a **Last fix** line. `pbpaste` still prints `canary` (Accessibility path: nothing was copied) | ★ |
| 92 | ⌘⌥Z immediately after row 91 | `hgsghl ` is back, the layout is ABC again, the **Last fix** line reads `(undone)` | ★ |
| 93 | TextEdit: type `hgsghl ` and press ⌃⌘F with **nothing selected** | Flipped via backspaces; `make logs` shows `flipping the typed run` and a positive caret verification | ★ |
| 94 | ⌃⌘F in an empty TextEdit document with nothing selected | Nothing at all: no ✕, no card, no log fault | ★ |
| 95 | Row 91, then click **Learn** | `harf --words list --lang ar` gains the Arabic words; the card goes. Repeat with `pr link` typed on the Arabic layout: `harf --words list --lang en` shows `pr` and `link` | |
| 96 | Row 91, then click **Not**, then ⌘⌥Z | The card goes, the lexicon is unchanged, **and the undo still works** — the click on the card did not count as input | ★ |
| 97 | Row 91, leave the card alone | It fades after about six seconds; nothing is learned | |
| 98 | **Slack.** Select wrong-layout text in the message box, ⌃⌘F | Replaced in place; `pbpaste` still prints `canary` | ★ |
| 99 | **Conductor** (WebView, in the verify-skip list). Select wrong-layout text, ⌃⌘F; then type a run and press ⌃⌘F with nothing selected | The selection flips. The no-selection press is refused with a ✕: the caret cannot be verified there | |
| 100 | **Ghostty** (no accessibility tree). Select text on the prompt line, ⌃⌘F | The selection is replaced (clipboard path: `make logs` shows the copy). `pbpaste` prints `canary` afterwards. The card appears, anchored to the pointer | ★ |
| 101 | Ghostty with nothing selected and an empty Harf buffer, ⌃⌘F | Nothing is typed into the shell, no stray `c` reaches the prompt, and `pbpaste` is untouched. The menu flashes ✕ and `make logs` reads `the selection went unanswered`: an application that does not answer ⌘C is no longer read as an empty selection | ★ |
| 102 | Safari, focus a password field, ⌃⌘F | ✕. `make logs` shows the flip dropped **before** any copy; `pbpaste` is untouched | ★ |
| 103 | ⌘⌥P (pause), then ⌃⌘F | ✕, nothing copied | |
| 104 | Set an app to **Off**, ⌃⌘F there; set it to **Suggest only**, ⌃⌘F again | Off → ✕. Suggest only → the flip goes through | |
| 105 | Press ⌃⌘F and **keep the chord held for two seconds** | The flip lands once the keys come up rather than refusing | ★ |
| 106 | ⌘A a long TextEdit document, ⌃⌘F | ✕ and the document is untouched (the length cap) | ★ |


## J. The tap, the burst and the card (whole-project review, C1-C13)

Rows added by the review recorded in
`.claude/plans/review-the-entire-projuect-cached-pie.md`. Every one of them is a
change to what reaches the keyboard, and none of them has a seam a headless test
can drive end to end.

| # | Do | Expect | ★ |
| --- | --- | --- | --- |
| 107 | Type `hgsghl` and hold the last letter down for two seconds, then wait (C2) | The repeats appear on screen and `make logs` reads `typed buffer dropped: the tap missed input (autorepeat)`. Nothing is offered or rewritten afterwards until you type again — the buffer no longer claims to describe the line | ★ |
| 108 | Auto-fix, then hold any letter down for a second, then press ⌘⌥Z (C2) | Nothing happens and the Undo item is greyed out. The repeated characters are in front of the caret, and an undo would delete those instead of the correction | ★ |
| 109 | Provoke a tap disable — run something that saturates the input path, or `sudo log config` while typing — until `make logs` shows `event tap disabled ...; re-enabled` (C1) | The same line is followed by `typed buffer dropped: the tap missed input (timeout)`, any card on screen goes, and the Undo item is greyed out | |
| 110 | In TextEdit, type more than 120 characters of the sample on the wrong layout without pausing for a second, then stop (C3) | No rewrite and no card. `make logs` shows `fix withheld: tooLong`; nothing is deleted. Press ⌃⌘F over the same run: `flip refused: tooLong`. The cap is 120 clusters | ★ |
| 111 | Type `cafe` + ⌥E E (a decomposed é), then wrong-layout text after it, and wait (C4) | No rewrite and no card: `fix withheld: ambiguousCluster`. Repeat with an Arabic letter carrying a haraka and with an emoji — same outcome, nothing deleted | ★ |
| 112 | Select `hgsghl ` in TextEdit, ⌃⌘F, then ⌘⌥Z (C4) | Both still work. The لا ligature the flip produces is a single scalar and must not be caught by row 111's rule — check a word containing لا specifically | ★ |
| 113 | Start a fix over ~40 characters and ⌘-Tab to another application while the backspaces are running (C3, C8) | The burst stops within about ten more backspaces rather than running to the end. `make logs` shows `fix failed (frontmostChanged) after deleting N/40`; the second application is untouched | ★ |
| 114 | Same, but type into the *same* field while the burst is running (C3) | The burst stops the same way, with `inputSinceVerification` | |
| 115 | In an app that reads characters off key-up — a cross-platform toolkit or a terminal emulator — provoke a correction longer than 60 UTF-16 units, so it is injected as more than one chunk (A7) | The correction is inserted exactly once, with no stray character between the chunks and none after the last: the key-up now carries an explicit empty unicode string rather than the payload or a keycode-derived `a`/`ش` | ★ |
| 116 | Open the debug window, type, close it, type again, reopen it (C10) | The window comes back empty rather than showing what was typed while it was closed. Nothing typed before it was ever opened appears in it | |
| 117 | Get a card on screen and immediately type through it, repeatedly (C13) | The Tab key keeps working in the application underneath. The card is never left swallowing keys after it has gone | |
| 118 | Switch layouts with ⌃Space mid-sentence, then type a wrong-layout word and wait (C11) | The word is still evaluated. Before this it was skipped and never looked at again until another key was pressed | |

---

## Superseded rows, and why

Kept here so a reader of the older task reports does not re-run something that
is now wrong.

- **T5.6 — "type the sample in Notes and Safari; nothing must change; verdict
  `skipped`, reason `app not allowlisted`."** Obsolete since M5 flipped
  `defaultPolicy` to `.normal`. Dodoma now rewrites in every application that
  is not explicitly listed, so the correct expectation for those two apps is
  rows 34 and 36, not "nothing happens".
- **T7.12 — "in an app with no AX caret text, ⇥ flashes ✕ and changes
  nothing."** Reversed by the M7 ruling; row 70 is the current expectation.
- **T8.6 (original) — "auto-fix, press Return, ⌘⌥Z → nothing."** Correct as far
  as it went, but rows 62–65 replace it with the four cases that distinguish
  "withdrawn" from "refused".
- **T2.14 — "click into a password field; nothing is captured."** Folded into
  row 32, which asks for the same thing and names the log evidence.

## Still unmeasured after M8

None of these has ever been observed on hardware. They are not rows because
there is no defined pass criterion yet — record what you see.

- TCC grant persistence across repeated `make install` with the stable
  `Dodoma Dev` identity.
- Injection timings (10 ms backspaces / 40 ms gap / 6 ms inserts) in Electron
  applications.
- `TISSelectInputSource` confirming inside 250 ms.
- Marker filtering of self-injected events on the tap.
- `FocusOracle.caretRead`'s accessibility mapping, which has no seam below it
  and is therefore verified only by rows 34, 63, 64 and 70.
