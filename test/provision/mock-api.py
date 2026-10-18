#!/usr/bin/env python3
"""A stand-in for the Supabase Management API, for testing scripts/provision-supabase.sh.

Standard library only. Imitates, with in-memory state, exactly the endpoints the provisioner
calls (shapes follow the Management API's OpenAPI document, components.schemas.*):

  GET  /v1/organizations                               OrganizationResponseV1
  GET  /v1/projects   POST /v1/projects                 V1ProjectWithDatabaseResponse / V1CreateProjectBody
  GET  /v1/projects/available-regions                  RegionsInfo
  GET  /v1/projects/{ref}                              status COMING_UP for two polls, then ACTIVE_HEALTHY
  GET  /v1/projects/{ref}/health?services=…            V1ServiceHealthResponse[]
  GET  /v1/projects/{ref}/config/auth   PATCH …        AuthConfigResponse / UpdateAuthConfigBody (subset)
  POST /v1/projects/{ref}/database/query               V1RunQueryBody → rows (201)
  GET/POST/PUT /v1/projects/{ref}/database/migrations  V1ListMigrationsResponse / V1CreateMigrationBody
  GET  /v1/projects/{ref}/api-keys?reveal=true         ApiKeyResponse[]: anon + publishable + two keys that
                                                       must never appear in the provisioner's output
  GET  /rest/v1/courts_live?select=id[&limit=n]        the project's PostgREST, keyed by the apikey header
  GET  /__state                                        test hook: the whole state and the request log

Every Management call must carry "Authorization: Bearer <token>" where token is --token. The SQL
"engine" recognises the migration files by their first-line header ("-- 0001 — …"), the seed by its
generator line, and a handful of selects; a migration applied twice answers 500 like Postgres would.

Usage: python3 -I test/provision/mock-api.py --token T [--port 0] [--port-file F] [--verbose]
"""
import argparse
import json
import re
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ORG = {"id": "org-legacy-id-0001", "slug": "pickup-bois", "name": "PickUp Bois"}
REGIONS = {
    "recommendations": {
        "smartGroup": {"name": "Americas", "code": "americas", "type": "smartGroup"},
        "specific": [{"name": "West US (North California)", "code": "us-west-1", "type": "specific", "provider": "AWS"}],
    },
    "all": {
        "smartGroup": [{"name": "Americas", "code": "americas", "type": "smartGroup"}],
        "specific": [
            {"name": "West US (North California)", "code": "us-west-1", "type": "specific", "provider": "AWS"},
            {"name": "West US (Oregon)", "code": "us-west-2", "type": "specific", "provider": "AWS"},
            {"name": "East US (North Virginia)", "code": "us-east-1", "type": "specific", "provider": "AWS"},
        ],
    },
}
POLLS_UNTIL_HEALTHY = 2  # GET /v1/projects/{ref} answers COMING_UP this many times, then ACTIVE_HEALTHY

LOCK = threading.RLock()  # re-entrant: route() holds it while send() appends to the log
STATE = {
    "token": None,
    "projects": {},   # ref → project record (spec shape) plus private fields under "_"
    "log": [],        # every request: {method, path, status}
    "secrets_to_never_see": [],
}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def new_project(name, org_slug, region):
    n = len(STATE["projects"]) + 1
    ref = ("pickupmockproject" + "abcdefghij"[n % 10] * 3)[:20]
    keys = [
        # The two public keys: a legacy anon JWT-stand-in and a publishable key.
        {"id": "k-anon", "name": "anon", "type": "legacy", "prefix": None, "description": None,
         "api_key": "mock-anon-key-" + ref, "hash": None, "secret_jwt_template": None,
         "inserted_at": now_iso(), "updated_at": now_iso()},
        {"id": "k-pub", "name": "default", "type": "publishable", "prefix": "sb_publishable_", "description": None,
         "api_key": "sb_publishable_mock_" + ref, "hash": None, "secret_jwt_template": None,
         "inserted_at": now_iso(), "updated_at": now_iso()},
        # The two keys the provisioner must never print or store.
        {"id": "k-sr", "name": "service_role", "type": "legacy", "prefix": None, "description": None,
         "api_key": "mock-privileged-key-MUST-NOT-LEAK-" + ref, "hash": None, "secret_jwt_template": None,
         "inserted_at": now_iso(), "updated_at": now_iso()},
        {"id": "k-sec", "name": "default", "type": "secret", "prefix": "sb_secret_", "description": None,
         "api_key": "sb_secret_mock_MUST_NOT_LEAK_" + ref, "hash": None, "secret_jwt_template": None,
         "inserted_at": now_iso(), "updated_at": now_iso()},
    ]
    STATE["secrets_to_never_see"] += [keys[2]["api_key"], keys[3]["api_key"]]
    return {
        "id": ref, "ref": ref, "organization_id": ORG["id"], "organization_slug": org_slug,
        "name": name, "region": region, "created_at": now_iso(), "status": "COMING_UP",
        "database": {"host": "db." + ref + ".supabase.co", "version": "17.4.1.043", "postgres_engine": "17",
                     "release_channel": "ga"},
        "_": {
            "polls": 0,
            "keys": keys,
            "auth": {"external_anonymous_users_enabled": False, "external_email_enabled": True,
                     "site_url": "http://localhost:3000", "uri_allow_list": "", "disable_signup": False,
                     "mailer_autoconfirm": False, "rate_limit_anonymous_users": 30},
            "migrations": [],        # [{version, name}] — what GET …/database/migrations returns
            "applied": [],           # fingerprints of SQL files run through …/database/query, in order
            "extensions": {},        # name → schema
            "courts": 0,
            "query_count": 0,
        },
    }


def public_view(p):
    return {k: v for k, v in p.items() if k != "_"}


def server_version():
    return datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")


class SqlError(Exception):
    pass


def run_sql(p, q):
    """A tiny recogniser for the SQL the provisioner sends. Returns rows (a list of dicts)."""
    priv = p["_"]
    priv["query_count"] += 1
    head = q.lstrip().splitlines()[0] if q.strip() else ""
    low = q.lower()
    m = re.match(r"--\s*(\d{4})\s", head)
    if m:                                           # a migration file (first line "-- 0001 — …")
        tag = m.group(1)
        if tag in priv["applied"]:
            raise SqlError('ERROR: 42710: type "sport" already exists (migration %s was applied before)' % tag)
        expected = "%04d" % (len([a for a in priv["applied"] if a != "seed"]) + 1)
        if tag != expected:
            raise SqlError("ERROR: migration %s applied out of order (expected %s)" % (tag, expected))
        priv["applied"].append(tag)
        return []
    if head.startswith("-- Generated by scripts/export-courts-seed.mjs"):
        if "0001" not in priv["applied"]:
            raise SqlError('ERROR: 42P01: relation "public.courts" does not exist')
        priv["applied"].append("seed")
        priv["courts"] = len(re.findall(r"^\s*\('", q, re.M))
        return []
    if "create extension" in low and "pg_cron" in low:
        sm = re.search(r"with\s+schema\s+([a-z_]+)", low)
        priv["extensions"].setdefault("pg_cron", sm.group(1) if sm else "public")
        return []
    if "from pg_extension" in low:
        return [{"extname": n, "schema": s} for n, s in priv["extensions"].items() if n in low]
    if "count(*)" in low and "public.courts" in low:
        if "0001" not in priv["applied"]:
            raise SqlError('ERROR: 42P01: relation "public.courts" does not exist')
        return [{"count": priv["courts"]}]
    if "supabase_migrations.schema_migrations" in low:
        return [{"version": m_["version"], "name": m_["name"]} for m_ in priv["migrations"]]
    if "pg_tables" in low or "to_regclass" in low:
        return [{"exists": "0001" in priv["applied"]}]
    return []


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-supabase-api/1"
    verbose = False

    def log_message(self, fmt, *args):  # quiet unless --verbose
        if self.verbose:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # -- plumbing ---------------------------------------------------------------------------
    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            raise SqlError("invalid JSON body")

    def send(self, status, payload=None):
        data = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)
        with LOCK:
            STATE["log"].append({"method": self.command, "path": self.path, "status": status})

    def authed(self):
        return self.headers.get("Authorization") == "Bearer " + STATE["token"]

    def project(self, ref):
        return STATE["projects"].get(ref)

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_PATCH(self):
        self.route("PATCH")

    # -- routes -----------------------------------------------------------------------------
    def route(self, method):
        u = urlsplit(self.path)
        path, qs = u.path.rstrip("/"), parse_qs(u.query)
        try:
            with LOCK:
                self.dispatch(method, path, qs)
        except SqlError as e:
            self.send(500, {"message": str(e)})
        except Exception as e:  # keep the mock alive and the failure visible
            self.send(500, {"message": "mock failure: %r" % (e,)})

    def dispatch(self, method, path, qs):
        if path == "/__state" and method == "GET":
            return self.send(200, {"projects": {r: public_view(p) | {"_": p["_"]} for r, p in STATE["projects"].items()},
                                   "log": STATE["log"], "secrets_to_never_see": STATE["secrets_to_never_see"]})

        # The project's own REST API (PostgREST), keyed by the apikey header, not the bearer token.
        if path.startswith("/rest/v1/"):
            return self.rest(method, path, qs)

        if not path.startswith("/v1/"):
            return self.send(404, {"message": "Cannot %s %s" % (method, path)})
        if not self.authed():
            return self.send(401, {"message": "Unauthorized"})

        if path == "/v1/organizations" and method == "GET":
            return self.send(200, [ORG])
        if path == "/v1/projects/available-regions" and method == "GET":
            if not qs.get("organization_slug"):
                return self.send(400, {"message": "organization_slug is required"})
            return self.send(200, REGIONS)
        if path == "/v1/projects" and method == "GET":
            return self.send(200, [public_view(p) for p in STATE["projects"].values()])
        if path == "/v1/projects" and method == "POST":
            b = self.body_json()
            for k in ("name", "organization_slug", "db_pass"):
                if not b.get(k):
                    return self.send(400, {"message": "%s should not be empty" % k})
            if b["organization_slug"] != ORG["slug"]:
                return self.send(403, {"message": "Forbidden action"})
            if len(b["db_pass"]) < 12:
                return self.send(400, {"message": "db_pass is too short"})
            sel = b.get("region_selection") or {}
            region = sel.get("code") if sel.get("type") == "specific" else b.get("region")
            if region not in [r["code"] for r in REGIONS["all"]["specific"]]:
                return self.send(400, {"message": "region_selection.code must be one of the available regions"})
            p = new_project(b["name"], b["organization_slug"], region)
            STATE["projects"][p["ref"]] = p
            out = public_view(p)
            out.pop("database")  # V1ProjectResponse (the create response) has no database block
            return self.send(201, out)

        m = re.match(r"^/v1/projects/([a-z]{20})(/.*)?$", path)
        if not m:
            return self.send(404, {"message": "Cannot %s %s" % (method, path)})
        p, rest = self.project(m.group(1)), m.group(2) or ""
        if not p:
            return self.send(404, {"message": "Project not found"})
        priv = p["_"]

        if rest == "" and method == "GET":
            priv["polls"] += 1
            if priv["polls"] > POLLS_UNTIL_HEALTHY:
                p["status"] = "ACTIVE_HEALTHY"
            return self.send(200, public_view(p))
        if rest == "/health" and method == "GET":
            services = ",".join(qs.get("services", [])).split(",") if qs.get("services") else []
            if not services or services == [""]:
                return self.send(400, {"message": "services should not be empty"})
            healthy = p["status"] == "ACTIVE_HEALTHY"
            st = "ACTIVE_HEALTHY" if healthy else "COMING_UP"
            return self.send(200, [{"name": s, "healthy": healthy, "status": st} for s in services])
        if rest == "/config/auth" and method == "GET":
            return self.send(200, priv["auth"])
        if rest == "/config/auth" and method == "PATCH":
            b = self.body_json()
            unknown = [k for k in b if k not in priv["auth"]]
            if unknown:
                return self.send(400, {"message": "property %s should not exist" % unknown[0]})
            if "site_url" in b and b["site_url"] and "," in b["site_url"]:
                return self.send(400, {"message": "site_url must match ^[^,]+$"})
            priv["auth"].update(b)
            return self.send(200, priv["auth"])
        if rest == "/database/query" and method == "POST":
            b = self.body_json()
            if not b.get("query"):
                return self.send(400, {"message": "query should not be empty"})
            return self.send(201, run_sql(p, b["query"]))
        if rest == "/database/migrations" and method == "GET":
            return self.send(200, [{"version": x["version"], "name": x["name"]} for x in priv["migrations"]])
        if rest == "/database/migrations" and method in ("POST", "PUT"):
            b = self.body_json()
            if not b.get("query"):
                return self.send(400, {"message": "query should not be empty"})
            if method == "POST":
                run_sql(p, b["query"])  # POST applies; PUT only records
            version = server_version() + "%02d" % len(priv["migrations"])  # server-assigned, unique
            priv["migrations"].append({"version": version, "name": b.get("name")})
            return self.send(200, {})
        if rest == "/api-keys" and method == "GET":
            reveal = (qs.get("reveal", [""])[0] or "").lower() in ("true", "1", "yes", "on", "y", "enabled")
            out = []
            for k in priv["keys"]:
                k = dict(k)
                if not reveal and k["type"] != "legacy":
                    k["api_key"] = None
                out.append(k)
            return self.send(200, out)
        return self.send(404, {"message": "Cannot %s %s" % (method, path)})

    def rest(self, method, path, qs):
        if method != "GET" or path != "/rest/v1/courts_live":
            return self.send(404, {"message": "mock REST serves GET /rest/v1/courts_live only"})
        key = self.headers.get("apikey") or ""
        p = next((x for x in STATE["projects"].values()
                  if key in [k["api_key"] for k in x["_"]["keys"] if k["name"] == "anon" or k["type"] == "publishable"]), None)
        if not p:
            return self.send(401, {"message": "Invalid API key", "hint": "Double check your Supabase `anon` or `service_role` API key."})
        n = p["_"]["courts"]
        rows = [{"id": "mock-court-%02d" % i} for i in range(1, n + 1)]
        if qs.get("limit"):
            rows = rows[: int(qs["limit"][0])]
        return self.send(200, rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--token", required=True, help="the bearer token every /v1 call must carry")
    ap.add_argument("--port", type=int, default=0, help="0 = any free port")
    ap.add_argument("--port-file", help="write the bound port here once listening")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    STATE["token"] = a.token
    Handler.verbose = a.verbose
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    port = srv.server_address[1]
    if a.port_file:
        with open(a.port_file, "w", encoding="utf-8") as f:
            f.write(str(port))
    sys.stderr.write("mock-api listening on http://127.0.0.1:%d\n" % port)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
