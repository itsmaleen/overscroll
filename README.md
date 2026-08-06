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
accessibility tree at each step, and merges the snapshots by **sequence alignment**: the longest
suffix/prefix run of rows shared between what it has and what just arrived. That is the same
overlap detection an image stitcher runs on pixels, done on rows instead — exact, cheap, and
correct even when a chat log is full of repeated `ok` and `👍`, because it matches *runs* rather
than individual rows.

The payoff is not only token count. **The accessibility tree carries link targets and exact text
that the rendered pixels no longer contain.** A link displayed as `docs.google.com/spread…` comes
out whole.

## Two input modes, on purpose

While you are dragging the rectangle your trackpad is busy holding it, so the keyboard is the only
free hand. Both work, in every state:

- **WASD / arrow keys** — scrolls the content under the region. Works *mid-drag*, before the region
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
| `I` | keep the image alongside the markdown |
| `Return` | finish — markdown to clipboard + `~/Documents/Overscroll/` |
| `Esc` | cancel |

The HUD only lists keys that currently do something: scroll keys stay hidden until a target window
resolves, `Return` until there is something to copy. When scrolling pulls content in, **the edge it
came from glows**, with a brief flash on the edge that just grew — the box never moves while the
content does, so this is the only signal that a scroll accomplished anything.

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
5. **Scroll step matters more than expected.** Gaps per 12 merges: 8 at a fixed 60px, **3 with an
   adaptive step** that halves on a gap and creeps back up on clean merges.

## Design notes

**Gaps are marked, never hidden.** When no shared run can be found, the content between two
snapshots was never seen. Overscroll records that inline rather than silently joining across it — a
transcript with an unmarked hole reads as complete, which is worse than one that admits the hole.

**A gap never re-appends rows already in the transcript.** Alignment is unknown at that point, and
blindly appending is what turns a thread with a small exposed window into the same four messages
repeated five times.

**Direction decides placement when alignment fails.** Scrolling backwards means unplaceable rows
belong at the *front*; without that, scrolling back through a thread puts the oldest messages at
the bottom.

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
  ScrollAccumulator.swift        sequence-alignment merge across scroll steps
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

`swift test` — 38 tests, all on the pure layer. Requires macOS 14+, Swift 6.

## Status

v0, working end to end against real WhatsApp threads: correct chronological order, real URLs,
provenance front matter, gaps marked where content was skipped.

Known rough edges:

- **Gap rate on WhatsApp is ~3 in 12 merges.** Messages are tall and few are exposed at once, so a
  run of 3 shared rows is hard to guarantee. Gaps are marked, but the transcript is not always
  complete.
- Adaptive stepping trades coverage for integrity — it backs off after a gap, so a given number of
  keypresses covers less ground.
- Only WhatsApp has been tested seriously. Slack, Messages, Mail and browsers are unverified — run
  `axprobe` against them and check the REJECTED roles list first.
- The OCR fallback has not been exercised against a real canvas-rendered app.
- The UI layer has no test coverage; it is AppKit drawing and event handling.

## License

MIT
