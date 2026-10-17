# Project conventions and locked decisions — OpenCourt (PickUp)

One `###` per ruling, newest first, each headed with its date. A ruling says what it supersedes and
what it leaves unchanged. `CLAUDE.md` carries the release record; this file carries the decisions
and the working rhythm. Read before changes.

## Working rhythm (per pass)

- **Before every pass**, state in one bullet what has materially changed since the previous
  response, then define the issue and its root cause before proposing a move (owner preference,
  2026-10-17).
- **Interpretations are recorded as assumptions for the owner to correct**, in the working note,
  before the build.
- **Findings live on the branch, not in the chat.** Any survey, audit or review gets a dated
  `working/<YYYY-MM-DD>-<slug>.md`, committed, and **updated when the work lands** with an
  **Outcomes** section (commit SHAs, what shipped, what was deliberately left, and every place the
  original survey turned out to be wrong, kept beside the original text as a correction).
- **`working/` is notes, never a product surface.** Nothing the page serves may depend on it.
- **End every pass with**, in this order: the two most important missing assumptions or facts;
  the highest-leverage short-term fix; the highest-leverage long-term solution (owner preference,
  2026-10-17). Say plainly what was not run or not verified.
- **Relabel at merge.** If another change claims a version first, the later one takes the next
  number and says so in its entry and its note.

## Locked decisions

### The backend is SQL under row-level security; a profile is enough to play (build rulings 2026-10-17, v1.2.0)

**Owner:** "Run the long term solution build. I'll work on the cloud console key."

- **Everything server-side is a migration** in `supabase/migrations/`: tables, views, functions,
  policies, grants, schedules. No Express tier, no edge function until push notifications need a
  secret (M4). Clients never insert into a table directly; every write with a rule is an RPC that
  reads `auth.uid()`.
- **A profile (name + username, skill optional) on an anonymous Supabase session is enough to
  create or join a pickup.** MIGRATION §3 had said "pickups require a non-anonymous account"; the
  build relaxed it to match the SRS's "lightweight identity (nickname + skill tag)" and keep the
  first visit free. Tighten it in one place, `require_profile()`, if abuse appears.
- **One report window: 90 minutes**, in `REPORT_TTL_MINUTES` and in the `courts_live` view;
  the SRS's "~2 h" (FR-25) is superseded. One rate limit: one report per court per session per
  15 minutes, enforced in `submit_report()`.
- **Capacity counts the organiser.** `capacity = 4` is a doubles game including the person who
  set it up (the 2021 hint read "e.g. 4 (doubles)").
- **The clock is the database's.** `start_due_pickups()`, `finalize_due_mvp_votes()` and
  `expire_stale_pickups()` run from `pg_cron`; no process holds timers. A vote closes 24 h after
  the result with whatever votes exist; a game nobody closed expires after 24 h and never counts.
- **Standing formula is provisional:** 2 points per win, 3 per MVP, in the `player_standing`
  view only. Change it there; never store it.
- **The page never lies about its data.** `#data-source` reads "Shared data" only when the
  backend answered; otherwise "Offline data · reports stay on this device" (or "Backend
  unreachable …"), and report feedback says "saved on this device" rather than "shared".
- **Markers draw through the page's own OverlayView** unless `GOOGLE_MAP_ID` is set; the JSON map
  style stays. **Unchanged:** the committed Maps key and its restriction are the owner's console
  work.
- **M3 (friends, results, MVP) ships in SQL first**, tested, with its screens to follow; M2's
  screens (pickups, inbox) ship now. **Unchanged:** the SRS's Supabase choice; the no-build rule;
  the seed stays in `courts.json` and `supabase/seed.sql` is generated from it.

### OpenCourt is PickUp's successor; the name and logo stay; the 2021 backend flow migrates here (owner ruling 2026-10-17, v1.1.0)

**"Opencourt is the modern successor — though keeping the pickup namesake and logo will be the path
forward: migration of pickup backend flow to the opencourt structure and working apis."** And, in the
same message: **"I want pickup's issue and goal stated, vision, mission statement, and
requirements/user stories and workflow as our fundamental requirements and agent md."**

- The product is **PickUp**; **OpenCourt** names the codebase, this repository and the LA court
  catalogue. The 2021 wordmark and icon are carried byte-identically (`assets/img/`).
- `docs/FOUNDATION.md` is the fundamental requirements document; `docs/MIGRATION.md` is the plan
  of record for the backend; `docs/LEGACY_PICKUP_BACKEND.md` is the source of truth for what 2021
  did. `PickUpBois/PickUp` and `PickUpBois/PickUpHasura` are frozen, read-only references.
- **Supersedes** nothing in the SRS; it extends it (FR-60 onward). The SRS's Phase 3 rows
  (FR-50–53) are restated in FOUNDATION Epic E/F.
- **Unchanged:** the court finder's code, data, deploy and the no-build-step rule; the SRS's
  Supabase choice (§7) stands as the plan of record (see the stack decision record in
  MIGRATION §1).
- **Open, for the owner:** the visible wording of the rename on the page ("PickUp" · "PickUp ·
  OpenCourt LA" · "PickUp LA"); the extension of the mission line; disabling the 2021 Google
  service account.

### Identity comes from the database, never from the client (review ruling 2026-10-17, v1.1.0)

The 2021 backend identified the caller by a header the client set (`X-Hasura-User-Id`), had no
permission rules and no admin secret, and so let any client act as any user and read or write any
table. **That design is not ported.** Every row's actor is `auth.uid()` (or the server-minted
anonymous id); every owner-only, invitee-only, capacity and one-vote rule is enforced in SQL under
row-level security; the migration's gate includes a cross-user refusal matrix. **Unchanged:** the
Maps browser key and a publishable anon key may appear in source; service keys never do.

### No build step until a build step is necessary (SRS NFR-01, re-affirmed 2026-10-17)

Plain HTML/CSS/JS deployable to GitHub Pages as-is. A backend client is a pinned CDN script. The
`scripts/check.sh` gate (data parses, scripts parse, no secret-shaped strings) is the floor every
push clears; it grows a backend test leg from M1.
