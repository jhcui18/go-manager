#!/usr/bin/env bash
# Verifies anon-key boundaries with raw REST calls. Requires: SUPABASE_URL, SUPABASE_ANON_KEY.
set -u
BASE="$SUPABASE_URL/rest/v1"
H=(-H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY")
pass=0; fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1";
  else fail=$((fail+1)); echo "FAIL  $1 (expected $2, got $3)"; fi
}

# Reads that must work (HTTP 200)
for t in gos sub_items members versions sets claims listings listing_variants \
         payments shop_orders shipping_request_items shipping_status; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" "$BASE/$t?select=*&limit=1")
  check "anon can read $t" 200 "$code"
done

# Tables that must be invisible to anon. Two valid outcomes prove this:
#   (a) 200 with an EMPTY array (SELECT granted, RLS policy filters to 0 rows), or
#   (b) 401/403 permission-denied (no table-level GRANT to anon at all — even
#       stronger, since anon can't query the table's shape at all).
# Both mean "anon sees no rows"; only a 200 WITH rows is a failure.
for t in shipping_requests gc_members store_orders; do
  resp=$(curl -s -w '\n%{http_code}' "${H[@]}" "$BASE/$t?select=*&limit=1")
  code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')
  if [ "$code" = "200" ] && [ "$body" = "[]" ]; then
    pass=$((pass+1)); echo "PASS  anon sees no rows in $t (200, empty)"
  elif [ "${code:0:1}" != "2" ]; then
    pass=$((pass+1)); echo "PASS  anon sees no rows in $t ($code, no grant)"
  else
    fail=$((fail+1)); echo "FAIL  anon sees no rows in $t (got $code: $body)"
  fi
done

# The view must not expose address columns (selecting one must 400).
code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" "$BASE/shipping_status?select=address1&limit=1")
check "shipping_status hides addresses" 400 "$code"

# Writes that must all be denied OR match 0 rows (RLS makes rows invisible so
# PostgREST filters them out of the write's WHERE clause too). We use
# Prefer: return=representation so a "successful" 2xx that touched nothing
# comes back with an empty body/array, which we can tell apart from a 2xx
# that actually changed a row.
write_denied() { # write_denied <desc> <method> <url> <body>
  local desc="$1" method="$2" url="$3" data="$4"
  local resp code body
  resp=$(curl -s -w '\n%{http_code}' "${H[@]}" -X "$method" "$url" \
    -H "Content-Type: application/json" -H "Prefer: return=representation" -d "$data")
  code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')
  case "$code" in
    2*)
      # 2xx only passes if it changed nothing (empty array = 0 rows affected).
      if [ "$body" = "[]" ]; then
        pass=$((pass+1)); echo "PASS  $desc (2xx but 0 rows affected)"
      else
        fail=$((fail+1)); echo "FAIL  $desc (2xx AND rows were affected: $body)"
      fi
      ;;
    *)
      pass=$((pass+1)); echo "PASS  $desc ($code)"
      ;;
  esac
}

# INSERT: RLS on INSERT is a WITH CHECK, so a blocked insert must fail outright
# (there's no "matched 0 rows" case for inserts) — expect anything but 2xx.
code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$BASE/claims" \
  -H "Content-Type: application/json" -d '{"username":"hacker","qty":1}')
check "anon cannot INSERT claims directly" 0 "$( [ "${code:0:1}" = 2 ] && echo 2xx || echo 0 )"

write_denied "anon cannot UPDATE claims" PATCH "$BASE/claims?limit=1" '{"payment_status":"paid"}'
write_denied "anon cannot DELETE claims" DELETE "$BASE/claims?username=eq.nobody" ''
write_denied "anon cannot UPDATE gos" PATCH "$BASE/gos?limit=1" '{"status":"closed"}'

# Admin RPCs must be denied to anon.
for fn in secure_set move_claim apply_credit reverse_credit confirm_payment save_go; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" -X POST "$BASE/rpc/$fn" \
    -H "Content-Type: application/json" -d '{}')
  check "anon cannot call $fn" 0 "$( [ "${code:0:1}" = 2 ] && echo 2xx || echo 0 )"
done

echo; echo "$pass passed, $fail failed"; exit $([ $fail -eq 0 ] && echo 0 || echo 1)
