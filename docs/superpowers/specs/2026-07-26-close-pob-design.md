# Close a POB (Sub-Item) with Leftover-Spot Claiming — Design

**Date:** 2026-07-26
**Status:** Design approved, pending spec review

## Problem

A GO's open/closed status is all-or-nothing. But POBs (sub-items) in one GO close at
different times — the admin wants to close **Makestar** while **Soundwave** stays
open. There's no per-POB close today.

## Goal

Let the admin **Close / Reopen** an individual POB (sub-item). A closed POB stops
taking new claims — **except** it still lets buyers fill **leftover empty slots in
sets that were secured as a whole set** (a committed full-set order), so the admin
can sell off the cards they've already ordered.

## Key distinction (reuses the secured-set flag)

A set can be "secured" two ways, and only one has leftover spots:

- **Secured by set** — the admin clicked *Secure* on the whole set, or it filled
  8/8. Post the secured-set-flag feature, this is exactly `set.status === 'secured'`
  (flagged **or** full). A committed full set → empty slots are **real leftover
  cards** → still claimable when closed.
- **Secured by individual members** — the admin per-slot-secured specific claims
  (e.g. 4 Felix, 5 Han). Such a set has `set.status === 'open'` (individual
  `claim_status==='secured'` slots don't flag the set). Nothing was ordered for the
  empty slots → **no leftover** → not claimable.

So "leftover claimable" = an empty member slot in a set with **`set.status ===
'secured'`**. No new state needed for the distinction — it already exists.

## Data model (backend — REQUIRES REDEPLOY)

New **`closed_subitems`** store, mirroring `secured_sets`:

- Sheet `closed_subitems`, columns `go_id, sub_item_id`. One row = that POB is closed.
- `getClosedSubItems()` (doGet) → `{ closed_subitems: [{go_id, sub_item_id}] }`.
- `setClosedSubItem(data)` (doPost) `{ go_id, sub_item_id, closed }`: add the row if
  `closed` truthy and absent; delete it if falsy and present. Match on both fields.
- Route both. `deleteGO` clears the GO's `closed_subitems` rows.

(Whole-GO close keeps using the existing `go.status`.)

## Frontend

### State + reconstruction

- Module `closedSubItems = {}` — key `go_id + '|' + sub_item_id` → true. Loaded in
  `syncFromBackend` from `getClosedSubItems` (added to the `Promise.all`), **before**
  reconstruction.
- Helper `isSubItemClosed(goId, siId)`.
- On each sub-item, set `si.closed = isSubItemClosed(goId, si.id)` during
  reconstruction so render/claim code can read it directly.

### Admin — Close / Reopen toggle

- In the admin GO detail, each sub-item header gets a **Close POB / Reopen POB**
  button (near the sub-item name / secured summary).
- `toggleSubItemClosed(goId, siId)`: flip `si.closed`, persist
  `apiPost('setClosedSubItem', { go_id, sub_item_id, closed })` via `persistWrite`,
  update `closedSubItems`, re-render. A closed POB's admin card shows a **Closed**
  badge; securing/dropping/fulfillment controls stay fully usable.

### Claim placement — the core rule

New claims into a **closed** POB are allowed **only** to fill an empty member slot in
a set whose `status === 'secured'`.

- **Buyer view** (`renderSetSubItemPublic` / batch equivalent): a closed POB renders
  with a **Closed** banner. The member picker offers **only** members that have an
  empty slot in some `status==='secured'` set (the leftover spots); members without a
  leftover secured spot are shown non-claimable. If no leftover spots exist, the POB
  is effectively fully closed (nothing selectable).
- **Placement guard** (the function that assigns a new set-claim its `set_num` — set
  logging `logSetClaim` and buyer `submitClaim` set path): when `si.closed`, restrict
  target slots to empty slots of `status==='secured'` sets; if none available for the
  requested member, **reject** ("This POB is closed."). Never create a new set for a
  closed POB, and never fill a non-secured set.
- Open POBs: unchanged (fill earliest open slot / create sets as today).

### Whole-GO close — same leftover rule (change)

Today a closed GO (`go.status==='closed'`) rejects **all** claims. Apply the same
leftover-spot rule: when the GO is closed, a claim is allowed only if it fills an
empty slot in a `status==='secured'` set (of any still-relevant sub-item). This makes
whole-GO close consistent with per-POB close (sell off committed sets, block new
ones).

## Buyer-visible behavior

- Closed POB / closed GO shows a **"Closed — only filling already-ordered sets"**
  note (reuses the existing closed-GO note styling).
- Only leftover secured-set spots are claimable; everything else is blocked with a
  clear toast.

## Out of scope (YAGNI)

- Auto-close by date/deadline (this is a manual toggle; deadlines stay display-only).
- Per-set-number close (the ask is per-POB).
- Batch POBs: closing a batch POB uses the same `si.closed` flag and Closed banner;
  since batches have no "secured set with leftover slots" concept, a closed batch
  simply takes **no** new claims (there's nothing to leave open). No special leftover
  path.

## Testing

- **Backend:** `getClosedSubItems` returns `[]` initially; `setClosedSubItem`
  add/remove round-trips; `deleteGO` clears rows. `node --check` the backend copy.
- **Frontend placement (Node logic check):** closed POB + a `status==='secured'` set
  with an empty Changbin → a Changbin claim lands in that slot; a Hyunjin claim (no
  leftover secured spot) is rejected; an individual-member-secured set (status
  'open') with empty slots offers **no** leftover (rejected). Open POB unchanged.
- **JS-parse** index.html.
- **Manual:** close Makestar while Soundwave stays open; Makestar shows Closed;
  claiming a leftover secured-set member works, others blocked; refresh persists;
  reopen restores normal claiming.

## Redeploy note

`closed_subitems` sheet + `getClosedSubItems` / `setClosedSubItem` require redeploying
`go-manager-backend.gs`. Pre-redeploy, `getClosedSubItems` errors → `closedSubItems`
empty → POBs behave as open (safe degrade); `setClosedSubItem` writes fail
(`persistWrite` surfaces + resyncs).
