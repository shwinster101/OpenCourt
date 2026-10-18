# 2026-10-18 — The first real provisioning run, and what it taught the script

## Report (owner, relayed from the agent on their machine, verbatim)

> "The Supabase project `pickup` exists and is healthy in us-west-1 on the Free plan, at
> https://sthveiqfuuyfyojrhhmu.supabase.co. The setup stopped partway, though. Migrations 0001 to 0003
> went in, but 0004 failed on a pg_cron privilege error, so no courts are loaded and `config.js` is still
> empty. Nothing was committed or pushed. I also hit a bug in the script, where a health-check parameter
> is now rejected. I worked around it on my side with a temporary copy."

## Root cause

- The mock could not know two things about the real API: the health endpoint rejects a query
  parameter the OpenAPI document lists, and the `postgres` role behind the query endpoint cannot do
  everything the pg_cron install page describes. The script treated both as fatal.
- `0004_schedules.sql` guarded on `pg_available_extensions`, which lists pg_cron as *available* even
  when this role cannot create or use it, so the migration itself raised instead of noticing.

## Fix (this commit)

- `wait_healthy`: tries the documented health call, then without `timeout_ms`, then bare; a 4xx on all
  three accepts `ACTIVE_HEALTHY` on the project status alone, with a note.
- Step 5 (pg_cron): each statement separately and best-effort through a new `try_sql`; a probe of
  `pg_extension` + `has_schema_privilege('cron','usage')` decides; never fatal.
- `0004`: creates the extension inside its own exception block, checks installed + usable, schedules
  inside another, and prints a notice at every exit. Idempotent (cron.schedule upserts by job name).
- `--schedule`: re-posts 0004 after the owner enables pg_cron in the dashboard and shows the jobs.
- README: the "a run stopped partway" line.

## Verification

- `sh scripts/check.sh --backend` → GATE PASSED, 182 assertions (0004's notice path on the throwaway).
- `bash test/provision/run.sh` → 40 assertions. The health fallback and the pg_cron failure path are
  not modelled by the mock yet (follow-up: a mock flag that 400s the health query string and 403s the
  grants).

## What remains

- The re-run on the owner's machine: resume, 0004 → 0005 → seed → anon key → `config.js`; `--check`;
  if pg_cron reads NOT usable, enable it in the dashboard and `--schedule`.
- The exact error text of the first run is still wanted, to make the pg_cron step precise rather than
  tolerant.

## Outcome (2026-10-18, later)

- The owner's agent re-ran the patched script: project `pickup` healthy in us-west-1, pg_cron installed,
  the three jobs active (`pickups-start-due` */1, `pickups-finalize-mvp` */15, `pickups-expire-stale`
  hourly), `config.js` committed as `a04ce05` (URL + anon key only).
- **The two-browser proof against the real project** (page served from the repo on localhost:8000, the
  page's own `config.js`): run 1 → 7 of 8 (step 8, the share-link highlight, timed out once with the row
  present); run 2 → **8 of 8**. The real project now holds two pickups on Memorial Park with 2 joined
  each and 2 live reports, written by the proof's throwaway anonymous players.
- Step 8's first miss is the only difference from the stand-in, where it was 3/3 after the highlight fix;
  the real realtime channel re-renders the court panel on B's own join event. Follow-up: make the proof
  wait for the highlight across one more render, or pin the highlight for 5 s after the deep link.
