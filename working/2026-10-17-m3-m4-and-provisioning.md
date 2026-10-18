# 2026-10-17 — M3 screens, M4 realtime + email upgrade, a one-command provisioner, a two-browser proof (v1.3.0)

## Request (owner, verbatim)

> "You do as much as you can look up instructions if needed. provision Supabase and fill config.js, then open
> two browsers and confirm a report on one appears on the other. • Highest-leverage long-term solution: M3
> screens plus M4 realtime and email upgrade, so friends, results and MVP reach the page and polling goes away."

Two asks: (1) the short-term fix from the v1.2.0 pass — provision, fill `config.js`, prove it in two browsers;
(2) the long-term solution — M3 screens and M4 (realtime, email upgrade).

## What materially changed since the previous pass

- v1.2.0 is pushed (`daa9ea0`, `fbc3bbd`): the backend exists as SQL and passes 167 assertions, the page is wired,
  but no Supabase project exists and the people flow has no friends/results/MVP screens and polls for everything.
- This pass adds: the M3 screens, M4's realtime channel and email upgrade, a provisioner that turns the
  owner's 15-minute checklist into one command, and a local stand-in for Supabase (a mini PostgREST + GoTrue over
  the real migrations) so the two-browser proof runs here, today, without a project or Docker.

## What this container can and cannot do (checked 2026-10-17)

| Need | Found | Consequence |
|---|---|---|
| A Supabase access token | none in the environment (no `SUPABASE_*` variable, no connector) | the project cannot be created from here; the provisioner is built and tested against a mock of the Management API, and runs for real once the owner stores `SUPABASE_ACCESS_TOKEN` as an environment secret |
| `api.supabase.com` | reachable (401 without a token); the Management API's OpenAPI document downloaded (115 paths) | the provisioner is written from the spec, not from memory |
| Docker daemon | client present, no daemon socket | no `supabase start`; hence the local stand-in |
| PostgreSQL 16 server binaries | present (`/usr/lib/postgresql/16/bin`) | the local stand-in runs the real migrations under the real roles |
| Playwright + Chromium | present | the two-browser proof runs headless here |
| `cdn.jsdelivr.net`, `registry.npmjs.org`, `supabase.com/docs` | reachable | the pinned client and the docs can be fetched |

## The issue and its root cause

- **Issue:** the owner's acceptance test ("a report on one browser appears on the other") cannot be run,
  because the only thing that would share state between two browsers — a Supabase project — does not exist,
  and this container holds no credential that could create one. Separately, three of the eight epics
  (friends, results, MVP) exist only in SQL, and the page polls for everything.
- **Root cause (short-term):** provisioning was specified as a human checklist (`supabase/README.md`), so it
  depends on a person at a dashboard. The Management API covers every step, so the checklist can be a script,
  and the acceptance test can be a script too — both runnable the minute a token exists.
- **Root cause (proof without a project):** every test so far ran either against the SQL alone (`psql`) or
  against a hand-written fake of supabase-js. Neither exercises the real client against the real SQL. A mini
  PostgREST/GoTrue over the real migrations closes that gap locally and makes the two-browser proof
  meaningful before the project exists.
- **Root cause (long-term):** M3 shipped SQL-first by ruling; the screens were the next pass. Polling was the
  honest default because realtime needs the tables in a publication and a channel status the page can trust.

## Assumptions recorded for the owner (correct in `docs/project-conventions.md` if wrong)

| # | Assumption | Where it bites | How to change it |
|---|---|---|---|
| B1 | The owner will store a Supabase personal access token as an environment secret named `SUPABASE_ACCESS_TOKEN` (never pasted in chat) so a later session can run `scripts/provision-supabase.sh`; until then the owner can run the same script on their own machine. | provisioning | the variable name is one line in the script |
| B2 | Project defaults: name `pickup`, region `us-west-1`, free tier; the database password is generated and printed once, never stored. | provisioning | env overrides |
| B3 | Realtime carries `pickups`, `pickup_attendees` and `notifications` only. `court_reports` stays polled: its RLS lets only the author read a row, so other visitors would receive no events. | M4 | add a public-safe reports view or a broadcast later |
| B4 | "· live" appears on the face only while the channel reports SUBSCRIBED; any other status falls back to the v1.2.0 polling, silently. | M4 | — |
| B5 | An anonymous player keeps the account by adding an email (`auth.updateUser`); signing in on another device is a magic link; Sign out is hidden for anonymous sessions because it would lose the profile. | M4 | — |
| B6 | Result entry: the organiser assigns the roster to two teams and types set scores as "6-4 3-6 10-7"; both teams' arrays are derived from that one string. | M3 | the parser |
| B7 | The local stand-in mirrors the subset of PostgREST and GoTrue the page uses; it is a test tool, never a deployment target, and any divergence from Supabase is a bug in the stand-in, not a feature. | tests | — |
| B8 | The Mine list, friends panel and profile sheet are header-level panels beside the inbox, not a navigation change; offline mode shows none of them. | M3 | — |

## Build

Run as one orchestrated pass (six workers, disjoint files, then a review panel), 2026-10-17 20:57 →
2026-10-18 ~03:30 UTC, with a pause while the worker quota reset. Every claim below was re-run by the lead
before commit (§Verification).

### M3 screens (`assets/js/app.js`, `backend.js`, `index.html`, `styles.css`; no new SQL)

- `backend.js` gained the M3 calls with the SQL functions' exact `p_*` names: `searchPlayers`,
  `friendStatus`, `myFriendEdges` (one read of my `friendships` rows → a status for a whole list),
  `sendFriendRequest` / `accept` / `reject` / `cancel`, `removeFriend`, `myFriends`,
  `incomingFriendRequests`, `inviteToPickup`, `cancelInvitation`, `recordResult`, `voteMvp`, `myVotes`,
  `pickupTeams`, `myStanding`, `profilesByIds`; and one short sentence per `raise` in `0003`.
- One `#sheet` with a panel stack (mine · friends · invite · result · vote · profile), one render function
  per panel, delegated clicks, ✕ closes the sheet, ‹ and Escape close the top layer only.
- **Mine:** `my_pickups` newest first; status chip; the one action its state allows. **Enter result:**
  roster → T1/T2 toggles, "6-4 3-6 10-7" → two int arrays, winner radio, client pre-checks, then
  `record_result`. **Vote MVP:** roster minus me, one tap. **Friends:** search (300 ms debounce, ≥2 chars,
  stale responses dropped), + Add · Requested ✓ (tap cancels) · Accept/Decline · Friends ✓ (tap → Remove),
  incoming requests above the list. **Invite:** friends not yet on the roster → `invite_to_pickup`; the
  roster shows "invited" with ✕. **You:** display name, @username, skill pips, standing tiles, formula
  behind ⓘ. Inbox items for enter_result / vote_mvp / friend_request open the matching panel.
- Two-tap arms for Cancel / Leave / Remove (first tap "Sure?", sends nothing).
- A header fix: `header { min-width: 0 }` (the grid column was already 411px at a 390px viewport before
  this pass); below 560px the slam name, clock pill and version badge hide so brand + buttons fit.

### M4 part one (`supabase/migrations/0005_realtime.sql`, `test/backend/t_040_realtime.sql`, the page)

- `0005`: a `DO` block adds `pickups`, `pickup_attendees`, `notifications` to `supabase_realtime` when
  that publication exists and is not FOR ALL TABLES; a notice otherwise. `court_reports` is not published
  (author-only RLS → nobody else would receive events; the page reads a view, which a publication cannot
  carry). The shim creates the empty publication so the branch runs in tests; `t_040` (15) checks the three
  members, RLS on each, replica identity, idempotence, and that a client still reads only its own rows.
- `Backend.subscribe({ onPickups, onNotifications, onStatus })`: one channel; `pickups` for every visitor;
  `pickup_attendees` and `notifications` (filter `recipient_id=eq.<uid>`) only with a session (anon has no
  select on them). Checked against the pinned bundle (realtime-js 2.10.2, auth-js 2.65.0) and the docs.
- `app.js`: "· live" (and `data-live`, `data-poll`) only while SUBSCRIBED; polling 60 s / 5 min
  otherwise; events coalesced 250 ms refresh the open court, Mine, courts_live counts and the inbox;
  re-subscribe on uid change and `pageshow(persisted)`, unsubscribe on `pagehide`; `renderPickups` keeps an
  open form across re-renders (the anonymous sign-in's own SIGNED_IN used to wipe the name form).
- Account: `detectSessionInUrl: true`; *Keep this account* → `updateUser({ email }, { emailRedirectTo })`;
  *Played before? Sign in* → `signInWithOtp({ shouldCreateUser: false })`; Sign out two-tap, hidden for
  anonymous sessions; `onAuthStateChange` → reload profile, inbox, Mine, open court, channel; the hash
  router ignores `access_token=` / `error=` hashes and cleans them; `#auth-notice` shows an expired-link
  line.

### The provisioner (`scripts/provision-supabase.sh`, `test/provision/`)

- Written from the Management API's OpenAPI document (saved during the pass; field names and their JSON
  paths are listed in the worker's report and in the script's comments). Steps: organisation →
  create-or-reuse (`region_selection`) → poll project + `/health?services=db,rest,auth` → PATCH auth
  config (`external_anonymous_users_enabled`, `external_email_enabled`, `uri_allow_list` union, `site_url`
  when default) → `create extension if not exists pg_cron with schema pg_catalog` + grants (Supabase's
  cron install page) → migrations and seed via `database/query`, each recorded with PUT
  `database/migrations` → `api-keys?reveal=true`, the anon (or publishable) key only → outside verify →
  `config.js` written atomically preserving `GOOGLE_MAP_ID` / `METRO`.
- The token travels to curl through a process-substitution `--config`; never argv, disk or output. The
  database password is generated (32 chars) and printed once. `--dry-run`, `--check`, `--help`.
- `test/provision/mock-api.py` + `run.sh`: 40 assertions (order, idempotency, key hygiene, `--check`,
  `--dry-run`, wrong token). The expected migration list is derived from the folder.

### The local stand-in and the proof (`test/e2e/`)

- `local-backend.py`: GoTrue subset (anonymous signup, user, refresh, updateUser, otp, logout, settings;
  HS256 test JWTs) and a PostgREST subset generic over schema `public` (select/filters/order/limit/offset,
  `Prefer: count=exact`, `Accept: …object+json` → 406 PGRST116, RPC typed from `pg_proc`), each request in
  one transaction under the real role with `request.jwt.claims` set, so `auth.uid()` and RLS behave as on
  Supabase; psql per request (psycopg2 absent), values as psql variables, identifiers validated against the
  catalog. CORS for a page on another port. No websocket (realtime 404s → the page polls, never "· live").
- `local-stack.sh start|stop|status` (cluster via `test/backend/run.sh KEEP=1`, backend 54400, page 8020;
  state in gitignored `test/e2e/.stack/`); `smoke-local-backend.sh` (44 curl checks incl. anon 401 on
  `my_notifications`, `rate_limited`, two users, inbox ownership, `open_pickup_count`).
- `two-browsers.cjs` (Playwright, CommonJS): two fresh contexts; config routed only when `OC_SUPABASE_*`
  are set (else the page's own `config.js`: real-project mode); Maps aborted (the list and panel do not need
  it); unique names per run; 8 steps with observed text; screenshots on failure; exit 1 on any FAIL.

### Fixed by the lead after the gate run

| Finding (from the run-all-gates worker) | Fix |
|---|---|
| Gate step 3 failed at HEAD: the v1.2.0 note spelled out the scan's own key names | reworded `working/2026-10-17-shared-backend-build.md` §1.4 |
| `0006_realtime.sql` with no `0005`; the provisioner mock enforces contiguity | renamed to `0005_realtime.sql` / `t_040_realtime.sql`; every reference updated; `test/provision/run.sh` now derives its expected list from the folder |
| two-browsers step 8 intermittent: the highlight was applied once and lost to the next render | `renderPickups` re-applies the highlight on every render of that court (scrolls once); dropped when another court opens |

## Verification (lead's own runs, 2026-10-18, after the fixes)

| Check | Result |
|---|---|
| `node --check` on every page and test script | ok |
| `sh scripts/check.sh --backend` (PostgreSQL 16, `PGPORT=54380`) | GATE PASSED · BACKEND TESTS PASSED (182 assertions = 25 + 71 + 71 + 15) |
| `PORT=8000 test/browser/check-offline.cjs` | 20 courts, 20 pins, 40 list rows, no auth dialog, no page errors |
| `PORT=8000 test/browser/check-backend.cjs` (fake supabase-js) | `errors: []`; "Shared data · live" with SUBSCRIBED; Mine rows open/open/in progress/closed; "Saved · closed · team 1 won"; "Voted ✓"; "Requested ✓" → "Friends ✓"; Invite → roster `B Smith:invited`; standing tiles; sign-in OTP captured with `shouldCreateUser:false`; CHANNEL_ERROR context polls at 60 s with no "· live"; auth-hash notice; `#pickup=` still works |
| `test/e2e/local-stack.sh start` + `smoke-local-backend.sh` | 44 passed, 0 failed |
| `test/e2e/two-browsers.cjs` ×3 on the stand-in | 8 passed, 0 failed, 0 skipped — three times (the step-8 fix holds) |
| `bash test/provision/run.sh` | PROVISION TESTS PASSED (40 assertions) |
| Review panel (three lenses → refute → fix → re-run) | see §Review below |

**Not run / not verifiable here:** anything against supabase.com (no token, no project): the real
provisioning, realtime delivery, the Keep-this-account and magic-link round trips, the two-browser proof on
the real project. The Maps billing fix is the owner's.

## Review (after the build and the lead's fixes; the worker quota reset at 01:40 UTC, so this ran as a resume)

Three lenses read the whole change set against the SQL (security and RLS alignment · honest signals and
the owner's product rules · correctness); every blocker/major was handed to two independent refuters;
one fixer applied what survived; an independent runner re-ran every gate.

| Lens | Findings | Of which blocker/major |
|---|---|---|
| security / RLS | 3 | 0 |
| honesty / product | 6 | 1 |
| correctness | 9 | 1 |

**Confirmed (both refuters agreed) and fixed:**
1. **The inbox was clipped** — `header { overflow: hidden }`, added for the phone-width header, cut the
   inbox dropdown off: a signed-in player saw the badge but never the notifications. A v1.2.0 feature
   regressed by v1.3.0, caught before merge. `.inbox` is now fixed-positioned; `check-backend.cjs` asserts
   the dropdown is the element under the pointer at 1280px and 390px.
2. **The stand-in's error status mapping** sent `P0002` (not-found paths) as 400 and deadlocks as 409,
   where PostgREST answers 500; a smoke assertion passed locally that would fail on Supabase. The mapping
   now mirrors PostgREST v12.2.3 case for case (the page is unaffected: it reads the message).

**Minor, fixed in the same pass:** the local page server binds 127.0.0.1; the court panel's Cancel is
two-tap armed and the inbox's `alert()` is gone (no native dialog remains, so the v1.3.0 sentence is
true); the bell closes an open sheet first; `#inbox-btn` / `#friends-btn` carry their counts in
`aria-label`; the polling tooltip names both cadences; the court-panel account copy shortened; the
provisioner's hand-applied message derives its range from the folder; the backend README points at the
Keep-this-account row; two-browsers step 3 compares the uncapped `recent_report_count` (it could pass
vacuously at five reports); a result or vote entered from the inbox opens Mine so its flash is seen;
Mine offers Cancel beside Enter result; a dead share link reads in `#auth-notice`; `signOut({ scope:
'local' })`; a result with unassigned roster players warns once before saving.

**Recorded, not changed:** `pickups.share_token` (and `organiser_id`, `mvp_id`) travel in the realtime
stream to anonymous subscribers, as they already did through the `anon` table grant in 0002. Ruling in
`docs/project-conventions.md`: the token is a convenience, not a secret; a column-level grant can hide it
later. **Owner's call:** whether the not-found paths (`P0002` in 0001–0003) should be re-raised with a
code Supabase logs as a 4xx (a new migration), and whether the provisioner should probe each object
before re-applying an unrecorded file after a half-recorded run.

**Independent re-run after the fixes:** GATE PASSED, 182 assertions; offline check 20 pins; fake-backend
check `errors: []` with the new inbox-visibility, bell-over-sheet and two-tap-Cancel assertions;
provisioner 40; stand-in smoke 44; two browsers 16/16 across two runs. The lead re-checked syntax and the
plain gate before committing.

## Follow-ups

**Owner (unblocks the live product):**
1. Store a Supabase personal access token as the environment secret `SUPABASE_ACCESS_TOKEN` (environment
   settings → Network secrets / environment variables; never in chat), then in a new session:
   `scripts/provision-supabase.sh --dry-run`, `scripts/provision-supabase.sh`, `--check`. Or run the same
   three commands on your own machine; the only output to keep is the database password line.
2. Then the proof against the real project: `python3 -m http.server 8000` and
   `OC_SUPABASE_URL=… OC_SUPABASE_ANON_KEY=… node test/e2e/two-browsers.cjs` (both values are the public
   ones now in `config.js`).
3. Link billing on the Google Cloud project that owns the Maps key (the referrers and the API restriction
   are right; the dialog persists without an auth failure and on localhost too).
4. Merge PR #1 when the pins fix is wanted; v1.3.0 rides the same branch.
5. Decide which host is production: GitHub Pages (the docs' assumption) or Cloudflare Pages
   (`opencourt.pages.dev`, which builds every branch).

**Next passes:** M4 part two (push via an edge function, share cards, "I'm here, need a 4th"); set
scores on closed pickups and an editable skill in the You sheet; the README/SETUP placeholder URLs; a Pages
`_site/` artifact so `test/`, `working/` and `supabase/` stop being served; the visible rename.

## Outcomes

- `c70b7c7` — v1.3.0 build: M3 screens, M4 part one, the provisioner, the local stand-in and the
  two-browser proof, the three lead fixes, the docs. Gate at that commit: GATE PASSED, 182 assertions;
  two-browsers 8/8 ×3.
- The commit after it — the review panel's fixes (the clipped inbox and the stand-in's status mapping,
  plus twelve minors), the share-token ruling, this section. Gate re-run green by an independent worker
  and by the lead.
- PR #1 (`shwinster101/OpenCourt`) carries both; its Cloudflare Pages check is green and the branch
  preview is `claude-pickup-opencourt-migr.opencourt.pages.dev`.
- What the plan got wrong, kept beside the text: the M4 worker numbered its migration 0006 (the lead's
  brief had reserved 0005 for an M3 migration that proved unnecessary); the two-browser step 8 was
  intermittent because the deep-link highlight was consumed by the first render; the lead's own v1.2.0
  note tripped the gate he had just tightened; the phone-width header fix clipped the inbox until the
  review caught it.
