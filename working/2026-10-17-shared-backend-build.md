# 2026-10-17 — The shared backend build: M1–M3 as SQL under RLS, proven; the page wired (v1.2.0)

## Request (owner, verbatim)

> "Runthe long term solution build. I'll work on the cloud console key."

The "long term solution" is the one the previous pass ended on (`working/2026-10-17-pickup-opencourt-review.md`
§Outcomes): build migration steps M1 (shared courts and reports on Supabase) and M2 (identity and pickups
on courts under row-level security, clock-driven starts) per `docs/MIGRATION.md`, with the 2021 pytest
flows ported as the acceptance tests. The owner took the Google Maps key / Cloud Console work (M0.5's
first item) themselves; nothing here touches the key.

## What materially changed since the previous pass

- v1.1.0 shipped the documents (foundation, legacy record, migration plan) and changed no code.
- This pass ships the backend itself (`supabase/`), its test leg (`test/backend/`), the page's wiring
  to it (`assets/js/backend.js`, `config.js`, a rewritten `app.js`, `index.html`, `styles.css`), and
  the gate's two new steps. No Supabase project exists yet, so nothing is live: the page on `main`
  would run exactly as before plus the restored pins and the honest "Offline data" badge.

## The issue and its root cause

- **Issue:** PickUp's people flow (friends, pickups on courts, invitations, results, MVP, inbox) has
  no working backend anywhere. The 2021 one is dead (Heroku 404) and was unsafe by design (a
  client-set `X-Hasura-User-Id`, no permissions); OpenCourt has courts but no shared store, so even
  its crowd reports stay on one device.
- **Root cause:** the two products were each half-modelled. 2021 had people and events but no
  trustworthy actor and no real venue; 2026 has venues but no actor at all. The join "a pickup
  happens at a court, organised by a player the database can name" existed in neither codebase, and
  no rule in either was enforced by anything a test could check.
- **The move:** put every rule in SQL where `auth.uid()` is the only actor, generate the venue rows
  from the court catalogue already in the repository, and prove the lot on a throwaway PostgreSQL
  before any project is provisioned — so the first live deploy is a configuration step, not a build.

## Assumptions recorded for the owner (each is a ruling in `docs/project-conventions.md`; correct there)

| # | Assumption | Where it bites | How to change it |
|---|---|---|---|
| A1 | A profile (display name + username, skill optional) on an **anonymous** Supabase session is enough to create or join a pickup. MIGRATION §3 had said non-anonymous only. | `require_profile()` in `0002` | tighten that one function |
| A2 | **Capacity counts the organiser** (capacity 4 = doubles including the person who set it up). | `join_pickup`, `create_pickup` | one comparison in `join_pickup` |
| A3 | **One report window, 90 minutes**, on the page and in `courts_live`; the SRS's "~2 h" (FR-25) is superseded. Rate limit: one report per court per session per 15 min. | `0001`, `REPORT_TTL_MINUTES` | one interval literal each side |
| A4 | **The clock is the database's**: `pg_cron` runs `start_due_pickups()` every minute, `finalize_due_mvp_votes()` every 15, `expire_stale_pickups()` hourly. Votes close 24 h after the result; a never-closed game expires after 24 h and never counts. | `0004`, `0003` | the cron lines / the intervals |
| A5 | **Standing is provisional**: 2 points per win, 3 per MVP, computed in the `player_standing` view, never stored. | `0003` | the view |
| A6 | Sports enum starts as `tennis`, `pickleball`, `basketball` (OpenCourt's two plus 2021's one real sport); extend by migration (FR-81). | `0001` | `alter type … add value` |
| A7 | `report_status` is `open · toss · full` ("toss" is what the UI calls Mixed) so the view and the page share one vocabulary. | `0001`, `app.js` | — |
| A8 | Notifications are written **inside the RPC transaction** by `notify()`, not by table triggers: same guarantee, one request. | `0002` | — |
| A9 | Markers draw through the page's own `OverlayView` unless `GOOGLE_MAP_ID` is configured (Advanced Markers then). The JSON map style stays. | `app.js` | set the Map ID in `config.js` |
| A10 | M3 (friends, results, MVP) ships as SQL with tests but **no screens** this release; M2's screens (pickups, inbox) ship now. | — | the next pass |

## 1. What was built

### 1.1 The backend (`supabase/`, no server code)

| File | Step | Contents |
|---|---|---|
| `migrations/0001_courts_and_reports.sql` | M1 | enums `sport`, `court_tier`, `demand_tier`, `report_status`; `courts` (columns = `courts.json` fields, `metro` on every row); `court_reports` (`reporter_id default auth.uid()`); RLS: courts readable by all, reports readable by their author only; view `courts_live` (last 5 reports within 90 min, `last_reported_availability`, `recent_report_count`); `submit_report(court, status)` security definer: `auth_required`, `unknown_court`, `private_court`, `rate_limited` |
| `migrations/0002_identity_and_pickups.sql` | M2 | `set_updated_at()`; `profiles` (username `^[a-z0-9_]{3,20}$`, skill 1–5, `is_anonymous`, generated `search` tsvector); enums `pickup_status`, `attendee_status`, `notification_kind`; `pickups` (court, organiser, sport, `starts_at`/`ends_at`, capacity 2–30, note ≤ 280, `share_token`, result fields), `pickup_attendees`, `notifications`, `event_log`; helpers `require_profile`, `log_event`, `notify`, `joined_count`; RPCs `upsert_profile`, `create_pickup`, `join_pickup` (capacity under `for update`), `leave_pickup`, `cancel_pickup`, `invite_to_pickup`, `cancel_invitation`, `respond_to_invitation`, `start_due_pickups` (service role only), `mark_notifications_read`; views `open_pickups` (anon + authenticated), `my_pickups`, `my_notifications` (`security_invoker`); `pickup_by_token`, `pickup_roster`; `courts_live` gains `open_pickup_count` |
| `migrations/0003_friends_results_mvp.sql` | M3 | `friendships` (directed edges: one = pending, both = friends), `are_friends`, `friend_status`, `send_friend_request` (returns `pending_out` or `friends` when it completes a pair), `accept_` / `reject_` / `cancel_friend_request`, `remove_friend`, `my_friends()`, `incoming_friend_requests()`, `search_players(text)` (parameterised; 2021 interpolated the string into SQL); `pickup_teams`, `record_result(pickup, team1[], team2[], scores, winner)` (organiser only, members must be attendees, team membership recorded — 2021 dropped it); `mvp_votes`, `vote_mvp` (one vote, not self, attendees only; the vote that completes the roster finalises), `finalize_mvp` (ties random among the leaders), `finalize_due_mvp_votes()`, `expire_stale_pickups()`; view `player_standing` |
| `migrations/0004_schedules.sql` | — | a `DO` block: schedules the three jobs if `pg_cron` is installed, else prints a notice naming what to run externally |
| `seed.sql` | — | the 20 courts, generated by `scripts/export-courts-seed.mjs` from `assets/data/courts.json` (`on conflict (id) do update`; the gate fails when it is stale) |
| `README.md` | — | the owner's provisioning steps (project, anonymous sign-ins, `pg_cron`, migrations, seed, `config.js`), the "keeping it honest" rules, the anonymous → email upgrade path |

Grants are explicit everywhere because Supabase's default privileges hand `anon` and `authenticated`
every right on a new table; each table starts with `revoke all` and gets back only what a view or
policy needs. `anon` can read `courts`, `courts_live`, `open_pickups` and a shared link's pickup, and
nothing else; no role but the functions' definer can insert into any table.

### 1.2 The test leg (`test/backend/`)

- `shim.sql`: what Supabase provides and a plain PostgreSQL does not — the three roles and their
  default privileges, `auth.users`, `auth.uid()/jwt()/role()` reading `request.jwt.claims`, and a
  `test` schema (`login(uid, anonymous)`, `anon()`, `admin()`, `check(bool, what)`,
  `expect_error(sql, error, what)`).
- `run.sh`: finds the PostgreSQL binaries (`PGBIN` or `/usr/lib/postgresql/*/bin`), runs `initdb` in a
  temp dir (as an unprivileged user when invoked as root, because `initdb` refuses root), applies the
  shim, every migration in order and the seed, runs each `t_*.sql`, and prints `BACKEND TESTS PASSED (N
  assertions)`. Skips with a message when no server is installed; `REQUIRE_BACKEND=1` turns the skip into
  a failure.
- `t_010_courts_reports.sql` (25): seed shape, anon reads, anon cannot write, `submit_report` on a
  public and a private court, the 15-minute limit, the 90-minute decay, two reporters, own-report
  visibility only.
- `t_020_identity_pickups.sql` (71): profiles and username rules; create → invite → respond → join →
  leave → cancel, the inbox each step writes, capacity at the boundary under concurrent-shaped calls,
  `start_due_pickups` moving only due rows, the share token path for `anon`, and the **cross-user refusal
  matrix** (a non-organiser cannot cancel, invite or read another's inbox; a non-invitee cannot respond).
- `t_030_friends_results_mvp.sql` (71): the 2021 pytest flows ported — request/accept/reject/cancel/
  remove, `friend_status` from both sides, search escaping; results with team membership, the one-vote
  and no-self-vote rules, early finalisation when every attendee has voted, the 24 h deadline, the
  tie-break staying among the leaders, standing, and expiry of a never-closed game.

### 1.3 The page

- `assets/js/config.js`: `window.OPENCOURT_CONFIG = { SUPABASE_URL, SUPABASE_ANON_KEY, GOOGLE_MAP_ID, METRO }`,
  empty by default. Public values only.
- `assets/js/backend.js`: `window.Backend` over the pinned `supabase-js@2.45.4` UMD: `enabled`,
  anonymous `ensureSession`, `signInWithEmail` / `linkEmail` / `signOut`, `fetchCourts` (`courts_live`),
  `submitReport`, `myProfile` / `upsertProfile`, `listPickups` / `myPickups` / `createPickup` / `joinPickup`
  / `leavePickup` / `cancelPickup` / `respondToInvitation` / `pickupByToken` / `roster`, `notifications` /
  `markRead`. SQL error names map to one human sentence each.
- `assets/js/app.js`: backend-first `fetchCourts` with the JSON as fallback and `state.dataSource`
  rendered into `#data-source` ("Shared data" · "Offline data · reports stay on this device" · "Backend
  unreachable …"); `submitReport` returns whether the report was shared and words its feedback
  accordingly; every court field passes `esc()` before `innerHTML`; markers via `OverlayView` (Advanced
  Markers only when a Map ID is set), a `has-game` ring when a court has an open pickup; the court panel
  lists pickups with Join / Leave / Cancel / Accept / Decline / Share, a one-time name prompt
  (`withProfile`), a create form; an inbox button with an unread count, polled while the tab is open;
  `#pickup=<token>` opens a shared pickup on load; a 5-minute re-read while live.
- `index.html`: the inbox button and panel, the data-source line, the version badge `v1.2.0`, scripts in
  the order `config.js` → `supabase-js` (defer) → `backend.js` → `app.js`.
- `assets/css/styles.css`: one appended block (badge, pickups, forms, inbox, `has-game`, reduced motion).

### 1.4 The gate (`scripts/check.sh`)

- Step 3 (secret-shaped strings) now flags private keys, service-account files, `service_role_key` /
  `SERVICE_ROLE` / `SUPABASE_SERVICE` names, payment and GitHub tokens, **and any JWT whose decoded
  payload has `role = service_role`**. The bare role name `service_role` is legitimate SQL (the
  migrations grant to it; the shim creates it) and no longer trips the gate; the anon key, also a JWT,
  passes. Checked with three probes: an anon-role JWT passes, a service-role JWT fails, a
  `SUPABASE_SERVICE_ROLE_KEY=` line fails.
- Step 4: `supabase/seed.sql` must equal the export of `courts.json`.
- `--backend` appends the test leg.

## 2. Verification (what ran here)

| Check | Result |
|---|---|
| `sh scripts/check.sh` | GATE PASSED (JSON ×2, JS ×3, no secret-shaped strings, seed current) |
| `sh scripts/check.sh --backend` on PostgreSQL 16.x (`/usr/lib/postgresql/16/bin`, no `pg_cron`) | `BACKEND TESTS PASSED (167 assertions)`: 25 + 71 + 71; `0004` printed its "schedule externally" notice as designed |
| Headless Chromium, offline mode (`config.js` empty), local `http.server` | 20 pins drawn, 0 script errors, badge "Offline data · reports stay on this device", a report persists in `localStorage` and says "saved on this device" |
| Headless Chromium, fake `supabase-js` injected (mirrors the views' shapes) | badge "Shared data"; `#pickup=<token>` opens the shared pickup; first Join prompts for a name then joins; Create posts the form; a report calls `submit_report`; the inbox lists and marks read |
| Secret-pattern probes (see §1.4) | pass / fail / fail as intended |

**Not run / not verified:** a real Supabase project (none exists); `pg_cron` scheduling on Supabase (the
`DO` block path is exercised only on the "absent" branch here); the Pages deploy of the new files (the
workflow uploads the whole checkout, so no file is left out, but it was not triggered); a phone; the
email upgrade path (`linkEmail` has no UI yet); the Maps key, which is the owner's console work.

## 3. Deviations from `docs/MIGRATION.md`, and corrections to earlier text

- §3 "pickups require a non-anonymous account" → relaxed (A1). Reason: the SRS's FR-51 "lightweight
  identity" and a first visit that should cost nothing. Reversible in one function.
- The plan's notification table triggers → `notify()` inside each RPC (A8).
- M3 landed in the same release as M2 (SQL only) because the test harness made it cheap; the plan had
  it a step later. Its screens are the next pass.
- The previous note's finding "no court pins on the live page" is **fixed in code** here (A9) but will
  not be visible on the live site until this branch merges; the Google "can't load Maps correctly"
  dialog is unchanged and is the owner's console item.
- Test-writing corrections kept for the record: under RLS a second user's `friendships` count is 0 (the
  first draft asserted 1); the recipients of a `vote_mvp` notification must be counted as the admin role,
  since RLS hides other recipients' rows from a player.

## 4. Follow-ups

**Owner (unblocks the live backend):**
1. Provision the project per `supabase/README.md` (anonymous sign-ins on, `pg_cron` on, migrations
   0001–0004, seed), then put the URL and anon key in `assets/js/config.js` and merge the branch.
2. The Maps key / Cloud Console check (in progress per the owner), and optionally a Map ID in
   `config.js` to switch to Advanced Markers.
3. Install the Claude GitHub App on `PickUpBois` so the legacy repos' `CLAUDE.md` / `AGENTS.md` /
   `README.md` can land (their staged copies remain in `docs/legacy-repo-docs/`).
4. Disable the 2021 Google service account in Google Cloud (unchanged from v1.1.0).

**Next passes:**
- M3 screens: friends list, requests, search; enter a result; vote MVP; standing on the profile.
- M4: realtime on `open_pickups`/`my_notifications` instead of polling; the email upgrade UI; push via
  an edge function (the first place a secret would live).
- Housekeeping: the README/SETUP placeholder URLs; a Pages `_site/` artifact so `test/`, `working/`
  and `supabase/` stop being served; the visible rename once the owner picks the wording.

## Outcomes

- Build commit: recorded in the follow-up commit below once the SHA exists.
- Previous pass: `2af6967` (v1.1.0), `253b1f2` (its verification record).
