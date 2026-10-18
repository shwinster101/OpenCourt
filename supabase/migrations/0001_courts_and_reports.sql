-- 0001 — courts and crowd reports (migration step M1; FOUNDATION FR-60, FR-62, FR-63, DR-10, DR-11;
-- SRS FR-25, FR-34–36). Additive only. Every table has row-level security; writes that carry a rule
-- go through security-definer functions that read auth.uid(), never a client-supplied id.
--
-- Runs on Supabase Postgres (15+) and on a plain PostgreSQL 16 with test/backend/shim.sql, which
-- provides the auth schema, the anon/authenticated/service_role roles and Supabase's default grants.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------------------------
-- Enumerations (FR-81: sports are an open enum, extended by migration)
-- ---------------------------------------------------------------------------------------------
create type public.sport as enum ('tennis', 'pickleball', 'basketball');
create type public.court_tier as enum ('free', 'low-cost', 'private');
create type public.demand_tier as enum ('low', 'medium', 'high');
-- The app's three report states are open · toss · full ("toss" is what the UI calls Mixed).
create type public.report_status as enum ('open', 'toss', 'full');

-- ---------------------------------------------------------------------------------------------
-- courts — the venue of record. Columns = assets/data/courts.json fields, verbatim (DR-04).
-- ---------------------------------------------------------------------------------------------
create table public.courts (
  id            text primary key check (id ~ '^[a-z0-9-]{3,64}$'),
  metro         text not null default 'LA',
  name          text not null,
  neighborhood  text,
  lat           double precision not null check (lat between -90 and 90),
  lng           double precision not null check (lng between -180 and 180),
  sports        public.sport[] not null check (cardinality(sports) >= 1),
  tier          public.court_tier not null,
  court_count   integer check (court_count is null or court_count between 1 and 200),
  demand_tier   public.demand_tier not null default 'medium',
  notes         text,
  source        text not null default 'curated' check (source in ('curated', 'user')),
  is_active     boolean not null default true,
  last_updated  date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.courts is 'Venue of record. A pickup happens at a court. Curated rows come from assets/data/courts.json.';
create index courts_metro_active_idx on public.courts (metro) where is_active;

-- ---------------------------------------------------------------------------------------------
-- court_reports — one row per tap. reporter_id is the (possibly anonymous) auth user.
-- ---------------------------------------------------------------------------------------------
create table public.court_reports (
  id          bigint generated always as identity primary key,
  court_id    text not null references public.courts (id) on delete cascade,
  reporter_id uuid not null default auth.uid(),
  status      public.report_status not null,
  created_at  timestamptz not null default now()
);
comment on table public.court_reports is 'Crowd availability reports. Inserted only through submit_report(); rate-limited per court per reporter.';
create index court_reports_court_time_idx on public.court_reports (court_id, created_at desc);
create index court_reports_reporter_time_idx on public.court_reports (reporter_id, created_at desc);

-- ---------------------------------------------------------------------------------------------
-- Row-level security and grants
-- ---------------------------------------------------------------------------------------------
alter table public.courts enable row level security;
alter table public.court_reports enable row level security;

-- Supabase grants all privileges on new public tables to anon/authenticated by default; the
-- revokes below make the intent explicit on any Postgres.
revoke all on public.courts from anon, authenticated;
revoke all on public.court_reports from anon, authenticated;
grant select on public.courts to anon, authenticated;
grant select on public.court_reports to authenticated;

create policy courts_read_all on public.courts
  for select to anon, authenticated using (is_active);

create policy court_reports_read_own on public.court_reports
  for select to authenticated using (reporter_id = auth.uid());
-- No insert/update/delete policies: writes go through submit_report().

-- ---------------------------------------------------------------------------------------------
-- courts_live — what fetchCourts() reads. Same field names as courts.json, with the live
-- signal computed server-side. One decay window: 90 minutes (REPORT_TTL_MINUTES in app.js).
-- The view runs with its owner's privileges on purpose: it exposes aggregates of court_reports,
-- never a reporter id.
-- ---------------------------------------------------------------------------------------------
create or replace view public.courts_live as
select
  c.id, c.metro, c.name, c.neighborhood, c.lat, c.lng,
  array_to_json(c.sports)::jsonb                      as sports,
  c.tier::text                                        as tier,
  c.court_count,
  c.demand_tier::text                                 as demand_tier,
  c.notes,
  coalesce((
    select jsonb_agg(jsonb_build_object('status', r.status, 'timestamp', r.created_at) order by r.created_at)
    from (
      select status, created_at from public.court_reports r
      where r.court_id = c.id and r.created_at > now() - interval '90 minutes'
      order by created_at desc limit 5
    ) r
  ), '[]'::jsonb)                                     as live_reports,
  (
    select jsonb_build_object('status', r.status, 'timestamp', r.created_at)
    from public.court_reports r
    where r.court_id = c.id and r.created_at > now() - interval '90 minutes'
    order by r.created_at desc limit 1
  )                                                   as last_reported_availability,
  (
    select count(*) from public.court_reports r
    where r.court_id = c.id and r.created_at > now() - interval '90 minutes'
  )::int                                              as recent_report_count
from public.courts c
where c.is_active;

grant select on public.courts_live to anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- submit_report — the only write path for reports.
--   auth required (anonymous sign-in counts); court must exist, be active and not private;
--   one report per court per reporter per 15 minutes (SRS FR-36).
-- ---------------------------------------------------------------------------------------------
create or replace function public.submit_report(p_court_id text, p_status public.report_status)
returns public.court_reports
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid  uuid := auth.uid();
  v_tier public.court_tier;
  v_row  public.court_reports;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  select tier into v_tier from public.courts where id = p_court_id and is_active;
  if not found then
    raise exception 'unknown_court' using errcode = 'P0002';
  end if;
  if v_tier = 'private' then
    raise exception 'private_court' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.court_reports
    where court_id = p_court_id and reporter_id = v_uid
      and created_at > now() - interval '15 minutes'
  ) then
    raise exception 'rate_limited' using errcode = 'P0001',
      hint = 'One report per court per device every 15 minutes.';
  end if;
  insert into public.court_reports (court_id, reporter_id, status)
  values (p_court_id, v_uid, p_status)
  returning * into v_row;
  return v_row;
end $$;

revoke all on function public.submit_report(text, public.report_status) from public;
grant execute on function public.submit_report(text, public.report_status) to authenticated;
