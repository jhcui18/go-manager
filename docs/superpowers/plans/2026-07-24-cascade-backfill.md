# Cascade Backfill on Claim Delete — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After an admin removes a set-slot claim, pack the freed member's column so there are no gaps (cascade), persisting each moved claim's set number.

**Architecture:** Single-file `index.html`. New `compactMemberColumn(si, member)` packs a member's non-OT claims into the lowest set positions (OT slots are obstacles), persists moved `set_num`s via the existing `updateClaim`, and recomputes set statuses. `removeSlotClaim` calls it for each freed member after the deletion.

**Tech Stack:** Vanilla JS single-file app. No backend change (reuses `updateClaim` which already writes `set_num`).

## Global Constraints

- Edit `index.html` only. No backend change / no redeploy.
- Set-based only; batch/FCFS unchanged (already compact).
- OT-occupied member slots are obstacles — never moved into or out of. Only non-OT claims shift.
- Persist each moved claim's new `set_num` via `apiPost('updateClaim', { claim_id, set_num })`, awaited before `saveLocal`.
- Idempotent: an already-packed column produces no moves/writes.
- No test harness. Verify with JS-parse + a Node logic test of the packing. JS-parse:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after the task.

---

### Task 1: `compactMemberColumn` + wire into `removeSlotClaim`

**Files:**
- Modify: `index.html` — add `compactMemberColumn` just before `removeSlotClaim`; rewrite `removeSlotClaim` to track freed members and compact each.

**Interfaces:**
- Consumes: `si.sets` (each `{ status, slots:{member:slot|null}, num }`), slot `{ user, claim_status, claim_id, ot }`, `apiPost`, `API_URL`.
- Produces: `compactMemberColumn(si, member)` (async).

- [ ] **Step 1: Add `compactMemberColumn` before `removeSlotClaim`**

Insert immediately before `async function removeSlotClaim(`:

```javascript
// Pack a member's NON-OT claims into the lowest set positions (no gaps), persisting any moved
// set_num. OT-occupied member slots are obstacles (never moved into/out of). Idempotent.
async function compactMemberColumn(si, member) {
  if (!si || !si.sets) return;
  // Positions available to this member's column: sets whose member slot is empty or a non-OT
  // claim. OT-occupied slots are excluded (obstacles). Ascending by set number.
  const avail = si.sets.slice().sort((a, b) => (a.num || 0) - (b.num || 0))
    .filter(s => !s.slots[member] || !s.slots[member].ot);
  // Pull out the donor claims (non-OT filled), in order, remembering their current set number.
  const donors = [];
  avail.forEach(s => {
    const sl = s.slots[member];
    if (sl && !sl.ot) { donors.push({ slot: sl, fromNum: s.num }); s.slots[member] = null; }
  });
  // Re-place donors into the lowest available positions; persist any that landed in a new set.
  const writes = [];
  donors.forEach((d, i) => {
    const target = avail[i];
    target.slots[member] = d.slot;
    if (target.num !== d.fromNum && API_URL && d.slot.claim_id) {
      writes.push(apiPost('updateClaim', { claim_id: d.slot.claim_id, set_num: target.num }).catch(() => {}));
    }
  });
  if (writes.length) await Promise.all(writes);
  // Compaction can change any set's fill — recompute every set's status.
  si.sets.forEach(s => {
    const filled = Object.values(s.slots).filter(Boolean);
    s.status = filled.length && filled.every(v => v.claim_status === 'secured') ? 'secured' : 'open';
  });
}
```

- [ ] **Step 2: Rewrite `removeSlotClaim` to track freed members and compact**

Replace the entire existing `removeSlotClaim` function:

```javascript
async function removeSlotClaim(goId, siId, setIdx, member) {
  const si = allGOs[goId].subItems.find(s => s.id === siId);
  const set = si && si.sets[setIdx];
  const slot = set && set.slots[member];
  if (!slot) return;
  const who = slot.user;
  if (slot.ot) {
    if (!confirm(`Remove ${who}'s full OT set for "${si.name}"? This can't be undone.`)) return;
    for (const m of Object.keys(set.slots)) {
      const s2 = set.slots[m];
      if (s2 && s2.ot && sameUser(s2.user, who)) {
        if (API_URL && s2.claim_id) { try { await apiPost('deleteClaim', { claim_id: s2.claim_id }); } catch (e) {} }
        set.slots[m] = null;
      }
    }
  } else {
    if (!confirm(`Remove ${who}'s claim for ${member}? This can't be undone.`)) return;
    if (API_URL && slot.claim_id) { try { await apiPost('deleteClaim', { claim_id: slot.claim_id }); } catch (e) {} }
    set.slots[member] = null;
  }
  // Cascade-backfill: pack each affected member's column so freed spots are filled from higher
  // sets (persists moved set_nums, recomputes set statuses).
  const freed = slot.ot ? (si.members || Object.keys(set.slots)) : [member];
  for (const m of freed) await compactMemberColumn(si, m);
  saveLocal();
  renderDetailContent(); renderAdminGOList(); renderOrdersList();
  toast('Claim removed.');
}
```

Note: `slot.ot` is read before the loop nulls the slots, so `freed` is decided correctly. For an OT removal, every member column is compacted (the freed OT positions become fillable); for a single removal, just that member.

- [ ] **Step 3: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 4: Verify packing logic in Node**

Write `/private/tmp/claude-501/-Users-jinghancui/96b57dba-e91a-4bf3-a521-0b65a82da0bf/scratchpad/compact.mjs` that reimplements the `compactMemberColumn` placement logic (sans network) against a fake `si.sets`, and asserts:

```
// Han in sets [1,2,3] plus a gap: after deleting set-2 Han (null), compact -> Han in sets [1,2]
//   (the set-3 Han moved down to set 2). set 3 Han empty.
// Cascade: Han in sets [1,2,3,4], delete set-1 -> Han packs to [1,2,3] (2->1,3->2,4->3).
// OT obstacle: set 3 Han is OT (owned) -> a set-2 gap does NOT pull the OT; only non-OT donors move,
//   OT stays in set 3.
// Idempotent: already-packed [1,2,3] with no gap -> no moves.
```

Print PASS/FAIL per case. Run it; all must PASS.

- [ ] **Step 5: Verify in browser**

Admin → Manage on a photocard GO where a member (e.g. Han) has claims across several sets (e.g. sets 1–4, different joiners). Delete Han in set 2 → the set-3 Han joiner slides into set 2, set-4 into 3, etc. — Han's column stays packed with no gap, and it persists after ↺ refresh. An **OT** set in the middle is not disturbed. Deleting a whole OT set frees its slots and pulls the other sets up.

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "Cascade backfill: pack a member's column after deleting a set-slot claim"
```

---

## Self-Review

**Spec coverage:** per-member packing into lowest positions, OT obstacles excluded, moved set_nums persisted via updateClaim, statuses recomputed → Step 1 ✓; wired into removeSlotClaim for single + OT (all members) → Step 2 ✓; set-based only (removeSlotClaim is set-based), batch/FCFS untouched ✓; idempotent (target.num===fromNum → no write) ✓; no backend change ✓.

**Placeholder scan:** none.

**Type/name consistency:** `compactMemberColumn(si, member)` defined Step 1, called Step 2. Uses `s.num`, `s.slots[member]`, `slot.ot`, `slot.claim_id`, `slot.claim_status` — matching `buildSetsFromClaims` slot shape. `updateClaim { claim_id, set_num }` matches the backend (writes `set_num`). `si.members` used for OT-freed member list (photocard/album-member sub-items always have `members`).
