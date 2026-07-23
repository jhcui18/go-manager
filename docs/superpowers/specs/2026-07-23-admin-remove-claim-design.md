# Admin: Remove a Specific Claim — Design

**Date:** 2026-07-23
**Status:** Design approved, pending spec review

## Problem

The admin needs to remove a specific joiner's specific claim (e.g. "@han_stan's
Han in Makestar"). Today:
- **FCFS** claims (versioned/single/random/merch) have a direct **×** in the admin
  claims table. ✅
- **Set-based slots** (photocard / album-member) are only removable via **Edit →
  Remove claim**, and that Edit control **only renders on secured sets** — so a
  claim in a pending/unsecured set has **no in-app removal path**.
- **Batch POB** cards have **no removal control at all**.

So for the common case (cancel someone's pending claim), the admin went to the
Google Sheet — which can reshuffle set numbers on rebuild. We need a reliable
in-app removal for every claim.

## Goal

A direct **× (remove)** on every filled claim in the admin Manage detail — set
slots (any state), batch cards, FCFS — that deletes exactly that claim by
`claim_id` and cleanly frees the spot, with a confirm. No sheet editing, no
renumbering surprises.

## Behavior

- **Set-based slot** (`renderDetailContent` set branch): each taken slot shows a
  small **×** alongside its Paid / Secure badges, in **all states** (secured or
  not). Clicking it confirms, then removes that slot's claim.
- **Batch card** (`isBatch` branch): each batch claim card gets a **×** next to its
  Paid / Secure badges.
- **FCFS** (claims table): keep the existing **×** (`removeFCFSClaim`) — no change.
- **OT full set:** an OT purchase is one buyer holding every member slot of a set
  (`slot.ot`). Clicking × on any OT slot removes the **whole OT set** — all of that
  buyer's slots for it — not a single member. (A partial OT is not a valid state.)

### Confirm + delete

Clicking × asks: **"Remove @handle's claim for <member/item>? This can't be
undone."** (For OT: "Remove @handle's full OT set for <sub-item>?") On confirm:
- Delete the claim(s) on the backend via the existing `deleteClaim` (by
  `claim_id`), awaited before local save (destructive-write invariant).
- Update local state: set the slot(s) to `null` (set-based) or remove the claim
  from `si.claims` (batch); recompute `set.status`.
- `saveLocal()`, then re-render (`renderDetailContent`, `renderAdminGOList`,
  `renderOrdersList`).

### Rebuild / consolidation (chosen behavior)

After removal, the app rebuilds sets normally. A previously *bumped/spilled* claim
(one whose stored `set_num` points at the freed slot) may move up to fill the gap —
this is the app's existing `buildSetsFromClaims` behavior and is desired (keeps sets
consolidated). The removal itself never touches any other claim's row, so nobody
except a genuine spill-fill moves. No "freeze" logic.

## Data / reuse

- Reuses backend `deleteClaim(claim_id)` (no backend change, no redeploy).
- Reuses the existing per-slot removal helper (`removeSetClaim`) where possible;
  add a batch remover and an OT-aware remover.
- Confirm via the existing `confirm()` pattern used by other destructive admin
  actions.

## Out of scope (YAGNI)

- Buyer-side self-removal (separate, previously discussed and shelved).
- Removing a whole set/batch at once (this is per-claim; OT is the one multi-row
  case, handled as a unit).
- Undo / restore of a removed claim.
- A "freeze set numbers" mode.

## Backend impact

None. Frontend-only, reuses `deleteClaim`.
