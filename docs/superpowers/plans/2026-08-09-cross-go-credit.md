# Cross-GO Credit (account balance) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a joiner spend credit from any GO toward what they owe on another GO, surfaced as one "account balance" in My Orders, applied via a "Use account balance" button, with the target GO's items auto-marked Paid.

**Architecture:** Keep per-GO Paid/Owed exactly as-is. Surplus rolls up into a *derived* account balance (`Σ per-GO credit`). "Use account balance" draws that surplus from source GOs (largest-first) and writes **paired ±credit payment rows** (shared `transaction_id`, `method:'credit'`), so `goPaymentSummary` reflects it with no change. The target GO's items are marked Paid up to the applied amount (full auto-marking, partial included), reusing the payment sheet's existing claim-marking. Reversible by admin.

**Tech Stack:** Single-file vanilla-JS `index.html` (inline `<script>`) + Google Apps Script `go-manager-backend.gs` + Google Sheets. No test framework — verify with JS-parse of the script blocks, `node --check` on a `.js` copy of the backend, and Node logic harnesses for pure functions.

## Global Constraints

- Credit rows use exactly `method: 'credit'`, `status: 'confirmed'`, and share one `transaction_id` per application (`'cr_' + Date.now() + '_' + <rand>`).
- Source rows carry **negative** `amount` (−d); the target row carries **positive** `amount` (+Y). `Y = Σ d`. Net zero.
- Each `d` (draw from a source GO) is capped at that GO's current credit; total `Y` = `spent` (the whole-item store-credit amount, ≤ `min(accountBalance, targetOwed)`).
- Draw order: **largest source credit first**, automatic (no source-picking UI).
- **Store-credit rule:** balance is spent only on **whole owed items** (units). The amount applied `Y` = the greedy sum of whole unpaid units (display order) that fits within the balance; the remainder of the balance is **kept**. So money spent always equals items marked Paid (no stranded partial). Example: $25 balance vs items [18,9,10] → spends $18 (Album), balance keeps $7, owed drops by $18. Full auto-marking: those covered whole items flip to Paid; reversal un-marks by recomputing.
- Per-GO Paid/Owed display is unchanged; the per-GO **Credit** line is removed (rolled into the one account-balance card).
- Money math must stay correct: `goPaymentSummary` (admin) and the buyer flat-claims summary must both remain the sources of truth; do not fork their owed logic.
- Backend `applyCredit`/`reverseCredit` require redeploying the Apps Script Web App.

**Reusable verification commands** (from repo root `/Users/jinghancui/Gitproj/Go-manager`):
- JS-parse: `node -e "const fs=require('fs');const h=fs.readFileSync('index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"`
- Backend check: `cp go-manager-backend.gs /tmp/gmb.js && node --check /tmp/gmb.js && echo "backend OK"`

Scratchpad for tests: `/private/tmp/claude-501/-Users-jinghancui/96b57dba-e91a-4bf3-a521-0b65a82da0bf/scratchpad`

---

### Task 1: Pure helpers — owed ids, greedy allocation, source draw, account balance

**Files:**
- Modify: `index.html` — `ownedUnitsFromClaims` (~4129); add `applyStoreCredit`, `drawSources`, `buyerGoSummary`, `myGoSummary`, `joinerGoIds`, `joinerGoCredit`, `accountBalance`, `computeBalanceApply` near the other payment helpers (after `goPaymentSummary`, ~4210).
- Test: `scratchpad/test-credit-helpers.js`

**Interfaces:**
- Produces (consumed by Tasks 2–4):
  - `ownedUnitsFromClaims(claims, siMeta)` → `[{ value:Number, ids:[claimId] }]` (adds `ids`; existing `.value` callers unaffected).
  - `applyStoreCredit(units, oldPaid, balance)` → `{ spent:Number, paidIds:[String], unpaidIds:[String] }` — display-order first-fit: units already covered by `oldPaid` stay Paid; each remaining WHOLE unit that fits the balance budget is covered (skip-too-big, keep checking); returns amount spent + claim-id split. Used by apply (balance>0) and reverse (balance=0 recompute).
  - `drawSources(perGoCredit, amount)` → `[{ go_id, go_name, amount:Number }]` — largest-credit-first, capped, cents-rounded.
  - `myGoSummary(u, goId)` → `{ paid, securedValue, owed, credit, pendingSubmitted }` (admin uses `goPaymentSummary`; buyer uses `buyerGoSummary`).
  - `joinerGoCredit(u)` → `[{ go_id, go_name, credit:Number }]` (credit>0 only, across the joiner's GOs).
  - `accountBalance(u)` → Number (Σ of `joinerGoCredit` credit).
  - `computeBalanceApply(u, goId)` → `{ balance:Number, spent:Number, paidIds:[], unpaidIds:[], sources:[{go_id,go_name,amount}] }` — the shared "what applying balance to goId does" calc, used by the button label and `payWithBalance`.

- [ ] **Step 1: Write the failing test**

Create `scratchpad/test-credit-helpers.js`:
```javascript
const fs = require('fs'), assert = require('assert');
function extractFn(src, name){const s=src.indexOf('function '+name+'(');if(s<0)throw new Error('missing '+name);let d=0;for(let j=src.indexOf('{',s);j<src.length;j++){if(src[j]==='{')d++;else if(src[j]==='}'){d--;if(d===0)return src.slice(s,j+1);}}throw new Error('brace '+name);}
const html = fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');
const F = {};
['ownedUnitsFromClaims','applyStoreCredit','drawSources'].forEach(n => { F[n] = new Function('return ('+extractFn(html,n)+')')(); });

// ownedUnitsFromClaims now carries ids
const siMeta = { S:{price:4,otPrice:32,kind:'member-set',minSecure:8}, V:{price:10,kind:'versioned',minSecure:7} };
const claims = [
  {sub_item_id:'S',member_or_version:'A',set_num:1,assigned_vers:'',claim_status:'secured',claim_id:'a1',qty:1},
  {sub_item_id:'S',member_or_version:'B',set_num:1,assigned_vers:'',claim_status:'secured',claim_id:'a2',qty:1},
  {sub_item_id:'V',member_or_version:'X',set_num:'',claim_status:'secured',claim_id:'v1',qty:2},
];
const units = F.ownedUnitsFromClaims(claims, siMeta);
assert.deepStrictEqual(units.map(u=>u.value).sort(), [4,4,20], 'values');
assert.ok(units.every(u=>Array.isArray(u.ids)), 'each unit has ids');
assert.deepStrictEqual([].concat(...units.map(u=>u.ids)).sort(), ['a1','a2','v1'], 'ids present');

// applyStoreCredit: display-order first-fit, whole units only, skip-too-big-but-continue
const U = [{value:18,ids:['i18']},{value:9,ids:['i9']},{value:10,ids:['i10']}];
assert.deepStrictEqual(F.applyStoreCredit(U, 0, 25), {spent:18,paidIds:['i18'],unpaidIds:['i9','i10']}, '25 -> Album 18 fits; 9/10 dont; balance keeps 7');
assert.deepStrictEqual(F.applyStoreCredit(U, 0, 7),  {spent:0, paidIds:[],       unpaidIds:['i18','i9','i10']}, '7 -> nothing fits, whole balance kept');
assert.deepStrictEqual(F.applyStoreCredit(U, 0, 12), {spent:9, paidIds:['i9'],   unpaidIds:['i18','i10']}, '12 -> skip 18, cover 9, skip 10 (checks all items)');
assert.deepStrictEqual(F.applyStoreCredit(U, 0, 28), {spent:27,paidIds:['i18','i9'],unpaidIds:['i10']}, '28 -> 18 then 9 (27<=28), 10 skipped');
assert.deepStrictEqual(F.applyStoreCredit(U, 18, 9), {spent:9, paidIds:['i18','i9'],unpaidIds:['i10']}, 'oldPaid 18 keeps Album; balance 9 covers PC');
assert.deepStrictEqual(F.applyStoreCredit(U, 18, 0), {spent:0, paidIds:['i18'],   unpaidIds:['i9','i10']}, 'reverse recompute: mark up to remaining paid only');

// drawSources: largest-first, capped per source, cents
const per = [{go_id:'A',go_name:'A',credit:10},{go_id:'C',go_name:'C',credit:15},{go_id:'B',go_name:'B',credit:2}];
assert.deepStrictEqual(F.drawSources(per, 20), [{go_id:'C',go_name:'C',amount:15},{go_id:'A',go_name:'A',amount:5}], 'draw 20 = 15 from C + 5 from A');
assert.deepStrictEqual(F.drawSources(per, 100), [{go_id:'C',go_name:'C',amount:15},{go_id:'A',go_name:'A',amount:10},{go_id:'B',go_name:'B',amount:2}], 'draw all = 27');
console.log('ALL PASS');
```

- [ ] **Step 2: Run — verify it fails**

Run: `node scratchpad/test-credit-helpers.js`
Expected: FAIL — `applyStoreCredit`/`drawSources` missing, and `ownedUnitsFromClaims` units lack `ids`.

- [ ] **Step 3: Add `ids` to `ownedUnitsFromClaims`**

In `index.html`, replace the body of `ownedUnitsFromClaims` (~4129) so every pushed unit carries `ids`:
```javascript
function ownedUnitsFromClaims(claims, siMeta) {
  const units = [];
  const sets = {}; // key -> { meta, ot:[], normal:[] }
  (claims || []).forEach(c => {
    const meta = siMeta[c.sub_item_id]; if (!meta) return;
    if (c.claim_status === 'dropped') return;
    const isSetKind = (meta.kind === 'member' || meta.kind === 'photocard' || meta.kind === 'member-set') && (parseInt(meta.minSecure) >= 0) && c.member_or_version && c.set_num !== '' && c.set_num !== undefined && c.set_num !== null;
    if (isSetKind) {
      if (c.claim_status !== 'secured') return;
      const key = c.sub_item_id + '|' + c.set_num;
      (sets[key] = sets[key] || { meta, ot: [], normal: [] });
      if (c.assigned_vers === 'OT') sets[key].ot.push(c);
      else sets[key].normal.push(c);
    } else {
      const isBatchKind = (meta.kind === 'member' || meta.kind === 'photocard' || meta.kind === 'member-set') && parseInt(meta.minSecure) < 0;
      if (isBatchKind && c.claim_status !== 'secured') return;
      if (c.claim_status === 'pending') return;
      units.push({ value: (parseFloat(meta.price) || 0) * (parseInt(c.qty) || 1), ids: [c.claim_id].filter(Boolean) });
    }
  });
  Object.values(sets).forEach(s => {
    if (s.ot.length) units.push({ value: parseFloat(s.meta.otPrice) || 0, ids: s.ot.map(c => c.claim_id).filter(Boolean) });
    s.normal.forEach(c => units.push({ value: parseFloat(s.meta.price) || 0, ids: [c.claim_id].filter(Boolean) }));
  });
  return units;
}
```
(Note: the normal-slot loop now iterates the claims to capture each `claim_id`, instead of the old id-less `forEach(() => ...)`.)

- [ ] **Step 4: Add the four new helpers**

Insert after `goPaymentSummary` (~4210) in `index.html`:
```javascript
// Store-credit spend over owed units in display order. A unit already covered by prior
// payments (running total <= oldPaid) stays Paid. Otherwise, cover the WHOLE unit only if it
// fits the remaining balance budget; a too-big unit is skipped but we keep checking later
// (cheaper) units. Units are {value, ids:[]}. Returns amount spent + claim_id split.
// Used by apply (balance>0) and by reverse recompute (balance=0 -> mark up to remaining paid).
// KNOWN EDGE (rare, accepted for v1): a stranded partial cash payment (oldPaid that doesn't
// tile to a whole unit) can overlap with a balance-covered unit; admin can reconcile.
function applyStoreCredit(units, oldPaid, balance) {
  const eps = 0.001; let acc = 0, spent = 0; const paidIds = [], unpaidIds = [];
  (units || []).forEach(u => {
    if (acc + u.value <= oldPaid + eps) { acc += u.value; (u.ids || []).forEach(id => paidIds.push(id)); }
    else if (spent + u.value <= balance + eps) { acc += u.value; spent += u.value; (u.ids || []).forEach(id => paidIds.push(id)); }
    else { (u.ids || []).forEach(id => unpaidIds.push(id)); }
  });
  return { spent, paidIds: paidIds.filter(Boolean), unpaidIds: unpaidIds.filter(Boolean) };
}

// Draw `amount` of credit from per-GO surplus, largest-credit-first, capped per source.
// perGoCredit: [{go_id, go_name, credit}]. Returns [{go_id, go_name, amount}] summing to <= amount.
function drawSources(perGoCredit, amount) {
  const eps = 0.001;
  const sorted = (perGoCredit || []).filter(g => g.credit > eps).sort((a, b) => b.credit - a.credit);
  const out = []; let need = amount;
  for (const g of sorted) {
    if (need <= eps) break;
    const take = Math.min(g.credit, need);
    if (take > eps) { out.push({ go_id: g.go_id, go_name: g.go_name, amount: Math.round(take * 100) / 100 }); need -= take; }
  }
  return out;
}

// Buyer-mode per-GO summary (My Orders lazy path) — mirrors the inline getSummary in
// doLookupRender so account-balance math matches what the joiner sees. Shop delegates
// to goPaymentSummary (uses shopOrders, which are loaded).
function buyerGoSummary(u, goId) {
  if (goId === 'shop') return goPaymentSummary(u, goId);
  const siMeta = {}; Object.values(allGOs).forEach(go => (go.subItems || []).forEach(si => { siMeta[si.id] = si; }));
  const claims = (myLookupClaims || []).filter(c => sameUser(c.username, u) && c.go_id === goId);
  const securedValue = ownedUnitsFromClaims(claims, siMeta).reduce((a, un) => a + un.value, 0);
  const mine = paymentProofs.filter(pp => sameUser(pp.username, u) && pp.go_id === goId);
  const paid = mine.filter(pp => pp.status === 'confirmed').reduce((a, pp) => a + (parseFloat(pp.amount) || 0), 0);
  const pendingSubmitted = mine.filter(pp => pp.status === 'pending').reduce((a, pp) => a + (parseFloat(pp.amount) || 0), 0);
  return { paid, securedValue, owed: Math.max(0, securedValue - paid), credit: Math.max(0, paid - securedValue), pendingSubmitted };
}

function myGoSummary(u, goId) { return isAdmin ? goPaymentSummary(u, goId) : buyerGoSummary(u, goId); }

// GO ids (incl. 'shop') the joiner has claims/orders in — mode-aware.
function joinerGoIds(u) {
  const ids = new Set();
  if (isAdmin) {
    Object.values(allGOs).forEach(go => (go.subItems || []).forEach(si => {
      if (si.sets) si.sets.forEach(s => Object.values(s.slots).forEach(sl => { if (sl && sameUser(sl.user, u)) ids.add(go.id); }));
      if (si.claims) si.claims.forEach(c => { if (sameUser(c.user, u)) ids.add(go.id); });
    }));
  } else {
    (myLookupClaims || []).forEach(c => { if (sameUser(c.username, u)) ids.add(c.go_id); });
  }
  if (shopOrders.some(o => sameUser(o.username, u))) ids.add('shop');
  return [...ids];
}

function goDisplayName(goId) { return goId === 'shop' ? 'Shop' : ((allGOs[goId] && allGOs[goId].name) || goId); }

// Per-GO surplus credit across the joiner's GOs (credit>0 only) and the total.
function joinerGoCredit(u) {
  return joinerGoIds(u).map(id => ({ go_id: id, go_name: goDisplayName(id), credit: myGoSummary(u, id).credit }))
    .filter(g => g.credit > 0.001);
}
function accountBalance(u) { return joinerGoCredit(u).reduce((a, g) => a + g.credit, 0); }

// The full "what happens if this joiner applies balance to goId" computation — shared by the
// button label (Task 3 Step 2) and payWithBalance (Task 3 Step 3) so they never disagree.
// balance = surplus from the joiner's OTHER GOs; spent = whole owed items of goId that fit;
// sources = which GOs the spent is drawn from; paid/unpaidIds = target marking.
function computeBalanceApply(u, goId) {
  const s = myGoSummary(u, goId);
  const perGo = joinerGoCredit(u).filter(g => g.go_id !== goId);
  const balance = perGo.reduce((a, g) => a + g.credit, 0);
  const siMeta = {}; Object.values(allGOs).forEach(go => (go.subItems || []).forEach(si => { siMeta[si.id] = si; }));
  const units = isAdmin
    ? paymentOwedUnits(u, goId)
    : ownedUnitsFromClaims((myLookupClaims || []).filter(c => sameUser(c.username, u) && c.go_id === goId), siMeta);
  const { spent, paidIds, unpaidIds } = applyStoreCredit(units, s.paid, balance);
  const sources = drawSources(perGo, spent);
  return { balance, spent, paidIds, unpaidIds, sources };
}
```

- [ ] **Step 5: Run — verify it passes**

Run: `node scratchpad/test-credit-helpers.js` → Expected: `ALL PASS`. Then JS-parse (Global Constraints) → `JS parses OK`.

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "Cross-GO credit: pure helpers (owed ids, allocate, drawSources, account balance)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Backend — applyCredit + reverseCredit

**Files:**
- Modify: `go-manager-backend.gs` — add `applyCredit`, `reverseCredit`; route both in `doPost` (~104, after `updatePayment`).
- Test: `node --check` + live curl (after redeploy).

**Interfaces:**
- Consumes: existing `SHEET_PAYMENTS` cols `[payment_id,username,go_id,go_name,amount,method,transaction_id,proof_url,email,status,created_at,note]`; `SHEET_JOINERS`; `setPaymentByIds(sheet, idCol, paidIds, unpaidIds, now)`.
- Produces:
  - `applyCredit({ username, transaction_id, rows:[{go_id, go_name, amount, note}], target_go_id, paid_claim_ids, unpaid_claim_ids })` → `{ ok, transaction_id }`. Appends each `rows[]` entry as a `method:'credit'`, `status:'confirmed'` payment row sharing `transaction_id`, then marks the target GO's claims via `setPaymentByIds`.
  - `reverseCredit({ transaction_id, paid_claim_ids, unpaid_claim_ids })` → `{ ok }`. Deletes all payment rows with that `transaction_id`, then re-marks the provided claim ids (admin-computed).

- [ ] **Step 1: Add `applyCredit`**

In `go-manager-backend.gs`, after `updatePayment` (before `createListing`), add:
```javascript
function applyCredit(data) {
  bootstrapSheets();
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const lock = LockService.getScriptLock();
  try { lock.waitLock(10000); } catch (e) { return { ok: false, error: 'busy', message: 'Server busy, please retry.' }; }
  try {
    const sheet = ss.getSheetByName(SHEET_PAYMENTS);
    const now = new Date().toISOString();
    (data.rows || []).forEach((r, i) => {
      const id = 'cr_' + Date.now() + '_' + i + '_' + Math.random().toString(36).slice(2, 5);
      sheet.appendRow([id, data.username, r.go_id, r.go_name || '', r.amount, 'credit', data.transaction_id || '', '', '', 'confirmed', now, r.note || '']);
    });
    if (data.paid_claim_ids || data.unpaid_claim_ids) {
      setPaymentByIds(ss.getSheetByName(SHEET_JOINERS), 'claim_id', data.paid_claim_ids || [], data.unpaid_claim_ids || [], now);
    }
    return { ok: true, transaction_id: data.transaction_id };
  } finally { lock.releaseLock(); }
}

function reverseCredit(data) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const lock = LockService.getScriptLock();
  try { lock.waitLock(10000); } catch (e) { return { ok: false, error: 'busy' }; }
  try {
    const sheet = ss.getSheetByName(SHEET_PAYMENTS);
    const rows = sheet.getDataRange().getValues();
    const txCol = rows[0].indexOf('transaction_id');
    // delete bottom-up so row indices stay valid
    for (let i = rows.length - 1; i >= 1; i--) {
      if (String(rows[i][txCol]) === String(data.transaction_id)) sheet.deleteRow(i + 1);
    }
    if (data.paid_claim_ids || data.unpaid_claim_ids) {
      setPaymentByIds(ss.getSheetByName(SHEET_JOINERS), 'claim_id', data.paid_claim_ids || [], data.unpaid_claim_ids || [], new Date().toISOString());
    }
    return { ok: true };
  } finally { lock.releaseLock(); }
}
```

- [ ] **Step 2: Route both in `doPost`**

In `go-manager-backend.gs` `doPost`, after the `updatePayment` line (~104), add:
```javascript
    else if (action === 'applyCredit')       result = applyCredit(body.data);
    else if (action === 'reverseCredit')      result = reverseCredit(body.data);
```

- [ ] **Step 3: Verify backend syntax**

Run: `cp go-manager-backend.gs /tmp/gmb.js && node --check /tmp/gmb.js && echo "backend OK"` → Expected: `backend OK`.

- [ ] **Step 4: Commit**

```bash
git add go-manager-backend.gs
git commit -m "Cross-GO credit backend: applyCredit + reverseCredit (paired rows + claim marking)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: (Post-redeploy, manual) live round-trip** — after the user redeploys, curl `applyCredit` with a test joiner's link + one −source row + one +target row; confirm both land with the shared `transaction_id` and correct signs; curl `reverseCredit` with that link and confirm both rows are gone. (Deferred to the human; note in the report.)

---

### Task 3: Frontend — account balance card, "Use account balance", payWithBalance

**Files:**
- Modify: `index.html` — `doLookupRender` total card (~1824) to add the balance card; `renderMyOrderGoBlock` (~1891) to drop the per-GO Credit line and add the "Use account balance" control; add `payWithBalance` near `submitGoPayment` (~2031); credit-row display in `myPaymentsSection` (~1856).

**Interfaces:**
- Consumes Task 1 (`computeBalanceApply`, `accountBalance`, `drawSources`, `applyStoreCredit`, `ownedUnitsFromClaims`/`paymentOwedUnits`) and Task 2 (`applyCredit`).
- Produces: `payWithBalance(u, goId)` handler; `creditApplyInFlight` guard; the account-balance card + form control + credit-row rendering.

- [ ] **Step 1: Account balance card** — in `doLookupRender`, after the `totalCard` definition (~1827), add:
```javascript
      const balance = accountBalance(u);
      const balanceCard = balance > 0.001 ? `<div class="card" style="margin-bottom:12px;border-color:var(--teal-100);">
        <div style="font-size:15px;font-weight:500;color:var(--teal-700);">👛 Account balance: <span style="font-family:var(--mono);">$${balance.toFixed(2)}</span></div>
        <div style="font-size:12px;color:var(--text3);margin-top:4px;">From overpayments/credit — use it on any GO you owe on below.</div>
      </div>` : '';
```
and change the render line (~1828) to prepend it:
```javascript
      blocksEl.innerHTML = totalCard + balanceCard + goList.map(g => renderMyOrderGoBlock(g, rows.filter(r => r.go_id === g.go_id), u, getSummary(g.go_id))).join('');
```

- [ ] **Step 2: Drop per-GO Credit display, add "Use account balance"** — in `renderMyOrderGoBlock`:

Replace `rightBadge` (~1894) so it never shows per-GO Credit (owed or all-paid only):
```javascript
  const rightBadge = s.owed > 0
    ? `Owed: <strong style="font-family:var(--mono);">$${s.owed.toFixed(2)}</strong>`
    : (s.paid > 0 ? `<span style="color:var(--teal-600);font-weight:500;">All paid ✓</span>` : '');
```
Replace `summaryLine` (~1908) to drop the Credit term:
```javascript
  const summaryLine = `Paid $${s.paid.toFixed(2)} · Owed $${s.owed.toFixed(2)}`
    + (s.pendingSubmitted > 0 ? ` · $${s.pendingSubmitted.toFixed(2)} awaiting confirmation` : '');
```
Replace `creditNote` (~1927) with an account-balance apply control (shown when this GO is owed and the joiner has balance elsewhere):
```javascript
  const ba = computeBalanceApply(u, g.go_id);   // {balance, spent, sources, paidIds, unpaidIds}
  const balanceControl = (s.owed > 0 && ba.spent > 0.001) ? `
        <div style="margin-top:10px;font-size:12px;color:var(--teal-700);background:var(--teal-50);border-radius:var(--radius);padding:8px 10px;">
          👛 You have <strong>$${ba.balance.toFixed(2)}</strong> account balance.
          <button class="btn btn-sm" style="margin-left:6px;" onclick="payWithBalance('${u}','${g.go_id}')">Use $${ba.spent.toFixed(2)} of balance</button>
        </div>` : '';
  const creditNote = '';
```
(The unused `creditNote` is kept as `''` so the return template `${deadlineNote}${form}${creditNote}` is untouched; append `${balanceControl}` — see next.)

Update the block's body return (~1944) to include the control:
```javascript
      ${deadlineNote}${form}${creditNote}${balanceControl}
```

- [ ] **Step 3: `payWithBalance` handler** — add near `submitGoPayment` (~2031):
```javascript
let creditApplyInFlight = false;
async function payWithBalance(u, goId) {
  if (creditApplyInFlight) { toast('One moment…'); return; }
  const ba = computeBalanceApply(u, goId);   // {balance, spent, sources, paidIds, unpaidIds}
  if (ba.spent <= 0.001) { toast('Balance too small for any item on this GO.'); return; }
  const link = 'cr_' + Date.now() + '_' + Math.random().toString(36).slice(2, 6);
  const rows = ba.sources.map(src => ({ go_id: src.go_id, go_name: goDisplayName(src.go_id), amount: -src.amount, note: 'Credit applied to ' + goDisplayName(goId) }));
  rows.push({ go_id: goId, go_name: goDisplayName(goId), amount: ba.spent, note: 'From credit on ' + ba.sources.map(s2 => goDisplayName(s2.go_id)).join(', ') });
  creditApplyInFlight = true;
  try {
    const res = await apiPost('applyCredit', { username: u, transaction_id: link, rows, target_go_id: goId, paid_claim_ids: ba.paidIds, unpaid_claim_ids: ba.unpaidIds });
    if (!res || res.ok === false) { toast('Couldn’t apply balance — try again.'); return; }
    // optimistic local update so the view reflects it before the next sync
    rows.forEach((r, i) => paymentProofs.push({ payment_id: 'cr_' + Date.now() + '_' + i + '_' + Math.random().toString(36).slice(2, 4), username: u, go_id: r.go_id, go_name: r.go_name, amount: r.amount, method: 'credit', transaction_id: link, status: 'confirmed', created_at: new Date().toISOString(), note: r.note }));
    (myLookupClaims || []).forEach(c => { if (ba.paidIds.includes(c.claim_id)) c.payment_status = 'paid'; else if (ba.unpaidIds.includes(c.claim_id)) c.payment_status = 'unpaid'; });
    toast('Applied $' + ba.spent.toFixed(2) + ' from your balance.');
    doLookupRender(u);
  } catch (e) { toast('Couldn’t apply balance — check your connection.'); }
  finally { creditApplyInFlight = false; }
}
```

- [ ] **Step 4: Show credit rows in "Your payments"** — in `myPaymentsSection` (~1856), where each proof row is rendered, credit rows (`pp.method === 'credit'`) should read clearly. Locate the row template and add, for credit rows, a label like `pp.amount < 0 ? 'Credit moved out' : 'Paid with balance'` with the `pp.note`. (Exact template lines are in `myPaymentsSection`; render `method:'credit'` rows with their signed amount and note instead of the normal method/txid line.)

- [ ] **Step 5: JS-parse** → `JS parses OK`.

- [ ] **Step 6: Manual (documented, DOM)** — as a buyer with credit in GO-A and owed in GO-B: the balance card shows the total; GO-B shows "Use $X balance"; clicking applies it → GO-B owed drops, GO-B items flip to Paid up to the amount, the balance card shrinks, and "Your payments" shows the ±credit rows. Left for the human; note in report.

- [ ] **Step 7: Commit**

```bash
git add index.html
git commit -m "Cross-GO credit: account balance card + Use-balance control + payWithBalance

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Admin — reverse a credit application

**Files:**
- Modify: `index.html` — `renderPaymentProofs` (credit rows get a Reverse button); add `reverseCreditApplication(link)` near `deletePaymentProof` (~4282).

**Interfaces:**
- Consumes Task 2 `reverseCredit`; Task 1 `paymentOwedUnits`/`applyStoreCredit`, `goPaymentSummary`.
- Produces: `reverseCreditApplication(link)` — deletes the linked credit rows and re-marks the target GO's claims for the reduced paid total.

- [ ] **Step 1: Reverse handler** — add near `deletePaymentProof` (~4282):
```javascript
function reverseCreditApplication(link) {
  if (!confirm('Reverse this balance application? The credit returns to its source GOs.')) return;
  const linked = paymentProofs.filter(p => p.transaction_id === link && p.method === 'credit');
  const target = linked.find(p => (parseFloat(p.amount) || 0) > 0);   // the +Y target row
  paymentProofs = paymentProofs.filter(p => !(p.transaction_id === link && p.method === 'credit'));
  let paidIds = [], unpaidIds = [];
  if (target) {
    // re-mark the target GO up to its now-reduced confirmed paid (admin has full refs).
    // balance=0 → applyStoreCredit just marks the whole units covered by the remaining paid.
    const s = goPaymentSummary(target.username, target.go_id);
    const alloc = applyStoreCredit(paymentOwedUnits(target.username, target.go_id), s.paid, 0);
    paidIds = alloc.paidIds; unpaidIds = alloc.unpaidIds;
    // reflect locally
    paymentOwedUnits(target.username, target.go_id).forEach(u => {
      const isPaid = u.ids.some(id => paidIds.includes(id));
      setUnitPaid(u, isPaid);
    });
  }
  if (API_URL) apiPost('reverseCredit', { transaction_id: link, paid_claim_ids: paidIds, unpaid_claim_ids: unpaidIds }).catch(()=>{});
  renderPaymentProofs();
  renderDetailContent();
  toast('Balance application reversed.');
}
```

- [ ] **Step 2: Reverse button on credit rows** — in `renderPaymentProofs`, for rows where `p.method === 'credit'` and `p.amount > 0` (the target row of each pair), render a `Reverse` button `onclick="reverseCreditApplication('${p.transaction_id}')"` instead of the normal confirm/reject/delete actions. (Source −rows render read-only with their note.)

- [ ] **Step 3: JS-parse** → `JS parses OK`.

- [ ] **Step 4: Manual (documented)** — after a joiner applies balance, the admin payments list shows the +target credit row with a Reverse button; reversing removes the paired rows, returns the credit to source GOs, and un-marks the target items that the credit had paid. Left for the human; note in report.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "Cross-GO credit: admin reverse a balance application

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Post-implementation
- **Redeploy** the Apps Script Web App (`applyCredit`/`reverseCredit`); user reports "redeployed"; then run Task 2 Step 5 live round-trip.
- **Push** `main` (GitHub Pages) after review; hard-refresh.
- End-to-end manual: buyer overpays GO-A → account balance appears → uses it on GO-B → GO-B owed drops + items Paid + balance shrinks → admin can reverse.
