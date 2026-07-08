# Single-edition Album Sub-item Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new album sub-item kind `single` (a version-less "single edition" album) so an admin can create/edit an album GO where buyers simply pick a quantity — no member or version selection.

**Architecture:** Single-file browser app (`index.html`, HTML+CSS+JS). Introduce an explicit `kind:'single'` sub-item shape `{ id, name, kind:'single', price, claims:[] }`. Reuse the existing FCFS quantity machinery (`adjustVersionedQty`, `type:'versioned'` claim state, `buildVersionedClaims`). No backend change — `go-manager-backend.gs` serializes sub-items generically.

**Tech Stack:** Vanilla JS in one HTML file. Backend is Google Apps Script (unchanged). Hosted on GitHub Pages.

## Global Constraints

- All edits are in `/Users/jinghancui/Gitproj/Go-manager/index.html`. No other file changes.
- Sub-item shape for this feature: `{ id, name, kind:'single', price, claims:[] }` — never a `members` or `versions` property.
- A single-edition claim must serialize to Sheets with `member_or_version:''` and `assigned_vers:''` (no `random`/`Default` leak).
- Buyers see **no** version/member badge for single-edition items — name, price, quantity picker only.
- No automated test harness exists. Verification is manual in a browser plus DevTools console assertions. Load the file locally with `open /Users/jinghancui/Gitproj/Go-manager/index.html` (admin PIN / API URL as normally used).
- Commit after each task.

---

### Task 1: Create-GO supports the `single` kind

**Files:**
- Modify: `index.html` — album Kind dropdown (~1828), `onSubItemKindChange` (~1869), `createGO` album branch (~1907)

**Interfaces:**
- Produces: create-GO can output a sub-item `{ id, name, kind:'single', price, claims:[] }`.

- [ ] **Step 1: Add the dropdown option**

In `addSubItem()`, the album `<select id="si-kind-${id}">` (around line 1828), add a third option after the `versioned` one:

```html
        <select id="si-kind-${id}" onchange="onSubItemKindChange('${id}')">
          <option value="member">Member ver (pick a member)</option>
          <option value="versioned">Version pick (buyer selects A/B/…)</option>
          <option value="single">Single edition (no versions)</option>
        </select>
```

- [ ] **Step 2: Clear the extra field area for `single`**

Update `onSubItemKindChange(id)` (around line 1869) so `single` shows no members/versions input:

```javascript
function onSubItemKindChange(id) {
  const kind = document.getElementById('si-kind-' + id).value;
  const extra = document.getElementById('si-extra-' + id);
  if (!extra) return;
  if (kind === 'member') {
    extra.innerHTML = `<div class="field" style="margin-bottom:0;"><label>Members (one per line)</label><textarea id="si-members-${id}" placeholder="Yujin\nGaeul\nRei\n..." style="min-height:80px;font-family:var(--mono);font-size:12px;"></textarea></div>`;
  } else if (kind === 'versioned') {
    extra.innerHTML = `<div class="field" style="margin-bottom:0;"><label>Versions (comma separated, e.g. A,B)</label><input type="text" id="si-versions-${id}" placeholder="A,B"></div>`;
  } else {
    extra.innerHTML = `<div class="field-hint" style="margin:0;">Single edition — buyers just choose a quantity.</div>`;
  }
}
```

- [ ] **Step 3: Handle `single` in `createGO`**

In `createGO()` album branch (around line 1907), replace the `else` that builds the versioned sub-item so it handles `single` first:

```javascript
    } else if (type === 'album') {
      const kind = (document.getElementById('si-kind-' + siId)||{}).value || 'member';
      const price = parseFloat((document.getElementById('si-price-' + siId)||{}).value) || 0;
      if (kind === 'member') {
        const membersRaw = (document.getElementById('si-members-' + siId)||{}).value || '';
        const members = membersRaw.split('\n').map(m=>m.trim()).filter(Boolean);
        if (!members.length) return;
        const emptySet = { status:'open', slots:{}, num:1 };
        members.forEach(m => emptySet.slots[m] = null);
        subItems.push({ id:siId, name:siName, kind:'member', members, minSecure, price, sets:[emptySet] });
      } else if (kind === 'single') {
        subItems.push({ id:siId, name:siName, kind:'single', price, claims:[] });
      } else {
        const versionsRaw = (document.getElementById('si-versions-' + siId)||{}).value || 'A,B';
        const versions = versionsRaw.split(',').map(v=>v.trim()).filter(Boolean);
        subItems.push({ id:siId, name:siName, kind:'versioned', versions, price, claims:[] });
      }
    } else {
```

- [ ] **Step 4: Verify in browser**

Open the app, go to admin → Create GO → type Album. Add a sub-item, choose **Single edition (no versions)**. Confirm the members/versions input disappears and a hint appears. Enter a name + price, create the GO. In DevTools console run:

```javascript
Object.values(allGOs).at(-1).subItems[0]
```

Expected: an object with `kind: "single"`, a `price`, `claims: []`, and **no** `members` or `versions` keys.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "Create GO: add single-edition (no versions) album kind"
```

---

### Task 2: Buyer claim page renders a quantity-only card

**Files:**
- Modify: `index.html` — album public render routing (~785), add `renderSingleSubItemPublic` (near `renderVersionedSubItemPublic`, ~910)

**Interfaces:**
- Consumes: `single` sub-item from Task 1; existing `adjustVersionedQty(siId, goId, delta)` handler.
- Produces: `renderSingleSubItemPublic(si, goId)` returning a card HTML string.

- [ ] **Step 1: Route `single` sub-items to the new renderer**

In `renderClaimPage` album branch (around line 783):

```javascript
  } else if (go.type === 'album') {
    go.subItems.forEach(si => {
      if (si.kind === 'member') html += renderSetSubItemPublic(si, goId);
      else if (si.kind === 'single') html += renderSingleSubItemPublic(si, goId);
      else html += renderVersionedSubItemPublic(si, goId);
    });
  } else {
```

- [ ] **Step 2: Add `renderSingleSubItemPublic`**

Add this function immediately after `renderVersionedSubItemPublic` (after its closing brace, ~line 910). It reuses the merch "random ver — just qty" markup but with no version/random wording and no badge:

```javascript
function renderSingleSubItemPublic(si, goId) {
  const totalClaimed = (si.claims||[]).reduce((a,c)=>a+c.qty,0);
  return `<div class="card" style="margin-bottom:12px;">
    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px;">
      <div style="font-weight:500;font-size:15px;">${si.name}</div>
      <span style="font-size:13px;font-weight:500;">$${(si.price||0).toFixed(2)}</span>
    </div>
    <div style="font-size:12px;color:var(--text3);margin-bottom:12px;">${totalClaimed} claimed</div>
    <div class="qty-row">
      <button class="qty-btn" onclick="adjustVersionedQty('${si.id}','${goId}',-1)">−</button>
      <span style="font-size:15px;font-weight:500;min-width:24px;text-align:center;" id="qty-val-${si.id}">0</span>
      <button class="qty-btn" onclick="adjustVersionedQty('${si.id}','${goId}',1)">+</button>
    </div>
  </div>`;
}
```

- [ ] **Step 3: Verify claim-state init already handles `single`**

No code change — confirm by reading `renderClaimPage`'s init loop (~line 800): `kind==='single'` falls to the final `else`, giving `claimState[si.id] = { type:'versioned', qty:0 }`. This is what `adjustVersionedQty` and the submit path expect.

- [ ] **Step 4: Verify in browser**

Open the single-edition GO's public claim page. Confirm: item name, price, "N claimed", and a −/+ quantity row — **no** FCFS/version/member badge, no "Default" tile. Set qty to 2, enter a username, submit. In console run:

```javascript
Object.values(allGOs).find(g => g.subItems.some(s => s.kind==='single')).subItems.find(s=>s.kind==='single').claims
```

Expected: one claim `{ user, qty:2, assignedVers:[], payment:'unpaid', fulfillment:'Pending' }`. If `API_URL` is set, check the Sheets `joiners` row has `member_or_version` and `assigned_vers` both empty (the submit path at ~line 1229 yields `[]` because `si.versions` is undefined).

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "Claim page: quantity-only card for single-edition albums"
```

---

### Task 3: Admin detail table renders cleanly for `single`

**Files:**
- Modify: `index.html` — `hasMemberCol` (line 1646), admin detail badge (~1568)

**Interfaces:**
- Consumes: `single` sub-item with `claims`.

- [ ] **Step 1: Exclude `single` from the Member/Ver column**

Change line 1646:

```javascript
      const hasVerCol = si.kind === 'versioned';
      const hasMemberCol = si.kind === 'member' || (si.kind !== 'versioned' && si.kind !== 'random' && si.kind !== 'single');
```

- [ ] **Step 2: Give `single` its own badge in the section title**

In the admin detail section-title logic (around line 1563), add a `single` branch before the final `else`:

```javascript
    if (si.sets) {
      html += ` <span class="badge badge-set" style="font-size:10px;">set-based</span>`;
      if (si.price) html += ` <span style="font-size:12px;color:var(--text3);">$${si.price.toFixed(2)}/copy</span>`;
    } else if (si.kind === 'versioned') {
      html += ` <span class="badge badge-fcfs" style="font-size:10px;">versioned FCFS</span>`;
    } else if (si.kind === 'single') {
      html += ` <span class="badge badge-fcfs" style="font-size:10px;">single edition</span>`;
      if (si.price) html += ` <span style="font-size:12px;color:var(--text3);">$${si.price.toFixed(2)}</span>`;
    } else {
      html += ` <span style="font-size:12px;color:var(--text3);">$${(si.price||0).toFixed(2)}</span>`;
    }
```

- [ ] **Step 3: Verify in browser**

Open admin → Manage on the single-edition GO. Confirm the section shows a "single edition" badge and the claims table has columns `# / Username / Qty / Payment / Fulfillment` only — **no** "Member/Ver" or "Versions" column. The buyer's qty-2 claim appears as a single row with Qty 2.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "Admin detail: clean table + badge for single-edition albums"
```

---

### Task 4: Single-edition albums survive a backend sync/refresh

**Files:**
- Modify: `index.html` — `syncFromBackend` reconstruction (~3004)

**Interfaces:**
- Consumes: Sheets rows where `go_{id}` has `kind:'single'`; existing `buildVersionedClaims(go.claims, subItemId)`.

- [ ] **Step 1: Add the `album + single` reconstruction branch**

In `syncFromBackend`, insert a branch after the `album && kind === 'versioned'` block (around line 3009, before the `merch` block):

```javascript
          } else if (rebuilt.type === 'album' && kind === 'versioned') {
            rebuilt.subItems.push({
              id: si.sub_item_id, name: si.name || '', kind: 'versioned',
              versions, price: parseFloat(si.price) || 0,
              claims: buildVersionedClaims(go.claims, si.sub_item_id)
            });
          } else if (rebuilt.type === 'album' && kind === 'single') {
            rebuilt.subItems.push({
              id: si.sub_item_id, name: si.name || '', kind: 'single',
              price: parseFloat(si.price) || 0,
              claims: buildVersionedClaims(go.claims, si.sub_item_id)
            });
          } else if (rebuilt.type === 'merch') {
```

- [ ] **Step 2: Verify in browser (requires `API_URL` configured)**

With the single-edition GO created and a claim submitted (Tasks 1–2), reload the page so `syncFromBackend` runs. In console:

```javascript
Object.values(allGOs).find(g => g.subItems.some(s => s.kind==='single'))
```

Expected: the GO still has its `single` sub-item with `claims` reconstructed (the qty-2 claim present). Before this task the sub-item would be missing after reload.

- [ ] **Step 3: Commit**

```bash
git add index.html
git commit -m "Sync: reconstruct single-edition album sub-items on refresh"
```

---

### Task 5: Edit-GO supports the `single` kind end-to-end

**Files:**
- Modify: `index.html` — new-item edit template dropdown (2152), `onEditSubItemKindChange` (~2189), existing-item edit render (~2096), edit save for existing (~2254) and new (~2289) items

**Interfaces:**
- Consumes: `single` sub-item shape from Task 1.

- [ ] **Step 1: Add `single` to the new-item edit dropdown**

In `addEditSubItem`'s album template `<select id="edit-si-kind-${id}">` (around line 2152):

```html
        <select id="edit-si-kind-${id}" onchange="onEditSubItemKindChange('${id}')">
          <option value="member">Member ver (pick a member)</option>
          <option value="versioned">Version pick (buyer selects A/B/…)</option>
          <option value="single">Single edition (no versions)</option>
        </select>
```

- [ ] **Step 2: Clear the extra area for `single` in edit**

Update `onEditSubItemKindChange(id)` (around line 2189):

```javascript
function onEditSubItemKindChange(id) {
  const kind = document.getElementById('edit-si-kind-' + id).value;
  const extra = document.getElementById('edit-si-extra-' + id);
  if (!extra) return;
  if (kind === 'member') {
    extra.innerHTML = `<div class="field" style="margin-bottom:0;"><label>Members (one per line)</label><textarea id="edit-si-members-${id}" placeholder="Yujin&#10;Gaeul&#10;Rei&#10;..." style="min-height:80px;font-family:var(--mono);font-size:12px;"></textarea></div>`;
  } else if (kind === 'versioned') {
    extra.innerHTML = `<div class="field" style="margin-bottom:0;"><label>Versions (comma separated, e.g. A,B)</label><input type="text" id="edit-si-versions-${id}" placeholder="A,B"></div>`;
  } else {
    extra.innerHTML = `<div class="field-hint" style="margin:0;">Single edition — buyers just choose a quantity.</div>`;
  }
}
```

- [ ] **Step 3: Render existing `single` items without a Versions input**

In the existing-item edit render (around line 2091–2101), split the `else` into `versioned` vs `single`:

```javascript
      if (si.kind === 'member') {
        inner += `<div class="field" style="margin-bottom:0;"><label>Members (one per line)</label>
          <textarea id="edit-si-members-${si.id}" style="min-height:70px;font-family:var(--mono);font-size:12px;">${si.members.join('\n')}</textarea>
          ${hasClaims ? '<div class="field-hint" style="color:var(--amber-800);">New members added will appear as open slots in existing sets.</div>' : ''}
        </div>`;
      } else if (si.kind === 'versioned') {
        inner += `<div class="field" style="margin-bottom:0;"><label>Versions (comma separated)</label>
          <input type="text" id="edit-si-versions-${si.id}" value="${(si.versions||[]).join(',')}">
          <div class="field-hint">Applies to new claims only.</div>
        </div>`;
      } else {
        inner += `<div class="field-hint" style="margin:0;">Single edition — no versions.</div>`;
      }
```

- [ ] **Step 4: Handle `single` when saving a NEW edit sub-item**

In `saveGOEdits` new-item collection album branch (around line 2284):

```javascript
    } else if (go.type === 'album') {
      if (kind === 'member') {
        const members = ((document.getElementById('edit-si-members-' + id)||{}).value||'').split('\n').map(m=>m.trim()).filter(Boolean);
        const slots = {}; members.forEach(m => slots[m] = null);
        go.subItems.push({ id, name, kind:'member', members, minSecure: minSecure||7, price, sets:[{ status:'open', slots, num:1 }], claims:[] });
      } else if (kind === 'single') {
        go.subItems.push({ id, name, kind:'single', price, claims:[] });
      } else {
        const versions = ((document.getElementById('edit-si-versions-' + id)||{}).value||'A,B').split(',').map(v=>v.trim()).filter(Boolean);
        go.subItems.push({ id, name, kind:'versioned', versions, price, claims:[] });
      }
    } else {
```

Existing `single` items need no branch in the existing-item save loop (lines ~2234–2257): they have no members/versions to update, so the loop correctly skips them after updating `price`.

- [ ] **Step 5: Verify in browser**

(a) Open Edit GO on the single-edition GO from Task 1. Confirm the existing sub-item shows only Name + Price + "Single edition — no versions." (no Versions box). Change the price, save, reopen — price persisted, still `kind:'single'` (check `currentGO.subItems` in console).
(b) In the same Edit GO, click add sub-item, choose **Single edition (no versions)**, give it a name + price, save. Console-check the new sub-item is `{ kind:'single', price, claims:[] }` with no `versions`.

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "Edit GO: full support for single-edition album kind"
```

---

## Self-Review

**Spec coverage:**
- Create dropdown/handler/createGO → Task 1 ✓
- Buyer quantity-only render, no badge → Task 2 ✓
- claim-state init + submitClaim already work → verified in Task 2 Steps 3–4 ✓
- Admin `hasMemberCol` + badge → Task 3 ✓
- `syncFromBackend` branch (data-loss fix) → Task 4 ✓
- Edit GO dropdown/handler/existing-render/save → Task 5 ✓
- Backend unchanged → confirmed in Global Constraints ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases" — every step shows exact code.

**Type/name consistency:** `kind:'single'` and shape `{ id, name, kind:'single', price, claims:[] }` used identically in Tasks 1, 4, 5. `renderSingleSubItemPublic(si, goId)` defined in Task 2 Step 2 and called in Task 2 Step 1 with matching signature. `adjustVersionedQty(siId, goId, delta)` reused with the existing signature.
