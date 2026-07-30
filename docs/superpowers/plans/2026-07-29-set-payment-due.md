# Per-Set Payment Due Date — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Admin sets an optional display-only payment due date per set; joiners see "Pay by <date>" on their secured, unpaid claims for that set in My Orders.

**Architecture:** Mirror the `subitem_deadlines` upsert store, but keyed by set (`go_id, sub_item_id, set_num`, like `secured_sets`). Loaded into a frontend `setPaymentDue` map; the admin set card gets an inline date field; `doLookup` attaches each set-based row's due date; `renderMyOrderGoBlock` shows "Pay by <date>" on secured unpaid rows. Display only.

**Tech Stack:** Single-file `index.html` (vanilla JS) + `go-manager-backend.gs` (Apps Script) + Google Sheets. No build, no test framework.

## Global Constraints

- Edit only `index.html` and `go-manager-backend.gs`.
- Display only — never affects placement, closed state, or owed.
- Key = `sub_item_id + '|' + set_num` (frontend map) / `sub_item_id`+String(`set_num`) match (backend). Use the set's persistent `set.num`, NOT the display counter `admSetNo`.
- Date granularity YYYY-MM-DD; store/display via `fmtDate`.
- Joiner "Pay by" shows only when a row is **Secured**, **not paid**, and its set has a due date.
- Backend `setSetPaymentDue` is an upsert (append / update cell / delete), `bootstrapSheets()` called inside it (like `setSubItemDeadline`).
- Persist via `persistWrite(apiPost(...), label)`.
- No test harness. Verify with JS-parse of `index.html` and `node --check` of a `.js` copy of the backend.
- JS-parse command:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after each task. Backend change REQUIRES REDEPLOY (call out in the commit body).

---

### Task 1: Backend `set_payment_due` store (upsert)

**Files:**
- Modify: `go-manager-backend.gs` — sheet constant + `ensureSheet` line; `getSetPaymentDue` / `setSetPaymentDue`; route both; clear in `deleteGO`.

**Interfaces:**
- Produces (doGet) `getSetPaymentDue()` → `{ set_payment_due: [{go_id, sub_item_id, set_num, due_date}] }`.
- Produces (doPost) `setSetPaymentDue({ go_id, sub_item_id, set_num, due_date })` → `{ ok:true }`.

- [ ] **Step 1: Sheet constant + ensure**

After the `SHEET_SUBITEM_DEADLINES` constant add:
```javascript
const SHEET_SET_PAYMENT_DUE = 'set_payment_due'; // per-set payment due dates (display only)
```
In `bootstrapSheets()`, after the `ensureSheet(ss, SHEET_SUBITEM_DEADLINES, ...)` line add:
```javascript
  ensureSheet(ss, SHEET_SET_PAYMENT_DUE, ['go_id','sub_item_id','set_num','due_date']);
```

- [ ] **Step 2: Route both**

In `doGet`, after the `getSubItemDeadlines` route add:
```javascript
    else if (action === 'getSetPaymentDue') result = getSetPaymentDue();
```
In `doPost`, after the `setSubItemDeadline` route add:
```javascript
    else if (action === 'setSetPaymentDue')  result = setSetPaymentDue(body.data);
```

- [ ] **Step 3: Clear on GO delete**

In `deleteGO`, after the `deleteRowsWhere(ss.getSheetByName(SHEET_SUBITEM_DEADLINES), 'go_id', goId);` line add:
```javascript
  deleteRowsWhere(ss.getSheetByName(SHEET_SET_PAYMENT_DUE), 'go_id', goId);
```

- [ ] **Step 4: Getter + upsert setter**

After `setSubItemDeadline` add:
```javascript
function getSetPaymentDue() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SET_PAYMENT_DUE);
  return { set_payment_due: sheet ? sheetToObjects(sheet) : [] };
}

function setSetPaymentDue(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SET_PAYMENT_DUE);
  const rows = sheet.getDataRange().getValues();
  const h = rows[0];
  const si = h.indexOf('sub_item_id'), sn = h.indexOf('set_num'), di = h.indexOf('due_date');
  let foundRow = -1;
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][si] === data.sub_item_id && String(rows[i][sn]) === String(data.set_num)) { foundRow = i; break; }
  }
  const due = data.due_date || '';
  if (due) {
    if (foundRow === -1) sheet.appendRow([data.go_id, data.sub_item_id, data.set_num, due]);
    else sheet.getRange(foundRow + 1, di + 1).setValue(due);
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
git commit -m "Backend: set_payment_due store (get/upsert-set/route/deleteGO)

REQUIRES BACKEND REDEPLOY + one bootstrap call to create the sheet.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Frontend state, load, admin per-set date field

**Files:**
- Modify: `index.html` — add `setPaymentDue` + `setDueDate` near `subItemDeadlines`; load in `syncFromBackend` `Promise.all` + parse; admin date field on the set card header in `renderDetailContent`; add `setSetPaymentDue` handler near `setSubItemDeadline`.

**Interfaces:**
- Consumes: `subItemDeadlines` load pattern; `persistWrite`, `apiPost`, `fmtDate`, `renderDetailContent`.
- Produces: `setPaymentDue` (map `'siId|setNum' → due`); `setDueDate(siId, setNum)`; `setSetPaymentDue(goId, siId, setNum, value)`.

- [ ] **Step 1: State + helper**

After the `subItemDeadlines`/`subItemDeadline` lines add:
```javascript
let setPaymentDue = {}; // 'siId|setNum' -> due date string (display only)
function setDueDate(siId, setNum) { return setPaymentDue[siId + '|' + setNum] || ''; }
```

- [ ] **Step 2: Fetch in `syncFromBackend`**

In the `Promise.all` destructuring + calls, add `getSetPaymentDue` as a new entry (mirroring `getSubItemDeadlines`): add `, dueResult` to the destructured array and `, apiGet('getSetPaymentDue')` to the calls array. Keep the closing `]);` intact.

- [ ] **Step 3: Parse (beside subItemDeadlines)**

Immediately after the `subItemDeadlines = {}; if (deadlineResult ...) { ... }` parse block add:
```javascript
      setPaymentDue = {};
      if (dueResult && Array.isArray(dueResult.set_payment_due)) {
        dueResult.set_payment_due.forEach(r => {
          if (r && r.sub_item_id && r.set_num !== undefined && r.set_num !== '' && r.due_date) setPaymentDue[r.sub_item_id + '|' + r.set_num] = fmtDate(r.due_date);
        });
      }
```

- [ ] **Step 4: Admin date field on the set card header**

In `renderDetailContent` (set-based branch), find the set card header controls div:
```javascript
            <div style="display:flex;gap:6px;align-items:center;">
              ${isSecured ? `<span class="badge badge-secured" style="cursor:pointer;" title="Click to unsecure" onclick="unsecureSet('${go.id}','${si.id}',${setIdx})">Secured ✕</span>` : ''}
```
Insert the date field as the FIRST children of that controls div (before the `${isSecured ...}` line):
```javascript
            <div style="display:flex;gap:6px;align-items:center;">
              <span style="font-size:10px;color:var(--text3);">pay by</span>
              <input type="date" value="${setDueDate(si.id, set.num)}" onclick="event.stopPropagation()" onchange="setSetPaymentDue('${go.id}','${si.id}',${set.num}, this.value)" style="font-size:10px;padding:1px 3px;border:0.5px solid var(--border2);border-radius:5px;">
              ${isSecured ? `<span class="badge badge-secured" style="cursor:pointer;" title="Click to unsecure" onclick="unsecureSet('${go.id}','${si.id}',${setIdx})">Secured ✕</span>` : ''}
```
(Leave the following `${!isSecured ? ...}` line and the closing `</div>` unchanged.)

- [ ] **Step 5: Handler**

Immediately after `function setSubItemDeadline(` … `}` add:
```javascript
function setSetPaymentDue(goId, siId, setNum, value) {
  const key = siId + '|' + setNum;
  if (value) setPaymentDue[key] = value; else delete setPaymentDue[key];
  if (API_URL) persistWrite(apiPost('setSetPaymentDue', { go_id: goId, sub_item_id: siId, set_num: setNum, due_date: value }), 'Payment due');
  renderDetailContent();
  toast(value ? ('Set payment due: ' + fmtDate(value)) : 'Payment due cleared.');
}
```

- [ ] **Step 6: JS-parse**

Run the JS-parse command. Expected: `JS parses OK`.

- [ ] **Step 7: Commit**

```bash
cd /Users/jinghancui/Gitproj/Go-manager && git add index.html
git commit -m "Per-set payment due: frontend state, load + admin set-card date field

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Joiner "Pay by <date>" in My Orders

**Files:**
- Modify: `index.html` — `doLookup` set-based rows carry `due`; `renderMyOrderGoBlock` shows "Pay by <date>" on secured unpaid rows.

**Interfaces:**
- Consumes: `setDueDate(siId, setNum)` (Task 2); row fields `claim`, `payment`, `due`.

- [ ] **Step 1: Attach `due` to set-based rows in `doLookup`**

In `doLookup`, the set-based branch pushes an OT row and a per-member row. Add `due: setDueDate(si.id, set.num)` to BOTH pushes.

The OT row — change:
```javascript
            rows.push({ go_id:go.id, go:go.name, item:si.name, detail:'OT'+membersToCheck.length+' full set', qty:1, price:si.otPrice||0, claim:(s0.claim_status==='dropped')?'Not fulfilled':((s0.claim_status==='secured')?'Secured':'Pending'), payment:s0.payment, fulfillment:s0.fulfillment });
```
to append `, due: setDueDate(si.id, set.num)` before the closing `});`:
```javascript
            rows.push({ go_id:go.id, go:go.name, item:si.name, detail:'OT'+membersToCheck.length+' full set', qty:1, price:si.otPrice||0, claim:(s0.claim_status==='dropped')?'Not fulfilled':((s0.claim_status==='secured')?'Secured':'Pending'), payment:s0.payment, fulfillment:s0.fulfillment, due: setDueDate(si.id, set.num) });
```
The per-member row — change:
```javascript
              rows.push({ go_id:go.id, go:go.name, item:si.name, detail:member, qty:1, price:si.price||0, claim:(slot.claim_status==='dropped')?'Not fulfilled':((slot.claim_status==='secured')?'Secured':'Pending'), payment:slot.payment, fulfillment:slot.fulfillment });
```
to:
```javascript
              rows.push({ go_id:go.id, go:go.name, item:si.name, detail:member, qty:1, price:si.price||0, claim:(slot.claim_status==='dropped')?'Not fulfilled':((slot.claim_status==='secured')?'Secured':'Pending'), payment:slot.payment, fulfillment:slot.fulfillment, due: setDueDate(si.id, set.num) });
```

- [ ] **Step 2: Show "Pay by" in the My Orders row Payment cell**

In `renderMyOrderGoBlock`, find the claim-row Payment cell:
```javascript
    <td><span class="badge ${r.payment==='paid'?'badge-paid':'badge-unpaid'}">${r.payment==='paid'?'Paid':'Unpaid'}</span></td>
```
Replace with:
```javascript
    <td><span class="badge ${r.payment==='paid'?'badge-paid':'badge-unpaid'}">${r.payment==='paid'?'Paid':'Unpaid'}</span>${(r.claim==='Secured' && r.payment!=='paid' && r.due) ? `<div style="font-size:10px;color:var(--red-400);margin-top:2px;">Pay by ${r.due}</div>` : ''}</td>
```

- [ ] **Step 3: JS-parse**

Run the JS-parse command. Expected: `JS parses OK`.

- [ ] **Step 4: Verify (manual)**

Set a due date on a set with a secured, unpaid claim → that joiner sees "Pay by <date>" under Unpaid in My Orders. A paid or unsecured claim shows nothing. Clearing the date removes it. Requires Task 1 redeploy + bootstrap.

- [ ] **Step 5: Commit**

```bash
cd /Users/jinghancui/Gitproj/Go-manager && git add index.html
git commit -m "Per-set payment due: joiner 'Pay by <date>' on secured unpaid claims in My orders

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Post-implementation (manual, by the admin)

1. Redeploy `go-manager-backend.gs`.
2. Fire one `bootstrap` call to create the `set_payment_due` sheet.
3. Hard-refresh.

## Self-Review

**Spec coverage:** backend upsert store keyed by set (get/set/route/deleteGO) → Task 1 ✓; `setPaymentDue` map + load-before-reconstruction → Task 2 ✓; admin per-set date field + handler (clear = delete), keyed on `set.num` not display counter → Task 2 ✓; joiner "Pay by <date>" on secured unpaid rows, per-set → Task 3 ✓; display-only (nothing touches placement/owed) ✓; safe degrade (empty map pre-redeploy) → Task 2 guarded parse ✓.

**Placeholder scan:** none — full code at every step; the two `doLookup` pushes and the Payment cell are shown verbatim.

**Type consistency:** `setPaymentDue['siId|setNum']` (string) ← key uses `set.num`; `setDueDate(siId, setNum)`; `setSetPaymentDue(goId, siId, setNum, value)`; row field `due`. Backend columns `go_id, sub_item_id, set_num, due_date` match the frontend load key. `fmtDate` used for the stored value and the input. The admin writes `set.num` and the joiner reads `set.num` (the claim's real set number), so the two agree even though the admin card is labeled with the display counter `admSetNo`.
