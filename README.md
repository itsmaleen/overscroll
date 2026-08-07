# Overscroll

**Capture past the edge of the window — and get markdown, not pixels.**

Select a region on macOS, scroll, and Overscroll assembles everything that passes through it into a
single markdown document with the real link targets intact. Built to get a long chat thread into an
AI session without copy-pasting it piecemeal or spending ~2,000 tokens on a screenshot whose URLs
have already been truncated to display text.

```markdown
---
source: "WhatsApp"
window: "Sarah Chen"
captured: 2026-08-06T14:22:31Z
region: "620x880 @ (340,180)"
mode: accessibility
rows: 47
---

have you seen this one [Reducto's parsing benchmark](https://reducto.ai/blog/benchmark-2026)
...
```

## Why not just take a screenshot

Every scrolling-capture tool on macOS (Shottr, CleanShot X, ScrollSnap) stitches **pixels** and
hands you an image. Every screen-to-text tool reads whatever is **currently** in the accessibility
tree — one screenful. Chat clients virtualize their message lists, so only the rendered rows exist
as elements, and a long thread falls through both approaches.

Overscroll does scrolling capture in the **text domain**. It scrolls the target, re-reads the
accessibility tree at each step, and merges the snapshots by **document geometry**: rows already
carry a screen position, so any row visible in two consecutive samples reveals exactly how far the
content moved. Accumulating that displacement gives every row a stable document coordinate, and
merging becomes insertion into a sorted set.

That has one property worth stating outright: **an anchor is a row present in both viewports, so
its existence proves they overlap and that nothing passed between them unseen.** A measured merge
therefore cannot have skipped content, no matter how far the view moved — and the converse is the
entire definition of a gap. Where an anchor exists, the transcript is provably complete.

The payoff is not only token count. **The accessibility tree carries link targets and exact text
that the rendered pixels no longer contain.** A link displayed as `docs.google.com/spread…` comes
out whole.

## Two input modes, on purpose

While you are dragging the rectangle your trackpad is busy holding it, so the keyboard is the only
free hand. Both work, in every state:

- **WASD / arrow keys** — scrolls the content under the region, vertically or sideways (`A`/`D` for wide tables). Works *mid-drag*, before the region
  is committed, and after it is locked.
- **Trackpad** — once the region locks, the overlay becomes mouse-transparent, so normal two-finger
  scrolling passes through to the app underneath while the overlay keeps keyboard focus.

## Usage

`⌘⇧2`, or **Capture…** from the `✂︎` menu-bar item.

| Key | Action |
|---|---|
| drag | draw the capture region |
| `Space` | toggle whole-window picking instead of dragging |
| `W` `A` `S` `D` / arrows | scroll the target |
| `G` | auto-scroll to the end, unattended |
| `O` | read pixels (OCR) instead of the accessibility tree |
| `I` | keep the image alongside the markdown |
| `Return` | finish — markdown to clipboard + `~/Documents/Overscroll/` |
| `Esc` | cancel |

The HUD only lists keys that currently do something: scroll keys stay hidden until a target window
resolves, `Return` until there is something to copy. When scrolling pulls content in, **the edge it
came from glows**, with a brief flash on the edge that just grew — the box never moves while the
content does, so this is the only signal that a scroll accomplished anything.

**Gaps point the way back.** Because gaps are spans in document space, their position relative to
what is currently on screen is a live quantity — so instead of a bare count, amber chevrons drift
toward the edge you must scroll to reach the missing content, labelled with how many spans lie that
way. Scroll toward one and the arrow flips sides as you pass it, then disappears once the skipped
ground has been re-observed. Amber and chevron-shaped so they cannot be confused with the blue
edge glow, which means the opposite thing (content successfully captured). When the selection sits
hard against a screen edge the arrows fold inside it rather than drawing off-screen, and they step
clear of the HUD rather than hiding behind it.

You can inspect the overlay without running a capture, which is otherwise awkward since it covers
the screen:

```bash
Overscroll --render-preview /tmp/overlay.png --gaps-above 2 --gaps-below 1 --locked [--edge]
```

Both the markdown and the file path land on the clipboard. Paste the text for a short clip; paste
the **path** for a long one, so an agent reads it only if it needs it instead of swallowing the
whole thing as context.

## Install

```bash
./Scripts/build-app.sh          # → /Applications/Overscroll.app
open /Applications/Overscroll.app
```

Two grants in **System Settings → Privacy & Security**:

- **Accessibility** — required. Reads other apps' element trees *and* posts the scroll events.
- **Screen Recording** — optional. Only for the OCR fallback and for keeping the image.

macOS ties TCC grants to the **code signature**, so an ad-hoc build makes you re-approve after
every rebuild. `build-app.sh` auto-detects a Developer ID or Apple Development certificate in your
keychain and signs with it, which keeps the grants stable. If a grant ever appears enabled but the
app disagrees, the signature changed — clear the stale entry:

```bash
tccutil reset Accessibility com.itsmaleen.overscroll
```

The menu-bar icon shows the state directly: `✂︎` ready, `✂︎⚠` not trusted. It polls, so it updates
within seconds of you flipping the switch — no relaunch needed.

## The probe

`axprobe` is a diagnostic CLI that shares the harvester with the app, so what it reports is exactly
what a capture will see. Driving the GUI only tells you a clip came back empty; this tells you why.

```bash
swift run -c release axprobe --list                 # on-screen windows
swift run -c release axprobe WhatsApp               # harvest + role breakdown
swift run -c release axprobe WhatsApp \
    --region 0.35,0.05,1.0,0.92 \                   # fractions of the window
    --scroll up:12 --hid --adaptive --emit          # scroll, merge, render the clip
```

It reports which roles carried text, which were **rejected** (candidates for
`AXHarvester.textRoles`), how many independent scroll areas the region spans, and the merge outcome
of every step. It inherits the Accessibility grant of whatever launched it, so your terminal needs
that permission — the app's grant does not cover a separate binary.

Captures also write a trace to `~/Documents/Overscroll/debug.log` recording every keypress, scroll
route, and merge outcome, which distinguishes the three failure modes that look identical from the
finished clip: the scroll never moved, the harvest never ran, or the filter held everything back.

## What testing against a real app found

Measured against WhatsApp, not assumed. All of these changed the design:

1. **`postToPid` scroll events do nothing in WhatsApp.** Twelve steps, zero movement. The HID-tap
   fallback works. Per-process scroll cannot be relied on, so Overscroll detects a scroll that
   changed nothing and switches routing after a single dead step.
2. **WhatsApp exposes no `AXURL` on message rows at all** — so "the accessibility tree gives you
   real link targets" is false *there*. But the full, unabbreviated URL sits in the message text,
   which the pixel path still cannot recover because the UI renders it ellipsised. Links are
   therefore recovered from two sources: `AXURL` and text scanning.
3. **WhatsApp exposes no `AXScrollArea` either**, so grouping rows by scroll container — the
   obvious structural fix for a region spanning a sidebar *and* a message list — silently does
   nothing. That forced the general rule: **scrolling content moves, chrome doesn't**
   (`ScrollingContentFilter`), which needs no cooperation from the app's tree.
4. **Every string is prefixed with U+200E.** Invisible, survives copy-paste, and quietly breaks text
   comparison — including the accumulator's own overlap matching. Stripped at the source.
5. **Scroll step mattered enormously — until it didn't.** Under run alignment, gaps per 12 merges
   ran 8 at a fixed 60px and 3 with an adaptive step. That whole class of tuning turned out to be
   compensating for the merge strategy rather than for anything real: switching to geometry took
   gaps to **zero at every step size tested**, and the step became a throughput knob instead of a
   correctness one.

## Browsers and Electron apps

Chromium-based apps (Chrome, Edge, Arc, Helium, and Electron apps like Slack or VS Code) **do not
build their web-content accessibility tree until an assistive technology asks for it** — it is
expensive to maintain, so it stays off. Before that request, a browser window reports a window
element with *no children at all*, which is indistinguishable from "this app has no text".

Overscroll sets both opt-in attributes on every target: `AXManualAccessibility` (added by Chromium
specifically for automation tools that aren't screen readers) and `AXEnhancedUserInterface` (the
long-standing VoiceOver signal that Electron and several native apps honour). They are harmless
no-ops on apps that already expose a full tree.

The tree is then built **asynchronously**, so the harvest immediately following a region lock can
still land before it exists. Overscroll re-harvests at 0.35s, 0.9s and 1.8s while the read is still
empty, and stops as soon as rows arrive.

Measured on a Chromium browser: 1 node → 458 nodes, and 6 captured rows → 76, after these two fixes.

## Canvas-rendered apps (Google Sheets, Docs, Figma)

**Google Sheets draws its grid to a `<canvas>`**, not to the DOM — Google moved the Docs editors to
canvas rendering in 2021. A canvas has no semantic structure to read, so there is no accessibility
tree for the cells and nothing for Overscroll to harvest.

Sheets does have a screen-reader mode: **Tools → Accessibility settings → Turn on screen reader
support**. With it enabled the app synthesises accessibility output and captures may work, though
it is built to announce the *focused* cell rather than expose the whole grid, so expect partial
results.

**For a spreadsheet specifically, screen capture is the wrong tool.** Selecting a range and copying
gives you the cells as TSV, losslessly, and File → Download → CSV gives you the sheet. Overscroll
exists for content with no export path; a spreadsheet has an excellent one.

The same reasoning applies to Figma, Google Docs, remote desktops, and games. Where there is no
tree, the OCR fallback is the only route — and it currently captures a single screenful without
scrolling, so it is not yet a real answer for long canvas content.

### Columns

Reading order is normally down-then-across, and a y-major sort produces it. A two-column layout
inverts that — the correct order is the whole left column, then the whole right — so a y-major sort
interleaves the two sides line by line.

When a gutter is detected the column becomes the primary sort key. The hazard is over-detection
rather than under-detection: an indented list also has rows at two x positions, and splitting *that*
would scatter every bullet away from its own continuation lines, which is worse than the problem
being solved. Three conditions must hold together — a gutter far wider than indentation, at least
five rows on the narrower side, and genuine vertical co-existence — and each rejects a specific
false positive.

### Per-app profiles

`AppProfiles` records what is already known about an app so it is not rediscovered on every capture:
WhatsApp starts on the HID tap, Google Docs/Sheets/Slides start on the pixel path. Matching is on
the window **title** as well as the app, because the app is often the wrong unit — a browser is a
good accessibility citizen on most pages and blind on a Google Doc.

A profile only ever gives a head start. It sets state that detection would have reached anyway, and
never disables the detection, so a profile that misfires costs the round-trip it was meant to save
and nothing worse.

### Auto-scroll

`G` scrolls to the end on its own. Each step is issued from the **completion of the previous
harvest** rather than on a timer, so the scroll structurally cannot outrun the read — which is the
failure a person cannot avoid by hand: a fast flick produced 3-row reads on a page where a paused
one produced 15.

It stops after three consecutive steps that add nothing. Three rather than one, because a single
barren step is common mid-document — a figure, a wide table, a stretch OCR fails on — and stopping
there would end the capture in the middle with no sign anything was missed. A step ceiling backstops
infinite feeds, where the stale rule would never fire, and the two stops report different reasons
because "reached the end" and "hit the limit" mean different things about completeness.

While it runs, `Esc` stops the scroll rather than discarding the capture; a second `Esc` cancels.

Measured on a full Wikipedia article via the pixel path: **828 rows, 0 gaps, stopped after 28 steps**
having correctly detected the end.

### OCR consensus

A line stays on screen across several scroll steps, so it is recognised several times — and the
readings disagree. Overscroll tallies every distinct reading of each line and renders the modal
one, which costs nothing because the observations were already being made.

Grouping them needs a tolerance (`TextSimilarity`, a Levenshtein ratio): exact comparison treats
`5. Markers/overlay circling…` and `• Markers/overlay circling…` as different lines, and so does
containment, since neither contains the other. The tolerance applies to recognised text only —
accessibility rows are matched exactly, because a tree reports text verbatim and two similar short
labels are genuinely different things.

Ties are the common case, since a line is usually seen only two or three times, and they are broken
on **lexical plausibility** rather than length. Two findings forced that:

- **Length is worthless as a tie-break.** OCR substitutes glyphs rather than dropping them, so a
  garbled reading is usually *exactly* as long as the correct one.
- **`VNRecognizedText.confidence` is a constant.** Measured across a full page it returned exactly
  `1.00` for every line, including `concurrenty, camuna rournier a Albe developea ine Uptopnone`.

What does discriminate is that OCR failures produce non-words. The proportion of dictionary words
scores that garbled line at **0.47** against **1.00** for its neighbours, and consensus then picks
`Optical character recognition` over `Ontical character recoanition`.

## Design notes

**Gaps are marked, never hidden.** A gap means no row was shared between two samples, so the
displacement had to be assumed from the commanded scroll rather than measured. Overscroll records
the span inline rather than silently joining across it — a transcript with an unmarked hole reads
as complete, which is worse than one that admits the hole.

**Repeated text is disambiguated by position, not by context.** Two `ok` messages sit at different
document coordinates, so they are trivially distinct. This is the case that most troubles
text-matching approaches, and geometry sidesteps it entirely.

**The scroll step scales to the region.** Because only one shared row is needed, the limit is
simply "less than a viewport" — so the step is sized from the region height instead of creeping up
from a small constant. On WhatsApp a 300px step captured 83 rows to a 150px step's 39, with no gaps
either way.

### The earlier approach, and why it changed

The first implementation merged by **sequence alignment**: the longest suffix/prefix run of rows
shared between the transcript and the incoming snapshot — the same overlap detection an image
stitcher runs on pixels, done on rows. It works, but it needs a run of three rows to be confident,
and a chat client showing a handful of tall link previews often cannot supply one. Every failure
was a gap.

Run alignment is still in the tree as `ScrollAccumulator`, and `axprobe` runs both strategies over
the *identical* snapshot stream so the comparison is not confounded by the target scrolling
differently between runs. Measured on live WhatsApp:

| scroll step | run alignment | geometry |
|---|---|---|
| 40px × 10 | 8 rows, **2 gaps** | 8 rows, **0 gaps** |
| 80px × 10 | 8 rows, **4 gaps** | 8 rows, **0 gaps** |
| 150px × 20 | 39 rows, **14 gaps** | 39 rows, **0 gaps** |
| 300px × 20 | 83 rows, **4 gaps** | 83 rows, **0 gaps** |

**Getting out is guaranteed.** The overlay covers the screen and goes mouse-transparent once locked,
so a click can pass through and hand focus to another app. There are four independent exits: the
view's `Esc`, a global key monitor, a **Cancel Capture** menu item, and a watchdog that tears down
an abandoned capture after 3 minutes. Accessibility requests are capped at 0.4s and the tree walk
runs off the main thread, so a busy target app cannot freeze the overlay either.

## Fallback behaviour

If a region yields no accessibility text at all — a canvas-rendered surface, a remote desktop, a
scanned PDF — Overscroll captures the window with ScreenCaptureKit, runs Apple's Vision OCR over it,
and labels the output `mode: ocr` so you know link targets may have been lost. A fallback, never the
default.

## Layout

```
Sources/OverscrollCore/          pure logic, no AppKit — fully unit-tested
  CapturedRow.swift              one harvested row + its normalized identity
  ScrollTranscript.swift         geometry merge: document-space placement (primary)
  ScrollAccumulator.swift        run-alignment merge, retained as comparison baseline
  ScrollingContentFilter.swift   separates scrolling content from static chrome
  ClipDocument.swift             markdown rendering + provenance front matter
Sources/OverscrollAX/            accessibility + window server, shared by app and probe
  AXHarvester.swift              tree walk, region-filtered, link extraction
  WindowTarget.swift             window resolution + coordinate spaces
  Scroller.swift                 synthetic scroll events + adaptive step
Sources/overscroll/              the app
  OCRHarvester.swift             ScreenCaptureKit + Vision fallback
  Overlay.swift                  selection UI + key handling
  CaptureController.swift        state machine
Sources/axprobe/                 diagnostic CLI
```

`swift test` — 52 tests, all on the pure layer. Requires macOS 14+, Swift 6.

## Status

v0, working end to end against real WhatsApp threads: correct chronological order, real URLs,
provenance front matter, gaps marked where content was skipped.

Known rough edges:

- **Gaps are now rare but not impossible.** They occur only when no row is shared between two samples; the fix is a smaller step, which the adaptive stepper does automatically.


- Adaptive stepping backs off after a gap, so a run of keypresses may cover less ground than the
  region-sized default would.
- Tested against WhatsApp and a Chromium browser. Slack, Messages and Mail are unverified — run `axprobe` against them and check the REJECTED roles list first.
- The OCR fallback has not been exercised against a real canvas-rendered app.
- The UI layer has no test coverage; it is AppKit drawing and event handling.

## License

MIT
