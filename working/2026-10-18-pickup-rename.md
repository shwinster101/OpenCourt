# 2026-10-18 — The name on the door is PickUp (v1.3.1)

## Request (owner, verbatim)

> "Eli5 the supa base steps., and yes after that do the pickup name change" — accepting: "My recommendation is
> \"PickUp\" as the wordmark, using the 2021 logo already in assets/img/, with \"OpenCourt LA\" kept as a small
> sub-line or the court-finder section label".

## What changed

- `index.html`: the header brand is the 2021 wordmark (`assets/img/pickup-logo.png`, 581×197, unchanged bytes)
  with "OpenCourt LA" as a sub-line and the tagline kept; `<title>`, description, `og:title`; an Apple touch
  icon from `pickup-icon-1024.png`; badge v1.3.1.
- `assets/css/styles.css`: `.brand-logo` (34px tall on a white tile, 28px under 560px), `.brand-sub`.
- Docs: CLAUDE.md v1.3.1 entry; FOUNDATION §3 "landed" note; the conventions' open item struck through; SRS 1.3.1.

## What did not change

Repository, codebase and catalogue names; ids, classes, files; the people flow; the backend; the Maps key.

## Verification

- `sh scripts/check.sh` → GATE PASSED.
- `PORT=8000 test/browser/check-offline.cjs` → see Outcomes.
- Header width at 390px: see Outcomes.

## Outcomes

- Gate: GATE PASSED. Offline check on localhost:8000: 20 courts, 20 pins, no page errors.
- Header fit: 390px → header 390, document 390 wide (no horizontal scroll), logo 79×28, header-right ends at
  374; 1280px → logo 97×34, tagline shown. Screenshots in the session scratchpad.
- Commit: the commit carrying this note, on `claude/pickup-opencourt-migration-rbgxlp` restarted from `main`
  (`6aefc54`) after PR #1 merged.
