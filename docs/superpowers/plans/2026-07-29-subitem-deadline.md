# Per-POB (Sub-Item) Deadline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the admin set an optional display-only deadline date per POB (sub-item); buyers see "Closes <date>" on that POB while it's open.

**Architecture:** Mirror the `closed_subitems` store. New backend `subitem_deadlines` store (upsert, keyed `go_id, sub_item_id`) loaded into a frontend `subItemDeadlines` map and stamped onto each rebuilt sub-item as `si.deadline`. Admin sets it via an inline date field in the GO-detail header; buyers see "Closes <date>" on the POB card. No auto-close, no effect on claim placement.

**Tech Stack:** Single-file `index.html` (vanilla JS) + `go-manager-backend.gs` (Google Apps Script) + Google Sheets. No build, no test framework.

## Global Constraints

- Edit only `index.html` and `go-manager-backend.gs`.
- Display only — the deadline never affects `isPobClosed`, placement, or the closed state.
- Date granularity YYYY-MM-DD; format for display with the existing `fmtDate(...)`.
- Buyers see "Closes <date>" ONLY when `si.deadline` is set AND the POB is not closed (`!isPobClosed(allGOs[goId], si)`).
- Backend `setSubItemDeadline` is an **upsert**: match on `go_id`+`sub_item_id`; non-empty deadline updates the existing row or appends; empty deadline deletes the row. `bootstrapSheets()` called inside the setter (like `setClosedSubItem`).
- Persist writes via `persistWrite(apiPost(...), label)`.
- No test harness. Verify with: JS-parse of `index.html`, `node --check` of a `.js` copy of the backend.
- JS-parse command:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after each task. Backend change REQUIRES REDEPLOY (call out in the commit body).

---

### Task 1: Backend `subitem_deadlines` store (upsert)

**Files:**
- Modify: `go-manager-backend.gs` — sheet constant + `ensureSheet` line; `getSubItemDeadlines` / `setSubItemDeadline`; route both; clear in `deleteGO`.

**Interfaces:**
- Produces (doGet) `getSubItemDeadlines()` → `{ subitem_deadlines: [{go_id, sub_item_id, deadline}] }`.
- Produces (doPost) `setSubItemDeadline({ go_id, sub_item_id, deadline })` → `{ ok:true }`.

- [ ] **Step 1: Sheet constant + ensure**

After the `SHEET_CLOSED_SUBITEMS` constant add:
```javascript
const SHEET_SUBITEM_DEADLINES = 'subitem_deadlines'; // per-POB display-only deadline dates
```
In `bootstrapSheets()`, after the `ensureSheet(ss, SHEET_CLOSED_SUBITEMS, ...)` line add:
```javascript
  ensureSheet(ss, SHEET_SUBITEM_DEADLINES, ['go_id','sub_item_id','deadline']);
```

- [ ] **Step 2: Route both**

In `doGet`, after the `getClosedSubItems` route add:
```javascript
    else if (action === 'getSubItemDeadlines') result = getSubItemDeadlines();
```
In `doPost`, after the `setClosedSubItem` route add:
```javascript
    else if (action === 'setSubItemDeadline')  result = setSubItemDeadline(body.data);
```

- [ ] **Step 3: Clear on GO delete**

In `deleteGO`, after the `deleteRowsWhere(ss.getSheetByName(SHEET_CLOSED_SUBITEMS), 'go_id', goId);` line add:
```javascript
  deleteRowsWhere(ss.getSheetByName(SHEET_SUBITEM_DEADLINES), 'go_id', goId);
```

- [ ] **Step 4: Getter + upsert setter**

After `setClosedSubItem` add:
```javascript
function getSubItemDeadlines() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SUBITEM_DEADLINES);
  return { subitem_deadlines: sheet ? sheetToObjects(sheet) : [] };
}

function setSubItemDeadline(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SUBITEM_DEADLINES);
  const rows = sheet.getDataRange().getValues();
  const h = rows[0];
  const gi = h.indexOf('go_id'), si = h.indexOf('sub_item_id'), di = h.indexOf('deadline');
  let foundRow = -1;
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][gi] === data.go_id && rows[i][si] === data.sub_item_id) { foundRow = i; break; }
  }
  const deadline = data.deadline || '';
  if (deadline) {
    if (foundRow === -1) sheet.appendRow([data.go_id, data.sub_item_id, deadline]);
    else sheet.getRange(foundRow + 1, di + 1).setValue(deadline);
  } else if (foundRow !== -1) {
    sheet.deleteRow(foundRow + 1);
  }
  return { ok: true };
}
```

- [ ] **Step 5: Syntax-check**

```bash
cp /Users/jinghancui/Gitproj/Go-manager/go-manager-backend.gs /tmp/bk.js && node --check /tmp/bk.js && echo "backend JS OK"
```
Expected: `backend JS OK`.

- [ ] **Step 6: Commit**

```bash
cd /Users/jinghancui/Gitproj/Go-manager && git add go-manager-backend.gs
git commit -m "Backend: subitem_deadlines store (get/upsert-set/route/deleteGO)

REQUIRES BACKEND REDEPLOY + one bootstrap call to create the sheet.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Frontend state, load, `si.deadline` stamp, admin inline date field

**Files:**
- Modify: `index.html` — add `subItemDeadlines` + `subItemDeadline` near `closedSubItems` (~528); load in `syncFromBackend` `Promise.all` + parse (beside `closedSubItems`); stamp `si.deadline` beside the `s.closed` stamp; admin date field in the sub-item header (`renderDetailContent`, beside the Close POB button); add `setSubItemDeadline` handler beside `toggleSubItemClosed`.

**Interfaces:**
- Consumes: `closedSubItems` load pattern; `persistWrite`, `apiPost`, `fmtDate`, `renderDetailContent`.
- Produces: `subItemDeadlines` (map `'goId|siId' → deadline`); `subItemDeadline(goId, siId)`; `setSubItemDeadline(goId, siId, value)`.

- [ ] **Step 1: State + helper**

After the `isSubItemClosed`/`isPobClosed`/`leftoverSlotOpen`/`pickTargetSet` block add:
```javascript
let subItemDeadlines = {}; // 'goId|siId' -> deadline date string (display only)
function subItemDeadline(goId, siId) { return subItemDeadlines[goId + '|' + siId] || ''; }
```

- [ ] **Step 2: Fetch in `syncFromBackend`**

In the `Promise.all` destructuring + calls, add `getSubItemDeadlines` as a new entry (mirroring `getClosedSubItems`): add `, deadlineResult` to the destructured array and `, apiGet('getSubItemDeadlines')` to the calls array. Keep the closing `]);` intact.

- [ ] **Step 3: Parse (beside closedSubItems)**

Immediately after the `closedSubItems = {}; if (closedResult ...) { ... }` parse block add:
```javascript
      subItemDeadlines = {};
      if (deadlineResult && Array.isArray(deadlineResult.subitem_deadlines)) {
        deadlineResult.subitem_deadlines.forEach(r => {
          if (r && r.go_id && r.sub_item_id && r.deadline) subItemDeadlines[r.go_id + '|' + r.sub_item_id] = fmtDate(r.deadline);
        });
      }
```

- [ ] **Step 4: Stamp `si.deadline` during reconstruction**

Immediately after the existing `rebuilt.subItems.forEach(s => { s.closed = isSubItemClosed(go.go_id, s.id); });` line add:
```javascript
        rebuilt.subItems.forEach(s => { s.deadline = subItemDeadline(go.go_id, s.id); });
```

- [ ] **Step 5: Admin inline date field in the sub-item header**

In `renderDetailContent`, the sub-item header currently ends with the Close/Reopen button then `</div>`. Find the Close/Reopen button line (added by the Close POB feature):
```javascript
    html += ` <button class="btn btn-sm btn-ghost" style="font-size:11px;padding:2px 8px;${si.closed ? 'color:var(--teal-600);' : 'color:var(--red-400);'}" onclick="event.stopPropagation();toggleSubItemClosed('${go.id}','${si.id}')">${si.closed ? 'Reopen POB' : 'Close POB'}</button></div>`;
```
Replace it with (insert the date field before the closing `</div>`):
```javascript
    html += ` <button class="btn btn-sm btn-ghost" style="font-size:11px;padding:2px 8px;${si.closed ? 'color:var(--teal-600);' : 'color:var(--red-400);'}" onclick="event.stopPropagation();toggleSubItemClosed('${go.id}','${si.id}')">${si.closed ? 'Reopen POB' : 'Close POB'}</button>`;
    html += ` <span style="font-size:11px;color:var(--text3);">closes</span> <input type="date" value="${si.deadline || ''}" onclick="event.stopPropagation()" onchange="setSubItemDeadline('${go.id}','${si.id}', this.value)" style="font-size:11px;padding:1px 4px;border:0.5px solid var(--border2);border-radius:5px;">`;
    html += `</div>`;
```

- [ ] **Step 6: Handler**

Immediately before `function toggleSubItemClosed(` add:
```javascript
function setSubItemDeadline(goId, siId, value) {
  const si = allGOs[goId].subItems.find(s => s.id === siId);
  if (!si) return;
  si.deadline = value || '';
  const key = goId + '|' + siId;
  if (si.deadline) subItemDeadlines[key] = si.deadline; else delete subItemDeadlines[key];
  if (API_URL) persistWrite(apiPost('setSubItemDeadline', { go_id: goId, sub_item_id: siId, deadline: si.deadline }), 'Deadline');
  renderDetailContent();
  toast(si.deadline ? ('Deadline set: ' + fmtDate(si.deadline)) : 'Deadline cleared.');
}
```

- [ ] **Step 7: JS-parse**

Run the JS-parse command. Expected: `JS parses OK`.

- [ ] **Step 8: Commit**

```bash
cd /Users/jinghancui/Gitproj/Go-manager && git add index.html
git commit -m "POB deadline: frontend state, load, si.deadline stamp + admin inline date field

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Buyer "Closes <date>" on POB cards

**Files:**
- Modify: `index.html` — add a "Closes <date>" line to `renderSetSubItemPublic`, `renderBatchSubItemPublic`, `renderVersionedSubItemPublic`, `renderSingleSubItemPublic`, shown only when `si.deadline` set and the POB is not closed.

**Interfaces:**
- Consumes: `isPobClosed(allGOs[goId], si)` (already computed as `closed` in each renderer by the Close POB feature), `si.deadline`, `fmtDate`.

- [ ] **Step 1: Reusable snippet**

Each of the four renderers already computes `const closed = isPobClosed(allGOs[goId], si);` near the top and prepends a Closed banner via `${closed ? '<div ...>Closed…</div>' : ''}`. Immediately after that banner expression (inside the same template literal, right after the `${closed ? ... : ''}` for the banner), add a deadline line:
```javascript
    ${(!closed && si.deadline) ? `<div style="font-size:12px;color:var(--text3);margin-bottom:8px;">Closes ${fmtDate(si.deadline)}</div>` : ''}
```

Apply this in all four renderers:
- **`renderSetSubItemPublic`** — the Closed banner is on the opening `<div class="card" ...>${siImg(si,'card')} ${closed ? '<div ...>Closed — only filling leftover spots...</div>' : ''}`. Add the deadline line right after that banner expression.
- **`renderBatchSubItemPublic`** — after its `${closed ? '<div ...>Closed — no longer accepting new claims.</div>' : ''}` banner.
- **`renderVersionedSubItemPublic`** — after its banner.
- **`renderSingleSubItemPublic`** — after its banner (this function uses `return \`...\``).

- [ ] **Step 2: JS-parse**

Run the JS-parse command. Expected: `JS parses OK`.

- [ ] **Step 3: Verify (manual)**

Set a deadline on an open POB → buyers see "Closes <date>" under its name; close the POB → the "Closes" text disappears and the Closed banner shows; clear the deadline → text gone; refresh persists (requires Task 1 redeploy + bootstrap).

- [ ] **Step 4: Commit**

```bash
cd /Users/jinghancui/Gitproj/Go-manager && git add index.html
git commit -m "POB deadline: buyer 'Closes <date>' on POB cards (open POBs only)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Post-implementation (manual, by the admin)

1. Redeploy `go-manager-backend.gs`.
2. Fire one `bootstrap` call to create the `subitem_deadlines` sheet.
3. Hard-refresh.

## Self-Review

**Spec coverage:** backend upsert store (get/set/route/deleteGO) → Task 1 ✓; `subItemDeadlines` map + load-before-reconstruction + `si.deadline` stamp → Task 2 ✓; admin inline date field + handler (clear = delete) → Task 2 ✓; buyer "Closes <date>" on all 4 POB renderers, open-only → Task 3 ✓; persistence + safe degrade (empty map pre-redeploy) → Task 2 (guarded parse) ✓; display-only, no placement effect → nothing in the plan touches `isPobClosed`/placement ✓.

**Placeholder scan:** none — every code step has complete code. Task 3 gives the exact snippet and names all four insertion points.

**Type consistency:** `si.deadline` (string), `subItemDeadlines['goId|siId']` (string), `subItemDeadline(goId, siId)`, `setSubItemDeadline(goId, siId, value)` — consistent across Tasks 2/3. Backend columns `go_id, sub_item_id, deadline` match the frontend load key in Task 2. `fmtDate` used for all display; the map stores the fmtDate'd string (Task 2 Step 3) so the date input and display agree.
