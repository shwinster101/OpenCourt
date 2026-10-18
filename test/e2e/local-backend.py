#!/usr/bin/env python3
"""local-backend.py — a local stand-in for Supabase (PostgREST + GoTrue) over the real migrations.

Purpose: let two real browsers share state on this machine with no Docker and no Supabase project.
It serves the subset of PostgREST and GoTrue that assets/js/backend.js (supabase-js 2.45.4) uses,
over a throwaway PostgreSQL that test/backend/run.sh prepared (shim, migrations, seed). The REST
layer is generic over every view, table and function in schema public, so new RPCs and views work
without a change here.

Standard library only. The database is reached through a `psql` subprocess per request (psycopg2
is not installed here; see test/e2e/README.md). Every value reaches SQL as a psql variable
interpolated with :'name', which psql quotes as a literal itself; identifiers are validated against
the catalog and double-quoted. Nothing from the request is ever spliced into SQL text raw.

Each request runs in one transaction as the real database role:
    begin; select set_config('request.jwt.claims', <claims json>, true); set local role anon|authenticated;
so row-level security and auth.uid() (test/backend/shim.sql reads request.jwt.claims) behave as on
Supabase. A request without a valid bearer JWT is anon (the configured anon key is not a JWT).

GoTrue subset (paths and bodies checked against the supabase-js 2.45.4 UMD source,
https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js):
    POST /auth/v1/signup            signInAnonymously(): body {data, gotrue_meta_security} — no email → anonymous user
    GET  /auth/v1/user              getUser(): bearer token → user
    PUT  /auth/v1/user              updateUser({email}): echoes the user with new_email (no mail is sent)
    POST /auth/v1/token?grant_type=refresh_token   {refresh_token} → a fresh session, same user
    POST /auth/v1/otp               signInWithOtp(): 200 {} (no mail is sent)
    POST /auth/v1/logout            signOut(): 204
    GET  /auth/v1/settings, /auth/v1/health
JWTs are HS256 with a fixed TEST secret (claims: aud, role, sub, is_anonymous, email, iat, exp 1 h,
session_id). They are test tokens for this machine only.

PostgREST subset:
    GET  /rest/v1/<relation>?select=*|a,b&<col>=eq.v|neq.v|gt.v|gte.v|lt.v|lte.v|like.v|ilike.v|is.null|is.true|is.false|in.(a,b)
         [&<col>=not.<op>...]&order=<col>.asc|desc[.nullsfirst|nullslast]&limit=n&offset=n
         Accept: application/vnd.pgrst.object+json → one object or 406 PGRST116; Prefer: count=exact → Content-Range total
    POST /rest/v1/rpc/<fn>  JSON object of named arguments → json_to_record(...) typed from pg_proc, then
         select public.<fn>(name => value, ...): setof → array, composite → object, scalar → bare value, void → 204
    SQL errors → {"code": sqlstate, "message", "details", "hint"}: 42501 → 403 (401 when anon), P0001 and other → 400,
         PT<nnn> → nnn, 42P01/42883 → 404, 23503/23505 → 409 (as PostgREST maps them).
Not served: inserts/updates/deletes on tables (the page writes only through RPC), realtime websockets,
storage, mail. One log line per request goes to stderr (method, path, role, status, ms); never a token.

Environment: OC_BACKEND_PORT (54400), OC_ANON_KEY (local-anon), PGHOST (socket dir), PGPORT, PGDATABASE,
PGUSER, PSQL (path to psql; default: psql on PATH).
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, unquote, urlsplit

# ---------------------------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------------------------
PORT = int(os.environ.get('OC_BACKEND_PORT', '54400'))
ANON_KEY = os.environ.get('OC_ANON_KEY', 'local-anon')
PG = {
    'host': os.environ.get('PGHOST', ''),
    'port': os.environ.get('PGPORT', '54410'),
    'db': os.environ.get('PGDATABASE', 'opencourt_test'),
    'user': os.environ.get('PGUSER', 'postgres'),
}
PSQL = os.environ.get('PSQL', 'psql')
# A fixed secret for test tokens on this machine. It is not a credential for anything else.
JWT_SECRET = b'opencourt-local-backend-test-secret-not-a-production-value'
TOKEN_TTL = 3600
MAX_BODY = 100 * 1024       # bodies travel to psql as one argv entry; keep well under MAX_ARG_STRLEN
CATALOG_TTL = 10.0          # seconds before the relation/function catalog is re-read
ISSUER = 'http://127.0.0.1:%d/auth/v1' % PORT

IDENT = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
REST_OPS = {'eq': '=', 'neq': '<>', 'gt': '>', 'gte': '>=', 'lt': '<', 'lte': '<=', 'like': 'like', 'ilike': 'ilike'}
RESERVED_PARAMS = {'select', 'order', 'limit', 'offset', 'on_conflict', 'columns'}
CORS_HEADERS = ('apikey, authorization, content-type, prefer, accept, accept-profile, content-profile, '
                'x-client-info, x-supabase-api-version, range, range-unit, x-upsert')


def log(msg):
    sys.stderr.write(msg.rstrip('\n') + '\n')
    sys.stderr.flush()


# ---------------------------------------------------------------------------------------------
# errors
# ---------------------------------------------------------------------------------------------
class HttpError(Exception):
    """An error with a ready HTTP status and JSON body (PostgREST or GoTrue shaped)."""

    def __init__(self, status, body):
        super().__init__(status)
        self.status = status
        self.body = body


class PgError(Exception):
    def __init__(self, sqlstate, message, detail=None, hint=None):
        super().__init__(message)
        self.sqlstate = sqlstate
        self.message = message
        self.detail = detail
        self.hint = hint


def pgrst_error(status, code, message, details=None, hint=None):
    return HttpError(status, {'code': code, 'message': message, 'details': details, 'hint': hint})


def gotrue_error(status, error_code, msg):
    # GoTrue's error shape under X-Supabase-Api-Version 2024-01-01; supabase-js reads msg and error_code.
    return HttpError(status, {'code': status, 'error_code': error_code, 'msg': msg})


def pg_status_for(sqlstate, authenticated):
    """PostgREST's mapping of SQLSTATEs to HTTP statuses (the part that matters here)."""
    if sqlstate == '42501':
        return 403 if authenticated else 401
    if sqlstate in ('42P01', '42883'):
        return 404
    if sqlstate in ('23503', '23505', '40001', '40P01'):
        return 409
    if sqlstate.startswith('PT') and sqlstate[2:].isdigit():
        return int(sqlstate[2:])
    if sqlstate[:2] in ('08', '53', '57'):
        return 503
    if sqlstate[:2] in ('XX', 'P0') and sqlstate != 'P0001' and sqlstate != 'P0002' and sqlstate != 'P0003' and sqlstate != 'P0004':
        return 500
    return 400


# ---------------------------------------------------------------------------------------------
# the database: one psql subprocess per request, values as psql variables
# ---------------------------------------------------------------------------------------------
class Script:
    """Collects SQL statements and their values. Each value becomes `-v vN=<value>` on the psql
    command line and is written into the SQL as :'vN', which psql itself turns into a properly
    quoted literal for the connection's settings. Values never enter the SQL text."""

    def __init__(self):
        self.vars = []

    def val(self, v):
        if v is None:
            return 'null'
        s = v if isinstance(v, str) else json.dumps(v)
        if '\x00' in s:
            raise pgrst_error(400, '22P05', 'a value contains a NUL byte')
        name = 'v%d' % len(self.vars)
        self.vars.append((name, s))
        return ":'%s'" % name


def qi(name):
    """Quote an identifier that the catalog has already confirmed exists."""
    return '"' + name.replace('"', '""') + '"'


_ERR_RE = re.compile(r'ERROR:\s+(?:([0-9A-Z]{5}):\s+)?(.*)')


def _parse_psql_error(stderr):
    code, msg, detail, hint = 'XX000', 'database error', None, None
    for raw in stderr.splitlines():
        line = re.sub(r'^psql:[^:]*:\d+:\s*', '', raw)
        m = _ERR_RE.match(line)
        if m and msg == 'database error':
            code = m.group(1) or 'XX000'
            msg = m.group(2).strip()
        elif line.startswith('DETAIL:'):
            detail = line[len('DETAIL:'):].strip()
        elif line.startswith('HINT:'):
            hint = line[len('HINT:'):].strip()
    return PgError(code, msg, detail, hint)


def run_script(body_sql, script, role=None, claims=None, read_only=False):
    """Run one transaction. `body_sql` must produce exactly one row of one text column (or nothing
    for a void call); the text is returned. Raises PgError on any SQL error (transaction rolled back)."""
    parts = ['\\set VERBOSITY verbose', '\\set ON_ERROR_STOP on',
             'begin isolation level read committed%s;' % (' read only' if read_only else ''),
             'set local standard_conforming_strings = on;',
             'set local search_path = public, pg_catalog;']
    if role:
        parts.append('\\o /dev/null')
        parts.append("select set_config('request.jwt.claims', %s, true);" % script.val(json.dumps(claims or {})))
        parts.append('\\o')
        parts.append('set local role %s;' % role)      # a constant from this file, never from the request
    parts.append(body_sql.rstrip(';') + ';')
    parts.append('commit;')
    text = '\n'.join(parts) + '\n'

    cmd = [PSQL, '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1',
           '-p', PG['port'], '-U', PG['user'], '-d', PG['db'], '-f', '-']
    if PG['host']:
        cmd[1:1] = ['-h', PG['host']]
    for name, v in script.vars:
        cmd += ['-v', '%s=%s' % (name, v)]
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'PGCLIENTENCODING': 'UTF8',
           'PGCONNECT_TIMEOUT': '5', 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8'}
    try:
        p = subprocess.run(cmd, input=text.encode('utf-8'), capture_output=True, timeout=60, env=env)
    except subprocess.TimeoutExpired:
        raise PgError('57014', 'statement timeout (local-backend: psql took longer than 60 s)')
    if p.returncode != 0:
        err = p.stderr.decode('utf-8', 'replace')
        if 'ERROR:' not in err:
            raise PgError('08006', 'could not reach the database: ' + err.strip()[-300:])
        raise _parse_psql_error(err)
    out = p.stdout.decode('utf-8', 'replace')
    return out[:-1] if out.endswith('\n') else out


def run_json(body_sql, script, **kw):
    out = run_script(body_sql, script, **kw)
    return json.loads(out) if out.strip() else None


# ---------------------------------------------------------------------------------------------
# the catalog: relations (tables and views) and functions in schema public
# ---------------------------------------------------------------------------------------------
class Catalog:
    def __init__(self):
        self.lock = threading.Lock()
        self.at = 0.0
        self.relations = {}
        self.functions = {}

    def refresh(self):
        rel_sql = """
            select coalesce(json_agg(json_build_object('name', c.relname, 'kind', c.relkind, 'cols',
                     (select json_agg(a.attname order by a.attnum) from pg_attribute a
                       where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped))), '[]'::json)::text
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p', 'f')"""
        fn_sql = """
            select coalesce(json_agg(json_build_object(
                     'name', p.proname, 'retset', p.proretset, 'rettype', format_type(p.prorettype, null),
                     'rettypetype', t.typtype, 'argnames', p.proargnames, 'argmodes', p.proargmodes,
                     'ndefaults', p.pronargdefaults,
                     'argtypes', (select json_agg(format_type(x.t, null) order by x.i)
                                    from unnest(p.proargtypes) with ordinality x(t, i)))), '[]'::json)::text
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_type t on t.oid = p.prorettype
            where n.nspname = 'public' and p.prokind = 'f'"""
        rels = run_json(rel_sql, Script(), read_only=True)
        fns = run_json(fn_sql, Script(), read_only=True)
        relations = {r['name']: r for r in rels}
        functions = {}
        for f in fns:
            names = f.get('argnames') or []
            modes = f.get('argmodes')
            types = f.get('argtypes') or []
            # IN-style arguments are the ones pg_proc.proargtypes lists: modes i (in), b (inout), v (variadic)
            in_names = [n for i, n in enumerate(names) if not modes or modes[i] in ('i', 'b', 'v')] if names else []
            if len(in_names) != len(types):          # unnamed arguments: cannot be called by name
                in_names = in_names[:len(types)] if len(in_names) > len(types) else in_names + [''] * (len(types) - len(in_names))
            nd = f.get('ndefaults') or 0
            required = in_names[:len(in_names) - nd] if nd else in_names
            functions.setdefault(f['name'], []).append({
                'name': f['name'], 'retset': bool(f['retset']), 'rettype': f['rettype'], 'rettypetype': f['rettypetype'],
                'args': list(zip(in_names, types)), 'required': [n for n in required if n],
            })
        with self.lock:
            self.relations, self.functions, self.at = relations, functions, time.time()

    def _fresh(self, name, table):
        with self.lock:
            hit = table.get(name)
            stale = time.time() - self.at > CATALOG_TTL
        if hit is not None and not stale:
            return hit
        self.refresh()
        with self.lock:
            return table.get(name)

    def relation(self, name):
        return self._fresh(name, self.relations)

    def function(self, name):
        return self._fresh(name, self.functions)


CATALOG = Catalog()


# ---------------------------------------------------------------------------------------------
# JWT (HS256) and sessions
# ---------------------------------------------------------------------------------------------
def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode('ascii')


def b64u_dec(s):
    return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))


def jwt_sign(claims):
    head = b64u(json.dumps({'alg': 'HS256', 'typ': 'JWT'}, separators=(',', ':')).encode())
    body = b64u(json.dumps(claims, separators=(',', ':')).encode())
    sig = hmac.new(JWT_SECRET, ('%s.%s' % (head, body)).encode('ascii'), hashlib.sha256).digest()
    return '%s.%s.%s' % (head, body, b64u(sig))


def jwt_verify(token):
    """The claims of a token this server signed, or None when the token is not one (or expired)."""
    try:
        head, body, sig = token.split('.')
        expect = hmac.new(JWT_SECRET, ('%s.%s' % (head, body)).encode('ascii'), hashlib.sha256).digest()
        if not hmac.compare_digest(b64u(expect), sig):
            return None
        claims = json.loads(b64u_dec(body))
        if not isinstance(claims, dict) or int(claims.get('exp', 0)) <= int(time.time()):
            return None
        if claims.get('role') not in ('anon', 'authenticated'):
            return None
        return claims
    except Exception:
        return None


SESSIONS_LOCK = threading.Lock()
REFRESH_TOKENS = {}       # refresh_token -> {'user_id', 'session_id'}
PENDING_EMAIL = {}        # user_id -> email asked for through updateUser (never confirmed: no mail is sent)
USER_META = {}            # user_id -> user_metadata (updateUser({data}))


def fetch_auth_user(user_id):
    s = Script()
    row = run_json("select coalesce((select row_to_json(u) from auth.users u where u.id = %s::uuid), 'null'::json)::text"
                   % s.val(user_id), s, read_only=True)
    return row or None


def create_anonymous_user():
    s = Script()
    uid = str(uuid.uuid4())
    row = run_json("with ins as (insert into auth.users (id, is_anonymous) values (%s::uuid, true) returning *) "
                   "select row_to_json(ins)::text from ins" % s.val(uid), s)
    return row


def user_json(row):
    uid = row['id']
    created = row.get('created_at')
    return {
        'id': uid, 'aud': 'authenticated', 'role': 'authenticated',
        'email': row.get('email') or None,
        'new_email': PENDING_EMAIL.get(uid),
        'phone': '', 'app_metadata': {}, 'user_metadata': USER_META.get(uid, {}),
        'identities': [], 'is_anonymous': bool(row.get('is_anonymous')),
        'created_at': created, 'updated_at': created, 'last_sign_in_at': created,
    }


def mint_session(row, session_id=None):
    now = int(time.time())
    sid = session_id or str(uuid.uuid4())
    user = user_json(row)
    claims = {
        'iss': ISSUER, 'sub': row['id'], 'aud': 'authenticated', 'exp': now + TOKEN_TTL, 'iat': now,
        'email': user['email'] or '', 'phone': '', 'app_metadata': {}, 'user_metadata': user['user_metadata'],
        'role': 'authenticated', 'aal': 'aal1', 'amr': [{'method': 'anonymous', 'timestamp': now}],
        'session_id': sid, 'is_anonymous': user['is_anonymous'],
    }
    refresh = secrets.token_urlsafe(24)
    with SESSIONS_LOCK:
        REFRESH_TOKENS[refresh] = {'user_id': row['id'], 'session_id': sid}
    return {
        'access_token': jwt_sign(claims), 'token_type': 'bearer', 'expires_in': TOKEN_TTL,
        'expires_at': now + TOKEN_TTL, 'refresh_token': refresh, 'user': user,
    }


# ---------------------------------------------------------------------------------------------
# PostgREST: reads over relations
# ---------------------------------------------------------------------------------------------
def split_csv_quoted(s):
    """Split a PostgREST list like a,"b,c",d on commas outside double quotes."""
    out, cur, q = [], '', False
    for ch in s:
        if ch == '"':
            q = not q
        elif ch == ',' and not q:
            out.append(cur)
            cur = ''
        else:
            cur += ch
    out.append(cur)
    return [x for x in out]


def build_read(relname, query, want_count):
    rel = CATALOG.relation(relname)
    if rel is None:
        raise pgrst_error(404, 'PGRST205', "Could not find the table 'public.%s' in the schema cache" % relname,
                          None, 'local-backend serves views and tables in schema public (the real migrations).')
    cols = set(rel['cols'] or [])

    def column(name):
        if name not in cols:
            raise pgrst_error(400, '42703', 'column %s.%s does not exist' % (relname, name))
        return qi(name)

    s = Script()
    select_list, conds, order, limit, offset = '*', [], [], None, None
    for key, value in query:
        if key == 'select':
            items = [x.strip() for x in split_csv_quoted(value) if x.strip()]
            if items == ['*'] or not items:
                select_list = '*'
            else:
                exprs = []
                for it in items:
                    if it == '*':
                        exprs.append('*')
                        continue
                    alias, _, col = it.rpartition(':')
                    if '(' in it or '::' in it or '->' in it or '!' in it:
                        raise pgrst_error(400, 'PGRST100', 'local-backend: select supports plain columns, alias:column and *, not "%s"' % it)
                    if alias:
                        if not IDENT.match(alias):
                            raise pgrst_error(400, 'PGRST100', 'bad alias "%s"' % alias)
                        exprs.append('%s as %s' % (column(col), qi(alias)))
                    else:
                        exprs.append(column(col))
                select_list = ', '.join(exprs)
        elif key == 'order':
            for term in split_csv_quoted(value):
                bits = term.strip().split('.')
                col = column(bits[0])
                direction = 'asc'
                nulls = ''
                for b in bits[1:]:
                    if b in ('asc', 'desc'):
                        direction = b
                    elif b == 'nullsfirst':
                        nulls = ' nulls first'
                    elif b == 'nullslast':
                        nulls = ' nulls last'
                    else:
                        raise pgrst_error(400, 'PGRST100', 'bad order term "%s"' % term)
                order.append('%s %s%s' % (col, direction, nulls))
        elif key == 'limit':
            if not value.isdigit():
                raise pgrst_error(400, 'PGRST100', 'limit must be an integer')
            limit = int(value)
        elif key == 'offset':
            if not value.isdigit():
                raise pgrst_error(400, 'PGRST100', 'offset must be an integer')
            offset = int(value)
        elif key in RESERVED_PARAMS:
            raise pgrst_error(400, 'PGRST100', 'local-backend does not support the "%s" parameter' % key)
        elif key in ('and', 'or'):
            raise pgrst_error(400, 'PGRST100', 'local-backend does not support and=()/or=() filters')
        else:
            col = column(key)
            negate = False
            op, _, rest = value.partition('.')
            if op == 'not':
                negate = True
                op, _, rest = rest.partition('.')
            if op == 'is':
                if rest not in ('null', 'true', 'false', 'unknown'):
                    raise pgrst_error(400, 'PGRST100', 'is. takes null, true, false or unknown')
                cond = '%s is %s' % (col, rest)
            elif op == 'in':
                if not (rest.startswith('(') and rest.endswith(')')):
                    raise pgrst_error(400, 'PGRST100', 'in. takes a parenthesised list')
                items = [x for x in split_csv_quoted(rest[1:-1])]
                items = [x for x in items if x != ''] if rest[1:-1].strip() != '' else []
                cond = ('%s in (%s)' % (col, ', '.join(s.val(x) for x in items))) if items else 'false'
            elif op in REST_OPS:
                if op in ('like', 'ilike'):
                    rest = rest.replace('*', '%')
                cond = '%s %s %s' % (col, REST_OPS[op], s.val(rest))
            else:
                raise pgrst_error(400, 'PGRST100', 'local-backend does not support the operator "%s"' % op)
            conds.append('not (%s)' % cond if negate else cond)

    where = (' where ' + ' and '.join(conds)) if conds else ''
    inner = 'select %s from public.%s%s' % (select_list, qi(relname), where)
    if order:
        inner += ' order by ' + ', '.join(order)
    if limit is not None:
        inner += ' limit %d' % limit
    if offset is not None:
        inner += ' offset %d' % offset
    total = ('(select count(*) from public.%s%s)' % (qi(relname), where)) if want_count else 'null'
    sql = ("select json_build_object('body', coalesce(json_agg(r), '[]'::json), 'total', %s)::text from (%s) r"
           % (total, inner))
    return sql, s


# ---------------------------------------------------------------------------------------------
# PostgREST: RPC
# ---------------------------------------------------------------------------------------------
def pick_function(name, keys):
    cands = CATALOG.function(name) or []
    fits = []
    for f in cands:
        argnames = [a for a, _ in f['args']]
        if all(k in argnames for k in keys) and all(r in keys for r in f['required']):
            fits.append(f)
    if not fits:
        shown = ', '.join(sorted(keys)) or ''
        raise pgrst_error(404, 'PGRST202',
                          'Could not find the function public.%s(%s) in the schema cache' % (name, shown),
                          'Searched for the function public.%s with parameter%s %s, but no matches were found in the schema cache.'
                          % (name, '' if len(keys) == 1 else 's', shown or '(none)'),
                          None if cands else 'local-backend knows every function in schema public; is the migration applied?')
    # Prefer the candidate with the fewest arguments beyond the provided keys (PostgREST would call it ambiguous otherwise).
    fits.sort(key=lambda f: len(f['args']))
    return fits[0]


def build_rpc(name, args):
    if not isinstance(args, dict):
        raise pgrst_error(400, 'PGRST102', 'local-backend: the RPC body must be a JSON object of named arguments')
    keys = list(args.keys())
    for k in keys:
        if not IDENT.match(k):
            raise pgrst_error(400, 'PGRST100', 'bad argument name "%s"' % k)
    f = pick_function(name, keys)
    types = dict(f['args'])
    s = Script()
    fq = 'public.' + qi(name)
    if keys:
        defs = ', '.join('%s %s' % (qi(k), types[k]) for k in keys)       # types come from pg_proc, not the request
        call_args = ', '.join('%s => pgrst_args.%s' % (qi(k), qi(k)) for k in keys)
        prefix = 'with pgrst_args as (select * from json_to_record(%s::json) as _(%s)) ' % (s.val(json.dumps(args)), defs)
        src = 'from pgrst_args, lateral %s(%s)' % (fq, call_args)
    else:
        prefix = ''
        src = 'from %s()' % fq
    void = f['rettype'] == 'void'
    composite = f['rettypetype'] in ('c', 'p') and not void      # a table/view row type, or record (returns table ...)
    if void:
        sql = prefix + 'select null::text %s as f' % src
        kind = 'void'
    elif f['retset'] and composite:
        sql = prefix + "select coalesce(json_agg(f), '[]'::json)::text %s as f" % src
        kind = 'set'
    elif f['retset']:
        sql = prefix + "select coalesce(json_agg(f.v), '[]'::json)::text %s as f(v)" % src
        kind = 'set'
    elif composite:
        sql = prefix + 'select row_to_json(f)::text %s as f' % src
        kind = 'object'
    else:
        sql = prefix + 'select to_json(f.v)::text %s as f(v)' % src
        kind = 'scalar'
    return sql, s, kind


# ---------------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'local-backend/1.0'
    sys_version = ''

    # -- plumbing ------------------------------------------------------------------------------
    def log_message(self, fmt, *args):       # the default access log is replaced by one line per request
        pass

    def handle(self):
        # A browser that resets a keep-alive connection (Chromium does after a refused websocket
        # handshake) must not print a traceback into the one-line-per-request log.
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError, TimeoutError):
            pass

    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Expose-Headers', 'Content-Range, Content-Length, X-Supabase-Api-Version')

    def _send(self, status, body=None, headers=None, raw=None):
        data = raw if raw is not None else (None if body is None else json.dumps(body, ensure_ascii=False).encode('utf-8'))
        self.send_response(status)
        self._cors()
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if data is None or status == 204 or self.command == 'HEAD':
            if status != 204:
                self.send_header('Content-Length', str(len(data or b'')))
            self.end_headers()
        else:
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        self._status = status

    def _read_body(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n > MAX_BODY:
            raise pgrst_error(413, 'PGRST102', 'local-backend: request body over %d bytes' % MAX_BODY)
        return self.rfile.read(n) if n else b''

    def _json_body(self):
        raw = self._read_body()
        if not raw.strip():
            return {}
        try:
            return json.loads(raw.decode('utf-8'))
        except Exception:
            raise pgrst_error(400, 'PGRST102', 'Empty or invalid json')

    def _identity(self):
        """(role, claims, token) from the Authorization header. The anon key or no token → anon."""
        auth = self.headers.get('Authorization') or ''
        token = auth[7:].strip() if auth.lower().startswith('bearer ') else ''
        if not token or token == ANON_KEY:
            self._role = 'anon'
            return 'anon', {'role': 'anon'}, None
        claims = jwt_verify(token)
        if claims is None:
            raise pgrst_error(401, 'PGRST301', 'JWT expired or not issued by this local backend')
        self._role = claims['role']
        return claims['role'], claims, token

    # -- verbs ---------------------------------------------------------------------------------
    def do_OPTIONS(self):
        t0 = time.time()
        self.send_response(204)
        self._cors()
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS')
        asked = self.headers.get('Access-Control-Request-Headers')
        self.send_header('Access-Control-Allow-Headers', CORS_HEADERS + ((', ' + asked) if asked else ''))
        self.send_header('Access-Control-Max-Age', '600')
        self.end_headers()
        self._status = 204
        self._log('-', t0)

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_PUT(self):
        self._dispatch()

    def do_PATCH(self):
        self._dispatch()

    def do_DELETE(self):
        self._dispatch()

    def _log(self, role, t0):
        log('%s %s %s role=%s %s %dms' % (time.strftime('%H:%M:%S'), self.command, self.path.split('?')[0], role,
                                          getattr(self, '_status', '?'), int((time.time() - t0) * 1000)))

    def _dispatch(self):
        t0 = time.time()
        self._role = '-'          # set by _auth/_rest as soon as the identity is known (an error after that still maps by role)
        role = '-'
        try:
            url = urlsplit(self.path)
            path = unquote(url.path)
            if path.startswith('/auth/v1/'):
                role = self._auth(path[len('/auth/v1/'):], url)
            elif path.startswith('/rest/v1/'):
                role = self._rest(path[len('/rest/v1/'):], url)
            elif path in ('/', '/health'):
                self._send(200, {'name': 'local-backend', 'rest': '/rest/v1', 'auth': '/auth/v1', 'db': PG['db']})
            elif path.startswith('/realtime/'):
                raise pgrst_error(404, 'PGRST404', 'local-backend serves no realtime websocket; the page polls')
            else:
                raise pgrst_error(404, 'PGRST404', 'no such route: ' + path)
        except HttpError as e:
            role = self._role
            self._send(e.status, e.body)
        except PgError as e:
            role = self._role
            self._send(pg_status_for(e.sqlstate, role == 'authenticated'),
                       {'code': e.sqlstate, 'message': e.message, 'details': e.detail, 'hint': e.hint})
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:      # a bug here must not take the server down or hide behind a hang
            log('local-backend: unexpected %s: %s' % (type(e).__name__, e))
            try:
                self._send(500, {'code': 'PGRST000', 'message': 'local-backend: %s' % e, 'details': None, 'hint': None})
            except Exception:
                pass
        self._log(role, t0)

    # -- GoTrue --------------------------------------------------------------------------------
    def _bearer_user(self):
        role, claims, token = self._identity()
        if token is None:
            raise gotrue_error(401, 'no_authorization', 'This endpoint requires a Bearer token')
        row = fetch_auth_user(claims['sub'])
        if row is None:
            raise gotrue_error(403, 'user_not_found', 'User from sub claim in JWT does not exist')
        return row, claims

    def _auth(self, sub, url):
        q = dict(parse_qsl(url.query, keep_blank_values=True))
        m = self.command
        if sub == 'health' and m == 'GET':
            self._send(200, {'name': 'GoTrue', 'version': 'local-backend', 'description': 'a local stand-in; no mail, no OAuth'})
            return '-'
        if sub == 'settings' and m == 'GET':
            self._send(200, {'external': {'anonymous_users': True, 'email': True, 'phone': False},
                             'disable_signup': False, 'mailer_autoconfirm': False, 'phone_autoconfirm': False,
                             'sms_provider': '', 'saml_enabled': False})
            return '-'
        if sub == 'signup' and m == 'POST':
            body = self._json_body()
            if body.get('email') or body.get('phone') or body.get('password'):
                raise gotrue_error(422, 'email_provider_disabled',
                                   'local-backend: only anonymous sign-up is served here (signInAnonymously)')
            row = create_anonymous_user()
            self._send(200, mint_session(row))
            return 'authenticated'
        if sub == 'token' and m == 'POST':
            if q.get('grant_type') != 'refresh_token':
                raise gotrue_error(400, 'unsupported_grant_type', 'local-backend serves grant_type=refresh_token only')
            body = self._json_body()
            with SESSIONS_LOCK:
                rec = REFRESH_TOKENS.get(str(body.get('refresh_token') or ''))
            if rec is None:
                raise gotrue_error(400, 'refresh_token_not_found', 'Invalid Refresh Token: Refresh Token Not Found')
            row = fetch_auth_user(rec['user_id'])
            if row is None:
                raise gotrue_error(400, 'user_not_found', 'Invalid Refresh Token: user no longer exists')
            self._send(200, mint_session(row, rec['session_id']))
            return 'authenticated'
        if sub == 'user' and m == 'GET':
            row, _ = self._bearer_user()
            self._send(200, user_json(row))
            return 'authenticated'
        if sub == 'user' and m == 'PUT':
            row, _ = self._bearer_user()
            body = self._json_body()
            email = body.get('email')
            if email is not None:
                if not isinstance(email, str) or not re.match(r'^[^@\s]+@[^@\s]+\.[^@\s]+$', email):
                    raise gotrue_error(422, 'validation_failed', 'Unable to validate email address: invalid format')
                PENDING_EMAIL[row['id']] = email.lower()
                log('local-backend: updateUser asked to link %s to %s; no confirmation mail exists here' % ('an email', row['id']))
            if isinstance(body.get('data'), dict):
                USER_META[row['id']] = dict(USER_META.get(row['id'], {}), **body['data'])
            if body.get('password') or body.get('phone'):
                raise gotrue_error(422, 'validation_failed', 'local-backend: only email and data can be updated')
            self._send(200, user_json(row))
            return 'authenticated'
        if sub == 'otp' and m == 'POST':
            body = self._json_body()
            if not body.get('email'):
                raise gotrue_error(422, 'validation_failed', 'local-backend: otp needs an email')
            log('local-backend: magic link requested for an email; no mail is sent by this stand-in')
            self._send(200, {})
            return 'anon'
        if sub == 'logout' and m == 'POST':
            role, claims, token = self._identity()
            if token is not None:
                with SESSIONS_LOCK:
                    scope = q.get('scope', 'global')
                    for k in [k for k, v in REFRESH_TOKENS.items()
                              if v['user_id'] == claims.get('sub') and (scope == 'global' or v['session_id'] == claims.get('session_id'))]:
                        del REFRESH_TOKENS[k]
            self._send(204)
            return role
        raise gotrue_error(404, 'not_found', 'local-backend: no such auth route %s %s' % (m, sub))

    # -- PostgREST -----------------------------------------------------------------------------
    def _rest(self, sub, url):
        role, claims, token = self._identity()
        query = parse_qsl(url.query, keep_blank_values=True)
        m = self.command
        prefer = (self.headers.get('Prefer') or '').lower()
        accept = (self.headers.get('Accept') or '').lower()
        want_object = 'application/vnd.pgrst.object+json' in accept
        if sub == '' or sub == '/':
            self._send(200, {'info': {'title': 'local-backend (PostgREST subset)', 'version': 'local'}, 'paths': {}})
            return role
        if sub.startswith('rpc/'):
            name = sub[4:]
            if not IDENT.match(name):
                raise pgrst_error(400, 'PGRST100', 'bad function name')
            if m == 'POST':
                args = self._json_body()
            elif m in ('GET', 'HEAD'):
                args = {k: v for k, v in query if k not in RESERVED_PARAMS}
            else:
                raise pgrst_error(405, 'PGRST105', 'rpc takes POST (or GET for stable functions)')
            sql, s, kind = build_rpc(name, args)
            out = run_script(sql, s, role=role, claims=claims, read_only=(m != 'POST'))
            if kind == 'void':
                self._send(204)
                return role
            data = json.loads(out) if out.strip() else None
            if want_object and kind == 'set':
                data, extra = self._as_object(data)
                self._send(200, data, extra)
                return role
            n = len(data) if isinstance(data, list) else 1
            self._send(200, data, {'Content-Range': ('0-%d/*' % (n - 1)) if n else '*/*'})
            return role
        if m not in ('GET', 'HEAD'):
            raise pgrst_error(405, 'PGRST105',
                              'local-backend serves reads and rpc only; the page writes through RPC functions (docs/project-conventions.md)')
        relname = sub.strip('/')
        if not IDENT.match(relname):
            raise pgrst_error(400, 'PGRST100', 'bad relation name')
        want_count = 'count=exact' in prefer or 'count=planned' in prefer or 'count=estimated' in prefer
        sql, s = build_read(relname, query, want_count)
        res = run_json(sql, s, role=role, claims=claims, read_only=True)
        rows, total = res['body'], res.get('total')
        if want_object:
            data, extra = self._as_object(rows, total)
            self._send(200, data, extra)
            return role
        n = len(rows)
        if n:
            rng = '0-%d/%s' % (n - 1, total if total is not None else '*')
        else:
            rng = '*/%s' % (total if total is not None else '*')
        self._send(200, rows, {'Content-Range': rng})
        return role

    def _as_object(self, rows, total=None):
        if len(rows) != 1:
            raise pgrst_error(406, 'PGRST116', 'JSON object requested, multiple (or no) rows returned',
                              'The result contains %d rows' % len(rows), None)
        return rows[0], {'Content-Range': '0-0/%s' % (total if total is not None else '*')}


def main():
    try:
        CATALOG.refresh()
    except PgError as e:
        log('local-backend: cannot read the database catalog (%s): %s' % (e.sqlstate, e.message))
        log('local-backend: PGHOST=%s PGPORT=%s PGDATABASE=%s PGUSER=%s PSQL=%s' % (PG['host'], PG['port'], PG['db'], PG['user'], PSQL))
        sys.exit(1)
    srv = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    srv.daemon_threads = True
    log('local-backend: http://127.0.0.1:%d  (db %s@%s:%s via psql subprocess; %d relations, %d functions in public; anon key "%s")'
        % (PORT, PG['db'], PG['host'] or 'localhost', PG['port'], len(CATALOG.relations), len(CATALOG.functions), ANON_KEY))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == '__main__':
    main()
