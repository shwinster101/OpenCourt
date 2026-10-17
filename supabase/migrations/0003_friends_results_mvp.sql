-- 0003 — friends, results and MVP (migration step M3; FOUNDATION FR-70–72, FR-90–95). Additive.
-- The 2021 model, with the rules it skipped: team membership recorded, one vote per attendee,
-- no self-vote, ties broken among the leaders only, standing derived never hand-edited.

-- ---------------------------------------------------------------------------------------------
-- friendships — directed edges; one edge = pending request, both edges = friends
-- ---------------------------------------------------------------------------------------------
create table public.friendships (
  requester_id  uuid not null references public.profiles (id) on delete cascade,
  addressee_id  uuid not null references public.profiles (id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);
create index friendships_addressee_idx on public.friendships (addressee_id);

alter table public.friendships enable row level security;
revoke all on public.friendships from anon, authenticated;
grant select on public.friendships to authenticated;
create policy friendships_read_mine on public.friendships
  for select to authenticated using (requester_id = auth.uid() or addressee_id = auth.uid());
-- Writes only through the functions below.

create or replace function public.are_friends(p_a uuid, p_b uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.friendships where requester_id = p_a and addressee_id = p_b)
     and exists (select 1 from public.friendships where requester_id = p_b and addressee_id = p_a);
$$;
revoke all on function public.are_friends(uuid, uuid) from public, anon, authenticated;
grant execute on function public.are_friends(uuid, uuid) to authenticated;

-- 'friends' | 'pending_out' (I asked) | 'pending_in' (they asked) | 'none'
create or replace function public.friend_status(p_other uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when public.are_friends(auth.uid(), p_other) then 'friends'
    when exists (select 1 from public.friendships where requester_id = auth.uid() and addressee_id = p_other) then 'pending_out'
    when exists (select 1 from public.friendships where requester_id = p_other and addressee_id = auth.uid()) then 'pending_in'
    else 'none' end;
$$;
revoke all on function public.friend_status(uuid) from public, anon, authenticated;
grant execute on function public.friend_status(uuid) to authenticated;

create or replace function public.send_friend_request(p_addressee uuid)
returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := public.require_profile();
begin
  if p_addressee = v_uid then
    raise exception 'cannot_friend_self' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles where id = p_addressee) then
    raise exception 'unknown_player' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.friendships where requester_id = v_uid and addressee_id = p_addressee) then
    raise exception 'already_requested' using errcode = 'P0001';
  end if;
  insert into public.friendships (requester_id, addressee_id) values (v_uid, p_addressee);
  if exists (select 1 from public.friendships where requester_id = p_addressee and addressee_id = v_uid) then
    -- They had already asked: this completes the friendship.
    perform public.notify(p_addressee, 'friend_accepted', v_uid, null);
    return 'friends';
  end if;
  perform public.notify(p_addressee, 'friend_request', v_uid, null);
  return 'pending_out';
end $$;
revoke all on function public.send_friend_request(uuid) from public, anon, authenticated;
grant execute on function public.send_friend_request(uuid) to authenticated;

create or replace function public.accept_friend_request(p_requester uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := public.require_profile();
begin
  if not exists (select 1 from public.friendships where requester_id = p_requester and addressee_id = v_uid) then
    raise exception 'no_request' using errcode = 'P0002';
  end if;
  insert into public.friendships (requester_id, addressee_id) values (v_uid, p_requester)
  on conflict do nothing;
  perform public.notify(p_requester, 'friend_accepted', v_uid, null);
end $$;
revoke all on function public.accept_friend_request(uuid) from public, anon, authenticated;
grant execute on function public.accept_friend_request(uuid) to authenticated;

create or replace function public.reject_friend_request(p_requester uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := public.require_profile();
begin
  if public.are_friends(v_uid, p_requester) then
    raise exception 'already_friends' using errcode = 'P0001', hint = 'Use remove_friend.';
  end if;
  delete from public.friendships where requester_id = p_requester and addressee_id = v_uid;
  if not found then
    raise exception 'no_request' using errcode = 'P0002';
  end if;
  perform public.notify(p_requester, 'friend_rejected', v_uid, null);
end $$;
revoke all on function public.reject_friend_request(uuid) from public, anon, authenticated;
grant execute on function public.reject_friend_request(uuid) to authenticated;

create or replace function public.cancel_friend_request(p_addressee uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := public.require_profile();
begin
  if public.are_friends(v_uid, p_addressee) then
    raise exception 'already_friends' using errcode = 'P0001', hint = 'Use remove_friend.';
  end if;
  delete from public.friendships where requester_id = v_uid and addressee_id = p_addressee;
  if not found then
    raise exception 'no_request' using errcode = 'P0002';
  end if;
end $$;
revoke all on function public.cancel_friend_request(uuid) from public, anon, authenticated;
grant execute on function public.cancel_friend_request(uuid) to authenticated;

create or replace function public.remove_friend(p_other uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := public.require_profile();
begin
  if not public.are_friends(v_uid, p_other) then
    raise exception 'not_friends' using errcode = 'P0002';
  end if;
  delete from public.friendships
  where (requester_id = v_uid and addressee_id = p_other) or (requester_id = p_other and addressee_id = v_uid);
end $$;
revoke all on function public.remove_friend(uuid) from public, anon, authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;

create or replace function public.my_friends()
returns setof public.profiles
language sql stable security definer set search_path = public, pg_temp as $$
  select pr.* from public.profiles pr
  join public.friendships f1 on f1.requester_id = auth.uid() and f1.addressee_id = pr.id
  join public.friendships f2 on f2.requester_id = pr.id and f2.addressee_id = auth.uid()
  order by pr.display_name;
$$;
revoke all on function public.my_friends() from public, anon, authenticated;
grant execute on function public.my_friends() to authenticated;

create or replace function public.incoming_friend_requests()
returns setof public.profiles
language sql stable security definer set search_path = public, pg_temp as $$
  select pr.* from public.profiles pr
  join public.friendships f on f.requester_id = pr.id and f.addressee_id = auth.uid()
  where not exists (select 1 from public.friendships r where r.requester_id = auth.uid() and r.addressee_id = pr.id)
  order by f.created_at desc;
$$;
revoke all on function public.incoming_friend_requests() from public, anon, authenticated;
grant execute on function public.incoming_friend_requests() to authenticated;

-- search_players — parameterised prefix search (2021 built this with string interpolation).
create or replace function public.search_players(p_query text)
returns setof public.profiles
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_q text := lower(btrim(coalesce(p_query, '')));
        v_like text;
begin
  if auth.uid() is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if length(v_q) < 2 then
    return;
  end if;
  v_like := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  return query
    select pr.* from public.profiles pr
    where pr.username like v_like || '%' escape '\'
       or lower(pr.display_name) like '%' || v_like || '%' escape '\'
    order by (pr.username like v_like || '%' escape '\') desc, pr.username
    limit 20;
end $$;
revoke all on function public.search_players(text) from public, anon, authenticated;
grant execute on function public.search_players(text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Results: pickup_teams + record_result
-- ---------------------------------------------------------------------------------------------
create table public.pickup_teams (
  id          bigint generated always as identity primary key,
  pickup_id   uuid not null references public.pickups (id) on delete cascade,
  team_no     smallint not null check (team_no in (1, 2)),
  set_scores  integer[] not null check (cardinality(set_scores) >= 1),
  unique (pickup_id, team_no)
);
alter table public.pickup_teams enable row level security;
revoke all on public.pickup_teams from anon, authenticated;
grant select on public.pickup_teams to anon, authenticated;
create policy pickup_teams_read on public.pickup_teams for select to anon, authenticated using (true);

create or replace function public.record_result(
  p_pickup_id uuid, p_team1 uuid[], p_team2 uuid[],
  p_team1_scores integer[], p_team2_scores integer[], p_winning_team integer)
returns public.pickups
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := public.require_profile();
  v_p   public.pickups;
  v_members uuid[] := array_cat(p_team1, p_team2);
  v_n   integer;
  r     record;
begin
  select * into v_p from public.pickups where id = p_pickup_id for update;
  if not found then
    raise exception 'unknown_pickup' using errcode = 'P0002';
  end if;
  if v_p.organiser_id <> v_uid then
    raise exception 'not_organiser' using errcode = '42501';
  end if;
  if v_p.status = 'open' and v_p.starts_at <= now() then
    update public.pickups set status = 'in_progress' where id = p_pickup_id;
    v_p.status := 'in_progress';
  end if;
  if v_p.status <> 'in_progress' then
    raise exception 'pickup_not_in_progress' using errcode = 'P0001';
  end if;
  if p_winning_team is null or p_winning_team not in (1, 2) then
    raise exception 'bad_winner' using errcode = '22023';
  end if;
  if cardinality(coalesce(p_team1, '{}')) < 1 or cardinality(coalesce(p_team2, '{}')) < 1 then
    raise exception 'teams_required' using errcode = '22023';
  end if;
  if cardinality(p_team1_scores) < 1 or cardinality(p_team1_scores) <> cardinality(p_team2_scores) then
    raise exception 'bad_scores' using errcode = '22023', hint = 'One score per set for each team.';
  end if;
  if exists (select 1 from unnest(array_cat(p_team1_scores, p_team2_scores)) s where s is null or s < 0 or s > 99) then
    raise exception 'bad_scores' using errcode = '22023';
  end if;
  select count(distinct m) into v_n from unnest(v_members) m;
  if v_n <> cardinality(v_members) then
    raise exception 'player_in_both_teams' using errcode = '22023';
  end if;
  if exists (
    select 1 from unnest(v_members) m
    where not exists (select 1 from public.pickup_attendees a
                      where a.pickup_id = p_pickup_id and a.player_id = m and a.status in ('owner', 'joined'))
  ) then
    raise exception 'member_not_attendee' using errcode = '22023';
  end if;

  insert into public.pickup_teams (pickup_id, team_no, set_scores)
  values (p_pickup_id, 1, p_team1_scores), (p_pickup_id, 2, p_team2_scores);
  update public.pickup_attendees set team_no = 1 where pickup_id = p_pickup_id and player_id = any (p_team1);
  update public.pickup_attendees set team_no = 2 where pickup_id = p_pickup_id and player_id = any (p_team2);
  delete from public.pickup_attendees where pickup_id = p_pickup_id and status = 'invited';
  update public.pickups set status = 'closed', ends_at = now(), winning_team_no = p_winning_team
  where id = p_pickup_id returning * into v_p;

  for r in select player_id from public.pickup_attendees where pickup_id = p_pickup_id and status in ('owner', 'joined') loop
    insert into public.notifications (recipient_id, kind, actor_id, pickup_id) values (r.player_id, 'vote_mvp', v_uid, p_pickup_id);
  end loop;
  perform public.log_event('RESULT_RECORDED', p_pickup_id,
    jsonb_build_object('team1', p_team1, 'team2', p_team2, 'scores', jsonb_build_array(p_team1_scores, p_team2_scores), 'winner', p_winning_team));
  return v_p;
end $$;
revoke all on function public.record_result(uuid, uuid[], uuid[], integer[], integer[], integer) from public, anon, authenticated;
grant execute on function public.record_result(uuid, uuid[], uuid[], integer[], integer[], integer) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- MVP: mvp_votes + vote_mvp + finalize
-- ---------------------------------------------------------------------------------------------
create table public.mvp_votes (
  pickup_id   uuid not null references public.pickups (id) on delete cascade,
  voter_id    uuid not null references public.profiles (id) on delete cascade,
  votee_id    uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (pickup_id, voter_id),
  check (voter_id <> votee_id)
);
alter table public.mvp_votes enable row level security;
revoke all on public.mvp_votes from anon, authenticated;
grant select on public.mvp_votes to authenticated;
create policy mvp_votes_read_own on public.mvp_votes for select to authenticated using (voter_id = auth.uid());

-- Internal: choose the MVP among the tied leaders at random, notify, log.
create or replace function public.finalize_mvp(p_pickup_id uuid)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_mvp uuid;
begin
  select votee_id into v_mvp
  from (select votee_id, count(*) as c from public.mvp_votes where pickup_id = p_pickup_id group by votee_id) t
  order by c desc, random()
  limit 1;
  if v_mvp is null then
    return null;
  end if;
  update public.pickups set mvp_id = v_mvp where id = p_pickup_id and mvp_id is null;
  if found then
    insert into public.notifications (recipient_id, kind, pickup_id) values (v_mvp, 'you_are_mvp', p_pickup_id);
    insert into public.event_log (kind, pickup_id, payload) values ('MVP_CHOSEN', p_pickup_id, jsonb_build_object('mvp_id', v_mvp));
  end if;
  return v_mvp;
end $$;
revoke all on function public.finalize_mvp(uuid) from public, anon, authenticated;

-- Returns true when this vote decided the MVP.
create or replace function public.vote_mvp(p_pickup_id uuid, p_votee uuid)
returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := public.require_profile();
  v_p   public.pickups;
begin
  select * into v_p from public.pickups where id = p_pickup_id for update;
  if not found then
    raise exception 'unknown_pickup' using errcode = 'P0002';
  end if;
  if v_p.status <> 'closed' or v_p.winning_team_no is null then
    raise exception 'pickup_not_closed' using errcode = 'P0001';
  end if;
  if v_p.mvp_id is not null then
    raise exception 'mvp_already_chosen' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.pickup_attendees where pickup_id = p_pickup_id and player_id = v_uid and status in ('owner', 'joined')) then
    raise exception 'not_an_attendee' using errcode = '42501';
  end if;
  if not exists (select 1 from public.pickup_attendees where pickup_id = p_pickup_id and player_id = p_votee and status in ('owner', 'joined')) then
    raise exception 'votee_not_attendee' using errcode = 'P0001';
  end if;
  if p_votee = v_uid then
    raise exception 'no_self_vote' using errcode = 'P0001';
  end if;
  begin
    insert into public.mvp_votes (pickup_id, voter_id, votee_id) values (p_pickup_id, v_uid, p_votee);
  exception when unique_violation then
    raise exception 'already_voted' using errcode = '23505';
  end;
  perform public.log_event('MVP_VOTE', p_pickup_id, null);
  if (select count(*) from public.mvp_votes where pickup_id = p_pickup_id)
     >= (select count(*) from public.pickup_attendees where pickup_id = p_pickup_id and status in ('owner', 'joined')) then
    perform public.finalize_mvp(p_pickup_id);
    return true;
  end if;
  return false;
end $$;
revoke all on function public.vote_mvp(uuid, uuid) from public, anon, authenticated;
grant execute on function public.vote_mvp(uuid, uuid) to authenticated;

-- Scheduled: close the vote 24 h after the result when not everyone voted (FR-91).
create or replace function public.finalize_due_mvp_votes()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; v_n integer := 0;
begin
  for r in
    select p.id from public.pickups p
    where p.status = 'closed' and p.mvp_id is null and p.ends_at < now() - interval '24 hours'
      and exists (select 1 from public.mvp_votes v where v.pickup_id = p.id)
  loop
    perform public.finalize_mvp(r.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function public.finalize_due_mvp_votes() from public, anon, authenticated;
grant execute on function public.finalize_due_mvp_votes() to service_role;

-- Scheduled: a game nobody closed is closed without a result after 24 h (it never counts).
create or replace function public.expire_stale_pickups()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n integer;
begin
  with stale as (
    update public.pickups set status = 'closed', ends_at = now()
    where status = 'in_progress' and starts_at < now() - interval '24 hours'
    returning id
  ), logged as (
    insert into public.event_log (kind, pickup_id) select 'PICKUP_EXPIRED', id from stale returning id
  )
  select count(*) into v_n from stale;
  return v_n;
end $$;
revoke all on function public.expire_stale_pickups() from public, anon, authenticated;
grant execute on function public.expire_stale_pickups() to service_role;

-- ---------------------------------------------------------------------------------------------
-- player_standing — the 2021 "GOAT score", derived (FR-92). The formula is provisional:
-- 2 points per win, 3 per MVP; change it here, never by editing a column.
-- ---------------------------------------------------------------------------------------------
create or replace view public.player_standing as
with games as (
  select a.player_id,
         count(*) filter (where p.status = 'closed' and p.winning_team_no is not null)                              as games,
         count(*) filter (where p.status = 'closed' and p.winning_team_no is not null and a.team_no = p.winning_team_no) as wins,
         count(*) filter (where p.mvp_id = a.player_id)                                                              as mvps
  from public.pickup_attendees a
  join public.pickups p on p.id = a.pickup_id
  where a.status in ('owner', 'joined')
  group by a.player_id
)
select pr.id as player_id, pr.username, pr.display_name, pr.skill,
       coalesce(g.games, 0)::int as games, coalesce(g.wins, 0)::int as wins, coalesce(g.mvps, 0)::int as mvps,
       (coalesce(g.wins, 0) * 2 + coalesce(g.mvps, 0) * 3)::int as goat_score
from public.profiles pr
left join games g on g.player_id = pr.id;
grant select on public.player_standing to authenticated;
