-- M1: courts and crowd reports (FOUNDATION FR-60, FR-62, FR-63; SRS FR-25, FR-34–36).
-- Each block is one transaction; test.login()/test.anon() switch the caller for that transaction.
\set ON_ERROR_STOP on

-- Anonymous visitor (no session): can read, cannot write.
begin;
select test.anon();
select test.check((select count(*) from public.courts_live) = 20, 'anon reads 20 courts from courts_live');
select test.check((select bool_and(live_reports = '[]'::jsonb and last_reported_availability is null and open_pickup_count = 0) from public.courts_live),
  'fresh view has empty live_reports, null last report, no pickups');
select test.check((select jsonb_typeof(sports) from public.courts_live where id = 'memorial-park-sm') = 'array', 'sports is a JSON array');
select test.expect_error($$insert into public.court_reports (court_id, status) values ('memorial-park-sm', 'open')$$, '42501', 'anon cannot insert a report directly');
select test.expect_error($$select public.submit_report('memorial-park-sm', 'open')$$, '42501', 'anon cannot call submit_report');
select test.expect_error($$select * from public.court_reports$$, '42501', 'anon cannot read raw reports');
select test.expect_error($$update public.courts set name = 'x' where id = 'memorial-park-sm'$$, '42501', 'anon cannot edit courts');
rollback;

-- Reporter A, an anonymous sign-in (Supabase anonymous user): reports, rate limit, decay.
begin;
select test.login('aaaaaaaa-0000-0000-0000-000000000001', true);
select test.check((select status from public.submit_report('memorial-park-sm', 'toss')) = 'toss', 'A (anonymous session) submits a report');
select test.check((select last_reported_availability ->> 'status' from public.courts_live where id = 'memorial-park-sm') = 'toss', 'view shows the live report');
select test.check((select recent_report_count from public.courts_live where id = 'memorial-park-sm') = 1, 'recent_report_count is 1');
select test.expect_error($$select public.submit_report('memorial-park-sm', 'open')$$, 'rate_limited', 'a second report within 15 minutes is refused');
select test.check((select status from public.submit_report('mar-vista-rec', 'open')) = 'open', 'A can report a different court');
select test.expect_error($$select public.submit_report('does-not-exist', 'open')$$, 'unknown_court', 'an unknown court is refused');
select test.expect_error($$insert into public.court_reports (court_id, status) values ('memorial-park-sm', 'open')$$, '42501', 'authenticated cannot insert a report directly');
select test.expect_error($$update public.courts set name = 'x' where id = 'memorial-park-sm'$$, '42501', 'authenticated cannot edit courts');
select test.check((select count(*) from public.court_reports) = 2, 'A sees only own raw report rows (2)');
commit;

-- Reporter B: private courts refuse, latest report wins, raw rows are per reporter.
begin;
select test.login('aaaaaaaa-0000-0000-0000-000000000002', true);
do $$
declare v_id text;
begin
  select id into v_id from public.courts where tier = 'private' limit 1;
  perform test.expect_error(format($f$select public.submit_report(%L, 'open')$f$, v_id), 'private_court', 'a private court refuses reports');
end $$;
select test.check((select status from public.submit_report('memorial-park-sm', 'full')) = 'full', 'B reports the same court');
select test.check((select last_reported_availability ->> 'status' from public.courts_live where id = 'memorial-park-sm') = 'full', 'the latest report wins');
select test.check((select jsonb_array_length(live_reports) from public.courts_live where id = 'memorial-park-sm') = 2, 'two reports in the 90-minute window');
select test.check((select count(*) from public.court_reports) = 1, 'B sees only own raw report row');
commit;

-- Decay: age A's reports past the window (as the owner) and the signal disappears.
begin;
update public.court_reports set created_at = created_at - interval '100 minutes'
where reporter_id = 'aaaaaaaa-0000-0000-0000-000000000001';
select test.check((select recent_report_count from public.courts_live where id = 'mar-vista-rec') = 0, 'a 100-minute-old report no longer colours the court');
select test.check((select last_reported_availability is null from public.courts_live where id = 'mar-vista-rec'), 'last_reported_availability decays to null');
select test.check((select jsonb_array_length(live_reports) from public.courts_live where id = 'memorial-park-sm') = 1, 'only the fresh report remains on memorial park');
commit;

-- After the window A may report again (rate limit is 15 min on the reporter's own last report).
begin;
select test.login('aaaaaaaa-0000-0000-0000-000000000001', true);
select test.check((select status from public.submit_report('mar-vista-rec', 'full')) = 'full', 'A reports again after the window');
commit;
