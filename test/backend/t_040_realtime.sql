-- M4: realtime. 0005 adds pickups, pickup_attendees and notifications to the supabase_realtime
-- publication when it exists (the shim creates it empty, as Supabase does). court_reports stays out:
-- its RLS lets only the author read a row, so other visitors would receive nothing.
\set ON_ERROR_STOP on

begin;
select test.check(exists (select 1 from pg_publication where pubname = 'supabase_realtime' and not puballtables),
  'the shim provides an empty supabase_realtime publication, as Supabase does');
select test.check(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pickups'),
  'pickups is published');
select test.check(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pickup_attendees'),
  'pickup_attendees is published');
select test.check(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications'),
  'notifications is published');
select test.check(not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'court_reports'),
  'court_reports is not published (author-only RLS: nobody else would receive a row)');
select test.check(not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename in ('event_log', 'profiles', 'friendships', 'mvp_votes', 'pickup_teams', 'courts')),
  'no other table is published');
select test.check((select count(*) from pg_publication_tables where pubname = 'supabase_realtime') = 3,
  'exactly three tables are published');
-- What a subscriber receives is decided by the same policies that decide what they can select.
select test.check((select bool_and(c.relrowsecurity)
                   from pg_publication_tables t
                   join pg_namespace n on n.nspname = t.schemaname
                   join pg_class c on c.relnamespace = n.oid and c.relname = t.tablename
                   where t.pubname = 'supabase_realtime'),
  'every published table has row-level security enabled');
select test.check((select count(*) from pg_publication_tables t
                   join pg_namespace n on n.nspname = t.schemaname
                   join pg_class c on c.relnamespace = n.oid and c.relname = t.tablename
                   where t.pubname = 'supabase_realtime' and c.relreplident <> 'd') = 0,
  'every published table keeps the default replica identity (each has a primary key)');
select test.check((select bool_and(exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary))
                   from pg_publication_tables t
                   join pg_namespace n on n.nspname = t.schemaname
                   join pg_class c on c.relnamespace = n.oid and c.relname = t.tablename
                   where t.pubname = 'supabase_realtime'),
  'every published table has a primary key, so updates and deletes still run under the publication');
commit;

-- A published table that lacked a replica identity would refuse UPDATE/DELETE at plan time; these
-- statements touch no row and prove the three tables still accept writes under the publication.
begin;
update public.pickups set note = note where false;
update public.pickup_attendees set team_no = team_no where false;
update public.notifications set read_at = read_at where false;
delete from public.notifications where false;
select test.check(true, 'updates and deletes plan on every published table');
rollback;

-- Re-running 0005 is a no-op: the tables are already members and the block reports, not raises.
begin;
do $do$
declare t text; v_all boolean;
begin
  select puballtables into v_all from pg_publication where pubname = 'supabase_realtime';
  if v_all is null or v_all then return; end if;
  foreach t in array array['pickups', 'pickup_attendees', 'notifications'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $do$;
select test.check((select count(*) from pg_publication_tables where pubname = 'supabase_realtime') = 3,
  'the 0005 block is idempotent: a second run leaves three tables');
commit;

-- The publication changes no client privilege: a visitor still cannot read another player's inbox
-- or write any of the three tables directly.
begin;
select test.login(test.get('C')::uuid);
select test.check((select count(*) from public.notifications where recipient_id <> auth.uid()) = 0,
  'C reads only their own notifications through the published table');
select test.expect_error($$insert into public.notifications (recipient_id, kind) values (auth.uid(), 'joined')$$, '42501',
  'no direct insert into notifications after publishing it');
select test.expect_error($$insert into public.pickup_attendees (pickup_id, player_id, status) values (test.get('p4')::uuid, auth.uid(), 'joined')$$, '42501',
  'no direct insert into pickup_attendees after publishing it');
commit;
