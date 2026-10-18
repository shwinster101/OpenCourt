-- 0004 — the clock (FR-84, FR-91). On Supabase, enable the pg_cron extension (Database →
-- Extensions) before running this; elsewhere it only prints a notice and the three functions
-- must be called by an external scheduler:
--   select public.start_due_pickups();        -- every minute
--   select public.finalize_due_mvp_votes();   -- every 15 minutes
--   select public.expire_stale_pickups();     -- hourly
-- Never fatal (2026-10-18): the first real run hit a privilege error here and left the project half
-- provisioned. If pg_cron cannot be created or used by this role, the block says so and the rest of
-- the schema still lands; re-post this file later (cron.schedule upserts by job name), e.g. with
-- scripts/provision-supabase.sh --schedule.
do $do$
declare
  usable boolean := false;
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available on this server; schedule start_due_pickups(), finalize_due_mvp_votes() and expire_stale_pickups() externally.';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron could not be created by this role (%): enable it in the dashboard, then re-run this file.', sqlerrm;
  end;
  select exists(select 1 from pg_extension where extname = 'pg_cron') and has_schema_privilege('cron', 'usage') into usable;
  if not usable then
    raise notice 'pg_cron is installed but not usable by this role (or not installed); enable it in the dashboard, then re-run this file.';
    return;
  end if;
  begin
    perform cron.schedule('pickups-start-due',      '* * * * *',    $cron$ select public.start_due_pickups(); $cron$);
    perform cron.schedule('pickups-finalize-mvp',   '*/15 * * * *', $cron$ select public.finalize_due_mvp_votes(); $cron$);
    perform cron.schedule('pickups-expire-stale',   '0 * * * *',    $cron$ select public.expire_stale_pickups(); $cron$);
    raise notice 'pg_cron jobs scheduled: pickups-start-due, pickups-finalize-mvp, pickups-expire-stale';
  exception when others then
    raise notice 'pg_cron jobs could not be scheduled (%); re-run this file once pg_cron is enabled in the dashboard.', sqlerrm;
  end;
end $do$;
