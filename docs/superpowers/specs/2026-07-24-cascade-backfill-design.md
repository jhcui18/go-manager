# Cascade Backfill on Claim Delete — Design

**Date:** 2026-07-24
**Status:** Design approved, pending spec review

## Problem

When the admin removes a set-slot claim (member M in set N), the freed spot is
**not** filled by a joiner who claimed M in a higher set. The app's rebuild only
pulls a claim up if it was a *collision spill* (its stored `set_num` already points
at the freed slot); a genuine higher-set claim keeps its `set_num`, so gaps stay
open and sets never reach the secure threshold as quickly as they could.

## Goal

After a set-slot deletion, **cascade-backfill** member M's column so it stays packed
with no gaps: the next M (lowest set > N) moves into N, the one after moves up, etc.
Each moved claim's `set_num` is **persisted** (via the existing `updateClaim`, which
already writes `set_num` — no backend change) so securing/status stay correct.

## Scope

- **Set-based sub-items only** (photocard / album-member). Batch (recomputes from
  order) and FCFS (no sets) already compact automatically — unchanged.
- Runs automatically **after a deletion** via `removeSlotClaim` (single slot **and**
  OT-set removal). For OT removal, every member whose slot was freed is compacted.

## Behavior — per-member column compaction

For each affected member M (the deleted member, or all members for an OT removal),
pack M's **non-OT** claims into the lowest available set positions:

1. **Available positions** = the GO's sets (ascending by `.num`) whose M slot is
   either empty (`null`) or a **non-OT** filled claim. Sets whose M slot is an **OT**
   claim are **obstacles** — excluded (an OT block is never split or displaced).
2. **Donor claims** = the non-OT filled M claims among those positions, in ascending
   `.num` order (capture each with its current `set.num`).
3. Clear those positions' M slot, then place the donor claims into the **lowest**
   available positions in order.
4. For every claim whose landing `set.num` differs from its original, persist
   `apiPost('updateClaim', { claim_id, set_num })` (awaited together before
   `saveLocal`).
5. Recompute `set.status` for every set (all-filled-secured → 'secured', else
   'open'). Re-render.

This is idempotent: an already-packed column produces no moves.

## Edge decisions (approved)

- **OT sets skipped:** OT-occupied M slots are obstacles — never moved into or out
  of. The cascade hops over them. (Deleting an OT still removes the whole OT block,
  then compacts the freed columns.)
- **Secured claims shift too:** a secured claim above a gap moves up a set and stays
  secured (securing is per-claim `claim_status`, independent of set number).
- **Empty trailing sets** are trimmed by the existing rebuild — no special handling.

## Consistency with rebuild

The move persists each donor's new `set_num`, so a later `syncFromBackend` →
`buildSetsFromClaims` rebuilds from the packed, unique, gap-free `set_num`s (no
collision, no spill) and shows the same packed layout. No divergence between the
in-memory compaction and the reconstructed state.

## Data / reuse

- Reuses backend `updateClaim` (writes `set_num`) and `deleteClaim` — **no backend
  change, no redeploy**.
- New frontend helper `compactMemberColumn(si, member)`; called from `removeSlotClaim`
  after the deletion (once per freed member).

## Out of scope (YAGNI)

- Compaction triggered by anything other than an admin deletion (e.g. a periodic
  "compact all" button) — not needed; gaps only arise from removals.
- Cross-member repacking / reordering whole sets.
- Changing the buyer-facing set numbering model.

## Backend impact

None. Frontend-only (reuses `updateClaim` set_num).
