# 2026-10-18 — UX pass, part one: the court panel as a bottom sheet on phones (v1.3.3)

## Request (owner, verbatim, with a phone screenshot of the live page)

> "Do a Ux pass. I'm unable to close out of this or even see it properly. Map is good but some user wants
> and usage is clunky"

## Root cause

`@media (max-width: 880px)` placed `.detail-panel` absolutely inside `.map-wrap` (the 40vh map row) with
`max-height: 80vh`: the panel's dark header, name and ✕ rendered above the map box's top edge, hidden behind
the header bar, and the whole thing scrolled with the page. The screenshot shows exactly the bottom half.

## Change

- Phone: `.detail-panel` is `position: fixed; bottom: 0; left/right: 0; max-height: 86dvh`, rounded top, a
  grip, ✕ at 32px, a `.detail-backdrop` that closes on tap, `body.detail-open { overflow: hidden }`.
- `openDetail()` / `closeDetail()` in app.js; Escape closes the court panel after the sheet and the inbox.
- Desktop (>880px) unchanged.

## Verification (390×844, headless Chromium, live config)

Tap a court: panel open, top 166 / bottom 844 of 844, ✕ is the element under the pointer, body locked,
backdrop shown. ✕ closes; Escape closes; backdrop tap closes. Offline check: 20 pins, no errors.
Fake-backend check: errors []. Gate: GATE PASSED.

## Still clunky (next passes, owner to rank)

- The hero paragraph and the slam box push the court list a full screen down on phones; the list is the
  product on a phone.
- Filter chips take three rows; a single horizontal scroller would do.
- The map is 40vh with the panel over it; a "map / list" toggle or a taller map on tap may read better.
- "Start a pickup here" opens a form inside the sheet; on a phone the keyboard covers half of it.
- The count tiles (0 · 13 · 7) have no labels until you scroll.


## Part two (2026-10-19, v1.3.4): the list above the fold

Owner: "Run item 1, the list above the fold, since finding a court is the first thing a visitor does."

- Phones (≤880px): hero = title + data-source line (subtitle hidden); sport chips on the face; tier and status
  behind `#filters-more` (aria-expanded, "More filters ▾" / "Fewer filters ▴"); stats as one strip; the season
  hint moved after the list in the markup (every size; it is secondary).
- Measured (headless Chromium, live config): 390×844 first row top 611, 4 rows visible; 375×667 first row 540,
  2 rows visible; the toggle opens the two folded rows and a tier chip still filters (Free → 14 rows).
  1280×800 unchanged (no toggle, three rows). No horizontal scroll at any width.
- Remaining items (2–5) stay listed above; the owner's long-term line is a phone-first pass with a word and
  tap budget pinned in the browser check.
