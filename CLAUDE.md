# CLAUDE.md — OpenCourt (PickUp's successor)

**v1.2.0 — THE SHARED BACKEND, BUILT AND PROVEN BEFORE IT HAS A HOME: COURTS AND REPORTS, IDENTITY AND
PICKUPS, FRIENDS, RESULTS AND MVP, AS SQL UNDER ROW-LEVEL SECURITY; THE PAGE WIRES TO IT AND STAYS HONEST
WITHOUT IT.** Owner (2026-10-17): "Run the long term solution build. I'll work on the cloud console key."
- **The backend is four migrations and a seed** (`supabase/`), no server code. M1 `courts`,
  `court_reports`, the `courts_live` view, `submit_report()` with the 15-minute rate limit. M2
  `profiles`, `pickups`, `pickup_attendees`, `notifications`, `event_log`; `upsert_profile`,
  `create_pickup`, `join_pickup`, `leave_pickup`, `cancel_pickup`, `invite_to_pickup`,
  `cancel_invitation`, `respond_to_invitation`, `start_due_pickups`, `mark_notifications_read`; views
  `open_pickups`, `my_pickups`, `my_notifications`; `pickup_by_token`, `pickup_roster`. M3 `friendships`
  and its six functions, `search_players` (parameterised; 2021 interpolated SQL), `pickup_teams`,
  `record_result` (team membership recorded; 2021 dropped it), `mvp_votes`, `vote_mvp` (one vote, not
  self, ties broken among the leaders), `finalize_due_mvp_votes`, `expire_stale_pickups`, the
  `player_standing` view (2 per win, 3 per MVP, provisional). `0004` schedules the three clock
  functions with `pg_cron` where it exists.
- **Every rule 2021 skipped is in SQL under `auth.uid()`:** organiser-only cancel/invite/result,
  invitee-only respond, capacity under a row lock, start by the database clock, owner-only inbox.
  Clients cannot insert into any table directly; `anon` reads courts, the board and a shared link.
- **Proven:** `test/backend/run.sh` starts a throwaway PostgreSQL, applies a Supabase shim (roles,
  `auth.uid()`, Supabase's default grants), all migrations and the seed, then `t_010`–`t_030`: the 2021
  pytest flows ported and extended, the cross-user refusal matrix, decay, capacity, the clock, the MVP
  tie-break and deadline. **167 assertions pass** here on PostgreSQL 16. `sh scripts/check.sh --backend`
  runs it; the plain gate also checks that `supabase/seed.sql` matches `courts.json`.
- **The page** (`assets/js/app.js`, `backend.js`, `config.js`; pinned `supabase-js@2.45.4` UMD): with
  a URL and anon key in `config.js` it reads `courts_live`, writes reports through `submit_report`,
  lists and starts pickups on each public court (name prompt on first action, anonymous session),
  joins/leaves/cancels/accepts, copies a share link (`#pickup=<token>`), opens one from a link, and
  shows an inbox. Without them it serves `courts.json`, keeps reports on the device, and the sidebar
  says so ("Offline data · reports stay on this device"); nothing claims to be shared. Court fields
  are escaped before they reach `innerHTML`.
- **Pins are back:** markers draw through the page's own OverlayView unless a `GOOGLE_MAP_ID` is
  configured (then Advanced Markers). Verified in headless Chromium: 20 pins, no script errors, in
  both offline mode and against a fake supabase-js that mirrors the views' shapes.
- **Decisions recorded** in `docs/project-conventions.md`: a profile (anonymous session allowed) is
  enough to run a pickup, tightenable in one function; one 90-minute report window on both sides;
  M2 before M3 in the UI (M3 ships in SQL only this release).
- **Not done:** no Supabase project exists yet (owner steps in `supabase/README.md`); the friends,
  results and MVP screens; realtime and push (M4); the visible rename. Working note:
  `working/2026-10-17-shared-backend-build.md`.

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
GitHub Pages on push to `main` (`.github/workflows/pages.yml`). It is a court finder for
recreational tennis and pickleball in Los Angeles County (`index.html`, `assets/js/app.js`,
`assets/js/backend.js`, `assets/js/config.js`, `assets/css/styles.css`, seed data in
`assets/data/courts.json` and `grand-slams.json`) with the PickUp people flow — profiles, pickups on
courts, invitations, the inbox, and in SQL also friends, results and MVP — on a **Supabase Postgres
backend defined entirely by `supabase/migrations/`** (PostgREST + RPC + RLS; no server code). The
page runs with or without the backend and says which. There is no package manager and no framework;
the only runtime dependency is the pinned `supabase-js` UMD script. The version is the headline of
this file; `index.html`'s badge and `docs/REQUIREMENTS.md` carry the same number.

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
sh scripts/check.sh              # the gate: data parses, scripts parse, no secret-shaped strings, seed current
sh scripts/check.sh --backend    # + migrations, RLS matrix and the ported 2021 flows on a throwaway PostgreSQL
python3 -m http.server 8000      # then walk docs/REQUIREMENTS.md §8 by hand at http://localhost:8000
```

The backend leg needs the PostgreSQL server binaries (it skips with a message otherwise; set
`REQUIRE_BACKEND=1` to fail instead). Pushes to `main` deploy Pages automatically. No production
activation is implied by preparing a branch; the live backend exists only once the owner provisions
the Supabase project (`supabase/README.md`) and fills `assets/js/config.js`.

## Legacy repositories (frozen, read-only)

| Repository | What it holds | Status |
|---|---|---|
| `PickUpBois/PickUp` | SwiftUI iOS app (111 views, Apollo codegen, Firebase Auth/Storage/Messaging), the wordmark and icon | frozen at `496b914e` 2021-11-06; `CLAUDE.md` there points here |
| `PickUpBois/PickUpHasura` | Hasura v2.0.4 metadata + 51 migrations, Express/TypeScript action handlers, pytest flows, docker-compose | frozen at `4244d6d` 2021-11-06; public; contains committed credentials (see its `CLAUDE.md`) |
| `shwinster101/MacroDash` | an unrelated project of the same owner; the exemplar for this document's conventions | not part of PickUp |
