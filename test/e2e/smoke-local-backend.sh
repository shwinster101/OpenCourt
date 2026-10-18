#!/usr/bin/env bash
# Smoke test of the local Supabase stand-in (test/e2e/local-backend.py) with curl. Needs the stack up:
#   sh test/e2e/local-stack.sh start && sh test/e2e/smoke-local-backend.sh
# Reads OC_SUPABASE_URL / OC_SUPABASE_ANON_KEY from the environment or test/e2e/.stack/urls.env.
# Prints PASS/FAIL per line and exits non-zero on any FAIL. Walks the page's own flow: CORS preflight,
# courts as anon, the inbox refused to anon, an anonymous sign-up, a report and its rate limit, a
# profile, a pickup, a second user who sees and joins it, the organiser's notification, the court count.
# Bash is needed (arrays); re-exec when started as `sh`.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
if [ -f "$ROOT/test/e2e/.stack/urls.env" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/test/e2e/.stack/urls.env"
fi
BASE=${OC_SUPABASE_URL:-http://127.0.0.1:54400}
KEY=${OC_SUPABASE_ANON_KEY:-local-anon}
export no_proxy="127.0.0.1,localhost${no_proxy:+,$no_proxy}" NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "PASS  $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL  $1${2:+ — $2}"; }
check() { # name condition-exit-code detail
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

# req METHOD PATH [TOKEN] [BODY] [EXTRA-HEADER]... → STATUS in $STATUS, body in $WORK/body, headers in $WORK/hdr
req() {
  local method=$1 path=$2 token=${3:-} body=${4:-}; shift $(( $# >= 4 ? 4 : $# ))
  local -a args=(-sS -o "$WORK/body" -D "$WORK/hdr" -w '%{http_code}' -X "$method" -H "apikey: $KEY")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token") || args+=(-H "Authorization: Bearer $KEY")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data "$body")
  for h in "$@"; do args+=(-H "$h"); done
  STATUS=$(curl "${args[@]}" "$BASE$path" 2>"$WORK/curlerr" || echo 000)
}
body() { cat "$WORK/body"; }
# jq-less JSON reads: py 'expr over d'
py() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)" < "$WORK/body" 2>/dev/null; }
hdr() { grep -i "^$1:" "$WORK/hdr" | tr -d '\r' | head -1 | cut -d' ' -f2-; }

RUN=$(printf '%x' "$(date +%s)")      # usernames unique per run, so the smoke can run twice against one database
U1NAME="s1_$RUN"; U2NAME="s2_$RUN"
echo "smoke: $BASE (anon key \"$KEY\")"

# 1. CORS preflight
STATUS=$(curl -sS -o /dev/null -D "$WORK/hdr" -w '%{http_code}' -X OPTIONS "$BASE/rest/v1/courts_live" \
  -H 'Origin: http://127.0.0.1:8020' -H 'Access-Control-Request-Method: GET' \
  -H 'Access-Control-Request-Headers: apikey,authorization,content-type' 2>/dev/null || echo 000)
allow_h=$(hdr Access-Control-Allow-Headers | tr 'A-Z' 'a-z')
[ "$STATUS" = 204 ] || [ "$STATUS" = 200 ]; c1=$?
[ "$(hdr Access-Control-Allow-Origin)" = '*' ]; c2=$?
case "$allow_h" in *apikey*authorization*content-type*prefer*) c3=0 ;; *) c3=1 ;; esac
case "$(hdr Access-Control-Allow-Methods)" in *GET*POST*PUT*PATCH*DELETE*OPTIONS*) c4=0 ;; *) c4=1 ;; esac
check "OPTIONS preflight → $STATUS with Allow-Origin *, the supabase-js headers and all six methods" $((c1 + c2 + c3 + c4)) "status=$STATUS origin=$(hdr Access-Control-Allow-Origin) headers=$allow_h"

# 2. courts as anon
req GET '/rest/v1/courts_live?select=id,name&limit=25'
n=$(py 'len(d)')
[ "$STATUS" = 200 ] && [ "$n" = 20 ]; check "GET courts_live?select=id,name&limit=25 as anon → 200 and 20 rows" $? "status=$STATUS rows=$n $(head -c 200 "$WORK/body")"
[ "$(hdr Access-Control-Allow-Origin)" = '*' ]; check "every response carries Access-Control-Allow-Origin: *" $? "$(hdr Access-Control-Allow-Origin)"
req GET '/rest/v1/courts_live?select=id&limit=3' '' '' 'Prefer: count=exact'
case "$(hdr Content-Range)" in 0-2/20) c=0 ;; *) c=1 ;; esac
check "Prefer: count=exact → Content-Range 0-2/20" $c "$(hdr Content-Range)"

# 3. the inbox as anon: 0002 grants select on my_notifications to authenticated only, so anon gets
#    "permission denied for view my_notifications" (42501), which PostgREST answers 401 when no JWT was sent.
req GET '/rest/v1/my_notifications?select=*'
code=$(py 'd.get("code")')
[ "$STATUS" = 401 ] && [ "$code" = 42501 ]; check "GET my_notifications as anon → 401 with code 42501 (no grant to anon; a 403 would need a JWT)" $? "status=$STATUS body=$(head -c 200 "$WORK/body")"

# 4. anonymous sign-up (what signInAnonymously sends)
req POST '/auth/v1/signup' '' '{"data":{},"gotrue_meta_security":{}}'
T1=$(py 'd["access_token"]'); U1=$(py 'd["user"]["id"]'); R1=$(py 'd["refresh_token"]')
anon_flag=$(py 'd["user"]["is_anonymous"]'); ttype=$(py 'd["token_type"]'); exp_in=$(py 'd["expires_in"]')
[ "$STATUS" = 200 ] && [ -n "$T1" ] && [ -n "$R1" ] && [ "$anon_flag" = True ] && [ "$ttype" = bearer ] && [ "$exp_in" = 3600 ]
check "POST /auth/v1/signup (no email) → session {access_token, refresh_token, token_type bearer, expires_in 3600, user.is_anonymous}" $? "status=$STATUS $(head -c 200 "$WORK/body")"
req GET '/auth/v1/user' "$T1"
[ "$STATUS" = 200 ] && [ "$(py 'd["id"]')" = "$U1" ]; check "GET /auth/v1/user with the token → the same user" $? "status=$STATUS"
req POST '/auth/v1/token?grant_type=refresh_token' '' "{\"refresh_token\":\"$R1\"}"
[ "$STATUS" = 200 ] && [ "$(py 'd["user"]["id"]')" = "$U1" ] && [ -n "$(py 'd["access_token"]')" ]; check "POST /auth/v1/token?grant_type=refresh_token → a fresh session for the same user" $? "status=$STATUS $(head -c 160 "$WORK/body")"
req PUT '/auth/v1/user' "$T1" '{"email":"player@example.com"}'
[ "$STATUS" = 200 ] && [ "$(py 'd["new_email"]')" = player@example.com ]; check "PUT /auth/v1/user {email} → user echoed with new_email (no mail is sent)" $? "status=$STATUS $(head -c 160 "$WORK/body")"
req POST '/auth/v1/otp' '' '{"email":"player@example.com","create_user":true,"data":{},"gotrue_meta_security":{}}'
[ "$STATUS" = 200 ] && [ "$(body)" = '{}' ]; check "POST /auth/v1/otp → 200 {}" $? "status=$STATUS $(body)"

# 5. a court for the flow: the first free court nobody has reported or set a game on yet, so the exact counts
#    below hold on a fresh stack and on a re-run against the same database (several free courts are seeded)
req GET '/rest/v1/courts_live?select=id,name,sports,tier&tier=eq.free&recent_report_count=eq.0&open_pickup_count=eq.0&order=name.asc&limit=1'
COURT=$(py 'd[0]["id"]'); SPORT=$(py 'd[0]["sports"][0]')
[ -n "$COURT" ] && [ -n "$SPORT" ]; check "a free court to play on: $COURT ($SPORT)" $? "status=$STATUS $(head -c 160 "$WORK/body")"

# 6. a report and its rate limit
req POST '/rest/v1/rpc/submit_report' "$T1" "{\"p_court_id\":\"$COURT\",\"p_status\":\"open\"}"
[ "$STATUS" = 200 ] && [ "$(py 'd["status"]')" = open ] && [ "$(py 'd["reporter_id"]')" = "$U1" ]
check "POST rpc/submit_report {p_court_id, p_status: open} → 200 object with status open and reporter_id = the user" $? "status=$STATUS $(head -c 200 "$WORK/body")"
req POST '/rest/v1/rpc/submit_report' "$T1" "{\"p_court_id\":\"$COURT\",\"p_status\":\"open\"}"
[ "$STATUS" = 400 ] && [ "$(py 'd["message"]')" = rate_limited ] && [ "$(py 'd["code"]')" = P0001 ]
check "the same report again → 400 {code P0001, message rate_limited, hint}" $? "status=$STATUS $(head -c 200 "$WORK/body")"
req POST '/rest/v1/rpc/submit_report' '' "{\"p_court_id\":\"$COURT\",\"p_status\":\"open\"}"
[ "$STATUS" = 401 ] && [ "$(py 'd["code"]')" = 42501 ]; check "submit_report as anon → 401 (execute is granted to authenticated only)" $? "status=$STATUS $(head -c 200 "$WORK/body")"
req GET "/rest/v1/courts_live?select=id,recent_report_count,last_reported_availability&id=eq.$COURT"
[ "$STATUS" = 200 ] && [ "$(py 'd[0]["recent_report_count"]')" = 1 ] && [ "$(py 'd[0]["last_reported_availability"]["status"]')" = open ]
check "courts_live now shows recent_report_count 1 and last_reported_availability.status open for that court" $? "status=$STATUS $(head -c 200 "$WORK/body")"

# 7. a profile (maybeSingle before and after)
req GET "/rest/v1/profiles?select=*&id=eq.$U1" "$T1" '' 'Accept: application/vnd.pgrst.object+json'
[ "$STATUS" = 406 ] && [ "$(py 'd["code"]')" = PGRST116 ] && [ "$(py '"0 rows" in d["details"]')" = True ]
check "GET profiles?id=eq.<me> with Accept object+json before a profile → 406 PGRST116 'The result contains 0 rows'" $? "status=$STATUS $(head -c 200 "$WORK/body")"
req POST '/rest/v1/rpc/upsert_profile' "$T1" "{\"p_username\":\"$(echo "$U1NAME" | tr a-z A-Z)\",\"p_display_name\":\"Smoke One\",\"p_skill\":3,\"p_metro\":\"LA\"}"
[ "$STATUS" = 200 ] && [ "$(py 'd["username"]')" = "$U1NAME" ] && [ "$(py 'd["id"]')" = "$U1" ] && [ "$(py 'd["is_anonymous"]')" = True ]
check "POST rpc/upsert_profile → 200 profile object (username lowercased, is_anonymous from the JWT claim)" $? "status=$STATUS $(head -c 200 "$WORK/body")"
req POST '/rest/v1/rpc/upsert_profile' "$T1" '{"p_username":"x","p_display_name":"Smoke One","p_skill":null,"p_metro":"LA"}'
[ "$STATUS" = 400 ] && [ "$(py 'd["message"]')" = invalid_username ]; check "upsert_profile with a bad username → 400 invalid_username (errcode 22023)" $? "status=$STATUS $(head -c 160 "$WORK/body")"
req GET "/rest/v1/profiles?select=*&id=eq.$U1" "$T1" '' 'Accept: application/vnd.pgrst.object+json'
[ "$STATUS" = 200 ] && [ "$(py 'd["username"]')" = "$U1NAME" ]; check "GET profiles?id=eq.<me> object+json after → 200 one object" $? "status=$STATUS"

# 8. a pickup
STARTS=$(python3 -I -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')
req POST '/rest/v1/rpc/create_pickup' "$T1" "{\"p_court_id\":\"$COURT\",\"p_sport\":\"$SPORT\",\"p_starts_at\":\"$STARTS\",\"p_capacity\":4,\"p_note\":\"smoke test\"}"
PICKUP=$(py 'd["id"]')
[ "$STATUS" = 200 ] && [ -n "$PICKUP" ] && [ "$(py 'd["status"]')" = open ] && [ "$(py 'd["organiser_id"]')" = "$U1" ] && [ "$(py 'd["capacity"]')" = 4 ]
check "POST rpc/create_pickup → 200 pickup object (status open, organiser = me, capacity 4)" $? "status=$STATUS $(head -c 240 "$WORK/body")"
TOKEN=$(py 'd["share_token"]')
req POST '/rest/v1/rpc/pickup_by_token' '' "{\"p_token\":\"$TOKEN\"}"
[ "$STATUS" = 200 ] && [ "$(py 'd[0]["id"]')" = "$PICKUP" ]; check "POST rpc/pickup_by_token as anon → the pickup (returns table → array of one row)" $? "status=$STATUS $(head -c 160 "$WORK/body")"
req GET "/rest/v1/my_pickups?select=*&order=starts_at.asc" "$T1"
[ "$STATUS" = 200 ] && [ "$(py 'd[0]["my_status"]')" = owner ]; check "GET my_pickups as the organiser → my_status owner" $? "status=$STATUS $(head -c 160 "$WORK/body")"

# 9. a second anonymous user sees the board and joins
req POST '/auth/v1/signup' '' '{"data":{},"gotrue_meta_security":{}}'
T2=$(py 'd["access_token"]'); U2=$(py 'd["user"]["id"]')
[ "$STATUS" = 200 ] && [ -n "$T2" ] && [ "$U2" != "$U1" ]; check "a second anonymous sign-up → a different user" $? "status=$STATUS"
req GET "/rest/v1/open_pickups?select=*&court_id=eq.$COURT&order=starts_at.asc"
[ "$STATUS" = 200 ] && [ "$(py 'len(d)')" = 1 ] && [ "$(py 'd[0]["id"]')" = "$PICKUP" ] && [ "$(py 'd[0]["spots_left"]')" = 3 ] && [ "$(py 'd[0]["organiser_username"]')" = "$U1NAME" ]
check "GET open_pickups?court_id=eq.<court> as anon → the pickup, spots_left 3, organiser_username = user 1" $? "status=$STATUS $(head -c 240 "$WORK/body")"
req POST '/rest/v1/rpc/join_pickup' "$T2" "{\"p_pickup_id\":\"$PICKUP\"}"
[ "$STATUS" = 403 ] && [ "$(py 'd["message"]')" = profile_required ]; check "join_pickup before a profile → 403 profile_required (42501 with a JWT)" $? "status=$STATUS $(head -c 160 "$WORK/body")"
req POST '/rest/v1/rpc/upsert_profile' "$T2" "{\"p_username\":\"$U2NAME\",\"p_display_name\":\"Smoke Two\",\"p_skill\":null,\"p_metro\":\"LA\"}"
[ "$STATUS" = 200 ]; check "second user upsert_profile → 200" $? "status=$STATUS $(head -c 160 "$WORK/body")"
req POST '/rest/v1/rpc/join_pickup' "$T2" "{\"p_pickup_id\":\"$PICKUP\"}"
[ "$STATUS" = 200 ] && [ "$(py 'd["status"]')" = joined ] && [ "$(py 'd["player_id"]')" = "$U2" ]
check "second user POST rpc/join_pickup → 200 attendee row, status joined" $? "status=$STATUS $(head -c 200 "$WORK/body")"
req POST '/rest/v1/rpc/join_pickup' "$T2" "{\"p_pickup_id\":\"$PICKUP\"}"
[ "$STATUS" = 400 ] && [ "$(py 'd["message"]')" = already_joined ]; check "joining again → 400 already_joined" $? "status=$STATUS $(head -c 160 "$WORK/body")"

# 10. notifications: the organiser has the join, the joiner has nothing
req GET '/rest/v1/my_notifications?select=*&read_at=is.null&order=created_at.desc&limit=20' "$T1"
[ "$STATUS" = 200 ] && [ "$(py 'len(d)')" = 1 ] && [ "$(py 'd[0]["kind"]')" = joined ] && [ "$(py 'd[0]["actor_username"]')" = "$U2NAME" ]
check "GET my_notifications as the organiser (read_at=is.null, order, limit) → 1 row: kind joined by user 2" $? "status=$STATUS $(head -c 240 "$WORK/body")"
NID=$(py 'd[0]["id"]')
req GET '/rest/v1/my_notifications?select=*&read_at=is.null' "$T2"
[ "$STATUS" = 200 ] && [ "$(py 'len(d)')" = 0 ]; check "GET my_notifications as the joiner → 0 rows" $? "status=$STATUS $(body)"
req POST '/rest/v1/rpc/mark_notifications_read' "$T2" "{\"p_ids\":[$NID]}"
[ "$STATUS" = 200 ] && [ "$(body)" = 0 ]; check "the joiner cannot mark the organiser's notification read (mark_notifications_read → 0 rows, bigint[] argument bound)" $? "status=$STATUS $(body)"
req POST '/rest/v1/rpc/mark_notifications_read' "$T1" "{\"p_ids\":[$NID]}"
[ "$STATUS" = 200 ] && [ "$(body)" = 1 ]; check "the organiser marks it read → scalar 1" $? "status=$STATUS $(body)"
req POST '/rest/v1/rpc/pickup_roster' "$T2" "{\"p_pickup_id\":\"$PICKUP\"}"
[ "$STATUS" = 200 ] && [ "$(py 'len(d)')" = 2 ] && [ "$(py 'd[0]["status"]')" = owner ]; check "POST rpc/pickup_roster → 2 rows, owner first" $? "status=$STATUS $(head -c 240 "$WORK/body")"
req POST '/rest/v1/rpc/leave_pickup' "$T1" "{\"p_pickup_id\":\"$PICKUP\"}"
[ "$STATUS" = 400 ] && [ "$(py 'd["message"]')" = organiser_cannot_leave ] && [ "$(py 'd["hint"]')" = 'Cancel the pickup instead.' ]
check "organiser leave_pickup → 400 organiser_cannot_leave with the SQL hint" $? "status=$STATUS $(head -c 200 "$WORK/body")"
req POST '/rest/v1/rpc/cancel_pickup' "$T2" "{\"p_pickup_id\":\"$PICKUP\"}"
[ "$STATUS" = 403 ] && [ "$(py 'd["message"]')" = not_organiser ]; check "joiner cancel_pickup → 403 not_organiser (42501 with a JWT)" $? "status=$STATUS $(head -c 160 "$WORK/body")"

# 11. the court shows the game; friends surface (M3) answers through the same generic layer
req GET "/rest/v1/courts_live?select=id,open_pickup_count&id=eq.$COURT"
[ "$STATUS" = 200 ] && [ "$(py 'd[0]["open_pickup_count"]')" = 1 ]; check "GET courts_live shows open_pickup_count 1 for that court" $? "status=$STATUS $(body)"
req POST '/rest/v1/rpc/friend_status' "$T1" "{\"p_other\":\"$U2\"}"
[ "$STATUS" = 200 ] && [ "$(body)" = '"none"' ]; check "POST rpc/friend_status (M3, scalar text) → \"none\"" $? "status=$STATUS $(body)"
req POST '/rest/v1/rpc/my_friends' "$T1" '{}'
[ "$STATUS" = 200 ] && [ "$(body)" = '[]' ]; check "POST rpc/my_friends {} (setof profiles, no arguments) → []" $? "status=$STATUS $(body)"
req POST '/rest/v1/rpc/accept_friend_request' "$T1" "{\"p_requester\":\"$U2\"}"
[ "$STATUS" = 500 ] && [ "$(py 'd["message"]')" = no_request ] && [ "$(py 'd["code"]')" = P0002 ]; check "accept_friend_request with no request → 500 P0002 no_request (PostgREST maps every P0* but P0001 to 500; void function path)" $? "status=$STATUS $(head -c 160 "$WORK/body")"
req POST '/rest/v1/rpc/leave_pickup' "$T2" "{\"p_pickup_id\":\"$PICKUP\"}"
[ "$STATUS" = 204 ] && [ ! -s "$WORK/body" ]; check "second user leave_pickup → 204 (void)" $? "status=$STATUS $(body)"
req GET "/rest/v1/profiles?select=id,username,display_name,skill&id=in.($U1,$U2)&order=username.asc" "$T2"
[ "$STATUS" = 200 ] && [ "$(py 'len(d)')" = 2 ]; check "GET profiles?id=in.(a,b) → 2 rows" $? "status=$STATUS $(head -c 200 "$WORK/body")"
req GET '/rest/v1/no_such_view?select=*'
[ "$STATUS" = 404 ] && [ "$(py 'd["code"]')" = PGRST205 ]; check "an unknown relation → 404 PGRST205" $? "status=$STATUS $(head -c 160 "$WORK/body")"
req POST '/rest/v1/rpc/no_such_fn' "$T1" '{"a":1}'
[ "$STATUS" = 404 ] && [ "$(py 'd["code"]')" = PGRST202 ]; check "an unknown function → 404 PGRST202" $? "status=$STATUS $(head -c 160 "$WORK/body")"
req POST '/auth/v1/logout?scope=global' "$T2"
[ "$STATUS" = 204 ]; check "POST /auth/v1/logout → 204" $? "status=$STATUS"

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
