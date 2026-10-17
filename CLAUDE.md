# CLAUDE.md — OpenCourt (PickUp's successor)

**v1.1.0 — PICKUP COMES HOME: THE NAME AND LOGO STAY, THE 2021 BACKEND FLOW MIGRATES INTO OPENCOURT'S
STRUCTURE.** Owner (2026-10-17): "Run a thorough review of each repo, and especially read commits run
by Arian. I want pickup's issue and goal stated, vision, mission statement, and requirements/user
stories and workflow as our fundamental requirements and agent md. Opencourt is the modern successor
— though keeping the pickup namesake and logo will be the path forward: migration of pickup backend
flow to the opencourt structure and working apis."
- **The foundation:** `docs/FOUNDATION.md` states the issue (two frictions, WHERE and WHO, and the
  loop nobody closed), the goal, the vision, the mission (OpenCourt's line kept, an extension
  proposed), six personas, 40 user stories in eight epics with their 2021 and current status, the
  core loop and state machines, and the fundamental requirements FR-60–102, DR-10–14, NFR-10–15,
  continuing the SRS numbering. The SRS (`docs/REQUIREMENTS.md`, 1.0.1 → 1.1.0) stays the
  court-finder spec; FOUNDATION adds the people half.
- **The record of what migrates:** `docs/LEGACY_PICKUP_BACKEND.md` — the 2021 Hasura + Express +
  Firebase flow as built, from source: 12 tables, 19 actions, the domain-event outbox and its
  listeners, the auth model (a client-set header, no permissions), the intended-vs-delivered table.
  Sources `PickUpBois/PickUpHasura` (9 commits, all Arian Rahbar) and `PickUpBois/PickUp` (80
  commits: Arian 47, David Reynolds 30, Ashwin 3), both frozen at 2021-11-06; the Heroku host answers
  404.
- **The path:** `docs/MIGRATION.md` — principles, the entity map (`users→profiles`,
  `locations→courts`, `events→pickups` …), identity and RLS, a schema sketch, the API surface (every
  2021 action as a PostgREST write or an RPC function with the rule 2021 skipped), what is not
  ported, steps M0–M5 with acceptance, risks and the owner calls still open.
- **Brand ruling:** the product is **PickUp**; **OpenCourt** names the codebase, the repository and
  the LA court catalogue. `assets/img/pickup-logo.png` (the 2021 wordmark, 581×197) and
  `assets/img/pickup-icon-1024.png` are carried byte-identically. The page header still reads
  "OpenCourt LA": the visible rename waits on the owner's wording (FOUNDATION §3).
- **Not ported, by ruling of the review:** header-trusted identity, Hasura-admin access for every
  client, the Express action tier, in-process timers, Firebase. The Google service account committed
  to the public PickUpHasura repository is compromised and must be disabled in Google Cloud.
- **The gate:** `scripts/check.sh` (JSON parses, JS parses, no secret-shaped strings). No test suite
  exists yet; the SRS §8 checklist is the manual acceptance until M1 adds tests.
- **Found, not fixed (owner's call, first item of M0.5):** in headless Chromium the **live page**
  (`shwinster101.github.io/OpenCourt`, v1.0.1) renders its map and list but **no court pins** —
  Advanced Markers are created on a map without a Map ID (20 console errors) — **and shows Google's
  "This page can't load Google Maps correctly" dialog** to every visitor: the committed key is
  referrer-restricted (an unlisted origin is refused), but its restriction, API scope or billing does
  not match the production URL; the cause is only readable in the owner's Cloud Console. The SRS still
  records the key as an open blocker. Fourteen further OpenCourt findings, eighteen backend findings
  and the MacroDash doc-rot list are in the working note.
- **Code and deploy unchanged** in this release: `index.html`, `assets/js/app.js`, `styles.css`,
  `courts.json` and the Pages workflow are as at v1.0.1. The legacy repos' `CLAUDE.md` and
  `AGENTS.md` pointers (and PickUpHasura's README) were written and committed on their branches, but
  the push was refused (the Claude GitHub App is not installed on `PickUpBois`); staged copies sit in
  `docs/legacy-repo-docs/` until they land, then that folder goes.
- Working note: `working/2026-10-17-pickup-opencourt-review.md` (the four-repo review, the
  Arian commit narrative, findings with their verification status, outcomes).

**v1.0.1 — 2026-09-16.** Referrer-restricted Google Maps browser key wired into `index.html`; Pages
workflow enables the site on first run. (Recorded retrospectively from the git log; the SRS header
carried 1.0.1 from 2026-09-15.)

**v1.0.0 — 2026-05 (pushed 2026-09-15).** OpenCourt LA Phase 1: 20 curated LA County court sites,
Google Map with auto-fit bounds, three-tier access filtering, heuristic availability, three-button
localStorage reports, seasonal Grand Slam theming, consolidated SRS. See `docs/ROADMAP.md`.

## Current brief

PickUp, rebuilt on the OpenCourt structure: a **no-build-step HTML/CSS/JS** web app deployed to
GitHub Pages on push to `main` (`.github/workflows/pages.yml`). Today it is a court finder for
recreational tennis and pickleball in Los Angeles County (`index.html`, `assets/js/app.js`,
`assets/css/styles.css`, data in `assets/data/courts.json` and `grand-slams.json`); its Phase 2
backend is Supabase Postgres (chosen in the SRS, not yet provisioned); its Phase 3 is the 2021 PickUp
people flow — friends, pickups on courts, invitations, results, MVP, notifications — rebuilt as
working APIs per `docs/MIGRATION.md`. There is no package manager and no framework. The version
is the headline of this file; `docs/REQUIREMENTS.md` carries the same number.

## Required reading

- `docs/project-conventions.md` — the locked decisions and the per-pass working rhythm. Read
  before changes.
- `docs/FOUNDATION.md` — why PickUp exists and what it must do. Read before any product change.
- `docs/MIGRATION.md` — the plan of record for the backend; read before touching data or APIs.
- `docs/LEGACY_PICKUP_BACKEND.md` — what the 2021 code did, with its defects named; the source of
  truth when a 2021 behaviour is in question. The legacy repositories themselves are read-only.
- `docs/REQUIREMENTS.md` (SRS), `docs/ROADMAP.md`, `docs/PROJECT_BRIEF.md`, `docs/SETUP.md`.
- `working/` — dated notes; the newest is the latest state of any open work.

## Invariants

- **Honest signals.** A heuristic is labelled a heuristic, a live report says how old it is, demo or
  fallback data is labelled as such. Never relabel stale, cached or illustrative data as live.
- **Identity from the database, never from the client.** A row's owner is `auth.uid()` or the
  server-minted anonymous id; no header, body field or query parameter names the actor. Every
  organiser-only, invitee-only, capacity and one-vote rule lives in SQL under row-level security.
- **No build step until a build step is necessary.** Plain HTML/CSS/JS, deployable as-is; a client
  library is a pinned CDN script.
- **Forward-compatible schema.** Every record carries `metro`; migrations add, never rename or drop
  without a deprecation note in `working/`.
- **Secrets never enter this repository.** The referrer-restricted Google Maps browser key and a
  Supabase publishable anon key are client credentials and may appear in source; service-role keys,
  service accounts and tokens never do. `scripts/check.sh` refuses secret-shaped strings.
- **The PickUp name and logo stay.** Rename decisions are the owner's; the assets are not redrawn.
- **Preserve dates and provenance.** A court's `last_updated`, a report's timestamp, a result's
  recorded time and a note's source date are facts, never restamped because a routine ran.
- **Findings live on the branch.** Any survey, audit or review gets a dated `working/` note that is
  updated when the work lands (an Outcomes section with commit SHAs, what shipped, what the plan
  got wrong, corrections kept beside the original text).

## Working rhythm (per pass)

The protocol is in `docs/project-conventions.md`; in short: state what materially changed, define
the issue and its root cause, record interpretations as assumptions for the owner to correct, quote
the owner's ruling with its date in the entry that lands it (what changed, what did not, what remains
open), prefer the smallest change that closes the issue, run the gate before every push, and end
with the missing assumptions, the highest-leverage short-term fix and the highest-leverage long-term
solution.

## Verification

```bash
sh scripts/check.sh              # the gate: data parses, scripts parse, no secret-shaped strings
python3 -m http.server 8000      # then walk docs/REQUIREMENTS.md §8 by hand at http://localhost:8000
```

Pushes to `main` deploy Pages automatically. No production activation is implied by preparing a
branch. From M1 on, the gate grows a backend test leg (RLS matrix, the ported 2021 flows); until
then, say so rather than claiming coverage that does not exist.

## Legacy repositories (frozen, read-only)

| Repository | What it holds | Status |
|---|---|---|
| `PickUpBois/PickUp` | SwiftUI iOS app (111 views, Apollo codegen, Firebase Auth/Storage/Messaging), the wordmark and icon | frozen at `496b914e` 2021-11-06; `CLAUDE.md` there points here |
| `PickUpBois/PickUpHasura` | Hasura v2.0.4 metadata + 51 migrations, Express/TypeScript action handlers, pytest flows, docker-compose | frozen at `4244d6d` 2021-11-06; public; contains committed credentials (see its `CLAUDE.md`) |
| `shwinster101/MacroDash` | an unrelated project of the same owner; the exemplar for this document's conventions | not part of PickUp |
