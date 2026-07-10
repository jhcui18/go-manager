# Quantity-batch POBs — Design

## Goal
Some POBs order in fixed batches of **N cards** (e.g. 8 or 16), where buyers claim **any
members with repeats allowed** (not one-of-each), pooled together. The admin fills batches of N,
and can **mark each full batch as ordered/secured** (persisted). Per-POB batch size.

## Why a new mode
The existing `member` kind is set-based with **member-keyed slots** (one slot per member, no
repeats). Batches need repeats and an arbitrary size N, so batch POBs are modeled as a
**claims-based** sub-item (flat list of member claims). Batches are **computed on the frontend by
count** — claims sorted by `created_at`, grouped into runs of N — NOT by stored `set_num`. This
reuses the claims-based lookup/payment/My-orders paths, needs **no backend change**, and means
**existing claims are preserved and auto-grouped** (no migration): a POB with 20 claims and
size 8 → Batch 1 (1–8), Batch 2 (9–16), Batch 3 (17–20 filling).

## Encoding (reuses min_secure column)
- `minSecure = -N` → batch mode with batch size N (negative = batch, magnitude = size).
  Survives backend/frontend `|| 7` coercion. Helpers: `isBatch(si)`, `batchSize(si) = -minSecure`.
- Replaces the earlier "don't require full sets" checkbox with an **"Order size (cards per
  batch)"** number field on member/photocard sub-item forms; blank/0 = normal full-set POB.

## Data shape
Batch-mode sub-item is claims-based: `{ id, name, kind:'member', members, minSecure:-N, price,
otPrice, claims:[ {user, member, claim_status, payment, fulfillment, claim_id, created_at, ot} ] }`
— **no `si.sets`**. (`created_at` carried so batches order deterministically; `ot` from
`assigned_vers==='OT'`.) `isBatch(si) = (si.kind==='member'||si.kind==='photocard') &&
parseInt(si.minSecure) < 0`.

## Frontend (index.html)
1. **Reconstruction** (`syncFromBackend`): for member/photocard with `min_secure < 0`, build the
   claims list (like `buildVersionedClaims` but carry `set_num` and `member_or_version`→`member`)
   instead of `buildSetsFromClaims`. A batch's `status` = secured if any of its claims is secured.
2. **Batch grouping helper** `goBatches(si)`: sort `si.claims` by `created_at` (tiebreak
   `claim_id`), slice into runs of `batchSize(si)`, each batch =
   `{ num, items:[claims], full: items.length >= batchSize(si), ordered: items.every(c => c.payment==='secured'||c.claim_status==='secured') }`.
3. **Buyer** `renderClaimPage`/`renderSetSubItemPublic`: when `isBatch(si)`, show
   **"Batch 1: 8/8 ✓ · Batch 2: 5/8"** (from `goBatches`) + a member picker (tap any member,
   repeats allowed → each tap = one claim). No member-slot board. **OT8 still supported**: if
   `otPrice > 0`, an `OT{members.length} — full set` tile creates one claim per member
   (`assigned_vers:'OT'`, flat OT price as one unit) counting as N-members cards toward the batches.
4. **Admin** `renderDetailContent`: when `isBatch(si)`, render each batch (its member/user claims)
   with a **Mark ordered / Unmark** button per batch → marks that batch's claims by `claim_id` via
   the existing `updateClaim` (claim_status secured/pending). Summary: `"X claimed · Y batches
   ordered"`.
5. **Claim submit** `submitClaim`: unchanged — a batch claim is just a member claim; the stored
   `set_num` is ignored for batching. Lookup/payment/My-orders use the existing claims-based branch.
6. `setsSummary`, `isNoSecure` removed/replaced by `isBatch` + `goBatches`.

## Backend
- **No change, no redeploy.** Securing a batch reuses the existing `updateClaim` endpoint per claim.
  Existing claims need no migration — they group into batches by `created_at` order automatically.

## Scope / non-goals
- Replaces the not-yet-merged "don't require full sets" toggle (that branch is superseded).
- **OT8 stays supported** in batch POBs (counts as N-members cards; priced as one flat unit —
  reuses existing OT claim handling in My-orders/payment for claims with `assigned_vers:'OT'`).
- **Existing claims are preserved** — converting a member POB to batch mode just re-groups its
  current claims into batches of N by `created_at`; nothing is lost, no migration.
- Editing batch size later re-groups the display only (claims untouched).
- Edge: an OT8 spanning a batch boundary can show partially ordered; and deleting a mid-batch claim
  shifts later claims' batch position (secured status stays per-claim). Both acceptable.

## Verification
- Create a member POB with order size 8. Buyers claim members incl. repeats + OT8; batches fill to
  8 and show ✓; a 9th claim opens batch 2. Mark batch 1 ordered → its claims persist as secured
  (via updateClaim); unmark reverts. Reconstructs correctly after sync. Convert an existing member
  POB with claims → they group into batches, none lost. Normal (blank size) POBs behave as today.
