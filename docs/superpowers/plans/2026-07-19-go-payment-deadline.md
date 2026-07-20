# Per-GO Payment Deadline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An optional per-GO payment deadline the admin sets in Create/Edit GO, stored in the backend, shown to buyers as "Pay by \<date\>" only where they still owe.

**Architecture:** New `payment_deadline` column on the `_gos` sheet + create/update wiring (Apps Script, needs redeploy). Frontend carries `paymentDeadline` on the GO object (create/edit/sync) and renders "Pay by" in `renderMyOrderGoBlock`.

**Tech Stack:** Vanilla JS `index.html`; Apps Script `go-manager-backend.gs`.

## Global Constraints

- Frontend edits in `index.html`; backend edits in `go-manager-backend.gs`.
- Task 1 (backend) REQUIRES the user to redeploy the Apps Script. Frontend degrades gracefully before then (`paymentDeadline` empty → no "Pay by"; setting one won't persist until redeploy).
- Frontend field `paymentDeadline` (camelCase, `YYYY-MM-DD` or ''); backend column/payload `payment_deadline`. `apiPost` payloads translate explicitly.
- Date only (matches the preorder deadline). "Pay by" shows only when `owed > 0` AND a deadline is set.
- No test harness. Verify frontend with JS-parse; backend with `node --check` on a `.js` copy. JS-parse:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after each task.

---

### Task 1: Backend — `payment_deadline` column + create/update

**Files:**
- Modify: `go-manager-backend.gs` — `bootstrapSheets` `SHEET_GOS` header (line ~20), `createGO` appendRow (line ~143), `updateGO` (line ~161).

- [ ] **Step 1: Add the column to the `_gos` schema**

Change the `SHEET_GOS` ensureSheet header:

```javascript
  ensureSheet(ss, SHEET_GOS,      ['go_id','name','type','deadline','status','min_secure','created_at','payment_deadline']);
```

- [ ] **Step 2: Write it in `createGO`**

Change the `createGO` appendRow to include the new final column:

```javascript
  goSheet.appendRow([goId, data.name, data.type, data.deadline, data.status || 'open', data.min_secure || 7, new Date().toISOString(), data.payment_deadline || '']);
```

- [ ] **Step 3: Write it in `updateGO`**

In `updateGO`, after the `if (data.status) ...` line (inside the matched-row block), add:

```javascript
      const pdCol = headers.indexOf('payment_deadline');
      if (pdCol !== -1 && data.payment_deadline !== undefined) goSheet.getRange(i+1, pdCol+1).setValue(data.payment_deadline);
```

- [ ] **Step 4: Syntax-check**

```bash
cp go-manager-backend.gs /tmp/pd.js && node --check /tmp/pd.js && echo "backend syntax OK"
```

- [ ] **Step 5: Commit**

```bash
git add go-manager-backend.gs
git commit -m "Backend: payment_deadline column on _gos + create/update wiring. REQUIRES REDEPLOY"
```

---

### Task 2: Frontend admin — Create/Edit GO field + save + sync

**Files:**
- Modify: `index.html` — create form (line ~383), `createGO` (lines ~2506, ~2565, ~2566), edit form (line ~427), edit-open populate (line ~2671), `saveGOEdits` (lines ~2864, ~2969), sync reconstruction (line ~3858).

- [ ] **Step 1: Add the Create-GO date field**

After the create-form Deadline field:

```html
        <div class="field"><label>Deadline</label><input type="date" id="new-go-deadline"></div>
```

add:

```html
        <div class="field"><label>Payment deadline</label><input type="date" id="new-go-payment-deadline"></div>
```

- [ ] **Step 2: Read + store + post it in `createGO`**

After:

```javascript
  const deadline = document.getElementById('new-go-deadline').value;
```

add:

```javascript
  const paymentDeadline = document.getElementById('new-go-payment-deadline').value;
```

Change the GO object assignment:

```javascript
  allGOs[id] = { id, name, type, deadline, paymentDeadline, status: 'open', subItems };
```

Change the create apiPost to include the backend field:

```javascript
  if (API_URL) apiPost('createGO', { ...allGOs[id], payment_deadline: paymentDeadline, min_secure: subItems[0]?.minSecure || 7 });
```

- [ ] **Step 3: Add the Edit-GO date field**

After the edit-form Deadline field:

```html
        <div class="field"><label>Deadline</label><input type="date" id="edit-go-deadline"></div>
```

add:

```html
        <div class="field"><label>Payment deadline</label><input type="date" id="edit-go-payment-deadline"></div>
```

- [ ] **Step 4: Populate it when opening Edit GO**

After:

```javascript
  document.getElementById('edit-go-deadline').value = fmtDate(go.deadline);
```

add:

```javascript
  document.getElementById('edit-go-payment-deadline').value = fmtDate(go.paymentDeadline);
```

- [ ] **Step 5: Read + post it in `saveGOEdits`**

After:

```javascript
  go.deadline = document.getElementById('edit-go-deadline').value;
```

add:

```javascript
  go.paymentDeadline = document.getElementById('edit-go-payment-deadline').value;
```

Change the update apiPost:

```javascript
  if (API_URL) apiPost('updateGO', { go_id: go.id, name: go.name, deadline: go.deadline, payment_deadline: go.paymentDeadline, status: go.status, subItems: go.subItems });
```

- [ ] **Step 6: Reconstruct it on sync**

Change the `rebuilt` GO object line:

```javascript
          deadline: fmtDate(go.deadline), paymentDeadline: fmtDate(go.payment_deadline), status: go.status || 'open',
```

- [ ] **Step 7: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 8: Commit**

```bash
git add index.html
git commit -m "Payment deadline: Create/Edit GO field + save + sync reconstruction"
```

---

### Task 3: Frontend buyer — "Pay by" in My orders

**Files:**
- Modify: `index.html` — `renderMyOrderGoBlock` (creditNote area ~1664 and the body return ~1676).

- [ ] **Step 1: Compute the deadline note and render it**

In `renderMyOrderGoBlock`, immediately after the `creditNote` line:

```javascript
  const creditNote = (s.owed <= 0 && s.credit > 0) ? `
        <div style="font-size:12px;color:var(--teal-600);background:var(--teal-50);border-radius:var(--radius);padding:8px 10px;">$${s.credit.toFixed(2)} is held as credit toward claims secured later.</div>` : '';
```

add:

```javascript
  const goObj = allGOs[g.go_id];
  const deadlineNote = (s.owed > 0 && goObj && goObj.paymentDeadline) ? `<div style="font-size:12px;color:var(--red-400);font-weight:500;margin:0 0 10px;">Pay by ${fmtDate(goObj.paymentDeadline)}</div>` : '';
```

Then in the return template, change the summary line so the deadline note follows it — replace:

```javascript
      <div style="font-size:12px;color:var(--text3);margin:10px 0;">${summaryLine}</div>
      ${form}${creditNote}
```

with:

```javascript
      <div style="font-size:12px;color:var(--text3);margin:10px 0;">${summaryLine}</div>
      ${deadlineNote}${form}${creditNote}
```

- [ ] **Step 2: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 3: Verify in browser**

Set a payment deadline on a GO (Edit GO) — after the backend is redeployed. Look up a buyer who owes on that GO: their GO block shows **"Pay by \<date\>"** under the Paid/Owed line. A GO they've fully paid, or one with no deadline, shows no "Pay by". (Before redeploy: no "Pay by" appears — expected.)

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "Payment deadline: show 'Pay by <date>' in My orders when the buyer owes"
```

---

## Self-Review

**Spec coverage:** backend column + create/update + getAllGOs passthrough → Task 1 ✓. Create/Edit field + save + sync → Task 2 ✓. Buyer "Pay by" when owed → Task 3 ✓. Graceful pre-redeploy degradation → empty `paymentDeadline` yields no note; apiPost adds the field harmlessly ✓.

**Placeholder scan:** none.

**Type/name consistency:** frontend `paymentDeadline` set in `createGO`/`saveGOEdits`/sync and read in `renderMyOrderGoBlock`; backend `payment_deadline` column read/written in Task 1 and sent via `apiPost` payloads (`payment_deadline: <camel>`) in Task 2. `getAllGOs` returns `payment_deadline` (via `sheetToObjects`), consumed as `go.payment_deadline` in the sync reconstruction.
