# The shared backend (Supabase Postgres)

This folder is the whole backend: four SQL migrations and a seed. There is no server code to
deploy. The frontend talks to the database through PostgREST and the RPC functions the
migrations create; every rule lives in SQL under `auth.uid()` and row-level security
(`docs/MIGRATION.md` §3–5). The same files run against a plain PostgreSQL in
`test/backend/run.sh`, which is how they are tested here.

| File | Step | What it creates |
|---|---|---|
| `migrations/0001_courts_and_reports.sql` | M1 | `courts`, `court_reports`, the `courts_live` view, `submit_report()` with the 15-minute rate limit |
| `migrations/0002_identity_and_pickups.sql` | M2 | `profiles`, `pickups`, `pickup_attendees`, `notifications`, `event_log`; `upsert_profile`, `create_pickup`, `join_pickup`, `leave_pickup`, `cancel_pickup`, invitations, `start_due_pickups`, `mark_notifications_read`; views `open_pickups`, `my_pickups`, `my_notifications`; `pickup_by_token`, `pickup_roster` |
| `migrations/0003_friends_results_mvp.sql` | M3 | `friendships` and its functions, `search_players`, `pickup_teams`, `record_result`, `mvp_votes`, `vote_mvp`, `finalize_due_mvp_votes`, `expire_stale_pickups`, the `player_standing` view |
| `migrations/0004_schedules.sql` | — | the three `pg_cron` jobs (prints a notice where pg_cron is absent) |
| `seed.sql` | — | the 20 curated courts, generated from `assets/data/courts.json` by `scripts/export-courts-seed.mjs` |

## Provisioning (one time, ~15 minutes)

1. **Create a Supabase project** (free tier is fine; note NFR-06 — free projects pause after a
   week idle, so plan a weekly read or the paid tier before real users arrive). Region: a US-West
   one for LA.
2. **Enable anonymous sign-ins**: Authentication → Providers → Anonymous sign-ins → on. (Court
   reports and lightweight player identities depend on it; FOUNDATION FR-60.) Keep email
   (magic link) enabled for the later account upgrade (FR-61).
3. **Enable `pg_cron`**: Database → Extensions → search `pg_cron` → enable (schema `pg_catalog`
   or `cron`, either is fine).
4. **Run the migrations in order** in the SQL editor (paste each file whole), or with the CLI:
   `supabase link --project-ref <ref>` then `supabase db push`. Expected: no errors; 0004 prints
   "pg_cron jobs scheduled".
5. **Run `seed.sql`**. Expected: 20 rows in `courts`; `select count(*) from courts_live` → 20.
6. **Put the URL and anon key into `assets/js/config.js`** (Project Settings → API). The anon key
   is a public, publishable credential; the service-role key must never leave the dashboard.
7. **Open the page**: the sidebar reads "Shared data"; a report on one browser shows on another
   within 5 minutes (or on reload); "Pickups here" appears on each public court.

## Keeping it honest

- Never grant `anon`/`authenticated` anything beyond what the migrations grant; if you add a
  table, enable RLS before anything else (Supabase's default privileges make a new table readable
  and writable otherwise).
- Add columns and functions with a new numbered migration; never edit a migration that has run.
- After any change, run `sh scripts/check.sh --backend` locally: it applies every migration to a
  throwaway PostgreSQL and runs the 2021 flows and the cross-user refusal matrix
  (`test/backend/t_*.sql`).
- Secrets: nothing in this folder is secret. `config.js` holds public values only.

## Upgrading an anonymous visitor to an account (M2, FR-61)

`Backend.linkEmail(email)` calls `auth.updateUser({ email })` on the anonymous session: the user
id does not change, so reports, profile and pickups follow the player. Supabase sends a
confirmation email; once confirmed the user is no longer anonymous and `profiles.is_anonymous`
is refreshed on the next `upsert_profile`. The page does not expose this yet; it is the first
item of M4's delivery work.
