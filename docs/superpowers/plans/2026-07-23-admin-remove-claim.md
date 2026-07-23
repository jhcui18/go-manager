# Admin Remove a Specific Claim — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A direct × (remove) on every filled claim in admin Manage — set slots (any state), batch cards — that deletes exactly that claim by `claim_id` (OT slots remove the whole OT set), with a confirm. FCFS already has its ×.

**Architecture:** Single-file `index.html`. Add `removeSlotClaim(goId,siId,setIdx,member)` (OT-aware) and `removeBatchClaim(goId,siId,claimId)`, and a × button in the set-slot `payHtml` and the batch card badge row. Reuses the existing backend `deleteClaim`.

**Tech Stack:** Vanilla JS single-file app. No backend change.

## Global Constraints

- Edit `index.html` only. No backend change / no redeploy (reuses `deleteClaim`).
- Deletes only the clicked claim by `claim_id`; OT slot → all of that buyer's OT slots in the set. Never touches other claims' rows.
- Await each `deleteClaim` before `saveLocal()` (destructive-write invariant), then re-render `renderDetailContent`/`renderAdminGOList`/`renderOrdersList`.
- × only on filled, non-dropped claims (dropped slots already show Restore).
- No test harness. Verify with JS-parse + manual browser. JS-parse:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after the task.

---

### Task 1: Remove-claim handlers + × buttons

**Files:**
- Modify: `index.html` — add `removeSlotClaim` + `removeBatchClaim` near `removeSetClaim`; add × in the set-slot `payHtml` (~line 2104) and the batch card badge row (~line 2029).

**Interfaces:**
- Consumes: `allGOs`, `apiPost('deleteClaim',…)`, `sameUser`, `saveLocal`, `renderDetailContent`/`renderAdminGOList`/`renderOrdersList`, `toast`.
- Produces: `removeSlotClaim(goId, siId, setIdx, member)`, `removeBatchClaim(goId, siId, claimId)`.

- [ ] **Step 1: Add the two handlers**

Immediately after the existing `removeSetClaim` function (find its closing brace), add:

```javascript
// Remove one set-slot claim (or, for an OT slot, the buyer's whole OT set). Deletes by
// claim_id — never touches other rows; the normal rebuild may fill the freed spot.
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
  const filled = Object.values(set.slots).filter(Boolean);
  set.status = filled.length && filled.every(v => v.claim_status === 'secured') ? 'secured' : 'open';
  saveLocal();
  renderDetailContent(); renderAdminGOList(); renderOrdersList();
  toast('Claim removed.');
}

// Remove one batch POB claim by claim_id.
async function removeBatchClaim(goId, siId, claimId) {
  const si = allGOs[goId].subItems.find(s => s.id === siId);
  const c = si && (si.claims || []).find(x => x.claim_id === claimId);
  if (!c) return;
  if (!confirm(`Remove ${c.user}'s claim for ${c.member}? This can't be undone.`)) return;
  if (API_URL && claimId) { try { await apiPost('deleteClaim', { claim_id: claimId }); } catch (e) {} }
  si.claims = si.claims.filter(x => x.claim_id !== claimId);
  saveLocal();
  renderDetailContent(); renderAdminGOList(); renderOrdersList();
  toast('Claim removed.');
}
```

- [ ] **Step 2: Add × to the set-slot badges (non-dropped `payHtml`)**

In the set-slot render, the non-dropped `payHtml` branch currently ends with the "Secure?" badge then `</div>`. Replace:

```javascript
            <span class="badge ${slot.claim_status==='secured'?'badge-secured':'badge-pending'}" style="font-size:10px;cursor:pointer;" title="Click to secure/unsecure this claim" onclick="toggleSlotSecure('${go.id}','${si.id}',${setIdx},'${member}')">${slot.claim_status==='secured'?'Secured':'Secure?'}</span>
          </div>`) : '';
```

with (adds a red × remove button after the Secure? badge):

```javascript
            <span class="badge ${slot.claim_status==='secured'?'badge-secured':'badge-pending'}" style="font-size:10px;cursor:pointer;" title="Click to secure/unsecure this claim" onclick="toggleSlotSecure('${go.id}','${si.id}',${setIdx},'${member}')">${slot.claim_status==='secured'?'Secured':'Secure?'}</span>
            <button class="btn btn-sm btn-ghost" style="font-size:11px;padding:1px 6px;color:var(--red-400);" title="Remove this claim" onclick="removeSlotClaim('${go.id}','${si.id}',${setIdx},'${member}')">×</button>
          </div>`) : '';
```

- [ ] **Step 3: Add × to the batch card badges**

In the batch card render, replace:

```javascript
              <span class="badge ${sec?'badge-secured':'badge-pending'}" style="font-size:10px;cursor:pointer;" onclick="toggleClaimSecure('${c.claim_id}','${go.id}','${si.id}')">${sec?'Secured':'Secure?'}</span>
            </div>
          </div>`;
        });
```

with (adds the × after the Secure? badge):

```javascript
              <span class="badge ${sec?'badge-secured':'badge-pending'}" style="font-size:10px;cursor:pointer;" onclick="toggleClaimSecure('${c.claim_id}','${go.id}','${si.id}')">${sec?'Secured':'Secure?'}</span>
              <button class="btn btn-sm btn-ghost" style="font-size:11px;padding:1px 6px;color:var(--red-400);" title="Remove this claim" onclick="removeBatchClaim('${go.id}','${si.id}','${c.claim_id}')">×</button>
            </div>
          </div>`;
        });
```

- [ ] **Step 4: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 5: Verify in browser**

Admin → Manage on a GO:
- **Photocard/album set** (unsecured): each taken member slot now shows a red **×**. Click it → confirms "Remove @handle's claim for <member>?" → on confirm the slot goes back to **open**, the claim disappears, and no other slot is disturbed. Works on secured sets too.
- **OT full set:** clicking × on any OT slot confirms "Remove @handle's full OT set…" and clears all that buyer's slots in the set.
- **Batch POB:** each batch card now has a **×**; removing drops just that card.
- Reload (↺) → the removed claim stays gone (persisted via `deleteClaim`); a previously bumped/spilled claim may have moved up to fill the freed spot (expected consolidation).

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "Admin: × to remove a specific claim on set slots (OT-aware) + batch cards"
```

---

## Self-Review

**Spec coverage:** × on set slots any state → Step 2 ✓; OT removes whole set → Step 1 `removeSlotClaim` ✓; batch × → Steps 1+3 ✓; FCFS unchanged (already has ×) ✓; deletes by claim_id via existing `deleteClaim`, awaited before saveLocal, recompute set.status, re-render → Step 1 ✓; consolidation on rebuild is existing behavior (untouched) ✓; frontend-only ✓.

**Placeholder scan:** none.

**Type/name consistency:** `removeSlotClaim(goId,siId,setIdx,member)` and `removeBatchClaim(goId,siId,claimId)` defined in Step 1, called from Steps 2/3 with matching args. `slot.ot`, `slot.claim_id`, `slot.user`, `c.claim_id`, `c.user`, `c.member` match the shapes produced by `buildSetsFromClaims`/`buildBatchClaims`. `sameUser` and `deleteClaim` reused as elsewhere.
