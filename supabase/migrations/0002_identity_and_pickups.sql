-- 0002 — identity and pickups (migration step M2; FOUNDATION FR-61–64, FR-80–88, FR-100–101,
-- DR-12). Additive only.
--
-- Identity: a profile is keyed by the auth user id (anonymous sign-ins included: SRS FR-51's
-- "nickname + skill"). The owner can tighten pickups to non-anonymous accounts later by changing
-- require_profile(); nothing else depends on it.
-- Every rule 2021 skipped lives here, in SQL, under auth.uid(): organiser-only cancel/invite,
-- invitee-only respond, capacity at join time under a row lock, start by the database clock.

-- ---------------------------------------------------------------------------------------------
-- Shared trigger: updated_at
-- ---------------------------------------------------------------------------------------------
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
revoke all on function public.set_updated_at() from public, anon, authenticated;

create trigger courts_updated_at before update on public.courts
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  username      text not null check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name  text not null check (length(display_name) between 1 and 40),
  photo_url     text check (photo_url is null or photo_url ~ '^https://'),
  metro         text not null default 'LA',
  skill         smallint check (skill is null or skill between 1 and 5),
  is_anonymous  boolean not null default false,
  search        tsvector generated always as (to_tsvector('simple', coalesce(display_name, '') || ' ' || coalesce(username, ''))) stored,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.profiles is 'A player. id = auth.users.id (anonymous or not). Usernames are lowercase and unique.';
create unique index profiles_username_key on public.profiles (username);
create index profiles_search_idx on public.profiles using gin (search);
create trigger profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, photo_url, skill, metro) on public.profiles to authenticated;

create policy profiles_read on public.profiles
  for select to authenticated using (true);
create policy profiles_update_own on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
-- Insert only through upsert_profile() (it validates and lowercases the username).

-- ---------------------------------------------------------------------------------------------
-- Enumerations
-- ---------------------------------------------------------------------------------------------
create type public.pickup_status as enum ('open', 'in_progress', 'closed', 'cancelled');
create type public.attendee_status as enum ('owner', 'invited', 'joined');
create type public.notification_kind as enum (
  'friend_request', 'friend_accepted', 'friend_rejected',
  'invitation', 'joined', 'left', 'cancelled',
  'enter_result', 'vote_mvp', 'you_are_mvp'
);

-- ---------------------------------------------------------------------------------------------
-- pickups — a game at a court (2021 `events`, with the court instead of a free-text place)
-- ---------------------------------------------------------------------------------------------
create table public.pickups (
  id               uuid primary key default gen_random_uuid(),
  court_id         text not null references public.courts (id),
  organiser_id     uuid not null references public.profiles (id),
  sport            public.sport not null,
  starts_at        timestamptz not null,
  ends_at          timestamptz,
  capacity         integer not null check (capacity between 2 and 30),
  note             text check (note is null or length(note) <= 280),
  status           public.pickup_status not null default 'open',
  share_token      text not null unique default encode(gen_random_bytes(8), 'hex'),
  winning_team_no  smallint check (winning_team_no is null or winning_team_no in (1, 2)),
  mvp_id           uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on table public.pickups is 'A pickup game. capacity counts every player including the organiser. Written only through functions.';
create index pickups_court_status_idx on public.pickups (court_id, status, starts_at);
create index pickups_due_idx on public.pickups (starts_at) where status = 'open';
create index pickups_organiser_idx on public.pickups (organiser_id);
create trigger pickups_updated_at before update on public.pickups
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- pickup_attendees — the roster (2021 `event_attendees`; `ok` is now `joined`, `conflict` is gone)
-- ---------------------------------------------------------------------------------------------
create table public.pickup_attendees (
  pickup_id   uuid not null references public.pickups (id) on delete cascade,
  player_id   uuid not null references public.profiles (id) on delete cascade,
  status      public.attendee_status not null,
  invited_by  uuid references public.profiles (id) on delete set null,
  team_no     smallint check (team_no is null or team_no in (1, 2)),
  joined_at   timestamptz,
  created_at  timestamptz not null default now(),
  primary key (pickup_id, player_id)
);
create index pickup_attendees_player_idx on public.pickup_attendees (player_id);

-- ---------------------------------------------------------------------------------------------
-- notifications — in-app inbox; written only by functions in the same transaction as the change
-- ---------------------------------------------------------------------------------------------
create table public.notifications (
  id            bigint generated always as identity primary key,
  recipient_id  uuid not null references public.profiles (id) on delete cascade,
  actor_id      uuid references public.profiles (id) on delete set null,
  pickup_id     uuid references public.pickups (id) on delete cascade,
  kind          public.notification_kind not null,
  created_at    timestamptz not null default now(),
  read_at       timestamptz
);
create index notifications_inbox_idx on public.notifications (recipient_id, read_at, created_at desc);

-- ---------------------------------------------------------------------------------------------
-- event_log — append-only audit (2021 `domain_events` without the relay)
-- ---------------------------------------------------------------------------------------------
create table public.event_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor_id   uuid,
  kind       text not null,
  pickup_id  uuid,
  payload    jsonb
);
create index event_log_pickup_idx on public.event_log (pickup_id, at);

-- ---------------------------------------------------------------------------------------------
-- Row-level security and grants
-- ---------------------------------------------------------------------------------------------
alter table public.pickups enable row level security;
alter table public.pickup_attendees enable row level security;
alter table public.notifications enable row level security;
alter table public.event_log enable row level security;

revoke all on public.pickups from anon, authenticated;
revoke all on public.pickup_attendees from anon, authenticated;
revoke all on public.notifications from anon, authenticated;
revoke all on public.event_log from anon, authenticated;

grant select on public.pickups to anon, authenticated;
grant select on public.pickup_attendees to authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

create policy pickups_read on public.pickups
  for select to anon, authenticated using (true);
create policy attendees_read on public.pickup_attendees
  for select to authenticated using (true);
create policy notifications_read_own on public.notifications
  for select to authenticated using (recipient_id = auth.uid());
create policy notifications_mark_own on public.notifications
  for update to authenticated using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());
-- event_log: no policies, no grants: owner-only.

-- ---------------------------------------------------------------------------------------------
-- Internal helpers (not callable by clients)
-- ---------------------------------------------------------------------------------------------
create or replace function public.require_profile() returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'profile_required' using errcode = '42501',
      hint = 'Call upsert_profile(username, display_name) first.';
  end if;
  return v_uid;
end $$;
revoke all on function public.require_profile() from public, anon, authenticated;

create or replace function public.log_event(p_kind text, p_pickup_id uuid, p_payload jsonb default null)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.event_log (actor_id, kind, pickup_id, payload) values (auth.uid(), p_kind, p_pickup_id, p_payload);
$$;
revoke all on function public.log_event(text, uuid, jsonb) from public, anon, authenticated;

create or replace function public.notify(p_recipient uuid, p_kind public.notification_kind, p_actor uuid, p_pickup_id uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.notifications (recipient_id, kind, actor_id, pickup_id)
  select p_recipient, p_kind, p_actor, p_pickup_id
  where p_recipient is not null and p_recipient is distinct from p_actor;
$$;
revoke all on function public.notify(uuid, public.notification_kind, uuid, uuid) from public, anon, authenticated;

create or replace function public.joined_count(p_pickup_id uuid) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int from public.pickup_attendees
  where pickup_id = p_pickup_id and status in ('owner', 'joined');
$$;
revoke all on function public.joined_count(uuid) from public, anon, authenticated;
grant execute on function public.joined_count(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- upsert_profile — create or update my profile (the only insert path)
-- ---------------------------------------------------------------------------------------------
create or replace function public.upsert_profile(
  p_username text, p_display_name text, p_photo_url text default null,
  p_skill integer default null, p_metro text default 'LA')
returns public.profiles
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid  uuid := auth.uid();
  v_user text := lower(btrim(p_username));
  v_anon boolean := coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
  v_row  public.profiles;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if v_user !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'invalid_username' using errcode = '22023',
      hint = '3–20 characters: a–z, 0–9, underscore.';
  end if;
  if p_skill is not null and p_skill not between 1 and 5 then
    raise exception 'invalid_skill' using errcode = '22023', hint = '1 (new) to 5 (competitive).';
  end if;
  begin
    insert into public.profiles (id, username, display_name, photo_url, skill, metro, is_anonymous)
    values (v_uid, v_user, btrim(p_display_name), p_photo_url, p_skill::smallint, coalesce(p_metro, 'LA'), v_anon)
    on conflict (id) do update set
      username = excluded.username, display_name = excluded.display_name,
      photo_url = excluded.photo_url, skill = excluded.skill, metro = excluded.metro,
      is_anonymous = excluded.is_anonymous
    returning * into v_row;
  exception when unique_violation then
    raise exception 'username_taken' using errcode = '23505';
  end;
  return v_row;
end $$;
revoke all on function public.upsert_profile(text, text, text, integer, text) from public, anon, authenticated;
grant execute on function public.upsert_profile(text, text, text, integer, text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- create_pickup
-- ---------------------------------------------------------------------------------------------
create or replace function public.create_pickup(
  p_court_id text, p_sport public.sport, p_starts_at timestamptz, p_capacity integer, p_note text default null)
returns public.pickups
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid    uuid := public.require_profile();
  v_court  public.courts;
  v_pickup public.pickups;
begin
  select * into v_court from public.courts where id = p_court_id and is_active;
  if not found then
    raise exception 'unknown_court' using errcode = 'P0002';
  end if;
  if v_court.tier = 'private' then
    raise exception 'private_court' using errcode = 'P0001';
  end if;
  if not (p_sport = any (v_court.sports)) then
    raise exception 'sport_not_at_court' using errcode = 'P0001';
  end if;
  if p_starts_at < now() - interval '15 minutes' then
    raise exception 'starts_in_past' using errcode = 'P0001';
  end if;
  if p_starts_at > now() + interval '30 days' then
    raise exception 'too_far_ahead' using errcode = 'P0001';
  end if;
  insert into public.pickups (court_id, organiser_id, sport, starts_at, capacity, note)
  values (p_court_id, v_uid, p_sport, p_starts_at, p_capacity, nullif(btrim(p_note), ''))
  returning * into v_pickup;
  insert into public.pickup_attendees (pickup_id, player_id, status, joined_at)
  values (v_pickup.id, v_uid, 'owner', now());
  perform public.log_event('PICKUP_CREATED', v_pickup.id, jsonb_build_object('court_id', p_court_id, 'sport', p_sport));
  return v_pickup;
end $$;
revoke all on function public.create_pickup(text, public.sport, timestamptz, integer, text) from public, anon, authenticated;
grant execute on function public.create_pickup(text, public.sport, timestamptz, integer, text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- join_pickup / leave_pickup
-- ---------------------------------------------------------------------------------------------
create or replace function public.join_pickup(p_pickup_id uuid)
returns public.pickup_attendees
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid  uuid := public.require_profile();
  v_p    public.pickups;
  v_mine public.attendee_status;
  v_row  public.pickup_attendees;
begin
  select * into v_p from public.pickups where id = p_pickup_id for update;
  if not found then
    raise exception 'unknown_pickup' using errcode = 'P0002';
  end if;
  if v_p.status <> 'open' then
    raise exception 'pickup_not_open' using errcode = 'P0001';
  end if;
  select status into v_mine from public.pickup_attendees where pickup_id = p_pickup_id and player_id = v_uid;
  if v_mine in ('owner', 'joined') then
    raise exception 'already_joined' using errcode = 'P0001';
  end if;
  if public.joined_count(p_pickup_id) >= v_p.capacity then
    raise exception 'pickup_full' using errcode = 'P0001';
  end if;
  if v_mine = 'invited' then
    update public.pickup_attendees set status = 'joined', joined_at = now()
    where pickup_id = p_pickup_id and player_id = v_uid returning * into v_row;
  else
    insert into public.pickup_attendees (pickup_id, player_id, status, joined_at)
    values (p_pickup_id, v_uid, 'joined', now()) returning * into v_row;
  end if;
  perform public.notify(v_p.organiser_id, 'joined', v_uid, p_pickup_id);
  perform public.log_event('PLAYER_JOINED', p_pickup_id, null);
  return v_row;
end $$;
revoke all on function public.join_pickup(uuid) from public, anon, authenticated;
grant execute on function public.join_pickup(uuid) to authenticated;

create or replace function public.leave_pickup(p_pickup_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid  uuid := public.require_profile();
  v_p    public.pickups;
  v_mine public.attendee_status;
begin
  select * into v_p from public.pickups where id = p_pickup_id for update;
  if not found then
    raise exception 'unknown_pickup' using errcode = 'P0002';
  end if;
  if v_p.status not in ('open', 'in_progress') then
    raise exception 'pickup_not_open' using errcode = 'P0001';
  end if;
  select status into v_mine from public.pickup_attendees where pickup_id = p_pickup_id and player_id = v_uid;
  if v_mine = 'owner' then
    raise exception 'organiser_cannot_leave' using errcode = 'P0001', hint = 'Cancel the pickup instead.';
  end if;
  if v_mine is distinct from 'joined' then
    raise exception 'not_joined' using errcode = 'P0001';
  end if;
  delete from public.pickup_attendees where pickup_id = p_pickup_id and player_id = v_uid;
  perform public.notify(v_p.organiser_id, 'left', v_uid, p_pickup_id);
  perform public.log_event('PLAYER_LEFT', p_pickup_id, null);
end $$;
revoke all on function public.leave_pickup(uuid) from public, anon, authenticated;
grant execute on function public.leave_pickup(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- cancel_pickup (organiser only)
-- ---------------------------------------------------------------------------------------------
create or replace function public.cancel_pickup(p_pickup_id uuid)
returns public.pickups
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := public.require_profile();
  v_p   public.pickups;
  r     record;
begin
  select * into v_p from public.pickups where id = p_pickup_id for update;
  if not found then
    raise exception 'unknown_pickup' using errcode = 'P0002';
  end if;
  if v_p.organiser_id <> v_uid then
    raise exception 'not_organiser' using errcode = '42501';
  end if;
  if v_p.status not in ('open', 'in_progress') then
    raise exception 'pickup_not_open' using errcode = 'P0001';
  end if;
  update public.pickups set status = 'cancelled' where id = p_pickup_id returning * into v_p;
  for r in select player_id from public.pickup_attendees where pickup_id = p_pickup_id and player_id <> v_uid loop
    perform public.notify(r.player_id, 'cancelled', v_uid, p_pickup_id);
  end loop;
  perform public.log_event('PICKUP_CANCELLED', p_pickup_id, null);
  return v_p;
end $$;
revoke all on function public.cancel_pickup(uuid) from public, anon, authenticated;
grant execute on function public.cancel_pickup(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Invitations: invite (organiser), cancel_invitation (organiser), respond (invitee)
-- ---------------------------------------------------------------------------------------------
create or replace function public.invite_to_pickup(p_pickup_id uuid, p_player_id uuid)
returns public.pickup_attendees
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := public.require_profile();
  v_p   public.pickups;
  v_row public.pickup_attendees;
begin
  select * into v_p from public.pickups where id = p_pickup_id for update;
  if not found then
    raise exception 'unknown_pickup' using errcode = 'P0002';
  end if;
  if v_p.organiser_id <> v_uid then
    raise exception 'not_organiser' using errcode = '42501';
  end if;
  if v_p.status <> 'open' then
    raise exception 'pickup_not_open' using errcode = 'P0001';
  end if;
  if p_player_id = v_uid then
    raise exception 'cannot_invite_self' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles where id = p_player_id) then
    raise exception 'unknown_player' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.pickup_attendees where pickup_id = p_pickup_id and player_id = p_player_id) then
    raise exception 'already_attendee' using errcode = 'P0001';
  end if;
  insert into public.pickup_attendees (pickup_id, player_id, status, invited_by)
  values (p_pickup_id, p_player_id, 'invited', v_uid) returning * into v_row;
  perform public.notify(p_player_id, 'invitation', v_uid, p_pickup_id);
  perform public.log_event('PLAYER_INVITED', p_pickup_id, jsonb_build_object('player_id', p_player_id));
  return v_row;
end $$;
revoke all on function public.invite_to_pickup(uuid, uuid) from public, anon, authenticated;
grant execute on function public.invite_to_pickup(uuid, uuid) to authenticated;

create or replace function public.cancel_invitation(p_pickup_id uuid, p_player_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := public.require_profile();
  v_p   public.pickups;
begin
  select * into v_p from public.pickups where id = p_pickup_id for update;
  if not found then
    raise exception 'unknown_pickup' using errcode = 'P0002';
  end if;
  if v_p.organiser_id <> v_uid then
    raise exception 'not_organiser' using errcode = '42501';
  end if;
  delete from public.pickup_attendees
  where pickup_id = p_pickup_id and player_id = p_player_id and status = 'invited';
  if not found then
    raise exception 'no_invitation' using errcode = 'P0002';
  end if;
  perform public.log_event('INVITATION_CANCELLED', p_pickup_id, jsonb_build_object('player_id', p_player_id));
end $$;
revoke all on function public.cancel_invitation(uuid, uuid) from public, anon, authenticated;
grant execute on function public.cancel_invitation(uuid, uuid) to authenticated;

create or replace function public.respond_to_invitation(p_pickup_id uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid  uuid := public.require_profile();
  v_p    public.pickups;
  v_mine public.attendee_status;
begin
  select * into v_p from public.pickups where id = p_pickup_id for update;
  if not found then
    raise exception 'unknown_pickup' using errcode = 'P0002';
  end if;
  select status into v_mine from public.pickup_attendees where pickup_id = p_pickup_id and player_id = v_uid;
  if v_mine is distinct from 'invited' then
    raise exception 'no_invitation' using errcode = 'P0002';
  end if;
  if p_accept then
    if v_p.status <> 'open' then
      raise exception 'pickup_not_open' using errcode = 'P0001';
    end if;
    if public.joined_count(p_pickup_id) >= v_p.capacity then
      raise exception 'pickup_full' using errcode = 'P0001';
    end if;
    update public.pickup_attendees set status = 'joined', joined_at = now()
    where pickup_id = p_pickup_id and player_id = v_uid;
    perform public.notify(v_p.organiser_id, 'joined', v_uid, p_pickup_id);
    perform public.log_event('INVITATION_ACCEPTED', p_pickup_id, null);
  else
    delete from public.pickup_attendees where pickup_id = p_pickup_id and player_id = v_uid;
    perform public.log_event('INVITATION_DECLINED', p_pickup_id, null);
  end if;
end $$;
revoke all on function public.respond_to_invitation(uuid, boolean) from public, anon, authenticated;
grant execute on function public.respond_to_invitation(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- start_due_pickups — the database clock replaces 2021's in-process timers (FR-84).
-- Scheduled by 0004 (pg_cron) or called by any trusted scheduler. Not callable by clients.
-- ---------------------------------------------------------------------------------------------
create or replace function public.start_due_pickups()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n integer;
begin
  with due as (
    update public.pickups set status = 'in_progress'
    where status = 'open' and starts_at <= now()
    returning id, organiser_id
  ), noted as (
    insert into public.notifications (recipient_id, kind, pickup_id)
    select organiser_id, 'enter_result', id from due
    returning pickup_id
  ), logged as (
    insert into public.event_log (kind, pickup_id) select 'PICKUP_STARTED', id from due returning id
  )
  select count(*) into v_n from due;
  return v_n;
end $$;
revoke all on function public.start_due_pickups() from public, anon, authenticated;
grant execute on function public.start_due_pickups() to service_role;

-- ---------------------------------------------------------------------------------------------
-- mark_notifications_read
-- ---------------------------------------------------------------------------------------------
create or replace function public.mark_notifications_read(p_ids bigint[])
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_n integer;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  update public.notifications set read_at = now()
  where id = any (p_ids) and recipient_id = v_uid and read_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.mark_notifications_read(bigint[]) from public, anon, authenticated;
grant execute on function public.mark_notifications_read(bigint[]) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------------------------
-- Public board: open and in-progress pickups (no share token, no ids beyond the pickup's own).
create or replace view public.open_pickups as
select
  p.id, p.court_id, c.name as court_name, c.lat, c.lng, p.sport::text as sport,
  p.starts_at, p.capacity, p.note, p.status::text as status,
  pr.username as organiser_username, pr.display_name as organiser_name,
  public.joined_count(p.id) as joined_count,
  greatest(p.capacity - public.joined_count(p.id), 0) as spots_left,
  p.created_at
from public.pickups p
join public.courts c on c.id = p.court_id
join public.profiles pr on pr.id = p.organiser_id
where p.status in ('open', 'in_progress') and p.starts_at > now() - interval '6 hours';
grant select on public.open_pickups to anon, authenticated;

-- My pickups, with my status and the share token (runs as the caller: RLS applies).
create view public.my_pickups with (security_invoker = true) as
select
  p.id, p.court_id, c.name as court_name, p.sport::text as sport, p.starts_at, p.ends_at, p.capacity,
  p.note, p.status::text as status, p.share_token, p.organiser_id, p.winning_team_no, p.mvp_id,
  a.status::text as my_status, a.team_no as my_team_no,
  public.joined_count(p.id) as joined_count
from public.pickup_attendees a
join public.pickups p on p.id = a.pickup_id
join public.courts c on c.id = p.court_id
where a.player_id = auth.uid();
grant select on public.my_pickups to authenticated;

-- My inbox.
create view public.my_notifications with (security_invoker = true) as
select
  n.id, n.kind::text as kind, n.created_at, n.read_at, n.pickup_id,
  a.username as actor_username, a.display_name as actor_name,
  p.court_id, c.name as court_name, p.starts_at as pickup_starts_at, p.sport::text as pickup_sport
from public.notifications n
left join public.profiles a on a.id = n.actor_id
left join public.pickups p on p.id = n.pickup_id
left join public.courts c on c.id = p.court_id
where n.recipient_id = auth.uid();
grant select on public.my_notifications to authenticated;

-- Deep link: one pickup by its share token (anonymous visitors included).
create or replace function public.pickup_by_token(p_token text)
returns table (
  id uuid, court_id text, court_name text, lat double precision, lng double precision, sport text,
  starts_at timestamptz, capacity integer, note text, status text,
  organiser_username text, organiser_name text, joined_count integer, spots_left integer)
language sql stable security definer set search_path = public, pg_temp as $$
  select p.id, p.court_id, c.name, c.lat, c.lng, p.sport::text, p.starts_at, p.capacity, p.note, p.status::text,
         pr.username, pr.display_name, public.joined_count(p.id),
         greatest(p.capacity - public.joined_count(p.id), 0)
  from public.pickups p
  join public.courts c on c.id = p.court_id
  join public.profiles pr on pr.id = p.organiser_id
  where p.share_token = p_token;
$$;
revoke all on function public.pickup_by_token(text) from public, anon, authenticated;
grant execute on function public.pickup_by_token(text) to anon, authenticated;

-- Roster of one pickup (players only).
create or replace function public.pickup_roster(p_pickup_id uuid)
returns table (player_id uuid, username text, display_name text, status text, team_no smallint, joined_at timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select a.player_id, pr.username, pr.display_name, a.status::text, a.team_no, a.joined_at
  from public.pickup_attendees a
  join public.profiles pr on pr.id = a.player_id
  where a.pickup_id = p_pickup_id
    and auth.uid() is not null
  order by a.status, a.joined_at nulls last;
$$;
revoke all on function public.pickup_roster(uuid) from public, anon, authenticated;
grant execute on function public.pickup_roster(uuid) to authenticated;

-- courts_live gains the count of games on each court (the map marks courts with a game on).
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
  )::int                                              as recent_report_count,
  (
    select count(*) from public.pickups p
    where p.court_id = c.id and p.status in ('open', 'in_progress') and p.starts_at > now() - interval '6 hours'
  )::int                                              as open_pickup_count
from public.courts c
where c.is_active;
grant select on public.courts_live to anon, authenticated;
