# CLAUDE.md — PickUpHasura (2021 backend) — FROZEN LEGACY SOURCE

**Status (owner ruling 2026-10-17):** "OpenCourt is the modern successor — though keeping the PickUp
namesake and logo will be the path forward: migration of PickUp backend flow to the OpenCourt
structure and working APIs." This repository is a **read-only reference**: the flow it implemented
is documented in OpenCourt's `docs/LEGACY_PICKUP_BACKEND.md` and is being rebuilt per
`docs/MIGRATION.md` in [`shwinster101/PickUp`](https://github.com/shwinster101/PickUp). When
anything here and anything there disagree, OpenCourt wins.

## ⚠️ Committed credentials — read first

This repository is **public** and has carried the following since 2021, at HEAD and in history:

| File | What it holds (key names only) |
|---|---|
| `firebase_key.json` | A Google service-account key for Firebase project `pickup-774f9`: `private_key`, `private_key_id`, `client_email`, `client_id`, … |
| `.env` | `GOOGLE_PRIVATE_KEY`, `GOOGLE_CONFIG_BASE64` (the same service account), `PASSWORD` (Postgres) and connection settings |
| `express-server/.env` | `GOOGLE_CONFIG_BASE64` |
| `tests/.env` | `PASSWORD` and connection settings |

Treat the service account as **compromised**. The remediation order is: (1) disable or delete the
service account in the Google Cloud project — this is the only step that actually revokes it;
(2) only then consider removing the files from the tree, remembering that history still contains
them. Never copy a value from these files into a chat, a note, another repository or a new project.
The Postgres password is for a local docker-compose database and is not reachable, but is still
not to be reused.

## What this repository is

- Hasura GraphQL Engine v2.0.4 (`hasura/metadata`, 51 migrations under `hasura/migrations/default`)
  over Postgres 12 + PostGIS; an Express/TypeScript server (`express-server/src`) with 19 Hasura
  action handlers, a domain-event webhook, a one-field remote schema and an in-process scheduler;
  a Firebase emulator (`firebase/`); pytest flow tests (`tests/`); `docker-compose.yml` wiring them.
- All 9 commits are by Arian Rahbar, 2021-07-18 → 2021-11-06: "initial code" → "added tests and
  finished most methods" → "stable, needs push notifications" → "curr metadata" (firebase-admin,
  the committed key) → "stable" ×2, "fixed tables.yaml" → "changes" (cleanup) → "fixed hasura"
  (Heroku endpoint, `CREATE EXTENSION postgis`). The Heroku app it deployed to is gone.
- The effective data model, the 19 actions with their guards and side effects, the event
  plumbing, the authorization model (none: a client-set `X-Hasura-User-Id` header, no permissions,
  no admin secret) and the defects are written up, with file references, in OpenCourt
  `docs/LEGACY_PICKUP_BACKEND.md`. Do not re-derive them here; correct them there if wrong.

## Where things are (for reading, not running)

| Need | Look at |
|---|---|
| Schema, in order | `hasura/migrations/default/*/up.sql` by timestamp; the init is `1626766762663_init`; later rewrites of `end_event`, `search_users`, `get_friends`, the `notifications` table rebuild (`1627354302627`) |
| GraphQL names (camelCase) and relationships | `hasura/metadata/databases/default/tables/*.yaml` (`custom_column_names`), `functions/*.yaml`, `actions.graphql`, `actions.yaml`, `remote_schemas.yaml` |
| Action handlers | `express-server/src/actions/<name>/<name>.ts`; shared data access in `src/models/`; types in `src/types.d.ts`, `src/enums.ts` |
| Event plumbing | `src/events/domainEvent.ts` (webhook), `eventEmitter.ts` (listeners), `eventHandlers/notificationHandler.ts`, `eventHandlers/eventHandler.ts` (start timers, MVP pick), `startEvent.ts` |
| The intended flows, executable | `tests/src/tests/test_flows.py` with `conftest.py` and `mutations.py` — port these as the acceptance tests of the migration (OpenCourt `docs/FOUNDATION.md` DR-14) |
| Running it (historical) | `docker-compose up` brought up express:3000, firebase, postgres:5432, hasura:5000 with the console on. Not verified in 2026; a clean bring-up likely fails on a duplicate `CREATE EXTENSION postgis` (see the legacy doc §7) |

## Rules for agents working here

- **Do not build features, upgrade dependencies, add CI or redeploy this stack.** The migration
  target is OpenCourt.
- **Do read freely**; quote `file:line` when you report.
- **Write findings in OpenCourt** (`working/<date>-<slug>.md`). The only edits this repository
  should receive are corrections to this file, `AGENTS.md`, `README.md`, and the credential
  removal once the owner has revoked the key.
- **Never port the authorization model.** OpenCourt's rule is identity from the database
  (`auth.uid()`) under row-level security; the header trust here is the defect the successor exists
  to fix.
