# Sync Concurrency Optimization — Design

**Date:** 2026-08-11
**Status:** Design — pending user review

## Problem

Apps Script throttles when many executions run at once (~30 simultaneous across all
users). The joiner flows fan out into many small parallel calls, so a handful of
active joiners (plus client retries) fill the slots and requests queue — producing
extreme, intermittent slowness (measured: a no-op `ping` at 21s; `getJoiners` for one
user at 75s, while other calls the same minute were ~1s). The lazy-load work already
shrank *payloads* (getGOsList vs getAllGOs) but each joiner action still spends several
execution slots, and the current retry logic **amplifies** a jam.

Current per-action call counts (buyer):
- **My Orders lookup** (`doLookup`): 4 parallel — `getJoiners` + `getPayments` +
  `getShopOrders` + `getShipping`.
- **Open a GO** (`loadGOClaims`): 5 parallel — `getGOClaims` + `getSecuredSets` +
  `getClosedSubItems` + `getSubItemDeadlines` + `getSubItemPayDue`.
- `apiGet` retries **3×** on any failure, fixed backoff 400/800ms, no jitter →
  under load, every slow call is re-sent 3× by every client (a retry storm).

Not fixable by archiving: closed GOs are still active for joiners (shipping requests,
status, remaining payment), so their claims must stay in the live sheets.

## Goal

Cut the execution-slot pressure that causes the throttling:
1. **Combine both multi-call hotspots** into one server-side endpoint each (a joiner
   session drops from ~9 execution slots to ~2).
2. **Gentler client retries** so a struggling server gets room to recover instead of
   a pile-on.

## Two new read-only backend endpoints (Apps Script — REQUIRES REDEPLOY)

Both are doGet actions that do, in **one execution**, what several calls do now. Both
reuse the existing per-sheet reads; the win is fewer executions (and smaller payloads
where filtered).

- **`getMyOrders(username)`** → `{ claims, payments, shop_orders, shipping }` — each
  array **filtered to that user server-side**, matching case-insensitively
  (`trim().toLowerCase().replace(/^@/,'')`, exactly as `getJoiners` does today):
  - `claims`: same rows as `getJoiners(username)`.
  - `payments`: payment rows where username matches (vs. all ~615 today).
  - `shop_orders`: shop-order rows where username matches.
  - `shipping`: shipping requests where username matches.
  Replaces the 4-call My-Orders lookup and shrinks the payload to one user's data.

- **`getGOBoard(goId)`** → `{ claims, secured_sets, closed_subitems,
  subitem_deadlines, subitem_payment_due }`:
  - `claims`: same as `getGOClaims(goId)` (joiners rows for that go_id).
  - The four flag maps: same whole-store reads the flag endpoints return today
    (`secured_sets`, `closed_subitems`, `subitem_deadlines`, `subitem_payment_due`).
  Replaces the 5-call GO-open.

The existing endpoints (`getJoiners`, `getPayments`, `getShopOrders`, `getShipping`,
`getGOClaims`, `getSecuredSets`, `getClosedSubItems`, `getSubItemDeadlines`,
`getSubItemPayDue`) stay — the admin path and the pre-redeploy fallback still use them.

## Frontend

- **`doLookup`** (buyer branch): call `getMyOrders(rawUsername)` once. Unpack into the
  same globals the 4 calls populate today — `myLookupClaims` = `res.claims`;
  `paymentProofs` = `res.payments` mapped through the existing normalizer;
  `shopOrders` = `res.shop_orders`; `shippingRequests` = `res.shipping`. Then
  `doLookupRender(u)` unchanged.
- **`loadGOClaims`**: call `getGOBoard(goId)` once. Unpack `claims` (rebuild each
  sub-item's sets/claims exactly as now) plus the four flag maps (same parse as
  `syncFromBackend` / today's `loadGOClaims`).
- **Graceful degrade:** if the combined call returns falsy / lacks its expected keys
  (pre-redeploy 404, handled by `apiGet`'s catch → falls through), **fall back to the
  existing multi-call path** unchanged. So the app works before and after redeploy.
  Detection: `if (!res || res.claims === undefined) { ...old parallel path... }`.

## Gentler retries

- **`apiGet`**: attempts default **3 → 2**; backoff becomes **longer + jittered**:
  `await sleep(1000 * (i + 1) + Math.random() * 1000)` instead of `400 * (i + 1)`.
  A one-off blip still self-heals on the single retry, but clients no longer retry in
  lockstep or hammer a slow server.
- **`apiPost`**: unchanged retry *condition* (only 404/429 — the "didn't process" signals,
  safe to resend), but same **jittered** backoff so writes don't synchronize either.

## Out of scope (YAGNI)

- The **admin** sync (`getAllGOs` + secondary endpoints) — one user, negligible
  concurrency contribution; leave as-is.
- Moving off Google Sheets / a real datastore (the true fix for read-time scaling as
  data grows, but a far bigger project).
- Archiving/segmenting claims (closed GOs are still live for joiners).
- Server-side caching of the new endpoints (per-user data changes on confirm; revisit
  only if still slow).

## Testing

- **Backend:** `node --check` the `.gs` copy. After redeploy, live-curl:
  - `getMyOrders(<real user>)` returns `{claims,payments,shop_orders,shipping}` all
    scoped to that user (counts match the old per-endpoint filtered results).
  - `getGOBoard(<goId>)` returns claims + the four flag maps (claims count matches
    `getGOClaims`).
  - Time **1 combined call vs the 4/5 separate calls** — confirm fewer round-trips.
- **Frontend:** JS-parse. Buyer My Orders renders identically from `getMyOrders`;
  opening a GO renders identically from `getGOBoard`; the pre-redeploy fallback
  (simulate the endpoint missing) still loads via the old calls.
- **Retry:** unit-check the backoff math (2 attempts, jittered ~1–2s) in Node.

## Redeploy note

`getMyOrders` + `getGOBoard` require redeploying the Apps Script Web App. The frontend
falls back to the existing calls if they 404, so it is safe to push the frontend before
the redeploy.
