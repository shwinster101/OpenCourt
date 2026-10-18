# AGENTS.md — OpenCourt (PickUp's successor)

> **Canonical project brief: [`CLAUDE.md`](./CLAUDE.md).** Read it first. It carries the owner's
> rulings with their dates, the release record, the invariants and the verification gate. When this
> file and CLAUDE.md disagree, **CLAUDE.md wins.**
>
> This file is deliberately a THIN POINTER with no version numbers, feature lists or status claims.
> Volatile facts live in exactly one place so that this file cannot rot.

**What this is.** PickUp, rebuilt on the OpenCourt structure: a no-build-step HTML/CSS/JS web app
that answers *"where can I play, and who's playing?"* for recreational court sports. The court
finder (map, availability, crowd reports) is live on GitHub Pages; the people half (friends,
pickups, invitations, scores, MVP, notifications) is being migrated from the 2021 PickUp backend.

## Read in this order

1. `CLAUDE.md` — rulings, release record, invariants, gate.
2. `docs/FOUNDATION.md` — the issue, goal, vision, mission, user stories, the core loop, the
   fundamental requirements.
3. `docs/MIGRATION.md` — how the 2021 flow becomes working APIs here.
4. `docs/LEGACY_PICKUP_BACKEND.md` — what the 2021 backend actually did (source of truth for the port).
5. `docs/REQUIREMENTS.md` — the court-finder SRS (Phase 1 shipped, Phase 2 scoped).
6. `working/` — dated findings; the newest note is the latest state of any open work.

## Commands

```bash
python3 -m http.server 8000      # serve the site locally (fetch() needs http://, not file://); 8000 is the origin the Maps key allows
sh scripts/check.sh              # the gate: data parses, JS parses, no secret-shaped strings, seed current
sh scripts/check.sh --backend    # + the backend leg: migrations, RLS matrix, the ported 2021 flows, the realtime publication
                                 #   against a throwaway PostgreSQL (needs the server binaries; see test/backend/run.sh)
node scripts/export-courts-seed.mjs > supabase/seed.sql   # after editing assets/data/courts.json
PORT=8000 node test/browser/check-offline.cjs /tmp/o.png                                   # Playwright on NODE_PATH
PORT=8000 node test/browser/check-backend.cjs test/browser/fake-supabase.js /tmp/b.png
sh test/e2e/local-stack.sh start && sh test/e2e/smoke-local-backend.sh                     # the local stand-in for Supabase
OC_SUPABASE_URL=http://127.0.0.1:54400 OC_SUPABASE_ANON_KEY=local-anon node test/e2e/two-browsers.cjs
sh test/e2e/local-stack.sh stop
bash test/provision/run.sh                                 # the provisioner against a mock of the Management API
SUPABASE_ACCESS_TOKEN=… scripts/provision-supabase.sh      # the real thing (owner; token from the environment, never a file)
```

There is no build step and no package manager for the site. The backend is SQL only
(`supabase/`); provisioning is one command, with the manual steps as fallback, in `supabase/README.md`. Deploys happen on push to `main`
through `.github/workflows/pages.yml`.

## Non-negotiables (details and rationale in CLAUDE.md)

- **Honest signals.** A heuristic is labelled a heuristic; a live report says how old it is.
  Never relabel stale or demo data as live.
- **Identity comes from auth, never from the client.** A row's owner is `auth.uid()` (or the
  server-minted anonymous id), never an id the client typed into a header or a body. This is the
  2021 backend's one unforgivable design, and it is not ported.
- **No build step until a build step is necessary.** Plain HTML/CSS/JS, deployable as-is.
- **Forward-compatible schema.** Every record carries `metro`; migrations add, never rename.
- **Secrets never enter this repository.** The only credentials allowed in source are the
  referrer-restricted Google Maps browser key and the Supabase anon (publishable) key; everything else
  is an environment variable. The gate refuses service-role keys.
- **Findings live on the branch, in a dated `working/` note, not in chat.**
- **The PickUp name and logo stay** (`assets/img/pickup-logo.png`, `pickup-icon-1024.png`).
