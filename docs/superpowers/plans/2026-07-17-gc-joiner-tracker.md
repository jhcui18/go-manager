# Per-GO Joiner List + "Added to GC" Tracker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the admin GO detail, show a collapsible Joiners section listing the GO's unique @handles with a synced "added to group chat" toggle per joiner, plus tap-to-copy a handle.

**Architecture:** New `gc_added` sheet (`go_id, username`) with `getGcAdded`/`setGcAdded` endpoints in the Apps Script backend (requires redeploy). Frontend collects joiners via `goJoiners(go)`, loads added-state into `gcAdded` on sync, and renders the section in `renderDetailContent` with toggle (`persistWrite`) + copy handlers.

**Tech Stack:** Vanilla JS single-file `index.html`; Google Apps Script backend `go-manager-backend.gs`.

## Global Constraints

- Frontend edits in `/Users/jinghancui/Gitproj/Go-manager/index.html`; backend edits in `/Users/jinghancui/Gitproj/Go-manager/go-manager-backend.gs`.
- Task 1 (backend) REQUIRES the user to redeploy the Apps Script; it is committed but not "live" until they redeploy. Frontend must degrade gracefully before then (empty `gcAdded`, failed `setGcAdded` handled by `persistWrite`).
- Dedup joiners case-insensitively (trim+lowercase), keep first-seen display casing. Dropped claims still count.
- Sort in the section: **not-yet-added first, then alphabetical**.
- Reuse existing `persistWrite`, `sameUser`-style normalization, `.admin-section`/`.admin-section-title` classes, chevron collapse pattern.
- No automated test harness. Verify frontend with the JS-parse check; verify backend with `node --check` on a `.js` copy. Manual browser check is the user's step.
- Frontend JS-parse check:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after each task.

---

### Task 1: Backend — `gc_added` sheet + get/set endpoints

**Files:**
- Modify: `go-manager-backend.gs` — sheet constant (near line 14), `bootstrapSheets` (near line 25), `doGet` routing (line ~64), `doPost` routing (line ~96), `deleteGO` (line ~184), and new `getGcAdded`/`setGcAdded` functions (add near `getStoreOrders`, line ~451).

**Interfaces:**
- Produces: `getGcAdded()` → `{ gc_added: [{go_id, username}] }`; `setGcAdded({go_id, username, added})` → `{ ok: true }`.

- [ ] **Step 1: Add the sheet constant**

After `const SHEET_STORE_ORDERS = 'store_orders'; ...` line, add:

```javascript
const SHEET_GC_ADDED = 'gc_added'; // per-GO: joiners marked as added to the IG group chat
```

- [ ] **Step 2: Ensure the sheet in `bootstrapSheets`**

After the `ensureSheet(ss, SHEET_STORE_ORDERS, [...]);` line, add:

```javascript
  ensureSheet(ss, SHEET_GC_ADDED, ['go_id','username']);
```

- [ ] **Step 3: Add the two functions**

Immediately after `getStoreOrders()` (before `createStoreOrder`), add:

```javascript
function getGcAdded() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_GC_ADDED);
  return { gc_added: sheet ? sheetToObjects(sheet) : [] };
}

function setGcAdded(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_GC_ADDED);
  const rows = sheet.getDataRange().getValues();
  const h = rows[0];
  const gi = h.indexOf('go_id'), ui = h.indexOf('username');
  const norm = s => String(s == null ? '' : s).trim().toLowerCase();
  let foundRow = -1;
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][gi] === data.go_id && norm(rows[i][ui]) === norm(data.username)) { foundRow = i; break; }
  }
  if (data.added) {
    if (foundRow === -1) sheet.appendRow([data.go_id, data.username]);
  } else if (foundRow !== -1) {
    sheet.deleteRow(foundRow + 1);
  }
  return { ok: true };
}
```

- [ ] **Step 4: Route the endpoints**

In `doGet`, after the `getStoreOrders` line, add:

```javascript
    else if (action === 'getGcAdded')      result = getGcAdded();
```

In `doPost`, after the `deleteStoreOrder` line, add:

```javascript
    else if (action === 'setGcAdded')       result = setGcAdded(body.data);
```

- [ ] **Step 5: Clear gc_added rows when a GO is deleted**

In `deleteGO`, right after the line that deletes the GO's joiners
(`deleteRowsWhere(ss.getSheetByName(SHEET_JOINERS), 'go_id', goId);`), add:

```javascript
  deleteRowsWhere(ss.getSheetByName(SHEET_GC_ADDED), 'go_id', goId);
```

- [ ] **Step 6: Syntax-check**

```bash
cp go-manager-backend.gs /tmp/gcbackend.js && node --check /tmp/gcbackend.js && echo "backend syntax OK"
```

Expected: `backend syntax OK`.

- [ ] **Step 7: Commit**

```bash
git add go-manager-backend.gs
git commit -m "Backend: gc_added sheet + getGcAdded/setGcAdded (per-GO group-chat tracking). REQUIRES REDEPLOY"
```

---

### Task 2: Frontend data — `goJoiners`, `gcAdded` state, load on sync

**Files:**
- Modify: `index.html` — add `let gcAdded = {};` near other state (after `let storeOrders = [];`, line ~3039); add `goJoiners`/`gcNorm`/`isGcAdded` helpers (near `sameUser`, line ~494); extend `syncFromBackend`'s `Promise.all` (line ~3749) and result handling (after the `storeResult` block, line ~3866).

**Interfaces:**
- Produces: `goJoiners(go)` → `string[]`; `gcNorm(u)`; `isGcAdded(goId, username)`; `gcAdded` map `go_id → { normUsername: true }`.

- [ ] **Step 1: Add the state variable**

After `let storeOrders = []; // admin's own orders placed with stores/proxies`, add:

```javascript
let gcAdded = {}; // go_id -> { normalizedUsername: true } — joiners marked added to the IG group chat
```

- [ ] **Step 2: Add the helpers**

Immediately after the `sameUser` function (line ~494), add:

```javascript
function gcNorm(u) { return String(u == null ? '' : u).trim().toLowerCase(); }
function isGcAdded(goId, username) { return !!(gcAdded[goId] && gcAdded[goId][gcNorm(username)]); }
// Unique joiner handles across ALL of a GO's claims (set slots + claims-based), case-insensitive dedup.
function goJoiners(go) {
  const seen = {}; const out = [];
  const add = (u) => { const k = gcNorm(u); if (!k || seen[k]) return; seen[k] = true; out.push(String(u).trim()); };
  (go.subItems || []).forEach(si => {
    if (si.sets) si.sets.forEach(set => Object.values(set.slots || {}).forEach(slot => { if (slot) add(slot.user); }));
    if (si.claims) si.claims.forEach(c => add(c.user));
  });
  return out;
}
```

- [ ] **Step 3: Fetch `getGcAdded` in the sync `Promise.all`**

Replace:

```javascript
    const [result, payResult, listResult, orderResult, shipResult, storeResult] = await Promise.all([
      apiGet('getAllGOs'), apiGet('getPayments'), apiGet('getListings'), apiGet('getShopOrders'), apiGet('getShipping'), apiGet('getStoreOrders')
    ]);
```

with:

```javascript
    const [result, payResult, listResult, orderResult, shipResult, storeResult, gcResult] = await Promise.all([
      apiGet('getAllGOs'), apiGet('getPayments'), apiGet('getListings'), apiGet('getShopOrders'), apiGet('getShipping'), apiGet('getStoreOrders'), apiGet('getGcAdded')
    ]);
```

- [ ] **Step 4: Build `gcAdded` from the result**

After the `storeResult` handling block:

```javascript
    if (storeResult && Array.isArray(storeResult.store_orders)) {
      storeOrders = storeResult.store_orders.filter(o => o && o.order_id);
    }
```

add:

```javascript
    if (gcResult && Array.isArray(gcResult.gc_added)) {
      gcAdded = {};
      gcResult.gc_added.forEach(r => {
        if (!r || !r.go_id || !r.username) return;
        (gcAdded[r.go_id] = gcAdded[r.go_id] || {})[gcNorm(r.username)] = true;
      });
    }
```

- [ ] **Step 5: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 6: Verify the collection in console**

Open the app as admin (synced). In DevTools console:

```javascript
goJoiners(Object.values(allGOs).find(g => (g.subItems||[]).some(s => s.sets || s.claims)))
```

Expected: an array of unique @-less handle strings (no duplicates by case). `gcAdded` is an object (empty until the backend is redeployed and rows exist).

- [ ] **Step 7: Commit**

```bash
git add index.html
git commit -m "GC tracker: goJoiners helper + gcAdded state loaded on sync"
```

---

### Task 3: Frontend UI — Joiners section + toggle/copy handlers

**Files:**
- Modify: `index.html` — `renderDetailContent` (insert the section near its top, after `let html = '';`, line ~1840); add `gcOpen`/`toggleGcSection`/`toggleGcAdded`/`copyHandle`/`gcJoinersSectionHtml` (near `renderDetailContent`).

**Interfaces:**
- Consumes: `goJoiners`, `isGcAdded`, `gcNorm`, `gcAdded` (Task 2); `persistWrite`, `apiPost`, `renderDetailContent`, `toast`.
- Produces: `gcJoinersSectionHtml(go)`, `toggleGcSection(goId)`, `toggleGcAdded(goId, username)`, `copyHandle(username)`.

- [ ] **Step 1: Render the section at the top of the GO detail**

In `renderDetailContent`, change:

```javascript
  let html = '';
  if ((go.subItems || []).length > 1) {
```

to:

```javascript
  let html = '';
  html += gcJoinersSectionHtml(go);
  if ((go.subItems || []).length > 1) {
```

- [ ] **Step 2: Add the section builder + handlers**

Immediately before `function renderDetailContent()`, add:

```javascript
let gcOpen = {}; // go_id -> bool; Joiners section open state (default collapsed)
function toggleGcSection(goId) {
  gcOpen[goId] = !gcOpen[goId];
  const body = document.getElementById('gc-body-' + goId);
  const chev = document.getElementById('gc-chev-' + goId);
  if (body) body.style.display = gcOpen[goId] ? 'block' : 'none';
  if (chev) chev.textContent = gcOpen[goId] ? '▾' : '▸';
}
function toggleGcAdded(goId, username) {
  const k = gcNorm(username);
  gcAdded[goId] = gcAdded[goId] || {};
  const added = !gcAdded[goId][k];
  if (added) gcAdded[goId][k] = true; else delete gcAdded[goId][k];
  if (API_URL) persistWrite(apiPost('setGcAdded', { go_id: goId, username, added }), 'Group-chat mark');
  renderDetailContent();
}
function copyHandle(username) {
  const handle = username.charAt(0) === '@' ? username : '@' + username;
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(handle).then(() => toast('Copied ' + handle)).catch(() => toast(handle));
  } else {
    toast(handle);
  }
}
// Collapsible Joiners section: unique @handles, not-yet-added first, each with an "added to GC" toggle.
function gcJoinersSectionHtml(go) {
  const joiners = goJoiners(go);
  const total = joiners.length;
  const added = joiners.filter(u => isGcAdded(go.id, u)).length;
  const open = !!gcOpen[go.id];
  const sorted = joiners.slice().sort((a, b) => {
    const aa = isGcAdded(go.id, a), ba = isGcAdded(go.id, b);
    if (aa !== ba) return aa ? 1 : -1;
    return a.toLowerCase().localeCompare(b.toLowerCase());
  });
  const rows = sorted.map(u => {
    const on = isGcAdded(go.id, u);
    const handle = u.charAt(0) === '@' ? u : '@' + u;
    const uEsc = u.replace(/'/g, "\\'");
    return `<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;padding:4px 0;">
      <span style="font-size:13px;cursor:pointer;" title="Tap to copy" onclick="copyHandle('${uEsc}')">${handle}</span>
      <button class="btn btn-sm ${on ? '' : 'btn-ghost'}" style="font-size:11px;${on ? 'color:var(--teal-600);border-color:var(--teal-100);' : ''}" onclick="toggleGcAdded('${go.id}','${uEsc}')">${on ? '✓ In GC' : 'Add to GC'}</button>
    </div>`;
  }).join('');
  return `<div class="admin-section">
    <div class="admin-section-title" style="cursor:pointer;user-select:none;" onclick="toggleGcSection('${go.id}')">
      <span id="gc-chev-${go.id}" style="width:12px;color:var(--text3);">${open ? '▾' : '▸'}</span>Joiners <span style="font-size:12px;color:var(--text3);font-weight:400;">— ${added} added / ${total} total</span>
    </div>
    <div id="gc-body-${go.id}" style="display:${open ? 'block' : 'none'};">
      ${total ? rows : '<div style="font-size:12px;color:var(--text3);padding:4px 0;">No joiners yet.</div>'}
    </div>
  </div>`;
}
```

- [ ] **Step 3: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 4: Verify in browser**

Open admin → Manage on a GO with claims. Confirm a **Joiners — X added / N total** header appears at the top; expanding it lists the unique @handles (not-added first). Tapping a handle copies it (toast "Copied @handle"). Clicking **Add to GC** flips the row to **✓ In GC**, the count updates, and the row moves down to the added group.
- If the backend is **redeployed**: reload → the ✓ persists (synced).
- If **not yet redeployed**: `persistWrite` toasts a save-failure and re-syncs (state won't stick) — expected until redeploy.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "GC tracker: Joiners section in GO detail with add-to-GC toggle + tap-to-copy"
```

---

## Self-Review

**Spec coverage:**
- `gc_added` sheet + `getGcAdded`/`setGcAdded` + routing + deleteGO cleanup → Task 1 ✓
- `goJoiners` dedup + `gcAdded` loaded on sync → Task 2 ✓
- Collapsible Joiners section, not-added-first sort, toggle via `persistWrite`, tap-to-copy → Task 3 ✓
- Graceful pre-redeploy degradation → Task 3 Step 4 note; empty `gcAdded` when `getGcAdded` errors ✓

**Placeholder scan:** No TBD/TODO — every step shows exact code.

**Type/name consistency:** `gcNorm`/`isGcAdded`/`goJoiners`/`gcAdded` defined in Task 2, consumed in Task 3. `getGcAdded` returns `{ gc_added: [...] }` (Task 1) matching the `gcResult.gc_added` reader (Task 2 Step 4). `setGcAdded({go_id, username, added})` signature (Task 1) matches the `apiPost('setGcAdded', { go_id: goId, username, added })` call (Task 3). Section element ids `gc-chev-${go.id}`/`gc-body-${go.id}` match between `gcJoinersSectionHtml` and `toggleGcSection`.
