# AGENTS.md — PickUpHasura (2021 backend) — frozen legacy source

> **Read [`CLAUDE.md`](./CLAUDE.md) first.** It states the owner's 2026-10-17 ruling: this
> repository is a read-only reference for the migration of PickUp's backend flow into
> [shwinster101/OpenCourt](https://github.com/shwinster101/OpenCourt). When this file and
> CLAUDE.md disagree, CLAUDE.md wins.

- **This repository is public and contains committed credentials** (`firebase_key.json`, `.env`,
  `tests/.env`, `express-server/.env`). Treat that service account as compromised; never reuse it,
  never copy its values anywhere. Details and the remediation order are in CLAUDE.md.
- **Do not build features here.** The flow is documented in
  `OpenCourt/docs/LEGACY_PICKUP_BACKEND.md` and is being rebuilt per `OpenCourt/docs/MIGRATION.md`.
- **Do read here** for the schema (`hasura/migrations/default/*/up.sql`), the Hasura metadata
  (`hasura/metadata/`), the 19 action handlers (`express-server/src/actions/`), the event plumbing
  (`express-server/src/events/`) and the end-to-end flow tests (`tests/src/tests/test_flows.py`).
- **Write findings in OpenCourt**, in a dated `working/` note there.
