# Explicit Set-Secured Flag + Per-Claim Owed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A set shows "Secured" only when explicitly secured (persisted flag) or full; individual claim securing no longer badges the set; owed is per-claim (any secured claim is charged).

**Architecture:** New `secured_sets` backend sheet + endpoints (needs redeploy). Frontend keys flags flatly by `subItemId|setNum` (sub-item ids are globally unique, so no goId threading). A shared `deriveSetStatus(siId, set, members)` (flagged-OR-full) replaces the `filled.every(secured)` rule at all 4 recompute sites and in reconstruction. `secureSet`/`unsecureSet` persist/clear the flag. `paymentOwedUnits` charges per-slot `claim_status==='secured'`.

**Tech Stack:** Vanilla JS `index.html`; Apps Script `go-manager-backend.gs`.

## Global Constraints

- Frontend `index.html`; backend `go-manager-backend.gs`. Task 1 needs the user to redeploy.
- Flat flag key: `securedSets[subItemId + '|' + setNum] = true`. `isSetFlagged(siId, setNum)`.
- `deriveSetStatus(siId, set, members)` = `(isSetFlagged(siId, set.num) || full) ? 'secured' : 'open'`, where **full** = members non-empty AND every member slot filled AND all filled slots `claim_status==='secured'`.
- No test harness. Frontend: JS-parse; backend: `node --check` on a `.js` copy. JS-parse:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after each task.

---

### Task 1: Backend — `secured_sets` sheet + endpoints

**Files:**
- Modify: `go-manager-backend.gs` — sheet constant, `bootstrapSheets`, `doGet`/`doPost` routing, `deleteGO`, new `getSecuredSets`/`setSecuredSet`.

- [ ] **Step 1: Sheet constant + ensureSheet**

After the last `SHEET_*` constant add:

```javascript
const SHEET_SECURED_SETS = 'secured_sets'; // sets the admin explicitly secured (badge = flagged OR full)
```

In `bootstrapSheets`, after the last `ensureSheet(...)`:

```javascript
  ensureSheet(ss, SHEET_SECURED_SETS, ['go_id','sub_item_id','set_num']);
```

- [ ] **Step 2: Add the two functions**

Add near `getGcAdded`/`setGcAdded` (or after `getStoreOrders`):

```javascript
function getSecuredSets() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SECURED_SETS);
  return { secured_sets: sheet ? sheetToObjects(sheet) : [] };
}

function setSecuredSet(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SECURED_SETS);
  const rows = sheet.getDataRange().getValues();
  const h = rows[0];
  const gi = h.indexOf('go_id'), si = h.indexOf('sub_item_id'), sn = h.indexOf('set_num');
  let foundRow = -1;
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][si] === data.sub_item_id && String(rows[i][sn]) === String(data.set_num)) { foundRow = i; break; }
  }
  if (data.secured) {
    if (foundRow === -1) sheet.appendRow([data.go_id, data.sub_item_id, data.set_num]);
  } else if (foundRow !== -1) {
    sheet.deleteRow(foundRow + 1);
  }
  return { ok: true };
}
```

- [ ] **Step 3: Route + deleteGO cleanup**

In `doGet`, after the `getGcAdded` route:

```javascript
    else if (action === 'getSecuredSets')  result = getSecuredSets();
```

In `doPost`, after the `setGcAdded` route:

```javascript
    else if (action === 'setSecuredSet')    result = setSecuredSet(body.data);
```

In `deleteGO`, after the `SHEET_GC_ADDED` cleanup line:

```javascript
  deleteRowsWhere(ss.getSheetByName(SHEET_SECURED_SETS), 'go_id', goId);
```

- [ ] **Step 4: Syntax-check**

```bash
cp go-manager-backend.gs /tmp/ss.js && node --check /tmp/ss.js && echo "backend syntax OK"
```

- [ ] **Step 5: Commit**

```bash
git add go-manager-backend.gs
git commit -m "Backend: secured_sets sheet + getSecuredSets/setSecuredSet. REQUIRES REDEPLOY"
```

---

### Task 2: Frontend — set-status model (flag + deriveSetStatus + secure/unsecure)

**Files:**
- Modify: `index.html` — add `securedSets` state + `isSetFlagged` + `deriveSetStatus` (near `sameUser`/set helpers); `syncFromBackend` `Promise.all` + result handling; the 4 recompute sites (lines ~2233, ~2335, ~3245, ~4290); `secureSet` and `unsecureSet`.

**Interfaces:**
- Produces: `securedSets` (`'siId|setNum'→true`), `isSetFlagged(siId, setNum)`, `deriveSetStatus(siId, set, members)`.

- [ ] **Step 1: State + helpers**

Immediately after the `sameUser` function, add:

```javascript
let securedSets = {}; // 'subItemId|setNum' -> true : sets the admin explicitly secured
function isSetFlagged(siId, setNum) { return !!securedSets[siId + '|' + setNum]; }
// A set is 'secured' iff explicitly flagged OR full (every member slot filled and all secured).
function deriveSetStatus(siId, set, members) {
  const ms = members || [];
  const full = ms.length && ms.every(m => set.slots[m]) && Object.values(set.slots).filter(Boolean).every(v => v.claim_status === 'secured');
  return (isSetFlagged(siId, set.num) || full) ? 'secured' : 'open';
}
```

- [ ] **Step 2: Load `securedSets` on sync**

Extend the `Promise.all` destructure + calls to add `securedResult` / `apiGet('getSecuredSets')`:

```javascript
    const [result, payResult, listResult, orderResult, shipResult, storeResult, gcResult, securedResult] = await Promise.all([
      apiGet('getAllGOs'), apiGet('getPayments'), apiGet('getListings'), apiGet('getShopOrders'), apiGet('getShipping'), apiGet('getStoreOrders'), apiGet('getGcAdded'), apiGet('getSecuredSets')
    ]);
```

After the `gcResult` handling block, add:

```javascript
    if (securedResult && Array.isArray(securedResult.secured_sets)) {
      securedSets = {};
      securedResult.secured_sets.forEach(r => {
        if (r && r.sub_item_id && r.set_num !== undefined && r.set_num !== '') securedSets[r.sub_item_id + '|' + r.set_num] = true;
      });
    }
```

Note: this must run **before** the GOs are reconstructed so `buildSetsFromClaims` sees the flags. If the `getAllGOs` reconstruction happens earlier in the function, move the `securedSets` build to just before the `result.gos.forEach` loop instead (same code, placed above the reconstruction).

- [ ] **Step 3: Replace the 4 recompute sites with `deriveSetStatus`**

Each currently reads `... = filled.length && filled.every(v => v.claim_status === 'secured') ? 'secured' : 'open';`. Replace with `deriveSetStatus(<siId>, <set>, <members>)`:

- **toggleSlotSecure (~2233):** `set.status = deriveSetStatus(si.id, set, si.members);` (remove the now-unused `filled` line if only used here).
- **applyClaimStatusRef (~2335):** `set.status = deriveSetStatus(si.id, set, si.members);`
- **compactMemberColumn (~3245):** in the `si.sets.forEach(s => {...})`, `s.status = deriveSetStatus(si.id, s, si.members);`
- **buildSetsFromClaims (~4290):** in `sets.forEach(s => {...})`, `s.status = deriveSetStatus(siId, s, members);` (it has `siId` + `members` params).

- [ ] **Step 4: `secureSet` — persist the flag**

In `secureSet`, after the existing `apiPost('secureSet', …)`, add the flag (local + persisted):

```javascript
  securedSets[siId + '|' + setNum] = true;
  if (API_URL) persistWrite(apiPost('setSecuredSet', { go_id: goId, sub_item_id: siId, set_num: setNum, secured: true }), 'Secure set');
```

(Keep the existing `si.sets[setIdx].status = 'secured';` and slot-marking.)

- [ ] **Step 5: `unsecureSet` — clear the flag + derive status**

In `unsecureSet`, change `si.sets[setIdx].status = 'open';` to recompute via derive after clearing the flag, and add the flag removal:

```javascript
  const si = allGOs[goId].subItems.find(s => s.id === siId);
  Object.values(si.sets[setIdx].slots).forEach(v => { if (v) v.claim_status = 'pending'; });
  const setNum = si.sets[setIdx].num || (setIdx + 1);
  delete securedSets[siId + '|' + setNum];
  si.sets[setIdx].status = deriveSetStatus(siId, si.sets[setIdx], si.members);
  if (API_URL) {
    persistWrite(apiPost('unsecureSet', { go_id: goId, sub_item_id: siId, set_num: setNum }), 'Unsecure set');
    persistWrite(apiPost('setSecuredSet', { go_id: goId, sub_item_id: siId, set_num: setNum, secured: false }), 'Unsecure set');
  }
```

(Keep the render calls + toast.)

- [ ] **Step 6: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 7: Verify in browser**

Admin → Manage on a photocard GO. Per-slot **Secure?** a single slot in a mostly-empty set → the **set badge stays "open"** (not Secured). Click the whole-set **Secure** button → the set shows **Secured**; reload → still Secured (flag persisted, after redeploy). **Unsecure** → back to open. A naturally **full** set with all slots secured shows Secured without the button.

- [ ] **Step 8: Commit**

```bash
git add index.html
git commit -m "Set status: secured = explicit flag OR full (deriveSetStatus); per-slot secure no longer badges the set"
```

---

### Task 3: Frontend — per-claim owed

**Files:**
- Modify: `index.html` — `paymentOwedUnits` set branch (~3766–3779).

- [ ] **Step 1: Charge per secured slot (not per secured set)**

Replace the set branch:

```javascript
    if (si.sets) {
      setDisplayOrder(si.sets, si.members).forEach(({ set }) => {
        if (set.status !== 'secured') return;
        const otSlots = [], normalSlots = [];
        (si.members||[]).forEach(m => {
          const slot = set.slots[m];
          if (slot && sameUser(slot.user, username)) (slot.ot ? otSlots : normalSlots).push(slot);
        });
        // OT full set → one unit at the flat OT price, covering all its slots.
        if (otSlots.length) {
          units.push({ ids: otSlots.map(s => s.claim_id).filter(Boolean), value: si.otPrice||0, kind: 'slot', refs: otSlots });
        }
        normalSlots.forEach(slot => units.push({ ids: [slot.claim_id].filter(Boolean), value: si.price||0, kind: 'slot', refs: [slot] }));
      });
    }
```

with (charge each of the user's **secured** slots, regardless of set badge):

```javascript
    if (si.sets) {
      si.sets.forEach(set => {
        const otSlots = [], normalSlots = [];
        (si.members||[]).forEach(m => {
          const slot = set.slots[m];
          if (!slot || !sameUser(slot.user, username) || slot.claim_status !== 'secured') return;
          (slot.ot ? otSlots : normalSlots).push(slot);
        });
        // OT full set → one unit at the flat OT price, covering all its (secured) slots.
        if (otSlots.length) {
          units.push({ ids: otSlots.map(s => s.claim_id).filter(Boolean), value: si.otPrice||0, kind: 'slot', refs: otSlots });
        }
        normalSlots.forEach(slot => units.push({ ids: [slot.claim_id].filter(Boolean), value: si.price||0, kind: 'slot', refs: [slot] }));
      });
    }
```

- [ ] **Step 2: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 3: Verify in browser**

A buyer with an **individually-secured** claim in a not-yet-secured set now shows that item as **owed** in My orders / the admin confirm modal (previously $0 until the whole set was secured). A button-/full-secured set still owes all its slots. Dropped/pending slots are not owed.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "Owed: charge per secured claim (slot claim_status), independent of set badge"
```

---

## Post-redeploy migration (manual, run by dev after the user redeploys)

Not a code task. After the backend is redeployed, backfill `secured_sets` so existing
secured sets keep their badge: for every set currently derived as secured
(all-filled-secured), call `setSecuredSet { go_id, sub_item_id, set_num, secured:true }`.
Owed is unaffected (it's now per-claim). Then the admin manually **unsecures** any
accidental ones (e.g. Soundwave 1/8) via the set's Unsecure control (which also
un-charges that claim). Verify counts before/after.

---

## Self-Review

**Spec coverage:** backend sheet+endpoints+cleanup → Task 1 ✓; flat flag state + deriveSetStatus (flagged-or-full) replacing all 4 recompute sites + reconstruction + secure/unsecure flag persistence → Task 2 ✓; per-claim owed → Task 3 ✓; migration documented ✓; graceful pre-redeploy (getSecuredSets errors → securedSets empty → status falls back to full-only; owed already per-claim) ✓.

**Placeholder scan:** none.

**Type/name consistency:** `securedSets` keyed `siId+'|'+setNum`; `isSetFlagged(siId,setNum)` and `deriveSetStatus(siId,set,members)` defined Task 2 Step 1, used at all 4 sites + secure/unsecure. Backend `secured_sets` columns `go_id,sub_item_id,set_num`; `setSecuredSet{go_id,sub_item_id,set_num,secured}` matches the `apiPost` calls. `getSecuredSets` → `{secured_sets:[…]}` matches the sync reader. `paymentOwedUnits` now keys on `slot.claim_status==='secured'`.
