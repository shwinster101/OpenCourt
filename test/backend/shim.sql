-- Supabase shim for a plain PostgreSQL. Applied by test/backend/run.sh BEFORE the migrations so
-- that supabase/migrations/*.sql run unchanged here and on Supabase.
--
-- It provides: the anon / authenticated / service_role roles, the auth schema with auth.users,
-- auth.uid(), auth.jwt() and auth.role() reading request.jwt.claims the way Supabase sets it,
-- Supabase's default grants on the public schema, and a test schema with login helpers.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

grant usage on schema public to anon, authenticated, service_role;
-- Supabase's default privileges: everything on new public objects to the three roles. Our
-- migrations therefore revoke explicitly where a table must not be written directly.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

create schema auth;
create table auth.users (
  id            uuid primary key default gen_random_uuid(),
  email         text,
  is_anonymous  boolean not null default false,
  created_at    timestamptz not null default now()
);

create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select auth.jwt() ->> 'role'
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;

-- Supabase creates an empty `supabase_realtime` publication in every project; 0005_realtime.sql adds
-- tables to it when it exists. Provided here so that branch runs in the tests (t_040). The throwaway
-- cluster runs with the default wal_level, which only draws a "wal_level is insufficient" warning:
-- the publication is created all the same, and nothing here replicates.
do $$ begin set local client_min_messages = error; create publication supabase_realtime; end $$;

-- ---------------------------------------------------------------------------------------------
-- test helpers (not part of the product)
-- ---------------------------------------------------------------------------------------------
create schema test;

-- Scratch variables shared between the transactions of one test file.
create table test.vars (k text primary key, v text);
create or replace function test.set(p_k text, p_v text) returns void language sql as $$
  insert into test.vars (k, v) values (p_k, p_v) on conflict (k) do update set v = excluded.v;
$$;
create or replace function test.get(p_k text) returns text language sql stable as $$
  select v from test.vars where k = p_k;
$$;

-- Become an authenticated user for the rest of the current transaction.
create or replace function test.login(p_uid uuid, p_anonymous boolean default false)
returns void language plpgsql as $$
begin
  execute 'reset role';
  insert into auth.users (id, is_anonymous) values (p_uid, p_anonymous) on conflict (id) do nothing;
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', p_uid, 'role', 'authenticated', 'is_anonymous', p_anonymous)::text, true);
  execute 'set local role authenticated';
end $$;

-- Become an anonymous visitor (no session at all) for the rest of the current transaction.
create or replace function test.anon()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
end $$;

-- Back to the superuser inside the same transaction.
create or replace function test.admin()
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Assert helper: raises with a readable message.
create or replace function test.check(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if p_ok is distinct from true then
    raise exception 'ASSERTION FAILED: %', p_what;
  end if;
  raise notice 'ok — %', p_what;
end $$;

-- Expect a function call to raise an error whose message starts with p_error.
create or replace function test.expect_error(p_sql text, p_error text, p_what text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like p_error || '%' or sqlstate = p_error then
      raise notice 'ok — % (raised %)', p_what, sqlerrm;
      return;
    end if;
    raise exception 'ASSERTION FAILED: % — expected error "%", got "%"', p_what, p_error, sqlerrm;
  end;
  raise exception 'ASSERTION FAILED: % — expected error "%", nothing was raised', p_what, p_error;
end $$;

grant usage on schema test to anon, authenticated, service_role;
grant select, insert, update on test.vars to anon, authenticated, service_role;
grant execute on all functions in schema test to anon, authenticated, service_role;
