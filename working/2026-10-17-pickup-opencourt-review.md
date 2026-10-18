# 2026-10-17 — The four-repo review, Arian's commits, and PickUp's foundation (v1.1.0)

## Request (owner, verbatim)

> Run a thorough review of each repo, and especially read commits run by Arian. I want pickup's issue
> and goal stated, vision, mission statement, and requirements/user stories and workflow as our
> fundamental requirements and agent md
>
> Opencourt is the modern successor- though keeping the pickup namesake and logo will be the path
> forward migration of pickup backend flow to the opencourt structure and working apis

**Interpretations, recorded as assumptions for the owner to correct:**

1. "Each repo" = the four in this session: `shwinster101/MacroDash`, `PickUpBois/PickUp`,
   `PickUpBois/PickUpHasura`, `shwinster101/OpenCourt`. MacroDash is unrelated to PickUp; it was read
   as the exemplar of how the owner wants agent docs written, and health-checked, but not changed.
2. "Agent md" = a `CLAUDE.md` + thin `AGENTS.md` pair in the MacroDash style, canonical in
   OpenCourt, with frozen-legacy pointers in the two PickUp repos.
3. "Fundamental requirements" = one document (`docs/FOUNDATION.md`) carrying issue, goal, vision,
   mission, personas, user stories, workflow and FR/DR/NFR tables that continue the SRS numbering.
4. "Working APIs" = the backend the SRS already chose (Supabase Postgres + PostgREST + RLS); the
   plan is written for it and notes the owner's Cloudflare stack as the one alternative worth a call.
5. The visible rename of the page (header still "OpenCourt LA") is the owner's wording to choose;
   the assets and the ruling were landed, the UI was not changed.
6. No code or deploy change was in scope for this pass beyond a gate script; the migration itself
   starts at M1.

**Baseline:** OpenCourt `main` 07d5315 (v1.0.1); PickUp `main` 496b914e; PickUpHasura `main` 4244d6d;
MacroDash `main` 73379fb (v8.51.0). All four designated branches `claude/pickup-opencourt-migration-rbgxlp`
existed on origin at parity with `main`; nothing was pushed to them before this pass.

## Method

- Scouted all four repositories by hand (tree, authors, branch state, remotes, secrets presence,
  logo asset history), then read the primary sources of the people flow directly: every Hasura
  action handler, the event plumbing, every migration that defines the final schema, the table
  metadata, the pytest flows, the iOS service layer, models and GraphQL operations, OpenCourt's
  `app.js` report/scoring/boot paths and all of its docs.
- Launched a six-reader workflow (backend, iOS, Arian history, OpenCourt, product intent, MacroDash
  conventions) with adversarial verification of each material finding. **The first run died on the
  session's usage limit** after ~13 minutes; the backend and iOS readers had already written their
  reports (53 KB and 28 KB) but not their structured findings, so no verification ran. The four
  other readers were relaunched after the limit reset; their results are recorded in §8 as they
  landed. Where a reader's claim and my own reading disagreed, the code was re-read and the result
  recorded below.
- Checked the 2021 production host (`https://pickuphasura.herokuapp.com`): HTTP 404 on `/healthz`
  and `/v1/version` — the backend is gone.
- Loaded GitHub for the 20 closed PickUp pull requests (2021-04-05 → 06-22), the repos'
  visibility (**both PickUp repos are public**), and the absence of issues on any of the three
  product repos. `PickUpBois/oldVersion` (2021-03-15) is an empty repository.

## 1. What each repository is (facts)

| Repo | What | Commits / authors | State |
|---|---|---|---|
| PickUp | SwiftUI iOS app, iOS 14, Apollo codegen + hand client, Firebase Auth/Storage/Messaging, 111 views | 80: Arian Rahbar 47, David Reynolds 30, Ashwin 3; history begins 2021-06-15 (`8c34855f`, a squash), ends 2021-11-06 | frozen; `Pods/` and `xcuserdata` tracked; unit test target does not compile |
| PickUpHasura | Hasura v2.0.4 + 51 migrations (Postgres 12/PostGIS), Express/TS with 19 actions, Firebase emulator, pytest flows, docker-compose | 9, all Arian, 2021-07-18 → 2021-11-06 | frozen; **public; service-account key and `.env` committed** |
| OpenCourt | No-build HTML/CSS/JS court finder for LA tennis/pickleball; 20 courts; heuristic availability; localStorage reports; Grand Slam theming; SRS + roadmap | 4, Ashwin, 2026-09-15 → 09-16 | live on Pages; Phase 2 Supabase scoped, not provisioned |
| MacroDash | Macro dashboard + ticker terminal on Cloudflare Pages (unrelated) | 129 reachable (shallow), v8.51.0 | the owner's documentation exemplar; not changed |

## 2. Arian's commits — the backend narrative

Sources: `git log --author=Arian` in both repos (47 + 9), `git show --stat` on each, diffs on the
substantive ones, the 20 closed PR titles on GitHub, the two unmerged branches.

**Phase 0 (April–June 2021, survives only as PR titles and the squash commit).** PR #1–2
"Backend auth" (Apr 5–6) → #3–5 "UI" (Apr 8–13, "splash screen, error handling, and email
verification") → #6 "Profile UI" (Apr 27) → #7–10 "Backend profile events" / "creating events, added
apollo graphql client, profile changes" (May 13–17) → #11–12 "Backend profile notifications" (May 21)
→ #16 "Notifications UI backend" (May 28) → #17 "Popups/Busyness/Profile" (Jun 9) → #18–19 "Backend
loading UI", "Profile pictures" (Jun 21) → #20 "Backend up" (Jun 22). Ashwin's courts-near-me screen
is dated 2021-05-12 in its file header; David's map 2021-05-21.

**Correction (from the history reader, 12:3x UTC; my first draft of this paragraph was wrong on
two points, kept here as written below the correction).** The backend was never "Firebase only": at
the root commit the app already spoke Apollo GraphQL to a custom server at
`pickupserver.herokuapp.com` / `localhost:3000` whose schema (`users`, `searchUsers`, `events`,
`userEvents`, `queryEvents`; `createUser`, `updateUser`, `removeUser`, `createEvent`, `updateEvent`,
`removeEvent`, `joinEvent`) is frozen in the root commit's `schema.json`; its source is in none of the
repositories. And `b7bb9420` (06-15) sent a **Firebase ID token** as `Authorization`, which that server
could verify; the downgrade to a bare `X-Hasura-User-Id` header came on 07-25 (`68cfbce0`), after an
abandoned branch (`origin/hasura`, 07-24) had tried `X-Hasura-Role: admin`. Hasura's console
migrations begin 2021-07-13; the app was re-pointed in three attempts (`hasura`, `hasura2` abandoned;
`hasura3` merged 08-04). `acceptEventInvitation` set `status: invited` instead of `ok` until the
09-16 commit fixed it; `functions.yaml` was dropped from `databases.yaml` on 08-04 and restored 09-16,
so `search_users`/`end_event` were untracked in that window.

*Original text:* **Phase 1 — wiring the client to a backend (2021-06-15 → 06-26).** `b7bb9420` adds
the Apollo `AuthenticationInterceptor` that sends the Firebase UID as `X-Hasura-User-Id` (the identity
model the whole system then rests on). `5a7a3354` Firebase Messaging + profile pictures (Storage).
`cd12045f` notifications: `PickUpAppDelegate` push registration, `putDeviceToken` from the login and
sign-up view models, the notification views. `840bdf09` leave event + `EventDetailsBoxViewModel`;
`f2f508ce`/`4d94b8b0` invitations (`InviteFriendsView`, `EditPickupListView`), `DeletedEventNotificationView`;
`9df7b1c7` `JoinedEventNotificationView` and layout; `b3b6a48b` search loading. Seven commits titled
"changed to online"/"changed to local" flip the backend host — the origin of the later
`ENV`/`DEV_HOST`/`PROD_HOST` build settings. Merges titled "merge david" fold David's UI branches
(`lollipop`, `more-ui`) in.

**Phase 2 — the Hasura backend repo (2021-07-18 → 08-04).** `7c5152f` "initial code": Hasura
metadata, first migrations, Express handlers. `9b00c3c` "added tests and finished most methods":
pytest flows, `/events/startEvent`, the squashed init migration. The migration log shows the design
being worked out live: `end_event` rewritten ~15 times (int[] → jsonb scores; the first version
closed every event for want of a `WHERE`), `search_users` 10 times (ending in string-built SQL),
`get_friends` 4 times, the `notifications` UNION function replaced by a table (`1627354302627`).
`a8dc776` "stable, needs push notifications" (Aug 3): the domain-event outbox + Hasura event trigger +
Node `EventEmitter`, notification writers, `node-schedule` start timers, jest. `f72085e` "curr
metadata" (Aug 4): firebase-admin and **`firebase_key.json` committed**. Same day on the client:
`3456e839` "fixed compilation errors" (−4,083 lines: the old `API.swift`/`schema.json` removed, every
view model re-pointed at the Hasura operations), `c9ba4ffe` "stable" (`GraphQLClient.swift`,
`EventModel`, `UserModel`, `URLSession` extension — the hand-written client beside Apollo), `e3dc81ca`
"Merge branch 'hasura3' update to hasura".

**Phase 3 — tail (2021-09-16, 11-06).** `3b185f1` "changes": cleanup across all 19 handlers
(error returns, `getClient()` factory), removed `convert.py` and debug logs. `4244d6d` "fixed
hasura": `hasura/config.yaml` → the Heroku endpoint, `CREATE EXTENSION postgis` prepended to the init
migration, `DROP FUNCTION` added to the `end_event` down migrations. `496b914e` "various fixes": two
GraphQL files (fragment field renames). Unmerged: `origin/hasura` (`6f394627` "initial bug fixes")
and `origin/hasura2` (`f733ddd3` "changed some graphql files"), both superseded by `hasura3`.

**Design decisions visible in the record (with the evidence):**

| Decision | Evidence | Reading |
|---|---|---|
| Firebase for auth/storage/push, Postgres for everything else, Hasura to skip writing a CRUD API | `Services.swift`, `docker-compose.yml`, `actions.graphql` | the actions exist only where a rule or a multi-row write was needed |
| Identity = Firebase UID in a header | `AuthenticationInterceptor.swift`, no permissions in metadata, no admin secret | a dev shortcut that became the production model |
| An outbox (`domain_events`) + event trigger + in-process emitter | `public_domain_events.yaml`, `events/*.ts` | side effects decoupled from the write; but the webhook answers 500 and retries are 0 |
| Notifications as rows, read by the client | `notificationHandler.ts`, `HomeViewModel.graphql` | push was the next step, never taken |
| Scores as jsonb unpacked through a remote schema | `event_teams` yaml `info`, `schema.graphql` | a workaround for Hasura's array handling in 2021 |
| Hand-written `GraphQLClient` beside Apollo | `c9ba4ffe` | faster iteration on new queries than codegen allowed |

## 3. PickUp iOS — what the app did (condensed from the reader's 111-view inventory)

Live against the backend: `ContentView`/`MainView` (5 tabs), `LoginView`, `SignUpView`,
`EventDetailsBoxView` (join/leave/delete), `EventAttendeesView`, `CreateEventView`/`CreateSportEventView`
(create), `EditPickupListView`, `InviteFriendsView`, `NotificationListView` and nine typed notification
views, `InputScoreView`/`TeamatePickerView` (end event), `FinishPickupView` (vote MVP), `ProfileView`,
`ProfilePicture`/`ImagePicker`, `UpcomingPickupsView`, `PastPickupView`, `ProfileSettingsView`
(logout), `FindTeammatesView`, `FriendsListView`, `NearMeView`/`PickUpTabListView`/`PickUpListView`
(upcoming events), `MapMainView` (Apple Maps search only).

Static, placeholder or dead: `HomeView`/`PrivateView`/`PostedPickUpsView` (three hard-coded posts),
`CreatePostView`, `TagFriendsView`, `AttachPickupView`, `Social/*`, `MessageView`/`ChatView` (seven
hard-coded chats), `CourtsNearMeView` ("BusyBars", ten hard-coded places — the owner's own 2021
screen), `BusynessView`, `PreferencesView`, `EventLocationPickerView` (typed, never sent),
`UpdateProfileView` (unreachable), `ForgotPasswordView` (calls login), `PopOverView` message/block/report,
`OnevOneView`, `PastScoresView`, `EditedPickupNotificationView`, `PostNotificationView`, `ModalHalfView`
(would not compile), `PostViewModel` (would not compile), `views/Busyness/` (duplicate of
`views/busyness/`), `CourtsNearMeFullView 2.swift`.

Forty user stories were derived with status; they are folded, with OpenCourt's own, into
`docs/FOUNDATION.md` §5. Defects worth carrying as requirements rather than bugs: sport hard-coded to
tennis, location never sent, capacity never enforced, self-vote and repeat votes allowed, date
picker pinned to 2021, logout leaves the device token, sign-up ignores the action status.

## 4. PickUpHasura — findings (each re-read in source after the reader's report)

| # | Finding | Severity | Status | Evidence |
|---|---|---|---|---|
| B1 | Any client can act as any user and read/write any table: identity is a client-set header; no permissions, no admin secret, no JWT. | critical (2021) / design input (2026) | confirmed | `AuthenticationInterceptor.swift:26`; no `*_permissions` in any table yaml; `docker-compose.yml` secret commented out |
| B2 | A Google service-account private key and `.env` credentials are committed to a **public** repository. | critical | confirmed | `firebase_key.json` (since `f72085e`), `.env`, `express-server/.env`, `tests/.env`; `list_repos` visibility public |
| B3 | `search_users` interpolates the search string into SQL via `FORMAT('%s')` inside quotes (injection). | high | confirmed | `1627260920648_search_users/up.sql` |
| B4 | `friend_status` computed field is always false for real friendships (variable/column name collision in PL/pgSQL). | medium | confirmed by reading; not executed | `1627255789123_friend_status/up.sql` |
| B5 | `voteForMvp` never awaits its attendee check; no one-vote, not-self, or event-closed rule. | medium | confirmed | `voteForMvp.ts:11` |
| B6 | MVP tie-break indexes the full attendee list, not the leaders. | medium | confirmed | `eventHandler.ts:26-38` |
| B7 | `deleteEvent` does not cancel the start timer (`job[jobId].cancel()` on a Job). | medium | confirmed | `eventHandler.ts:40-47` |
| B8 | `end_event` discards team membership; `team_id` never set; no `RETURN QUERY`. | medium | confirmed | `1627598022100_end_event/up.sql` |
| B9 | Capacity never enforced; inviter/canceller not checked; `markNotificationAsRead` has no ownership check. | medium | confirmed | `joinEvent.ts`, `inviteUserToEvent.ts`, `cancelEventInvitation.ts`, `markNotificationAsRead.ts` |
| B10 | Push notifications never sent (`sendNotification` has no callers). | info | confirmed | `models/notification.ts`; grep |
| B11 | Domain-event webhook always answers 500; retries 0, so it works once by accident. | low | confirmed | `events/domainEvent.ts:11`, `public_domain_events.yaml` |
| B12 | Start timers live in one process; events whose start passed during downtime never start. | medium | confirmed by reading | `eventHandler.ts:49-58`, `index.ts:34` |
| B13 | pytest `test_end_event` cannot pass as committed (flat args vs `input:`). | low | confirmed | `tests/src/tests/mutations.py:57-64`, `actions.graphql:44-47` |
| B14 | A clean `docker-compose up` would run `CREATE EXTENSION postgis` twice. | low | inferred, not executed | `docker-compose.yml:43`, init migration line 1 |
| B15 | Hasura "prod" configuration is not in the repo; whether Heroku ever had an admin secret is not found; the client could not have worked against a secured engine. | info | not found | `hasura/config.yaml` |
| B16 | `set_fk_*` migrations made `events.mvp_id/status/winner_id` and `event_teams.event_id` cascade on delete, so deleting a user deletes the events they were MVP of (and deleting an enum row deletes events). | medium | confirmed | `1627000935907..1627000983778_set_fk_*/up.sql` |
| B17 | `createEvent` inserts `EVENT_CREATED` in a second request with no error handling; if it fails the event never gets its start job. | low | confirmed | `createEvent.ts:58-69` |
| B18 | The hand-written iOS `GraphQLClient` is dead code (no caller of `Services.shared.client`); Apollo is the only transport. | info | confirmed | `Services.swift:88`, grep |

## 5. OpenCourt — review of the baseline (v1.0.1)

From my own reading of `app.js`, `index.html`, the docs and the git log; the reader's findings are
appended in §8 when they land.

- **Architecture:** `boot()` → `fetchCourts()`/`fetchSlams()` → `hydrateReportsIntoCourts()` →
  `applyTheme()` → `renderAll()` every 10 min (FR-24 ✓); `submitReport()` keeps the last 5 reports
  per court (FR-31 ✓); `REPORT_TTL_MINUTES = 90` (FR-32 ✓); reports are per browser
  (`localStorage['opencourt-la-reports-v1']`). Extension points are exactly the three functions the
  code comments name.
- **Maps key:** committed in `index.html:153` by `2bd4fb0`/`07d5315`, whose messages say
  referrer-restricted; the SRS still lists NFR-04 as ⬜ blocker and ROADMAP "still open" — **doc rot
  relative to the commit** (or the restriction is unverified; the console was not checked here).
- **Docs vs repo:** README's live link is a `YOUR_USERNAME.github.io/opencourt-la` placeholder and
  the tree is drawn as `opencourt-la/`; the repository is `shwinster101/OpenCourt`. The Pages
  workflow uploads the whole repository (`path: '.'`), so `docs/`, `push-to-github.sh` and now
  `working/` are published too — acceptable for an open project, worth knowing.
- **Small code notes:** `else renderList(), renderStats();` uses the comma operator (works, reads
  oddly); the 5-second key-warning timer fires on slow networks as well as on a missing key; the
  theme calendar is 2026-only (known issue in ROADMAP).
- **Gap to the people flow:** no identity, no backend, no `pickups`; Phase 3 in the roadmap is the
  2021 flow by another name. Mapping in `docs/MIGRATION.md` §2.

**The OpenCourt reader's findings (landed 12:21 UTC; each checked against the cited lines):**

| # | Finding | Severity | Status |
|---|---|---|---|
| O1 | `new google.maps.Map` is created with a JSON `styles` array and **no `mapId`**, while `&libraries=marker` guarantees the `AdvancedMarkerElement` branch; Google documents that Advanced Markers need a Map ID (and that a Map ID disables JSON `styles`). **Confirmed in headless Chromium (§9): the map and its tiles render, the list shows all 20 courts, the console logs "The map is initialized without a valid Map ID, which will prevent use of Advanced Markers" twenty times, and the DOM holds 0 `.gm-pin` / 0 `gmp-advanced-marker` elements — no court pins on the map.** The fix is either a Map ID (and the editorial JSON style moves to a cloud style) or forcing the existing `OverlayView` branch (keeps the style; two lines in `createMarker`). Not applied in this pass; first item of M0.5. | high | **confirmed** (browser) |
| O2 | A real browser key is committed (`index.html:153`, 39 chars); its restriction is asserted only by a commit title; the SRS (NFR-04 ⬜ blocker), ROADMAP, README, SETUP and the in-page banner all still describe the key as missing. **Browser evidence (§9):** an unlisted origin is refused (`RefererNotAllowedMapError`), so a referrer restriction exists; but the production origin itself shows Google's "can't load Google Maps correctly" dialog, so the key's referrer pattern, API restriction or billing does not match the live URL `https://shwinster101.github.io/OpenCourt/` (the docs' placeholder is `…/opencourt-la/`, a likely candidate). Owner's console check needed. | high | confirmed (dialog on live); cause not determinable here |
| O3 | Report feedback copy claims "live for the next 90 min **for anyone using OpenCourt**" and "by a player on the ground" while reports are per-browser `localStorage` — contradicts FR-23 and the brief's own honesty principle. | medium | confirmed |
| O4 | Court fields are interpolated into `innerHTML` unescaped (`app.js:327-356, 427-491`); harmless with curated JSON, a hole the moment user text arrives. | medium | confirmed |
| O5 | On phones the detail panel (≈550–600 px) can exceed the 40 vh map it is anchored in, hiding its header and × behind the app header. | medium | inferred from CSS, not rendered |
| O6 | The Pages workflow uploads the whole checkout (`path: '.'`): `docs/`, the push script, and from now on `working/`, `CLAUDE.md` and the migration plan are served at the public URL. | medium | confirmed |
| O7 | Repository identity is wrong in every doc: `YOUR_USERNAME.github.io/opencourt-la`, `opencourt-la/` tree, `push-to-github.sh` defaults, the SETUP referrer example; the repo is `shwinster101/OpenCourt`. | medium | confirmed |
| O8 | `push-to-github.sh` always warns about the placeholder key (it matches the banner copy and the HTML comment), does `git add .`, and hard-codes "v1.0.1". | low | confirmed |
| O9 | Theme engine: negative "days out" in the Feb–Apr gap; `activate` leads are 30/28/21/49/126 days, not "~4 weeks"; duplicate `australian-open` id (intentional year wrap). | low | confirmed |
| O10 | The key-warning banner is never cleared once the map loads late; `gm_authFailure` is unhandled. | low | confirmed |
| O11 | No `aria-*`, `role`, `tabindex`, `:focus-visible` or `prefers-reduced-motion`; nine rules at 8–9 px; `100vh` + `overflow: hidden` clips under iOS Safari's toolbar. | low | confirmed by grep |
| O12 | Version strings disagree (README "v1.0.0" vs 1.0.1 elsewhere; ROADMAP "shipped May 2026" vs a 2026-09-15 import). README fixed in this pass ("Phase 1, shipped"); the rest recorded. | low | confirmed |
| O13 | "Frontend change is one fetch URL" is optimistic: PostgREST returns a bare array and `live_reports`/`last_reported_availability` must come from a view that returns `[]`, never `null`. Two decay horizons exist (client 90 min, FR-25 "~2 h"). | info | confirmed; MIGRATION §5 now states one 90-minute window |
| O14 | The reader proposes deferring friends in favour of deep links and a public board. The owner's ruling is to migrate the backend flow, friends included; MIGRATION keeps them and re-sequences: identity + pickups + links (M2) before friends + invitations + results (M3). | — | decision recorded |

**The product-intent reader (landed 12:20 UTC)** agrees with the foundation on every row of the
intended-vs-delivered table and adds, with evidence: the campus framing (an unused Iowa State campus
map, "State Gym", `usc.edu`, US Central timestamps); "Teammates" as the word for friends and a dropped
"Opponent" relation; a drawn-but-unbuilt attendee **score confirmation** step and an **edited-pickup
re-consent** notification; the planned `conflict` (double-booking) status; the sets-based result model
(doubles tennis was the team's mental model; `test_flows.py` always creates `tennis`, capacity 4); the
overlap sport between 2021 and 2026 being tennis only. Folded into FOUNDATION §1–2 and FR-89, FR-89b,
FR-94, FR-95.

## 6. MacroDash — health check (from the conventions reader; verified items only)

Version headline v8.51.0 matches `package.json`; every script and file CLAUDE.md names exists; CI
runs the four gates on Node 22; `.gitignore` covers env and key files; the only tracked env-like
file defines a mode flag. **Doc rot found, not fixed (not in scope):** two line-wrapped "Ball /
Street" mentions survived the v8.49.0 rename (`docs/project-conventions.md:292-293`,
`functions/api/screener/job.js:14-15`); AGENTS.md says CLAUDE.md holds "every release note" (it holds
v8.19.0+ and points to the archive) and states a "matching test change" non-negotiable that CLAUDE.md
does not; README's documentation map omits `docs/project-conventions.md` and AGENTS.md and claims CI
on every push (it runs on `main` pushes and PRs); the per-pass closing protocol sits under the "TT
macro gate" heading and a Phase-0 placeholder remains in the conventions file. `npm test` was not run
(no `node_modules`, installing was out of scope).

## 7. Decisions taken in this pass

- **Where the docs live:** OpenCourt is the forward repo; it gets the foundation, legacy record,
  migration plan, conventions, agent md and this note. The PickUp repos get `CLAUDE.md`/`AGENTS.md`
  pointers (and PickUpHasura a README) marking them frozen; PickUpHasura's `CLAUDE.md` leads with the
  credential warning.
- **Logo:** `assets/img/pickup-logo.png` is `PickUp/Assets.xcassets/logo.imageset/Logo-2.png`
  (byte-identical to `Logo.png`; `Logo-1.png` is the same bitmap); the icon is `Picture3-1024.png`.
- **Version:** OpenCourt v1.0.1 → v1.1.0 (a ruling and a foundation, no code); the SRS header
  carries the same number; CLAUDE.md's headline is the version record because there is no
  `package.json`.
- **A gate:** `scripts/check.sh` so that "run the gate" means something in a no-build repo.
- **Not done, deliberately:** no UI rename (owner's wording), no Supabase provisioning (M1), no
  changes to MacroDash, no removal of the committed credentials (revoking at the source comes
  first and only the owner can do it), no rewrite of the PickUp repos' history.

## 8. Reader reports (appended as they landed)

- `backend` (06:29 UTC): report written; structured findings lost to the limit; its claims were
  re-read and are folded into §4 and `docs/LEGACY_PICKUP_BACKEND.md` (five corrections made to my
  first draft: `friend_status` broken, the delete-timer bug, `end_event`'s empty return and no
  status check, the injection wording, the pytest `endEvent` mismatch).
- `ios` (06:27 UTC): screen inventory and 40 user stories written (§3, FOUNDATION §5); sections on
  auth flow, vocabulary, navigation, brand and code findings were not reached before the limit; those
  facts came from my own reads (`Services.swift`, `AuthenticationInterceptor.swift`, `MainView.swift`,
  `SignUpView.swift`, the colorsets).
- `conventions` (12:18 UTC): template and health check (§6). One correction to my brief: the phrase
  "define the issue" is the owner's instruction in this session, not a MacroDash line; it is recorded
  as an owner preference in `docs/project-conventions.md`, not attributed to the exemplar.
- `opencourt` (12:21 UTC): fourteen findings (§5); its gap analysis and API sketch agree with
  MIGRATION on the entity map and on PostgREST + RPC + anonymous identity; its one sequencing
  disagreement (friends deferred) is recorded as O14.
- `intent` (12:20 UTC): evidence table, candidate statements and a combined statement; folded into
  FOUNDATION §1–2 and four new requirements (above).
- `history` (12:3x UTC): a dated timeline across both repos and the unmerged branches, with twelve
  ranked findings (all of which re-appear in §4 as B1–B18) and the two corrections recorded in §2.
  Its appendix maps every Arian commit to the branch it came from.

**The adversarial verification pass** (two skeptic lenses per high finding, one per medium) ran
until the subagent limit returned at 12:3x UTC. Verdicts that completed, with my own source re-read
where the pass did not run:

| Finding | Code lens | Significance lens | Net |
|---|---|---|---|
| opencourt-1 (Advanced Markers without a Map ID) | not refuted, high | not refuted, high | **confirmed**, and independently confirmed in the browser (§9) |
| opencourt-2 (committed key; docs stale) | not refuted, high | not refuted; proposes severity low because the key is referrer-restricted | confirmed; kept high only because the live page shows Google's error dialog (§9) |
| opencourt-3 (report copy promises a shared signal) | not refuted, high | not run | confirmed |
| opencourt-4 (unescaped `innerHTML`) | not refuted, high | not run | confirmed |
| intent-1 (delivered core is a game with a result) | not refuted; tightens: the MVP vote is untested, `test_end_event` is broken, scheduler untested | not refuted; severity medium (restates the recorded baseline) | confirmed; FOUNDATION DR-14 amended in spirit: score-entry and MVP acceptance tests must be written, not ported |
| intent-2 (college friend group) | not refuted, medium: overstated | **refuted**, medium: `college` is not the only extra attribute (`goat_score`), the shipped sign-up never populates it, nothing targets a campus | **contested → softened** in FOUNDATION §1 to "plausibly, circumstantial" |
| intent-3 (tennis hard-coded) | not refuted, high | not refuted, high | confirmed |
| intent-4 (the "where" half is demo data) | not refuted (line numbers 45–54, not 25) | not refuted, medium | confirmed |
| intent-5 ("Teammates", mutual by construction) | not refuted, high | not run | confirmed |
| intent-6 (GOAT score never computed) | not refuted, high | not run | confirmed |
| conventions-9 (only the working-rhythm rules port) | not refuted, high (21 of 23 sections are MacroDash-specific) | not run | confirmed |
| history-1…12, opencourt-5…12, intent-7…12, conventions-1…8, 10–12 | not run (limit) | not run | history-1…12 and opencourt-5…7 were each re-read in source by me and stand (§4 B1–B18, §5 O5–O7); the rest are low/info and recorded as the readers stated them |

The first attempt at the whole workflow (06:16–06:29 UTC) and the verification tail (12:3x UTC)
both died on the session's subagent limit; the readers' reports survived because they were written
to files before the structured-output step.

## 9. Verification

- `sh scripts/check.sh` in OpenCourt: **GATE PASSED** (2 JSON files, 1 JS file, no secret-shaped
  strings) after excluding the script's own pattern list from the scan.
- **Headless Chromium against the local page** (Playwright 1.56, Chromium 1194; script in the
  session scratchpad, not in the repo). On `http://localhost:8765` the Maps API answered
  `RefererNotAllowedMapError` — so the committed key **is** referrer-restricted (O2's open question,
  answered: the restriction exists; whether an API restriction exists is still not verifiable from
  here). On `http://localhost:8000` (the port `docs/SETUP.md` names) the map loaded with tiles,
  `state.mapReady` and `state.dataReady` were true, 20 courts and 40 list rows rendered, the theme was
  `australian-open`, and **0 pins** were in the DOM with 20 "without a valid Map ID" console errors
  (O1 confirmed). The page's own 5-second key-warning banner did not show.
- **The live production page** (`https://shwinster101.github.io/OpenCourt/`, HTTP 200, footer
  v1.0.1, loaded through the session's egress proxy in the same headless Chromium, 20 s wait): the
  map and its tiles render, the list shows all 20 courts, **0 `.gm-pin` / 0 `gmp-advanced-marker`
  elements exist**, 20 "without a valid Map ID" errors are logged, **and Google's modal "Error — This
  page can't load Google Maps correctly. Do you own this website?" is displayed over the map**
  (screenshot kept in the session scratchpad). A `gm_authFailure` hook installed before the page
  scripts did not fire and no "Google Maps JavaScript API error: …" console line was captured on this
  origin, so the exact cause (referrer pattern, API restriction or billing on the key) could not be
  named from here; on `localhost:8765` the same dialog came with `RefererNotAllowedMapError`. Either
  way, **every visitor to the live page today sees an error dialog and no court pins.** This
  supersedes the SRS's ✅ on FR-01 for the map until fixed (FOUNDATION US-A1 reads 🔶).
- Every file path and line cited in `docs/LEGACY_PICKUP_BACKEND.md` and §4 was opened in this
  session; claims marked "inferred" were not executed (no Docker socket, no `npm install`).
- Not run: the PickUp Xcode build, the PickUpHasura stack, MacroDash's `npm run gates`.

## 10. Follow-ups for the owner

1. **Disable the 2021 service account** in the Google Cloud project behind Firebase `pickup-774f9`
   (then, optionally, remove the files from PickUpHasura's tree; history keeps them regardless).
2. **Rule on the page wording** for the PickUp name (FOUNDATION §3) and on the mission-line
   extension (FOUNDATION §2).
3. **Confirm Supabase** as the M1 backend, or say "Cloudflare" before M1 starts (MIGRATION §1).
4. Decide whether the Maps key's restriction is verified (then flip NFR-04 to ✅) or still open.

## Outcomes

- **PickUpBois/PickUp** — commit `d18380e7` (CLAUDE.md, AGENTS.md) made locally on
  `claude/pickup-opencourt-migration-rbgxlp`; **push refused** (`403`: "Claude doesn't have GitHub
  access to PickUpBois/PickUp for your organization"); the GitHub API push also answered 403
  ("Resource not accessible by integration"). The commit exists only in the session container.
- **PickUpBois/PickUpHasura** — commit made locally (CLAUDE.md, AGENTS.md, README.md); push refused
  the same way.
- **Workaround:** both repos' files are staged under `docs/legacy-repo-docs/` in this repository with
  a README saying so; delete the folder once they land in their own repos. Fix for the owner: install
  the Claude GitHub App on the `PickUpBois` organisation (or reconnect GitHub) at
  https://claude.ai/connect-github, then a session with those repos attached can push.
- **shwinster101/OpenCourt** — `2af6967` "v1.1.0: PickUp comes home …" pushed to
  `claude/pickup-opencourt-migration-rbgxlp` (new branch on origin; `main` untouched; no deploy,
  since Pages deploys only from `main`). A follow-up commit on the same branch records the
  verification verdicts above and this Outcomes section. The gate (`scripts/check.sh`) passed on
  both.
- **What shipped:** FOUNDATION, LEGACY_PICKUP_BACKEND, MIGRATION, project-conventions, CLAUDE.md,
  AGENTS.md, scripts/check.sh, the logo and icon, README/PROJECT_BRIEF/REQUIREMENTS pointers, the
  staged legacy docs, this note. **Deliberately left:** every code change (the pins fix, the honesty
  wording, the Pages artifact, the repo-URL placeholders) — all listed under M0.5 for the owner's
  call; MacroDash untouched; no credential removal (revocation first).
- **Where the survey was wrong, kept beside the original text:** §2 (the pre-Hasura custom server
  and the ID-token-then-UID-header sequence); FOUNDATION §1's campus framing (softened after the
  skeptic's refutation); LEGACY's first draft of `friend_status`, the delete-timer path, `end_event`'s
  return and the `GraphQLClient` ("a second transport" → dead code).
