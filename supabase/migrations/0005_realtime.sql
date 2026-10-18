-- 0005 — realtime (M4, FOUNDATION FR-102 before any push exists; MIGRATION §5 "Realtime
-- subscription on my_notifications"). Supabase streams row changes to browsers through the
-- `supabase_realtime` publication (Realtime → Postgres Changes). Every project has the publication,
-- empty, from day one; this migration adds the three tables the page listens to. Elsewhere (the test
-- shim creates the publication too; a plain PostgreSQL without it) it only prints a notice: polling
-- keeps working, nothing else depends on it.
--
-- Postgres Changes authorises every event against each subscriber's own role and claims, so the
-- row-level security of these tables decides what a browser receives:
--   pickups           select to anon, authenticated using (true) → every visitor sees a new, started
--                     or cancelled pickup on a court;
--   pickup_attendees  select to authenticated using (true)      → a signed-in player sees joins and
--                     leaves (the counts on the court panel and the Mine list);
--   notifications     select to authenticated using (recipient_id = auth.uid()) → a player receives
--                     only their own inbox rows (the client also filters recipient_id=eq.<uid>).
-- NOT published: court_reports. Its policy (0001: court_reports_read_own) lets only the author read
-- a row, so other visitors would receive nothing; the aggregate the page reads is the courts_live
-- view, which Postgres Changes cannot stream (views are not in a publication). Reports therefore
-- stay on the 5-minute poll until a public-safe table or a broadcast carries them.
-- Also not published: event_log (owner-only), profiles, friendships, pickup_teams, mvp_votes (no
-- screen needs them live).
--
-- Each table has a primary key, so the default replica identity satisfies "publishes updates and
-- deletes". DELETE events carry no RLS check in Realtime (docs), which is why every table here is
-- either public to read (pickups) or written only by functions that never delete rows a stranger
-- should not know about (an attendee row deleted on leave names only the pickup and the player).
-- Sources: https://supabase.com/docs/guides/realtime/postgres-changes (enable a table, RLS, filters).
do $do$
declare
  t text;
  v_all boolean;
begin
  select puballtables into v_all from pg_publication where pubname = 'supabase_realtime';
  if v_all is null then
    raise notice 'realtime: no publication named supabase_realtime on this server; the page polls (inbox 60 s, courts 5 min). On Supabase the publication exists; re-run this migration there.';
    return;
  end if;
  if v_all then
    raise notice 'realtime: supabase_realtime is FOR ALL TABLES; nothing to add (consider narrowing it to pickups, pickup_attendees and notifications).';
    return;
  end if;
  foreach t in array array['pickups', 'pickup_attendees', 'notifications'] loop
    if exists (select 1 from pg_publication_tables
               where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      raise notice 'realtime: public.% is already in supabase_realtime', t;
    else
      execute format('alter publication supabase_realtime add table public.%I', t);
      raise notice 'realtime: public.% added to supabase_realtime', t;
    end if;
  end loop;
end $do$;
