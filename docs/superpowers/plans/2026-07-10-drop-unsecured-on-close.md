# Drop Unsecured Claims on GO Close — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an admin closes a GO, let them review the still-unsecured claims and mark them **Dropped** (won't be ordered) via a confirm step, while never auto-dropping paid claims and keeping every drop reversible.

**Architecture:** Single-file browser app (`index.html`, HTML+CSS+JS). Reuse the existing per-claim `claim_status` field by adding one value, `'dropped'`. A closed GO's unsecured claims — set-based slots in non-secured sets, and batch claims not yet secured — are collected by a new `collectUnsecured(go)` helper, shown in a review modal, and set to `claim_status:'dropped'` on confirm (persisted via the existing `updateClaim` endpoint). FCFS claims-based items (versioned/single/random/album-member-FCFS) are firm orders and out of scope. No backend change.

**Tech Stack:** Vanilla JS in one HTML file. Backend is Google Apps Script (unchanged). Hosted on GitHub Pages.

## Global Constraints

- All edits are in `/Users/jinghancui/Gitproj/Go-manager/index.html`. No other file changes.
- No backend redeploy: `apiPost('updateClaim', { claim_id, claim_status })` already persists `claim_status`; writing `'dropped'` or `'pending'` uses it unchanged.
- **Scope:** only set-based (`si.sets`) and batch (`isBatch(si)`) sub-items have unsecured claims. FCFS claims-based items are never in the drop flow.
- **Never auto-drop a paid claim** (`slot.payment === 'paid'` / `c.payment === 'paid'`): route it to the review modal's "Needs your attention" group, never drop it on confirm.
- Persistence rule: all `updateClaim` calls in the confirm handler are `await`ed before `saveLocal()`.
- Copy: buyer badge reads **"Not fulfilled"**; admin badge reads **"Dropped"**; the restore control reads **"Restore"**.
- No automated test harness exists. Verification is manual in a browser plus DevTools console assertions. Load with `open /Users/jinghancui/Gitproj/Go-manager/index.html` (admin PIN / API URL as normally used).
- Commit after each task.

---

### Task 1: Core helpers — collect, drop, restore, and exclude dropped from batches

**Files:**
- Modify: `index.html` — `goBatches` (line 511), and add new helpers immediately after `unsecureSet` (ends line 2103)

**Interfaces:**
- Produces:
  - `collectUnsecured(go)` → `{ droppable: Ref[], paid: Ref[] }`
  - `Ref` = `{ siId, siName, kind:'set'|'batch', setIdx:(number|null), member:(string|null), claimId:(string|undefined), user:string, label:string }`
  - `applyClaimStatusRef(go, ref, status)` — sets `claim_status` on the ref'd slot/claim and (for set refs) recomputes `set.status`
  - `restoreClaim(goId, kind, siId, setIdx, member, claimId)` — sets the target back to `'pending'`, persists, re-renders

- [ ] **Step 1: Exclude dropped claims from batch grouping**

In `goBatches` (line 511), filter out dropped claims before sorting/grouping so a dropped batch claim no longer occupies a batch slot:

```javascript
function goBatches(si) {
  const n = batchSize(si);
  const claims = (si.claims || []).filter(c => c.claim_status !== 'dropped').slice().sort((a, b) => {
    const ta = a.created_at || '', tb = b.created_at || '';
    if (ta !== tb) return ta < tb ? -1 : 1;
    return String(a.claim_id) < String(b.claim_id) ? -1 : 1;
  });
  const batches = [];
  for (let i = 0; i < claims.length; i += n) {
    const items = claims.slice(i, i + n);
    batches.push({ num: batches.length + 1, items, full: items.length >= n, ordered: items.length > 0 && items.every(c => c.claim_status === 'secured') });
  }
  return batches;
}
```

- [ ] **Step 2: Add the collect / apply / restore helpers**

Immediately after `unsecureSet` (after its closing brace, line 2103), add:

```javascript
// ── Drop-unsecured-on-close ────────────────────────────────────────────────
// Collect a GO's not-yet-secured claims from set-based & batch sub-items only.
// Paid claims go to `paid` (never auto-dropped); the rest to `droppable`.
function collectUnsecured(go) {
  const droppable = [], paid = [];
  (go.subItems || []).forEach(si => {
    if (si.sets) {
      si.sets.forEach((set, setIdx) => {
        if (set.status === 'secured') return;
        Object.keys(set.slots).forEach(member => {
          const slot = set.slots[member];
          if (!slot || slot.claim_status === 'secured' || slot.claim_status === 'dropped') return;
          const ref = { siId: si.id, siName: si.name, kind: 'set', setIdx, member, claimId: slot.claim_id, user: slot.user, label: member };
          (slot.payment === 'paid' ? paid : droppable).push(ref);
        });
      });
    } else if (isBatch(si)) {
      (si.claims || []).forEach(c => {
        if (c.claim_status === 'secured' || c.claim_status === 'dropped') return;
        const ref = { siId: si.id, siName: si.name, kind: 'batch', setIdx: null, member: null, claimId: c.claim_id, user: c.user, label: (c.member || '') + (c.ot ? ' (OT)' : '') };
        (c.payment === 'paid' ? paid : droppable).push(ref);
      });
    }
    // FCFS claims-based (versioned/single/random/member-FCFS): firm orders — skipped.
  });
  return { droppable, paid };
}

// Set claim_status on the slot/claim a ref points to. For set refs, recompute set.status.
function applyClaimStatusRef(go, ref, status) {
  const si = (go.subItems || []).find(s => s.id === ref.siId);
  if (!si) return;
  if (ref.kind === 'set') {
    const set = si.sets[ref.setIdx];
    const slot = set && set.slots[ref.member];
    if (!slot) return;
    slot.claim_status = status;
    const filled = Object.values(set.slots).filter(Boolean);
    set.status = filled.length && filled.every(v => v.claim_status === 'secured') ? 'secured' : 'open';
  } else {
    const c = (si.claims || []).find(x => x.claim_id === ref.claimId);
    if (c) c.claim_status = status;
  }
}

// Restore a dropped claim back to pending (active/unsecured). Persists + re-renders.
async function restoreClaim(goId, kind, siId, setIdx, member, claimId) {
  const go = allGOs[goId];
  const ref = { kind, siId, setIdx, member, claimId };
  applyClaimStatusRef(go, ref, 'pending');
  if (API_URL && claimId) { try { await apiPost('updateClaim', { claim_id: claimId, claim_status: 'pending' }); } catch (e) {} }
  saveLocal();
  renderDetailContent(); renderAdminGOList(); renderOrdersList();
  toast('Claim restored.');
}
```

- [ ] **Step 3: Verify in browser (console)**

Open the app, log in as admin so `allGOs` is populated. Pick a GO id with a partly-filled photocard or batch sub-item and run in DevTools console:

```javascript
const go = Object.values(allGOs).find(g => g.subItems.some(s => s.sets || (typeof isBatch==='function' && isBatch(s))));
collectUnsecured(go)
```

Expected: an object `{ droppable: [...], paid: [...] }`. Each entry has `siId`, `kind` (`'set'` or `'batch'`), `user`, `label`, and `claimId`. Secured slots/claims and paid ones are absent from `droppable` (paid ones appear in `paid`). Then confirm the mutator works:

```javascript
const ref = collectUnsecured(go).droppable[0];
applyClaimStatusRef(go, ref, 'dropped');
// re-read: the target slot/claim now has claim_status 'dropped'
collectUnsecured(go).droppable.find(r => r.claimId === ref.claimId)  // → undefined (no longer droppable)
applyClaimStatusRef(go, ref, 'pending');  // put it back for a clean state
```

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "Drop-on-close: collectUnsecured + apply/restore helpers, exclude dropped from batches"
```

---

### Task 2: Read-side rendering — buyer 'Not fulfilled', summaries exclude dropped

**Files:**
- Modify: `index.html` — badge CSS (~line 55), `setsSummary` (line 525), `doLookup` OT row (line 1527), set row (line 1533), claims row (line 1542), totals + count (~lines 1558–1565), lookup badge (line 1567)

**Interfaces:**
- Consumes: `claim_status === 'dropped'` written by Task 1 helpers.

- [ ] **Step 1: Add a muted dropped badge class**

After the `.badge-secured` rule (line 55), add:

```css
  .badge-dropped { background:var(--gray-100);color:var(--text3); }
```

- [ ] **Step 2: Show a dropped tally in `setsSummary`**

Replace `setsSummary` (line 525) so dropped claims are subtracted from the active count and reported separately:

```javascript
function setsSummary(si) {
  if (isBatch(si)) {
    const batches = goBatches(si);
    const ordered = batches.filter(b => b.ordered).length;
    const active = (si.claims || []).filter(c => c.claim_status !== 'dropped').length;
    const dropped = (si.claims || []).filter(c => c.claim_status === 'dropped').length;
    return `${active} claimed · ${ordered}/${batches.length} secured` + (dropped ? ` · ${dropped} dropped` : '');
  }
  if (si.sets) {
    const real = si.sets.filter(s => Object.values(s.slots).some(v => v)).length;
    const secured = si.sets.filter(s => s.status === 'secured').length;
    const dropped = si.sets.reduce((a, s) => a + Object.values(s.slots).filter(v => v && v.claim_status === 'dropped').length, 0);
    return `${real} set${real !== 1 ? 's' : ''} · ${secured} secured` + (dropped ? ` · ${dropped} dropped` : '');
  }
  const n = (si.claims || []).reduce((a, c) => a + (c.qty || 1), 0);
  return `${n} claimed`;
}
```

- [ ] **Step 3: Render dropped claims as "Not fulfilled" in `doLookup`**

Change the three row-push sites to map a dropped status to `'Not fulfilled'`.

OT row (line 1527) — replace the `claim:` expression:

```javascript
            rows.push({ go_id:go.id, go:go.name, item:si.name, detail:'OT'+membersToCheck.length+' full set', qty:1, price:si.otPrice||0, claim:(s0.claim_status==='dropped')?'Not fulfilled':((s0.claim_status==='secured'||set.status==='secured')?'Secured':'Pending'), payment:s0.payment, fulfillment:s0.fulfillment });
```

Set row (line 1533):

```javascript
              rows.push({ go_id:go.id, go:go.name, item:si.name, detail:member, qty:1, price:si.price||0, claim:(slot.claim_status==='dropped')?'Not fulfilled':((slot.claim_status==='secured'||set.status==='secured')?'Secured':'Pending'), payment:slot.payment, fulfillment:slot.fulfillment });
```

Claims row (line 1542):

```javascript
            rows.push({ go_id:go.id, go:go.name, item:si.name, detail, qty:c.qty, price:si.price||0, claim:(c.claim_status==='dropped')?'Not fulfilled':((c.claim_status && c.claim_status !== 'secured') ? 'Pending' : 'Secured'), payment:c.payment, fulfillment:c.fulfillment });
```

- [ ] **Step 4: Exclude dropped rows from totals and the active-claim count**

Locate the totals block (lines ~1558–1560):

```javascript
  document.getElementById('result-count').textContent = rows.length + ' active claim' + (rows.length!==1?'s':'');
  const tbody = document.getElementById('lookup-tbody');
  const grandTotal = rows.reduce((a, r) => a + (r.price * r.qty), 0);
  const paidTotal = rows.filter(r => r.payment === 'paid').reduce((a, r) => a + (r.price * r.qty), 0);
```

Replace with (dropped rows still render, but don't count toward totals or the active tally):

```javascript
  const activeRows = rows.filter(r => r.claim !== 'Not fulfilled');
  document.getElementById('result-count').textContent = activeRows.length + ' active claim' + (activeRows.length!==1?'s':'');
  const tbody = document.getElementById('lookup-tbody');
  const grandTotal = activeRows.reduce((a, r) => a + (r.price * r.qty), 0);
  const paidTotal = activeRows.filter(r => r.payment === 'paid').reduce((a, r) => a + (r.price * r.qty), 0);
```

- [ ] **Step 5: Give the dropped row a muted badge**

Change the claim-status badge cell (line 1567):

```javascript
    <td><span class="badge ${r.claim==='Secured'?'badge-secured':r.claim==='Not fulfilled'?'badge-dropped':'badge-pending'}">${r.claim}</span></td>
```

- [ ] **Step 6: Verify in browser**

Reuse the GO from Task 1. In console, drop one buyer's claim manually and note the buyer handle:

```javascript
const go = Object.values(allGOs).find(g => g.subItems.some(s => s.sets || isBatch(s)));
const ref = collectUnsecured(go).droppable[0];
applyClaimStatusRef(go, ref, 'dropped'); saveLocal();
ref.user  // ← look this buyer up
```

Go to **My orders**, look up that buyer. Expected: their dropped item shows a greyed **"Not fulfilled"** badge, is NOT counted in "N active claims", and is excluded from the owed/grand total. In admin, the sub-item header summary now ends with "· 1 dropped". Restore for a clean state:

```javascript
applyClaimStatusRef(go, ref, 'pending'); saveLocal();
```

- [ ] **Step 7: Commit**

```bash
git add index.html
git commit -m "Drop-on-close: buyer 'Not fulfilled' rendering + summaries exclude dropped"
```

---

### Task 3: Admin detail — Dropped badge + Restore on set slots and batch claims

**Files:**
- Modify: `index.html` — batch claim card (~lines 1851–1859), set slot `payHtml` (~lines 1916–1919), and add a dropped-batch sub-section after the batch loop (~line 1863)

**Interfaces:**
- Consumes: `claim_status === 'dropped'`; `restoreClaim(goId, kind, siId, setIdx, member, claimId)` from Task 1.

- [ ] **Step 1: Set-based slot — show Dropped + Restore instead of Secure?**

In the set slot render, replace the `payHtml` definition (lines ~1916–1919) so a dropped slot swaps its Paid/Secure badges for a muted Dropped badge and a Restore button:

```javascript
          const payHtml = taken ? (slot.claim_status === 'dropped' ? `<div style="margin-top:3px;display:flex;gap:4px;flex-wrap:wrap;align-items:center;">
            <span class="badge badge-dropped" style="font-size:10px;">Dropped</span>
            <button class="btn btn-sm btn-ghost" style="font-size:10px;padding:2px 6px;" onclick="restoreClaim('${go.id}','set','${si.id}',${setIdx},'${member}')">Restore</button>
          </div>` : `<div style="margin-top:3px;display:flex;gap:4px;flex-wrap:wrap;">
            <span class="badge ${slot.payment==='paid'?'badge-paid':'badge-unpaid'}" style="font-size:10px;cursor:pointer;" title="Click to toggle paid/unpaid" onclick="toggleSlotPayment('${go.id}','${si.id}',${setIdx},'${member}')">${slot.payment==='paid'?'Paid':'Unpaid'}</span>
            <span class="badge ${slot.claim_status==='secured'?'badge-secured':'badge-pending'}" style="font-size:10px;cursor:pointer;" title="Click to secure/unsecure this claim" onclick="toggleSlotSecure('${go.id}','${si.id}',${setIdx},'${member}')">${slot.claim_status==='secured'?'Secured':'Secure?'}</span>
          </div>`) : '';
```

- [ ] **Step 2: Batch — add a "Dropped" sub-section with Restore**

Dropped batch claims are filtered out of `goBatches` (Task 1), so they no longer render inside batch cards. After the `batches.forEach(...)` loop closes and before the `} else if (si.sets) {` (the block ends at line 1863 with `html += \`</div></div>\`;` inside the loop, then `});`), add a dropped list. Insert immediately after the batch `});` that closes `batches.forEach`:

```javascript
      const droppedBatch = (si.claims || []).filter(c => c.claim_status === 'dropped');
      if (droppedBatch.length) {
        html += `<div class="card" style="margin-bottom:10px;"><div style="font-size:12px;color:var(--text3);margin-bottom:8px;">Dropped — not ordered</div><div class="member-grid">`;
        droppedBatch.forEach(c => {
          html += `<div style="background:var(--surface2);border-radius:8px;padding:8px 10px;border:0.5px solid var(--border);">
            <div style="font-size:12px;font-weight:500;">${c.member}${c.ot?' <span style="color:var(--text3);font-weight:400;">(OT)</span>':''}</div>
            <div style="font-size:11px;color:var(--text3);margin-top:2px;">${c.user}</div>
            <div style="margin-top:3px;display:flex;gap:4px;flex-wrap:wrap;align-items:center;">
              <span class="badge badge-dropped" style="font-size:10px;">Dropped</span>
              <button class="btn btn-sm btn-ghost" style="font-size:10px;padding:2px 6px;" onclick="restoreClaim('${go.id}','batch','${si.id}',null,null,'${c.claim_id}')">Restore</button>
            </div>
          </div>`;
        });
        html += `</div></div>`;
      }
```

- [ ] **Step 3: Verify in browser**

Open admin → Manage on the test GO. Drop a claim via console (`applyClaimStatusRef(go, collectUnsecured(go).droppable[0], 'dropped'); saveLocal(); renderDetailContent();`). Expected:
- **Set-based:** the dropped slot now shows a muted **Dropped** badge and a **Restore** button (no Paid/Secure? badges).
- **Batch:** the claim disappears from its batch card and appears under a **"Dropped — not ordered"** sub-section with a **Restore** button.
Click **Restore**. The claim returns to its normal Secure?/Unpaid state (set) or back into a batch card (batch), and the "· N dropped" summary clears.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "Drop-on-close: admin Dropped badge + Restore for set slots and batch claims"
```

---

### Task 4: Close → review → confirm modal, wired into saveGOEdits

**Files:**
- Modify: `index.html` — `saveGOEdits` status capture (line 2604) and tail (lines 2710–2715); add `openDropReviewModal` / `secureFromReview` / `confirmDropUnsecured` near the Task 1 helpers (after `restoreClaim`)

**Interfaces:**
- Consumes: `collectUnsecured`, `applyClaimStatusRef` (Task 1); `showModal`/`closeModal` (lines 2740/2744); `apiPost`, `saveLocal`, `renderDetailContent`, `renderAdminGOList`, `renderOrdersList`.
- Produces: `openDropReviewModal(goId)`, `secureFromReview(goId, kind, siId, setIdx, member, claimId)`, `confirmDropUnsecured(goId)`.

- [ ] **Step 1: Capture the previous status in `saveGOEdits`**

At the top of `saveGOEdits` (line 2604 sets `go.status`), capture the prior value first:

```javascript
  const prevStatus = go.status;
  go.status = document.getElementById('edit-go-status').value;
```

- [ ] **Step 2: Open the review modal on an open→closed transition**

At the end of `saveGOEdits`, replace the final `toast('Changes saved.');` (line 2714) with a transition check:

```javascript
  toast('Changes saved.');
  if (prevStatus !== 'closed' && go.status === 'closed') {
    const { droppable, paid } = collectUnsecured(go);
    if (droppable.length || paid.length) openDropReviewModal(go.id);
  }
```

- [ ] **Step 3: Add the review modal + its actions**

After `restoreClaim` (from Task 1), add:

```javascript
// Review modal shown when a GO is closed with still-unsecured claims.
function openDropReviewModal(goId) {
  const go = allGOs[goId];
  const { droppable, paid } = collectUnsecured(go);

  // Group droppable refs by sub-item name.
  const byItem = {};
  droppable.forEach(r => { (byItem[r.siName] = byItem[r.siName] || []).push(r); });

  let body = '';
  if (droppable.length) {
    body += `<div style="font-size:13px;color:var(--text2);margin-bottom:12px;">${droppable.length} claim${droppable.length!==1?'s':''} across ${Object.keys(byItem).length} item${Object.keys(byItem).length!==1?'s':''} didn't reach secured. Closing will drop them.</div>`;
    Object.keys(byItem).forEach(name => {
      body += `<div style="font-weight:500;font-size:13px;margin:10px 0 6px;">${name}</div>`;
      byItem[name].forEach(r => {
        const args = `'${goId}','${r.kind}','${r.siId}',${r.kind==='set'?r.setIdx:'null'},${r.kind==='set'?`'${r.member}'`:'null'},${r.claimId?`'${r.claimId}'`:'null'}`;
        body += `<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;padding:4px 0;">
          <div style="font-size:12px;"><span style="font-weight:500;">${r.label}</span> <span style="color:var(--text3);">${r.user}</span></div>
          <button class="btn btn-sm btn-ghost" style="font-size:10px;padding:2px 8px;" onclick="secureFromReview(${args})">Secure anyway</button>
        </div>`;
      });
    });
  } else {
    body += `<div style="font-size:13px;color:var(--text2);margin-bottom:12px;">No unsecured claims left to drop.</div>`;
  }

  if (paid.length) {
    body += `<div style="margin-top:14px;padding:10px 12px;background:var(--amber-50);border:0.5px solid var(--amber-200,#fde68a);border-radius:8px;">
      <div style="font-size:12px;font-weight:500;color:var(--amber-800);margin-bottom:6px;">Needs your attention — ${paid.length} paid but not secured</div>
      <div style="font-size:11px;color:var(--amber-800);margin-bottom:6px;">These won't be dropped. Check for a labeling error (Secure them), or refund off-app then drop them manually.</div>`;
    paid.forEach(r => { body += `<div style="font-size:12px;padding:2px 0;"><span style="font-weight:500;">${r.siName} · ${r.label}</span> <span style="color:var(--text3);">${r.user}</span></div>`; });
    body += `</div>`;
  }

  const footer = droppable.length
    ? `<div style="display:flex;gap:8px;margin-top:18px;">
        <button class="btn btn-primary" style="flex:1;justify-content:center;" onclick="confirmDropUnsecured('${goId}')">Close &amp; drop remaining</button>
        <button class="btn btn-ghost" onclick="closeModal()">Cancel</button>
      </div>`
    : `<div style="display:flex;margin-top:18px;"><button class="btn btn-primary" style="flex:1;justify-content:center;" onclick="closeModal()">Done</button></div>`;

  showModal(`<div style="font-size:16px;font-weight:500;margin-bottom:4px;">Review unsecured claims</div>
    <div style="font-size:13px;color:var(--text2);margin-bottom:16px;">${go.name}</div>${body}${footer}`);
}

// Rescue exactly one claim (per-claim secure), then re-render the modal.
async function secureFromReview(goId, kind, siId, setIdx, member, claimId) {
  const go = allGOs[goId];
  applyClaimStatusRef(go, { kind, siId, setIdx, member, claimId }, 'secured');
  if (API_URL && claimId) { try { await apiPost('updateClaim', { claim_id: claimId, claim_status: 'secured' }); } catch (e) {} }
  saveLocal();
  renderDetailContent(); renderAdminGOList(); renderOrdersList();
  openDropReviewModal(goId);
}

// Confirm: drop every still-unsecured (non-paid) claim. Awaits all writes before saveLocal.
async function confirmDropUnsecured(goId) {
  const go = allGOs[goId];
  const { droppable } = collectUnsecured(go);
  for (const ref of droppable) {
    applyClaimStatusRef(go, ref, 'dropped');
    if (API_URL && ref.claimId) { try { await apiPost('updateClaim', { claim_id: ref.claimId, claim_status: 'dropped' }); } catch (e) {} }
  }
  saveLocal();
  closeModal();
  renderDetailContent(); renderAdminGOList(); renderOrdersList();
  toast(droppable.length + ' unsecured claim' + (droppable.length !== 1 ? 's' : '') + ' dropped.');
}
```

- [ ] **Step 4: Verify in browser (full flow)**

On a GO with a partly-filled photocard/batch sub-item and at least one unsecured, unpaid claim (and, ideally, one unsecured **paid** claim to test the attention group — set one via `applyClaimStatusRef`/`toggleSlotPayment` if needed):
1. Admin → Manage → **Edit GO** → set Status to **Closed** → **Save**.
2. Expected: the **Review unsecured claims** modal opens, listing unsecured claims grouped by sub-item, each with **Secure anyway**; any paid-but-unsecured claim appears in the amber **"Needs your attention"** group (not the droppable list).
3. Click **Secure anyway** on one row → it disappears from the list (modal re-renders, count drops), and that claim is now secured in the board behind the modal.
4. Click **Close & drop remaining** → modal closes; remaining unsecured claims now show **Dropped** (admin) and **Not fulfilled** (buyer My-orders); the paid claim is untouched (still Paid, not secured).
5. Re-open **Edit GO**, Save again without changing status (stays Closed) → the modal does **not** reappear (no open→closed transition).

Console check after step 4:

```javascript
collectUnsecured(allGOs['<goId>']).droppable.length   // → 0 (all dropped or secured)
```

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "Drop-on-close: close-GO review modal (secure-anyway, drop, paid attention group)"
```

---

## Self-Review

**Spec coverage:**
- Data model `claim_status:'dropped'`, soft, no redeploy → Task 1 ✓ (used throughout)
- Scope set-based/batch only; FCFS skipped → Task 1 `collectUnsecured` ✓
- Close→review→confirm on open→closed transition → Task 4 Steps 1–3 ✓
- Secure anyway = just that claim → Task 4 `secureFromReview` ✓
- Paid never auto-dropped, "Needs your attention" group → Task 1 (`paid` bucket) + Task 4 modal ✓
- Buyer "Not fulfilled", excluded from totals/count → Task 2 ✓
- Admin "Dropped" badge + Restore → Task 3 ✓; reversible → Task 1 `restoreClaim` ✓
- `setsSummary` "· K dropped" separate → Task 2 Step 2 ✓
- Batch grouping unaffected by drops (derived, no cascade) → Task 1 Step 1 filters dropped ✓
- Awaited writes before saveLocal → Task 4 `confirmDropUnsecured` ✓
- Reopen keeps drops (no auto-restore) → no code restores on status change; Task 4 modal only fires on open→closed ✓
- Backend unchanged → Global Constraints ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases" — every code step shows exact code.

**Type/name consistency:** `Ref` shape `{ siId, siName, kind, setIdx, member, claimId, user, label }` is produced by `collectUnsecured` (Task 1) and consumed by `applyClaimStatusRef` (Task 1), `restoreClaim` (Tasks 1/3), `secureFromReview` and the modal (Task 4). `restoreClaim(goId, kind, siId, setIdx, member, claimId)` signature is identical at definition (Task 1) and both call sites (Task 3 Steps 1–2). `secureFromReview(goId, kind, siId, setIdx, member, claimId)` signature matches its call in `openDropReviewModal` (Task 4). `claim_status` values used: `'secured'`, `'pending'`, `'dropped'` — consistent with existing code (`toggleSlotSecure`/`toggleClaimSecure` use `'secured'`/`'pending'`).
