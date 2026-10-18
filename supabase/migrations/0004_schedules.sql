-- 0004 — the clock (FR-84, FR-91). On Supabase, enable the pg_cron extension (Database →
-- Extensions) before running this; elsewhere it only prints a notice and the three functions
-- must be called by an external scheduler:
--   select public.start_due_pickups();        -- every minute
--   select public.finalize_due_mvp_votes();   -- every 15 minutes
--   select public.expire_stale_pickups();     -- hourly
do $do$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('pickups-start-due',      '* * * * *',    $cron$ select public.start_due_pickups(); $cron$);
    perform cron.schedule('pickups-finalize-mvp',   '*/15 * * * *', $cron$ select public.finalize_due_mvp_votes(); $cron$);
    perform cron.schedule('pickups-expire-stale',   '0 * * * *',    $cron$ select public.expire_stale_pickups(); $cron$);
    raise notice 'pg_cron jobs scheduled: pickups-start-due, pickups-finalize-mvp, pickups-expire-stale';
  else
    raise notice 'pg_cron is not available on this server; schedule start_due_pickups(), finalize_due_mvp_votes() and expire_stale_pickups() externally.';
  end if;
end $do$;
