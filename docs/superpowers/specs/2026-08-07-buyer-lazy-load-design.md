# Buyer Lazy-Load — Fast First Open — Design

**Date:** 2026-08-07
**Status:** Design approved, pending spec review

## Problem

Every visitor's first open calls `getAllGOs`, which returns **all claims for all GOs**
(measured: **1.8 MB, ~7.5 s, 3,666 claims across 16 GOs**) and blocks behind a loading
overlay. First-time joiners (no cached data) wait the full time, and it grows forever.
A native app wouldn't help — the cost is the Apps Script data fetch, not page delivery.

## Goal

Make the **buyer** path load only what each screen needs:
- **Landing list** loads GO + sub-item **metadata only** (no claims).
- **Opening a GO** lazy-loads *that* GO's claims.
- **My Orders** loads just the looked-up user's claims (`getJoiners`).

The **admin** path is unchanged (one user; needs the full picture).

## Decisions (from brainstorming)

- **Landing list is minimal**: GO name, deadline, "N POBs", Open/Closed. **No per-POB
  claim summary** on the list (drop `renderGoPreview` for buyers). So the landing needs
  zero claims.
- **My Orders builds from `getJoiners(username)`** + the light price metadata, not a
  full reconstruction. Owed/credit is computed from the user's own claims (validated to
  match the admin's `paymentOwedUnits` on real data — see Testing).
- **Buyer vs admin** is the existing `isAdmin` (`sessionStorage 'go_admin'`).

## Backend (Apps Script — REQUIRES REDEPLOY)

Two new doGet actions. Both reuse the existing GO/sub-item reading; the win is **not
reading the `joiners` sheet** on the landing call.

- **`getGOsList()`** → `{ gos: [ { go_id, name, type, deadline, status, min_secure,
  created_at, payment_deadline, subItems: [ { sub_item_id, name, kind, members,
  versions, price, ot_price, min_secure, image_url } ] } ] }`. **Identical to
  `getAllGOs` but omits the per-GO `claims` array** (skip the joiners-sheet read
  entirely). This is the fast landing payload.
- **`getGOClaims(goId)`** → `{ claims: [ …joiners rows for this go_id… ] }`. Reads the
  joiners sheet filtered to one `go_id` (same row shape `getAllGOs` already returns per
  claim).
- `getJoiners(username)` already exists (a user's claims across all GOs) — reused as-is.

`getAllGOs` stays for the admin path.

## Frontend

### Load-path branch

`syncFromBackend` (or a buyer variant) branches on `isAdmin`:
- **Admin:** current behavior — `getAllGOs` + all the secondary endpoints. Unchanged.
- **Buyer:** `getGOsList` + `getListings` only (shop grid). Reconstruct `allGOs` with
  sub-items but **empty** sets/claims (`buildSetsFromClaims([], …)` / empty claims). Do
  **not** load payments/shipping/store/secured/closed/deadline flags on landing — those
  are admin- or My-Orders-scoped. (Closed/deadline/pay-due flags that the buyer board
  needs are loaded with the GO on open — see below.)
- On **admin login** (`isAdmin` flips true), trigger a full `syncFromBackend` so the
  admin gets everything.

State: `claimsLoaded = {}` (`goId → true`) tracks which GOs have had claims pulled.

### Landing list

`renderOrdersList` renders GO cards from metadata (name, deadline,
`subItems.length` POBs, Open/Closed). **Skip `renderGoPreview` when `!isAdmin`** (the
per-POB `setsSummary` needs claims). The card's existing meta line already shows the POB
count, matching the approved "minimal" look.

### Open a GO (lazy claims)

`openClaimPage(goId)` becomes async on the buyer path: if `!isAdmin && !claimsLoaded[goId]`,
show a small "loading…" state, `await` `getGOClaims(goId)` **plus** the per-GO flags the
board needs (`getSecuredSets`, `getClosedSubItems`, `getSubItemDeadlines`,
`getSubItemPayDue` — these are already small, whole-store fetches; load them here so the
board renders secured/closed/deadline correctly), rebuild that GO's sub-items via
`buildSetsFromClaims` / `buildBatchClaims`, set `claimsLoaded[goId] = true`, then render
the claim page. ↺ / re-open reloads. If the fetch fails, show a retry message (don't
render an empty board as if there are no claims).

### My Orders

The buyer lookup (`doLookup` / its trigger) becomes: `await getJoiners(username)` +
`getPayments` + `getShopOrders` + `getShipping`, then build the buyer's view from the
**flat claims** + the light sub-item metadata (`allGOs` prices/names):
- **Rows** (`item`, `member/version`, `qty`, `price`, `claim`, `payment`, `fulfillment`,
  `due`) come directly from each `getJoiners` claim + its sub-item's price from `allGOs`.
- **Owed / credit** per GO: replicate `paymentOwedUnits` from the user's flat claims —
  group set-based claims by `(sub_item, set_num)`; an all-OT set (`assigned_vers==='OT'`)
  → one unit at `ot_price`; other secured slots → one unit at `price`; batch/FCFS secured
  → `price × qty`; skip `dropped` and (batch/merch) unsecured. `paid` = confirmed payment
  proofs for that GO. This is the one new computation; it MUST match the admin's numbers
  (see Testing).
- Shop orders + shipping requests render from their own (already small) fetches.

### Admin path

Unchanged: `getAllGOs` + all secondary endpoints, full reconstruction, all admin views.

### Sync robustness

Keep the `apiGet`/`apiPost` retry + `Promise.allSettled` already in place.

## Error handling / degrade

- Landing `getGOsList` fails → keep any localStorage-cached `allGOs` and show the soft
  "couldn't refresh" note (existing pattern).
- `getGOClaims` fails on open → retry message on the board, not a false-empty board.
- Pre-redeploy (endpoints missing) → the buyer branch's calls 404; fall back to the old
  `getAllGOs` path so nothing breaks before the backend is deployed.

## Testing

- **Backend:** `getGOsList` returns GOs with sub-items and **no `claims`** key, and is
  materially smaller/faster than `getAllGOs` (verify via curl size/time). `getGOClaims`
  returns exactly the claims for one `go_id` (count matches that GO's slice of
  `getAllGOs`). `node --check` the backend copy.
- **Owed parity (critical):** for several real buyers (e.g. `@lexi_stay21`,
  `@queenracha8`), the new flat-claims owed/credit computation MUST equal the admin's
  `paymentOwedUnits`/`goPaymentSummary` output for the same user+GO. Validate with a Node
  harness against live data before shipping.
- **Frontend:** JS-parse. Buyer landing renders the GO list from metadata with no claims
  loaded; opening a GO lazy-loads and the board matches the admin's view of that GO;
  My Orders totals match; admin path still loads everything.
- **Manual:** buyer first open is fast (metadata only); open a GO → board fills;
  My Orders correct; admin login pulls full data.

## Out of scope (YAGNI)

- Server-side pagination of claims within one GO (per-GO is already small enough).
- Caching `getGOClaims` beyond the session.
- Changing the admin path.
- A PWA/installable wrapper (doesn't fix first-open data cost).

## Redeploy note

`getGOsList` + `getGOClaims` require redeploying `go-manager-backend.gs`. The buyer
branch falls back to `getAllGOs` if the new actions 404 (pre-redeploy safe).

## Suggested phasing (for the plan)

1. **Backend** `getGOsList` + `getGOClaims` (+ verify size/speed).
2. **Buyer landing** on `getGOsList` (metadata list, skip preview) + admin-login resync
   + fallback.
3. **Lazy claims on open** (`getGOClaims` + per-GO flags + reconstruct).
4. **My Orders** on `getJoiners` + owed-parity validation.
