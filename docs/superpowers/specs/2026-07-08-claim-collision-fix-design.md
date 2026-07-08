# Claim slot-collision fix — Design

## Problem
Set-based sub-items (photocard, album `member`) store one claim row per (sub-item, set_num,
member) slot. Two buyers can end up with claims for the **same slot** (same sub-item, same
`set_num`, same member) when a client submits with stale state — especially after a GO is
edited/recreated, or on concurrent claims. On reconstruction, `buildSetsFromClaims` fills
`slots[member] = {user}` in sheet-row order, so **the later row overwrites the earlier one**
and the earlier claimant silently disappears from My orders and admin Manage. Real cases found
in the live sheet: @g.hags9, @sehnitrades, @here.for.the.vibes_, @neukamemma, @sakeoftrades.

## Fix #1 — Recovery (frontend, `buildSetsFromClaims`, no redeploy)
Never overwrite; spill collisions into other sets so every claim stays visible.

Algorithm:
1. `filtered` = claims for this sub-item. If none, return one empty set (`num:1`).
2. Sort `filtered` by `created_at` ascending (tiebreak `claim_id`) — **earliest claim wins a
   contested slot** (fair; also fixes the case where the first claimant was the one hidden).
3. Maintain `setsByNum` (num → {status, slots, num}); `getSet(n)` lazily creates a set with all
   `members` slots = null.
4. For each claim (in sorted order), let `n = parseInt(set_num)||1`, `member = member_or_version`.
   Try to place into the first set among `[n, ...existing nums > n]` whose `slots[member]` is free.
   If none is free, create a brand-new set at the smallest unused number and place it there.
   Placing a claim whose `claim_status==='secured'` marks that set `secured`.
5. Sort sets by `num`. If the last set is full, append a trailing empty set (existing behavior).
- Slot object unchanged: `{ user, payment, fulfillment, claim_id, ot: assigned_vers==='OT' }`.
- OT sets: a buyer's OT batch shares one `set_num` and each member is free there, so they stay
  together in the normal case. (Rare OT-vs-OT collisions may scatter; acceptable — still visible.)

Effect: on the next sync, all currently-hidden buyers reappear (in their own sets), and genuine
two-people-one-slot conflicts show as extra sets so the admin can adjudicate.

## Fix #2 — Prevention (backend `go-manager-backend.gs` `submitClaim`, needs redeploy)
Make the **server** assign `set_num` authoritatively so a stale/concurrent client can't book a
taken slot. Chosen behavior: **auto-place in the next set where that member is free** (not reject).

Algorithm (inside `submitClaim`, guarded by `LockService.getScriptLock().waitLock(10000)`):
1. Split incoming `data.claims` into set-based (kind `member`/`photocard`, has `member_or_version`)
   and other (versioned/single/random/merch — `set_num` stays empty, append as today).
2. For set-based, read current joiners rows for each `(go_id, sub_item_id)` and build
   `taken[set_num] = Set(members)`; also track `assigned` made within this batch.
3. Normal member claim: assign the smallest `set_num >= 1` whose member slot is free in
   `taken` ∪ `assigned`; record it. OT batch (any `assigned_vers==='OT'`): assign the whole
   batch to one fresh set = `max(existing set_num) + 1`.
4. Append rows with the **server-assigned** `set_num`; release the lock in a `finally`.
- Return the assigned `set_num`s so the client can reconcile (optional; sync will correct anyway).

## Scope / non-goals
- Only set-based sub-items are affected. FCFS (versioned/single/random) is unchanged.
- Fix #1 does not rewrite the sheet; it only changes reconstruction. Fix #2 changes what
  `set_num` gets written going forward. Past colliding rows are healed on read by Fix #1.
- No schema change.

## Verification
- Fix #1: with the current sheet, after sync, the 5 known collisions show **both** buyers in
  separate sets (nobody missing); a unit check of `buildSetsFromClaims` on the collision fixtures.
- Fix #2 (post-redeploy): two rapid claims for the same member land in different `set_num`s;
  a normal claim still fills the lowest open set; an OT claim gets its own new set.
