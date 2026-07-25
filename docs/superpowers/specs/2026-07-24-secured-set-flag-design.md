# Explicit "Set Secured" Flag + Per-Claim Owed — Design

**Date:** 2026-07-24
**Status:** Design approved, pending spec review

## Problem

A set's "Secured" status is **derived** from its claims — "every filled slot is
secured ⇒ the set is Secured." So securing a **single** claim in a 1-claim set
flips the whole set to Secured (and, today, makes it owed). The admin secures
individual claims for some set-based cards, and that shouldn't mark the *set* as
secured. The data has no way to tell "admin clicked Secure set" from "admin secured
each claim individually."

## Goal

Two changes:

1. **Set "Secured" badge** shows only when the admin **clicked Secure-set** (an
   explicit, persisted flag) **or** the set is **full** (every member slot filled
   and all secured). Individual claim securing never badges the set.
2. **Owed is per-claim:** a claim the admin has secured (individually, via the
   Secure-set button, or as part of a full set) is **charged**, regardless of
   whether the whole *set* shows secured.

## Backend (Apps Script — REQUIRES REDEPLOY)

New sheet **`secured_sets`** — columns `go_id, sub_item_id, set_num`. One row = that
set was explicitly secured.

- `SHEET_SECURED_SETS = 'secured_sets'`; `ensureSheet(..., ['go_id','sub_item_id','set_num'])`.
- **`getSecuredSets()`** (doGet) → `{ secured_sets: [{go_id, sub_item_id, set_num}] }`.
- **`setSecuredSet(data)`** (doPost) `{ go_id, sub_item_id, set_num, secured }`:
  add the row if `secured` truthy and absent; delete it if falsy and present.
  (Match on all three, `set_num` compared as string.)
- Route both. `deleteGO` clears the GO's `secured_sets` rows.
- Existing `secureSet` / `unsecureSet` endpoints (which set claim_status) are
  unchanged — the flag is written separately by the frontend (below).

## Frontend

### State + reconstruction

- Module `securedSets = {}` — `go_id → { 'siId|setNum': true }`. Built in
  `syncFromBackend` from `getSecuredSets` (added to the `Promise.all`).
- Helper `isSetFlagged(goId, siId, setNum)`.
- `buildSetsFromClaims(claims, siId, members, goId)`: a set's `status` is
  **'secured'** iff **flagged** (`isSetFlagged`) **OR full** (all member slots
  filled AND every filled slot `claim_status==='secured'`). Otherwise 'open'.
  (Pass `goId` through so it can check the flag.)
- The other in-memory `set.status` recomputes (in `toggleSlotSecure`,
  `toggleSlotPayment`, `secureSet`/`unsecureSet`, `removeSlotClaim`/compaction,
  drop) use the **same rule** via a shared helper `deriveSetStatus(go, si, set)` →
  flagged-or-full. This replaces the current `filled.every(secured)` formula
  everywhere, so per-slot securing no longer auto-secures a partial set.

### Secure / unsecure the set (button)

- **`secureSet`**: as now, mark all filled slots `claim_status='secured'` and set
  `set.status='secured'`; **additionally** persist the flag:
  `persistWrite(apiPost('setSecuredSet', { go_id, sub_item_id, set_num, secured:true }), …)`
  and set `securedSets[goId]['siId|setNum']=true`.
- **`unsecureSet`**: revert slots to pending, remove the flag (`setSecuredSet …
  secured:false`, delete the local key), recompute status.

### Per-slot secure (`toggleSlotSecure`)

- Unchanged in what it persists (the claim's `claim_status`), but the set-status
  recompute now uses `deriveSetStatus` — so securing one slot does **not** flag the
  set; the set stays 'open' unless full or flagged. The individual slot still shows
  "Secured" to the buyer (via its `claim_status`).

### Owed — per-claim (`paymentOwedUnits`, set branch)

- Change from "only sets with `set.status==='secured'`" to **per-slot**: for each of
  the user's slots, charge it when `slot.claim_status==='secured'` and not dropped.
  - **OT** full set (all `slot.ot`): if the user's OT slots are secured, one unit at
    `si.otPrice`.
  - **Normal** slots: one unit at `si.price` per secured, non-OT slot.
- This makes individually-secured claims owed, and keeps button-/full-secured sets
  owed (their slots are all secured). No dependence on `set.status`.

## Migration (safe — after redeploy)

After the backend is redeployed, run a one-time backfill: for every set currently
derived as secured (all-filled-secured), write a `secured_sets` flag — so **nothing
un-secures on deploy** (the 19 existing secured sets keep their badge and owed).
Then the admin manually **unsecures** the few accidental ones (e.g. the Soundwave
1/8). Going forward, the new rule applies. (Backfill run via the API from the dev
side, like prior data cleanups.)

## Consistency notes

- Buyer "Secured" display (`doLookup`) already keys on
  `slot.claim_status==='secured' || set.status==='secured'` — still correct
  (individually-secured slots show Secured via claim_status).
- `setsSummary` "N secured" (admin) counts `set.status==='secured'` — now reflects
  flagged-or-full sets, matching the badge.

## Out of scope (YAGNI)

- Buyer-visible set-secured state beyond the existing per-claim display.
- Auto-securing at a threshold (explicitly not wanted).

## Redeploy note

`secured_sets` sheet + `getSecuredSets`/`setSecuredSet` require redeploying
`go-manager-backend.gs`. Pre-redeploy the frontend degrades: `getSecuredSets` errors
→ `securedSets` empty → set.status falls back to **full-only**, and `setSecuredSet`
writes fail (persistWrite surfaces + resyncs). So securing partial sets won't badge
until the redeploy + migration — expected.
