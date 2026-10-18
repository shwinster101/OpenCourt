# PickUpHasura — the 2021 PickUp backend (frozen)

The backend of the 2021 PickUp iOS app (`PickUpBois/PickUp`): Hasura GraphQL Engine v2.0.4 over
Postgres/PostGIS, an Express/TypeScript server providing 19 Hasura actions, a Firebase emulator and
pytest flow tests, wired by `docker-compose.yml`. Written by Arian Rahbar, July–November 2021.

**This repository is frozen.** PickUp continues in
[shwinster101/PickUp](https://github.com/shwinster101/PickUp), which keeps the PickUp name and
logo and rebuilds this flow on working APIs. Start with `CLAUDE.md` here, then OpenCourt's
`docs/LEGACY_PICKUP_BACKEND.md` (what this code does) and `docs/MIGRATION.md` (how it moves).

**Security note:** this public repository contains committed credentials (`firebase_key.json`,
`.env` files). They are to be treated as compromised and revoked at the source; see `CLAUDE.md`.

## Layout

| Path | Contents |
|---|---|
| `hasura/metadata/` | tables, relationships, enum tables, actions (`actions.graphql`, `actions.yaml`), the `domain_events` event trigger, the remote schema |
| `hasura/migrations/default/` | 51 timestamped SQL migrations; `1626766762663_init` is the schema |
| `express-server/src/` | `actions/*` (one handler per action), `models/*` (data access), `events/*` (webhook → EventEmitter → notification and scheduling handlers), `index.ts` |
| `firebase/` | emulator config (`firebase.json`, `storage.rules`) and two empty exports |
| `tests/` | pytest flows (`src/tests/test_flows.py`) and their docker-compose stack |
| `docker-compose.yml` | express:3000 · firebase:9099/9199/4000 · postgres:5432 · hasura:5000 |

## Historical run instructions (unverified in 2026)

```bash
cp .env.example .env   # there is no example file; the committed .env was used directly — do not reuse it
docker-compose up      # Hasura console at http://localhost:5000, actions at http://localhost:3000/actions/*
```

Production ran on Heroku at `pickuphasura.herokuapp.com`, which no longer exists.
