# PickUp 2021 — the legacy backend flow, as built

**Status:** reference record, written 2026-10-17 from the source in `PickUpBois/PickUpHasura` and
`PickUpBois/PickUp` (both frozen at their 2021-11-06 commits). This is the **source of truth for
what is being migrated**; it describes what the code does, not what it was meant to do. Every claim
names the file it comes from. Where the code and its intent diverge, both are stated.

Companion documents: [`FOUNDATION.md`](./FOUNDATION.md) (why PickUp exists and what it must do),
[`MIGRATION.md`](./MIGRATION.md) (how this flow moves into OpenCourt's structure).

---

## 1. Shape of the 2021 system

```
iOS app (SwiftUI, Apollo codegen + a hand-written GraphQL client)
   │  POST /v1/graphql, header X-Hasura-User-Id: <Firebase UID>
   ▼
Hasura GraphQL Engine v2.0.4 ──── Postgres 12 + PostGIS
   │  actions (19)            ▲  event trigger on domain_events (insert)
   ▼                          │
Express/TypeScript "actions" server :3000
   /actions/*   → one handler per action, each writing back through Hasura (admin, no role)
   /events/domainEvent → in-process EventEmitter → notification / scheduling handlers
   /graphql     → a one-field remote schema (getEventTeam)
Firebase: Auth (email+password), Storage (profile photos), Cloud Messaging (tokens stored, never sent)
```

| Piece | Where | Evidence |
|---|---|---|
| Hasura + Postgres + Express + Firebase emulator, wired by docker-compose | `PickUpHasura/docker-compose.yml` | images `hasura/graphql-engine:v2.0.4.cli-migrations-v3`, `postgis/postgis:12-master`; `ACTION_BASE_URL=http://express:3000/actions`, `EVENT_BASE_URL=http://express:3000/events`, `REMOTE_SCHEMA_URL=http://express:3000/graphql` |
| Production host the app pointed at | `PickUp/PickUp.xcodeproj/project.pbxproj` | `PROD_HOST = "https://pickuphasura.herokuapp.com"`, `DEV_HOST = "http://localhost:5000"`, `ENV = PROD`. The host answers HTTP 404 on 2026-10-17: **the 2021 backend is dead.** |
| Express dependencies | `PickUpHasura/express-server/package.json` | `express`, `express-graphql`, `graphql-tools`, `graphql-request`, `firebase-admin`, `node-schedule`, `dotenv` |
| Apollo codegen at build time | `project.pbxproj` build phase | downloads the schema from `${URL}/v1/graphql` into `PickUp/schema.json`; generated code is `PickUp/API.swift` (4,808 lines) |

---

**Before Hasura (April–July 2021).** The oldest surviving iOS code already spoke GraphQL through
Apollo to a custom server at `pickupserver.herokuapp.com` / `localhost:3000` whose schema
(`users, user, searchUsers, events, userEvents, queryEvents, event`; `createUser, updateUser,
removeUser, createEvent, updateEvent, removeEvent, joinEvent`) is frozen in the root commit's
`schema.json`. Friends, notifications, invitations, MVP voting, scores and the GOAT score existed as
features of that server; Hasura re-implemented them in July 2021. **The custom server's source is in
none of the repositories.** Three attempts re-pointed the app at Hasura (`origin/hasura`,
`origin/hasura2`, both abandoned; `hasura3`, merged 2021-08-04).

## 2. Identity and authorization (the part that must NOT be ported as-is)

- **Identity = the Firebase UID, sent as a plain header.** Both clients add
  `X-Hasura-User-Id: <auth.currentUser.uid>` (`PickUp/services/interceptors/AuthenticationInterceptor.swift`,
  `PickUp/services/GraphQLClient.swift`). No ID token is sent and nothing verifies one. It was not
  always so: the interceptor of 2021-06-15 (`b7bb9420`) fetched a Firebase ID token and sent it as
  `Authorization`, which the custom server could verify; the abandoned `origin/hasura` branch sent
  `X-Hasura-Role: admin`; the downgrade to the bare UID header landed on 2021-07-25 (`68cfbce0`) and
  was never revisited.
- **Hasura has no permission rules.** No table yaml under `hasura/metadata/databases/default/tables/`
  contains `select_permissions`, `insert_permissions`, `update_permissions` or `delete_permissions`;
  `docker-compose.yml` leaves `HASURA_GRAPHQL_ADMIN_SECRET` commented out and configures no JWT or
  webhook auth. Every request therefore runs with full access to every table.
- **Actions trust the header.** Each handler reads `req.body.session_variables['x-hasura-user-id']`
  as the actor (e.g. `express-server/src/actions/createEvent/createEvent.ts`). Hasura forwards whatever
  the client sent (`forward_client_headers: true` in `actions.yaml`).
- Consequence: any client could read or write any row, and act as any user, by choosing the header.
  Acceptable for a 2021 student prototype on an emulator; a non-starter for the successor. The
  migration replaces this with the database's own identity (`auth.uid()`) and row-level security
  (see `MIGRATION.md` §3).
- **Firebase Storage rules** allow unrestricted read and write (`firebase/storage.rules`).

---

## 3. Data model (effective, after all migrations)

Migrations live in `hasura/migrations/default/` and apply in timestamp order; the init migration is
`1626766762663_init/up.sql`. Hasura exposes camelCase names through `custom_column_names` in each
table's yaml; both names are given below as `sql_name → graphqlName`.

### 3.1 Tables

| Table | Columns (key ones) | Notes |
|---|---|---|
| `users` | `user_id → id` (text PK = Firebase UID), `first_name`, `last_name`, `username` (UNIQUE), `college`, `photourl → photoUrl`, `tokens` tsvector, `goat_score → goatScore` int default 0 | `tokens` is maintained by the `users_search_trigger` (lower first+last+username). **`goat_score` is never written by any backend code** (grep of `express-server/src` and all migrations). |
| `events` | `event_id → id` serial PK, `name`, `info`, `start_date → startDate`, `end_date → endDate`, `deleted` bool, `capacity` int, `result_info`, `winner_id → winnerId` FK `event_teams`, `mvp_id → mvpId` FK `users`, `location_id` FK `locations`, `status` FK `event_status` default `'open'`, `type` FK `event_type` | **`location_id` is never set**: `CreateEventInput` has no location field (`actions.graphql`), and the iOS `CreateEventViewModel` hardcodes `type: tennis`. |
| `event_attendees` | PK (`event_id → eventId`, `attendee_id → id`), `joined_at`, `invited_at`, `invited_by` FK users, `vote_count → voteCount`, `voted` bool, `team_id` FK `event_teams`, `status` FK `event_attendee_status` | The owner is an attendee row with `status = owner`. **`team_id` is never set** (see `end_event`). |
| `event_teams` | `team_id → id`, `event_id → eventId`, `set_scores → scores` **jsonb** `{"scores":[6,4,...]}` | Was `integer[]`; changed to jsonb in `1627593746368_event_teams_jsonb`. `members` relationship exists but is always empty. `info` is a *remote relationship* to the Express remote schema (`getEventTeam`), which reads the same row back through Hasura. |
| `relationships` | PK (`user_id`, `friend_id`), `created_at`, `status` FK `friend_status` (only value: `friend`) | Directional rows. One row = a pending request from `user_id` to `friend_id`; two reciprocal rows = friends. |
| `notifications` | `id` serial, `user_id → userId` FK users (cascade), `actor_id → actorId`, `event_id → eventId`, `created_at → createdAt`, `type` FK `notification_type`, `status` FK `notification_status` | Recreated as a table in `1627354302627_notifications_table` (dropping the earlier `get_notifications` UNION function); `status` added in `1627354749502`. |
| `device_tokens` | PK (`user_id`, `token`) | FCM registration tokens. Written by `putDeviceToken`/`removeDeviceToken`; **read only by `sendNotification`, which nothing calls.** |
| `domain_events` | `id` bigserial, `created_at`, `payload` jsonb, `type` FK `domain_event_type`, `event_id`, `user_id` | The outbox: every state change inserts a row; a Hasura event trigger relays it (see §5). |
| `locations` | `location_id`, `name`, `capacity`, `num_people`, `coordinates` **geography(Point,4326)**, `street`, `city`, `state`, `postal_code`, `country`, `iso_country_code`, `sub_locality` | Designed, tracked in Hasura, **never written or read** by any action or client query. |
| `event_files` | `id`, `event_id`, `user_id`, `extension`, `file_url`, `created_at` | No handler (`router.post('/uploadEventFiles')` is registered with no controller in `actionRoutes.ts`). |
| `info_notifications` | legacy notification rows | Superseded by `notifications`; still tracked. |
| lookup tables | `event_status`, `event_type`, `event_attendee_status`, `friend_status`, `notification_status`, `notification_type`, `domain_event_type` | Hasura enum tables; values in `1626770639404_enums/up.sql`. |

### 3.2 Enumerations (values as seeded)

| Enum | Values |
|---|---|
| `event_status` | `open` · `ip` (in progress) · `closed` (plus the `deleted` boolean flag on `events`) |
| `event_type` (sport) | `tennis` · `basketball` |
| `event_attendee_status` | `owner` · `invited` · `ok` (joined) · `conflict` (never written) |
| `friend_status` | `friend` |
| `notification_status` | `unread` · `read` |
| `notification_type` | `friendRequestSend` · `friendRequestAccept` · `friendRequestReject` · `eventInvitation` · `finishEvent` · `voteForMvp` · `selectedMvp` · `leftEvent` · `joinedEvent` · `deletedEvent` (seeded; its handler `addDeleteEventNotification` is an empty function) |
| `domain_event_type` | `USER_CREATED` · `USER_LEFT_EVENT` · `USER_JOINED_EVENT` · `USER_INVITED_TO_EVENT` · `USER_ACCEPT_FRIEND_REQUEST` · `USER_REJECTED_FRIEND_REQUEST` · `USER_SELECTED_MVP` · `USER_SENT_FRIEND_REQUEST` · `EVENT_STARTED` · `EVENT_DELETED` · `EVENT_FINISHED` · `EVENT_CREATED` · `USER_VOTED_FOR_MVP` |

### 3.3 SQL functions tracked by Hasura

| Function | Exposed as | What it does | Source |
|---|---|---|---|
| `end_event(event_id, team1_members, team2_members, team1_win, team1_scores, team2_scores)` | mutation `end_event` | Inserts two `event_teams` rows with the scores as jsonb, sets `events.status='closed'`, `winner_id`, `end_date=now()`, deletes attendees still `invited`. **Ignores `team1_members`/`team2_members`**: no attendee gets a `team_id`. Checks no prior status itself (the action does), has no `RETURN QUERY` so it returns an empty set, and is callable directly by any client because Hasura tracks it as a mutation. The init version updated **every** event (`UPDATE events SET status='closed'` with no `WHERE`); fixed from the fourth rewrite on. | `1627598022100_end_event/up.sql` (the last of ~15 rewrites between `1626986061283` and `1627598022100`) |
| `search_users(search)` | query `search_users` | Splits the search on spaces, appends `:*` prefix matching joined by `|`, runs `to_tsquery` against `users.tokens`. Builds the query with `FORMAT('… ''%s''')` inside hand-written quotes, so the search text is **interpolated unescaped into SQL** (an injection point, and a quote in a name breaks the query). | `1627260920648_search_users/up.sql` |
| `get_friends(user_row)` | computed field `users.friends` | Users with reciprocal `friend` rows. Correct. | `1627255672294_get_friends/up.sql` |
| `friend_status(user_row, hasura_session)` | computed field `users.friendStatus` | Meant to say whether the session user and the row are mutual friends. **Broken as written:** the second `EXISTS` compares `r2.user_id = friend_id`, which PL/pgSQL resolves to the *column* `relationships.friend_id` rather than the variable `friendId`, so the field is false for every real friendship. The iOS `UserDetails` fragment selects it and `PopOverView` branches on it, so the profile pop-over never showed the "friends" state. | `1627255789123_friend_status/up.sql` |
| `add_tokens()` trigger | — | Rebuilds `users.tokens` before insert/update. | `1627260541673_users_search_trigger/up.sql` |

---

## 4. API inventory — the 19 Hasura actions

All actions are synchronous, `handler: {{ACTION_BASE_URL}}/<name>`, `forward_client_headers: true`
(`hasura/metadata/actions.yaml`); types in `hasura/metadata/actions.graphql`. Every action returns
`ActionResult { status: SUCCESS | ERROR | USERNAME_ALREADY_EXISTS, reason, id }`. "Actor" is the
header user (§2). Handlers live in `express-server/src/actions/<name>/<name>.ts`.

| # | Action | Input | Guard (as coded) | Writes | Domain event → follow-on |
|---|---|---|---|---|---|
| 1 | `createUser(arg1: CreateUserInput{firstName, lastName, username, college?})` | — | none (a `FindUsersByUsername` query is defined but not used, so `USERNAME_ALREADY_EXISTS` is never returned; the UNIQUE constraint surfaces as `ERROR`) | `users` row with `id = actor` | `USER_CREATED` (no handler) |
| 2 | `updateUser(arg1: UpdateUserInput{firstName?, lastName?, username?, photoUrl?, college?})` | — | none | merges non-null fields over the current row (`curr || old`, so a field can never be cleared) | — |
| 3 | `sendFriendRequest(friendId)` | friend exists; no request already from friend | `relationships(actor → friend, 'friend')` | `USER_SENT_FRIEND_REQUEST` → notify friend `friendRequestSend` |
| 4 | `acceptFriendRequest(friendId)` | a request from friend to actor exists and is not yet reciprocal | `relationships(actor → friend)` (now mutual) | `USER_ACCEPT_FRIEND_REQUEST` → notify sender `friendRequestAccept` |
| 5 | `rejectFriendRequest(friendId)` | — | deletes `relationships(friend → actor)` | `USER_REJECTED_FRIEND_REQUEST` → notify sender `friendRequestReject` |
| 6 | `removeFriend(friendId)` | mutual friends | deletes both rows | — |
| 7 | `createEvent(arg1: CreateEventInput{name, info, startDate, capacity, type, status})` | none; `status` input ignored (DB default `open`) | `events` + owner `event_attendees` row (`status: owner`, `joinedAt: now`) | `EVENT_CREATED` → schedule start (§5). The only action that inserts its domain event in a **second** request, without error handling: if it fails, the event never gets its start job |
| 8 | `deleteEvent(eventId)` | actor is `owner`; not already deleted | `events.deleted = true` (soft delete) | `EVENT_DELETED` → cancel scheduled start; `deletedEvent` notification never sent |
| 9 | `joinEvent(eventId)` | event exists; actor not already `ok` | `event_attendees(actor, 'ok', joinedAt)` — **capacity is not checked** | `USER_JOINED_EVENT` → notify owner `joinedEvent` |
| 10 | `leaveEvent(eventId)` | actor is `ok` | deletes the attendee row | `USER_LEFT_EVENT` → notify owner `leftEvent` |
| 11 | `inviteUserToEvent(userId, eventId)` | user and event exist; user not already an attendee — **the inviter is not checked to be the owner or even an attendee** | `event_attendees(user, 'invited', invitedAt, invited_by: actor)` | `USER_INVITED_TO_EVENT` → notify invitee `eventInvitation` (actor shown = owner, not the inviter) |
| 12 | `cancelEventInvitation(userId, eventId)` | — | deletes the attendee row | — |
| 13 | `acceptEventInvitation(eventId)` | actor's row is `invited` | sets `status: ok` | — (no `joinedEvent` notification for accepted invitations) |
| 14 | `declineEventInvitation(eventId)` | — | deletes the attendee row | — |
| 15 | `endEvent(input: EndEventInput{eventId, team1_members, team2_members, team1_scores, team2_scores, team1_win})` | event `status = ip`; actor is `owner` | calls `end_event` (§3.3) | `EVENT_FINISHED` → notify **every attendee** `voteForMvp` |
| 16 | `voteForMvp(eventId, userId)` | intended: votee is an attendee — **the check is broken** (`getEventAttendee` is not awaited, so a Promise is always truthy); the voter is not checked to be an attendee and may vote repeatedly | voter `voted = true`; votee `vote_count + 1` | `USER_VOTED_FOR_MVP` → when every attendee has voted, pick the MVP (§5) |
| 17 | `markNotificationAsRead(notificationId)` | — (any user can mark any notification) | `notifications.status = read` | — |
| 18 | `putDeviceToken(token)` | — | upsert `device_tokens` | — |
| 19 | `removeDeviceToken(token)` | — | delete `device_tokens` | — |

Reads the iOS app performs directly against Hasura tables (no action, no permission): upcoming events
(`events where status in [open, ip] and not deleted` — **every event, for every user; there is no
"near me" or "my friends" filter**), joined/past events by status, the user with `friends`,
unread notifications with actor and event, invited attendees of an event, `search_users`
(`PickUp/resources/graphql/*.graphql`).

Remote schema: `getEventTeam(teamId): EventTeam{id, eventId, scores}` served by Express
(`express-server/src/index.ts`, `schema.graphql`); it exists only to unpack `event_teams.set_scores`
jsonb into `[Int]` for the `info` remote relationship.

---

## 5. The event-driven plumbing

1. A handler inserts a `domain_events` row in the same GraphQL mutation as its state change.
2. Hasura's `domain_events_trigger` (insert, `num_retries: 0`, timeout 60s) POSTs the row to
   `{{EVENT_BASE_URL}}/domainEvent` (`tables/public_domain_events.yaml`).
3. `domainEventController` emits `type` with `payload` on a Node `EventEmitter` and then
   **answers HTTP 500 unconditionally** (`events/domainEvent.ts`); Hasura records every delivery as
   failed but, with zero retries, nothing is re-sent.
4. Listeners (`events/eventEmitter.ts`):
   - notification writers in `eventHandlers/notificationHandler.ts` insert `notifications` rows
     (types listed in §4);
   - `eventCreatedHandler` schedules an in-process `node-schedule` job `start:<eventId>` at
     `startDate` (or starts immediately if in the past) → `startEventHandler` sets `status = ip`
     and inserts `EVENT_STARTED` → `addFinishEventNotification` tells the owner to finish the event;
   - `eventDeletedHandler` is meant to cancel that job, but calls `job[jobId].cancel()` on the Job
     object itself (`eventHandler.ts:45`), which throws inside the listener: **the start timer is
     never cancelled, so a deleted event still flips to `ip` and the owner still gets `finishEvent`;**
   - `votedForMvpHandler` runs after each vote: once no attendee has `voted = false`, the attendee(s)
     with the highest `vote_count` are found and one is chosen at random — **but the random index is
     applied to the full `attendees` array, not to the tied leaders**, so the MVP can be any
     attendee — then `setEventMvp` writes `events.mvp_id` and inserts `USER_SELECTED_MVP` →
     `selectedMvp` notification to the MVP.
5. On boot `startOpenEvents()` re-schedules a start job for every open event, because the schedule
   is process memory and is lost on restart (`eventHandlers/eventHandler.ts`, `index.ts`). A job
   whose `startDate` passed while the process was down is not created, so that event never starts;
   two replicas would start every event twice. `POST /events/startEvent` also starts any event for
   any caller with no check (`events/startEvent.ts`; its `catch` returns `SUCCESS`); the pytest
   `start_event` fixture uses it.
6. Push: `models/notification.ts#sendNotification` would multicast through FCM to a user's
   `device_tokens` and prune rejected tokens. **No code calls it.** Arian's commit `a8dc776`
   (2021-08-03) says it: "stable, needs push notifications".

Event lifecycle, as the data sees it:

```
createEvent ─▶ open ──(node-schedule at startDate)──▶ ip ──(owner: endEvent)──▶ closed
     │                                                                  │
     └──(owner: deleteEvent)──▶ deleted = true (any status)             └─▶ votes ─▶ mvp_id set
attendee: owner | invited ─(accept)─▶ ok ; invited ─(decline/cancel)─▶ row deleted ; ok ─(leave)─▶ row deleted
friend:   A→B row (request) ─(accept)─▶ A→B + B→A (friends) ; (reject) ─▶ A→B deleted ; (remove) ─▶ both deleted
```

---

## 6. Clients

- **Apollo client** (`PickUp/services/Services.swift`) with `AuthenticationInterceptor` for the
  codegen'd operations is the only transport. The **hand-written `GraphQLClient`**
  (`services/GraphQLClient.swift`, 2021-08-02) with `EventModel`/`UserModel` (`PickUp/models/`) is
  **never called** (`Services.shared.client` has no caller): the start of an escape from codegen
  that was abandoned when the project went quiet. Treat it as dead code, not a second transport.
  The `.graphql` operation files (15 under `resources/graphql/`), not `API.swift`, are the spec.
- Auth: Firebase email+password through `AuthService`; `AppState.listen()` publishes the UID.
  Sign-up calls `createUser` right after Firebase account creation (`views/auth/SignUpViewModel.swift`).
- Profile photos go to Firebase Storage (`services/StorageService.swift`), the URL into `users.photourl`
  via `updateUser`.
- Push registration: `PickUpAppDelegate` requests notification permission and sets the APNs token on
  Firebase Messaging; `putDeviceToken` is called from the login/sign-up view models.
- Court discovery ("Courts near me", "Busyness") is **hardcoded demo data** in
  `views/nearme/CourtsNearBy/CourtsNearMeView.swift` (written by Ashwin, 2021-05-12) and
  `views/busyness/BusynessView.swift`; the map tab uses Apple MapKit `MKLocalSearch` with the user's
  typed query (`views/map/MapViewModel.swift`). The backend's `locations` table never met these screens.
- Feed, posts, likes, comments, shares and chat screens exist as UI only (`views/home/*`,
  `views/message/*`) with no backend operation behind them.

---

## 7. Tests and tooling

- `express-server`: jest configured; one test file (`acceptEventInvitation.test.ts`), one happy
  path of one action, with a mock setup that would throw before its assertion.
- `tests/` (Python, pytest, 11 tests): `test_flows.py` drives the full flows end to end against the
  docker stack — accept/decline/cancel invitation, join/leave, delete, friend request
  accept/reject/remove, update user, start and end an event (`tests/src/tests/test_flows.py`,
  fixtures in `conftest.py`). Assertions check only `status == SUCCESS`; nothing is read back and
  there are no negative cases. `mutations.py` calls `endEvent` with flat arguments while the action
  takes `input: EndEventInput!`, so `test_end_event` fails GraphQL validation as committed. Even so,
  these flows are the best executable statement of the intended behaviour and are worth porting as
  the acceptance tests of the migration (`FOUNDATION.md` DR-14).
- A fresh `docker-compose up` would run `CREATE EXTENSION postgis` twice (once from
  `tests/db_init_scripts/up.sql`, once from the last commit's edit to the init migration), so the
  migration would fail on a clean machine; the last commit targeted Heroku, where no init script runs
  (inferred, not executed).
- `test.http`: hand requests against `localhost:3000/actions/*`.
- Nothing has been run in 2026; the Node 2021 toolchain (`ts-node-dev`, tslint) and Hasura 2.0.4
  images are unverified here.

---

## 8. Secrets committed to the public repository

`PickUpBois/PickUpHasura` is **public**. It contains, at HEAD and in history:

- `firebase_key.json` — a Google service-account key (`type`, `project_id`, `private_key_id`,
  `private_key`, `client_email`, …).
- `.env` and `tests/.env` — database credentials and `GOOGLE_PRIVATE_KEY` / `GOOGLE_CONFIG_BASE64`
  (the same service account, base64).
- `express-server/.env` — `GOOGLE_CONFIG_BASE64`.

Treat the service account as compromised: **disable or delete it in the Google Cloud project**
(the Firebase project in `PickUp/PickUp/GoogleService-Info.plist`'s `PROJECT_ID`) regardless of
whether the files are later removed, because removal does not purge history. The iOS
`GoogleService-Info.plist` holds client-side Firebase config (API key, app id); those are not
server secrets, but the project should be considered retired with the Heroku host.

---

## 9. What the record says about intent vs. delivery

| Intended (names, enums, tables, UI) | Delivered (code paths that run) |
|---|---|
| Sports: tennis and basketball | Every created event is `tennis` (client hardcode) |
| Events at a location (PostGIS point, address) | No event has a location |
| Capacity-limited pickups | Capacity stored, never enforced |
| Teams with members and set scores, a winner | Scores and winner stored; members never assigned |
| MVP by vote, a GOAT score | MVP chosen (with the index bug); GOAT score never changes |
| Push notifications | Tokens stored; nothing sent |
| In-app notifications, 10 types | 9 types written; `deletedEvent` never |
| Discovery: courts near me, busyness | Demo data in the client |
| Social feed, chat | UI only |

That table is the migration's honest starting line: the **friend graph, the pickup lifecycle
(create → invite/join → start → end with scores → MVP) and in-app notifications** are real,
tested flows; everything in the right-hand column is a requirement to carry forward, not code to port.
