# Payment Function Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let buyers see what they owe per group order inside My Orders, pay via the manager's PayPal/Venmo/Zelle/Wise handles, and log the payment; the manager confirms and the buyer's claims in that GO flip to Paid.

**Architecture:** All changes are in the single-file `index.html`. A new pure helper computes the owed amount per GO from the existing lookup rows. A per-GO "Pay panel" renders in the My Orders result. Submitting a payment sends the real `go_id` (the current bug) so the already-implemented backend confirm path can mark claims Paid. No backend (`go-manager-backend.gs`) changes; no Apps Script redeploy required.

**Tech Stack:** Vanilla HTML/CSS/JS (single file), Google Apps Script + Sheets backend (unchanged), GitHub Pages hosting.

**Spec:** `docs/superpowers/specs/2026-06-21-payment-function-design.md`

---

## Verification approach (read first)

This project has **no automated test framework** and is a deliberately single
self-contained `index.html`. Established verification (used for every change in
this codebase) is:

1. **Syntax check** — extract inline JS and run `node --check`:
   ```bash
   python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
   ```
2. **Pure-logic check** — for the owed-amount helper, a throwaway Node assertion
   script (Task 2) validates the logic before it touches the DOM.
3. **Manual browser check** — after deploy, hard-refresh the live site and verify
   the flow by hand (steps given per task).

Do not add pytest/jest or split the file — the single-file architecture is a
constraint.

---

## File structure

- **Modify only:** `/Users/jinghancui/Gitproj/Go-manager/index.html`
  - Add `PAYMENT_METHODS` constant (near other top-level consts, ~line 429).
  - Add `go_id` to lookup rows in `doLookup` (~line 988).
  - Add pure helper `computeOwedByGO(rows)` (near `doLookup`).
  - Add `<div id="lookup-pay-panels">` to the `lookup-result` block (~line 165).
  - Render Pay panels + add `submitGoPayment(goId)` handler.
  - Refresh My Orders after `confirmPayment` (~line 2029).
- **No change:** `go-manager-backend.gs` (its `submitPayment` / `updatePayment`
  already handle storage and confirm→paid).

---

## Task 1: Add the PAYMENT_METHODS constant

**Files:**
- Modify: `index.html` (near the other top-level constants, e.g. just after
  `const FULFILLMENT = [...]`)

- [ ] **Step 1: Add the constant**

Find the line:
```javascript
const FULFILLMENT = ['Pending','Ordered','On the way','Ready','Dispatched'];
```
Add immediately after it:
```javascript
// Single source of truth for the manager's payment handles (mirrors the Rules page).
const PAYMENT_METHODS = [
  { method: 'PayPal', handle: '@jinghanc',          note: 'F&F (no note)' },
  { method: 'Venmo',  handle: '@Jinghan-Cui',       note: '' },
  { method: 'Zelle',  handle: 'jhcui1818@gmail.com', note: '' },
  { method: 'Wise',   handle: '@jinghanc3',         note: '' },
];
```

- [ ] **Step 2: Syntax check**

Run:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
```
Expected: `JS OK`

- [ ] **Step 3: Commit**

```bash
git add index.html
git commit -m "Add PAYMENT_METHODS constant"
```

---

## Task 2: Add and validate the pure owed-amount helper

**Files:**
- Modify: `index.html` (add `computeOwedByGO` just above `function doLookup()`)

- [ ] **Step 1: Write a throwaway test for the pure logic**

Create `/tmp/owed.test.mjs` with the function body inlined plus assertions:
```javascript
// Mirror of computeOwedByGO for pre-wiring validation.
function computeOwedByGO(rows) {
  const byGo = {};
  rows.forEach(r => {
    if (r.payment === 'paid') return;
    const key = r.go_id || r.go;
    if (!byGo[key]) byGo[key] = { go_id: r.go_id, go: r.go, owed: 0 };
    byGo[key].owed += (r.price || 0) * (r.qty || 0);
  });
  return Object.values(byGo).filter(g => g.owed > 0);
}

const rows = [
  { go_id:'g1', go:'A', price:10, qty:1, payment:'unpaid' },
  { go_id:'g1', go:'A', price:10, qty:2, payment:'paid'   },
  { go_id:'g1', go:'A', price:5,  qty:1, payment:'unpaid' },
  { go_id:'g2', go:'B', price:8,  qty:1, payment:'unpaid' },
  { go_id:'g3', go:'C', price:0,  qty:1, payment:'unpaid' },
];
const out = computeOwedByGO(rows);
const g1 = out.find(g => g.go_id==='g1');
const g2 = out.find(g => g.go_id==='g2');
const g3 = out.find(g => g.go_id==='g3');
if (!g1 || g1.owed !== 15) throw new Error('g1 owed should be 15, got ' + (g1&&g1.owed));
if (!g2 || g2.owed !== 8)  throw new Error('g2 owed should be 8, got ' + (g2&&g2.owed));
if (g3) throw new Error('g3 (owed 0) should be excluded');
console.log('owed-calc OK');
```

- [ ] **Step 2: Run it to confirm the logic**

Run: `node /tmp/owed.test.mjs`
Expected: `owed-calc OK`

- [ ] **Step 3: Add the same function to index.html**

Immediately above `function doLookup() {`, add:
```javascript
// Sum a looked-up user's UNPAID claim rows into an owed total per GO.
// rows: [{ go_id, go, price, qty, payment, ... }] (from doLookup).
function computeOwedByGO(rows) {
  const byGo = {};
  rows.forEach(r => {
    if (r.payment === 'paid') return;
    const key = r.go_id || r.go;
    if (!byGo[key]) byGo[key] = { go_id: r.go_id, go: r.go, owed: 0 };
    byGo[key].owed += (r.price || 0) * (r.qty || 0);
  });
  return Object.values(byGo).filter(g => g.owed > 0);
}
```

- [ ] **Step 4: Syntax check**

Run:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
```
Expected: `JS OK`

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "Add computeOwedByGO helper for payment owed totals"
```

---

## Task 3: Carry go_id on lookup rows

**Files:**
- Modify: `index.html` — the three `rows.push({ ... })` calls inside `doLookup`
  (set-based OT row, set-based per-member row, claims-based row).

**Context:** Lookup rows currently start with `go:go.name` but no `go_id`. The Pay
panel needs the real `go_id` to submit and to group reliably. Add `go_id:go.id` to
each pushed row object.

- [ ] **Step 1: Add go_id to the OT row**

Find:
```javascript
            rows.push({ go:go.name, item:si.name, detail:'OT'+membersToCheck.length+' full set', qty:1, price:si.otPrice||0, claim:set.status==='secured'?'Secured':'Pending', payment:s0.payment, fulfillment:s0.fulfillment });
```
Replace with (add `go_id:go.id,` right after `{`):
```javascript
            rows.push({ go_id:go.id, go:go.name, item:si.name, detail:'OT'+membersToCheck.length+' full set', qty:1, price:si.otPrice||0, claim:set.status==='secured'?'Secured':'Pending', payment:s0.payment, fulfillment:s0.fulfillment });
```

- [ ] **Step 2: Add go_id to the per-member set row**

Find:
```javascript
              rows.push({ go:go.name, item:si.name, detail:member, qty:1, price:si.price||0, claim:set.status==='secured'?'Secured':'Pending', payment:slot.payment, fulfillment:slot.fulfillment });
```
Replace with:
```javascript
              rows.push({ go_id:go.id, go:go.name, item:si.name, detail:member, qty:1, price:si.price||0, claim:set.status==='secured'?'Secured':'Pending', payment:slot.payment, fulfillment:slot.fulfillment });
```

- [ ] **Step 3: Add go_id to the claims-based row**

Find:
```javascript
            rows.push({ go:go.name, item:si.name, detail, qty:c.qty, price:si.price||0, claim:'Secured', payment:c.payment, fulfillment:c.fulfillment });
```
Replace with:
```javascript
            rows.push({ go_id:go.id, go:go.name, item:si.name, detail, qty:c.qty, price:si.price||0, claim:'Secured', payment:c.payment, fulfillment:c.fulfillment });
```

- [ ] **Step 4: Syntax check**

Run:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
```
Expected: `JS OK`

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "Carry go_id on My Orders lookup rows"
```

---

## Task 4: Add the Pay-panels container to the My Orders result

**Files:**
- Modify: `index.html` — inside `#lookup-result`, after the `</div>` that closes the
  `.card` holding the table (~line 165).

- [ ] **Step 1: Add the container**

Find:
```html
      <div class="table-wrap">
        <table>
          <thead><tr><th>GO</th><th>Item</th><th>Version/Member</th><th>Qty</th><th>Price</th><th>Claim</th><th>Payment</th><th>Fulfillment</th></tr></thead>
          <tbody id="lookup-tbody"></tbody>
        </table>
      </div>
    </div>
  </div>
</div>
```
Replace the trailing `</div>\n  </div>\n</div>` so a panels container sits after the
card but inside `#lookup-result`:
```html
      <div class="table-wrap">
        <table>
          <thead><tr><th>GO</th><th>Item</th><th>Version/Member</th><th>Qty</th><th>Price</th><th>Claim</th><th>Payment</th><th>Fulfillment</th></tr></thead>
          <tbody id="lookup-tbody"></tbody>
        </table>
      </div>
    </div>
    <div id="lookup-pay-panels"></div>
  </div>
</div>
```

- [ ] **Step 2: Syntax check (HTML well-formedness via the JS extractor still passing)**

Run:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
```
Expected: `JS OK`

- [ ] **Step 3: Commit**

```bash
git add index.html
git commit -m "Add Pay-panels container to My Orders result"
```

---

## Task 5: Render the Pay panels in doLookup

**Files:**
- Modify: `index.html` — end of `doLookup`, after the tbody is populated and totals
  computed (just before the function's closing `}`).

**Context:** `doLookup` builds `rows`, fills `lookup-tbody`, and computes
`grandTotal`/`paidTotal`. After that, render one Pay panel per GO with an unpaid
balance into `#lookup-pay-panels`, or a "Paid ✓" line if nothing is owed.

- [ ] **Step 1: Add the render block**

At the end of `doLookup`, immediately before the final `}` of the function, add:
```javascript
  // ── Pay panels (one per GO with an unpaid balance) ──
  const payEl = document.getElementById('lookup-pay-panels');
  if (payEl) {
    const owed = computeOwedByGO(rows);
    const handles = PAYMENT_METHODS.map(p =>
      `<span class="tag">${p.method}${p.note ? ' ' + p.note : ''}: ${p.handle}</span>`
    ).join(' ');
    if (!owed.length) {
      payEl.innerHTML = rows.length
        ? `<div class="card" style="margin-top:12px;"><div style="font-size:13px;color:var(--teal-600);font-weight:500;">All paid ✓</div></div>`
        : '';
    } else {
      payEl.innerHTML = owed.map(g => `
        <div class="card" style="margin-top:12px;">
          <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:10px;">
            <div style="font-weight:500;font-size:15px;">${g.go}</div>
            <div style="font-size:13px;">Owed: <strong style="font-family:var(--mono);">$${g.owed.toFixed(2)}</strong></div>
          </div>
          <div style="font-size:12px;color:var(--text2);margin-bottom:6px;">Send payment to one of:</div>
          <div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:12px;">${handles}</div>
          <div class="field-row">
            <div class="field" style="margin-bottom:0;"><label>Method</label>
              <select id="pay-method-${g.go_id}">${PAYMENT_METHODS.map(p=>`<option>${p.method}</option>`).join('')}</select>
            </div>
            <div class="field" style="margin-bottom:0;"><label>Amount paid</label>
              <input type="number" id="pay-amount-${g.go_id}" step="0.01" value="${g.owed.toFixed(2)}">
            </div>
          </div>
          <div class="field" style="margin-top:8px;margin-bottom:8px;"><label>Transaction ID / note</label>
            <input type="text" id="pay-txid-${g.go_id}" placeholder="e.g. PayPal txn ID or a note">
          </div>
          <button class="btn btn-primary" style="width:100%;justify-content:center;" onclick="submitGoPayment('${g.go_id}')">I paid</button>
        </div>`).join('');
    }
  }
```

- [ ] **Step 2: Syntax check**

Run:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
```
Expected: `JS OK`

- [ ] **Step 3: Commit**

```bash
git add index.html
git commit -m "Render per-GO Pay panels in My Orders"
```

---

## Task 6: Add the submitGoPayment handler

**Files:**
- Modify: `index.html` — add a new function near `doLookup` (e.g. right after it).

**Context:** Reads the looked-up username (from `#lookup-input`), the per-GO method/
amount/txid fields, and submits a payment record tagged with the real `go_id`. Uses
the existing `addPaymentProof` (local admin list) and `apiPost('submitPayment', ...)`
(backend). The GO name comes from `allGOs[goId].name`.

- [ ] **Step 1: Add the handler**

After the closing `}` of `doLookup`, add:
```javascript
function submitGoPayment(goId) {
  const rawUser = (document.getElementById('lookup-input')||{}).value || '';
  const username = rawUser.trim();
  if (!username) { toast('Look up your username first.'); return; }
  const u = username.startsWith('@') ? username : '@' + username;
  const go = allGOs[goId];
  const amount = parseFloat((document.getElementById('pay-amount-'+goId)||{}).value) || 0;
  const method = (document.getElementById('pay-method-'+goId)||{}).value || '';
  const txid = (document.getElementById('pay-txid-'+goId)||{}).value || '';
  if (amount <= 0) { toast('Enter the amount you paid.'); return; }
  const proof = {
    payment_id: 'pay_' + Date.now(),
    username: u,
    go_name: go ? go.name : '',
    go_id: goId,
    amount,
    method,
    transaction_id: txid,
    proof_url: '',
    status: 'pending',
    created_at: new Date().toISOString()
  };
  addPaymentProof(proof);
  if (API_URL) apiPost('submitPayment', proof).catch(()=>{});
  toast('Payment submitted — the manager will confirm it.');
  // Disable the button to prevent double-submit until next lookup refresh
  const btn = document.querySelector(`#lookup-pay-panels button[onclick="submitGoPayment('${goId}')"]`);
  if (btn) { btn.disabled = true; btn.textContent = 'Submitted ✓'; }
}
```

- [ ] **Step 2: Syntax check**

Run:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
```
Expected: `JS OK`

- [ ] **Step 3: Commit**

```bash
git add index.html
git commit -m "Add submitGoPayment handler (sends real go_id)"
```

---

## Task 7: Refresh My Orders Paid state after admin confirm

**Files:**
- Modify: `index.html` — `confirmPayment` (~line 2029).

**Context:** `confirmPayment` already calls `renderPaymentProofs()` and
`renderDetailContent()` and posts `updatePayment(status:'confirmed', username,
go_id)`. The backend flips claims to paid in Sheets, but the local in-memory claim
objects are not updated, so the buyer's My Orders still shows Unpaid until a sync.
Mark the matching local claims paid so the UI is immediately consistent.

- [ ] **Step 1: Read confirmPayment to find its body**

Run: `grep -n "function confirmPayment" index.html` and read the function. It sets
`p.status='confirmed'` and posts updatePayment.

- [ ] **Step 2: Mark local claims paid inside confirmPayment**

Inside `confirmPayment`, after the `apiPost('updatePayment', ...)` line and before
`renderPaymentProofs()`, add:
```javascript
  // Reflect paid status locally so My Orders updates without waiting for a sync.
  const goLocal = p.go_id && allGOs[p.go_id];
  if (goLocal) {
    goLocal.subItems.forEach(si => {
      if (si.sets) si.sets.forEach(set => {
        (si.members||[]).forEach(m => { const s = set.slots[m]; if (s && s.user === p.username) s.payment = 'paid'; });
      });
      if (si.claims) si.claims.forEach(c => { if (c.user === p.username) c.payment = 'paid'; });
    });
  }
```

- [ ] **Step 3: Syntax check**

Run:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
```
Expected: `JS OK`

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "Mark local claims paid on confirm so My Orders updates immediately"
```

---

## Task 8: Deploy and manual end-to-end verification

**Files:** none (deploy + manual check).

- [ ] **Step 1: Push**

```bash
git push
```

- [ ] **Step 2: Wait for the live deploy**

Run:
```bash
for i in $(seq 1 30); do n=$(curl -s "https://jhcui18.github.io/go-manager/index.html?cb=$(date +%s%N)" | grep -c "function submitGoPayment"); if [ "$n" -gt 0 ]; then echo "LIVE after ~$((i*12))s"; break; fi; sleep 12; done
```
Expected: `LIVE after ~Ns`

- [ ] **Step 3: Manual browser check (buyer)**

On the live site, hard-refresh (`Cmd+Shift+R`):
1. Go to **My orders**, look up a username that has unpaid claims with a price set.
2. Confirm a **Pay panel** appears per GO with an unpaid balance, showing the
   correct **Owed** total, the four handles, and the form.
3. Submit "I paid" with a method + amount + note. Confirm the toast and the button
   flips to "Submitted ✓".

- [ ] **Step 4: Manual browser check (admin)**

1. Enter admin, open the **Pending payment proofs** table; confirm the new record
   shows the right username, GO, amount, method, txn ID.
2. Click **Confirm**. Verify the GO detail shows that buyer's claims as **Paid**.
3. Back in **My orders**, look up the same username and confirm the panel now shows
   **All paid ✓** (no panel) and the Payment column reads Paid.

- [ ] **Step 5: Final commit (if any verification fixes were needed)**

Only if Step 3/4 surfaced a fix:
```bash
git add index.html && git commit -m "Fix payment flow issue found in manual verification" && git push
```

---

## Notes / deferred (from spec)

- Shipping payment phase — out of scope.
- Online card checkout — out of scope (needs a separate secure backend).
- Screenshot upload — out of scope.
- Partial-payment accounting — not enforced; confirming marks all of that buyer's
  claims in the GO paid regardless of amount. Admin uses judgment at confirm time.
- The dead standalone `#page-payment` block is already unreachable (no nav tab); the
  spec treats it as retired. Leaving its markup in place is fine; an optional later
  cleanup can remove `#page-payment`, `_submitPaymentForm`, and `renderPaymentGoSelect`.
