# Pay-Ahead Credit & Overpayment Marking — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface pay-ahead **credit** — money a buyer paid beyond the value of their currently-secured claims — per buyer per GO, on both the joiner (My orders) and admin (confirm modal) sides, with no backend change.

**Architecture:** Single-file browser app (`index.html`, HTML+CSS+JS). One shared helper `goPaymentSummary(username, goId)` computes `{ paid, securedValue, owed, credit, pendingSubmitted }`, deriving `securedValue` by reusing the existing `paymentOwedUnits` so the joiner and the admin confirm modal always agree. A small batch-consistency fix to `paymentOwedUnits` makes unsecured batch cards count as credit (not owed), matching set-based behavior.

**Tech Stack:** Vanilla JS in one HTML file. Backend is Google Apps Script (unchanged). Hosted on GitHub Pages.

## Global Constraints

- All edits in `/Users/jinghancui/Gitproj/Go-manager/index.html`. No other file changes. No backend change / no redeploy.
- `goPaymentSummary` MUST derive `securedValue` from `paymentOwedUnits(username, goId)` (sum of unit values) so it matches the admin modal's `securedTotal` exactly.
- **Paid = confirmed payments only** (`paymentProofs` with `status === 'confirmed'`). Submitted-but-pending amounts are `pendingSubmitted`, shown separately, never in `paid`.
- `owed = max(0, securedValue − paid)`, `credit = max(0, paid − securedValue)` (mutually exclusive).
- Copy strings, exact: joiner line `Paid $X · Owed $Y · Credit $Z`, pending suffix `· $P awaiting confirmation`; admin row label `Credit (held for later)`; admin over-payment note `$Z will be held as credit for claims secured later.`; txid hint `· same txid on <GO name>`.
- No automated test harness. Verify with a JS-parse check plus, where noted, a small Node logic harness. Full behavioral checks are the user's manual browser step. Load with `open /Users/jinghancui/Gitproj/Go-manager/index.html`.
- Commit after each task.

**JS-parse check (used in every task):**
```bash
node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
```

---

### Task 1: `goPaymentSummary` helper + `paymentOwedUnits` batch-consistency fix

**Files:**
- Modify: `index.html` — `paymentOwedUnits` claims branch (the line `if (sameUser(c.user, username) && c.claim_status !== 'dropped') units.push(...)`); add `goPaymentSummary` immediately after `paymentOwedUnits`'s closing brace.

**Interfaces:**
- Consumes: `paymentOwedUnits(username, goId)` (existing), `paymentProofs` (global), `sameUser`, `isBatch(si)`.
- Produces: `goPaymentSummary(username, goId) -> { paid, securedValue, owed, credit, pendingSubmitted }`.

- [ ] **Step 1: Batch-consistency fix in `paymentOwedUnits`**

Replace the claims-based push line so a batch item's unsecured cards are not counted (set-based already only counts secured sets; FCFS claims-based have no `claim_status` and stay counted):

```javascript
    if (si.claims) si.claims.forEach(c => {
      if (!sameUser(c.user, username) || c.claim_status === 'dropped') return;
      if (isBatch(si) && c.claim_status !== 'secured') return;  // batch: only secured cards are owed/payable
      units.push({ ids: [c.claim_id].filter(Boolean), value: (si.price||0) * (c.qty||1), kind: 'claim', refs: [c] });
    });
```

- [ ] **Step 2: Add `goPaymentSummary`**

Immediately after `paymentOwedUnits`'s closing brace (before `function setUnitPaid`), add:

```javascript
// Per-buyer, per-GO money summary — the single source for both the joiner My-orders
// line and the admin confirm modal, so the two never disagree. securedValue reuses
// paymentOwedUnits (same claims the modal allocates against). paid = CONFIRMED only.
function goPaymentSummary(username, goId) {
  const securedValue = paymentOwedUnits(username, goId).reduce((a, u) => a + u.value, 0);
  const mine = paymentProofs.filter(pp => sameUser(pp.username, username) && pp.go_id === goId);
  const paid = mine.filter(pp => pp.status === 'confirmed').reduce((a, pp) => a + (parseFloat(pp.amount) || 0), 0);
  const pendingSubmitted = mine.filter(pp => pp.status === 'pending').reduce((a, pp) => a + (parseFloat(pp.amount) || 0), 0);
  const owed = Math.max(0, securedValue - paid);
  const credit = Math.max(0, paid - securedValue);
  return { paid, securedValue, owed, credit, pendingSubmitted };
}
```

- [ ] **Step 3: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 4: Verify the summary math in Node**

Write `/private/tmp/claude-501/-Users-jinghancui/96b57dba-e91a-4bf3-a521-0b65a82da0bf/scratchpad/verify-summary.mjs` that reimplements the `goPaymentSummary` arithmetic against a stub `paymentOwedUnits` and a stub `paymentProofs`, and asserts:

```js
// stubs: securedValue=30 (units sum), confirmed payments sum=50, pending=5
// expect: paid=50, owed=0, credit=20, pendingSubmitted=5
// case B: securedValue=30, confirmed=10  -> owed=20, credit=0
// case C: securedValue=0,  confirmed=8   -> owed=0,  credit=8  (paid ahead, nothing secured yet)
```

Print PASS/FAIL per case. Run it; all three must PASS.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "Payment credit: goPaymentSummary helper + batch-consistency fix in paymentOwedUnits"
```

---

### Task 2: Joiner My-orders — per-GO Paid / Owed / Credit

**Files:**
- Modify: `index.html` — the "Pay panels" block in `doLookup` (from `const payEl = document.getElementById('lookup-pay-panels');` through the end of its `if (payEl) { ... }`, immediately before `renderShipPanel(u);`).

**Interfaces:**
- Consumes: `goPaymentSummary` (Task 1), `rows` (local, has `{go_id, go, claim}`), `PAYMENT_METHODS`, `submitGoPayment`, `u` (the looked-up handle).

- [ ] **Step 1: Replace the pay-panels block**

Replace this exact existing block:

```javascript
  const payEl = document.getElementById('lookup-pay-panels');
  if (payEl) {
    const owed = computeOwedByGO(rows);
    const handles = PAYMENT_METHODS.map(p =>
      `<span class="tag">${p.method}${p.note ? ' ' + p.note : ''}: ${p.handle}</span>`
    ).join(' ');
    if (!owed.length) {
      // Show "All paid ✓" only if the buyer has secured claims (all paid).
      // If they only have pending/unsecured claims, nothing is owed yet — show nothing.
      const hasSecured = rows.some(r => r.claim === 'Secured');
      payEl.innerHTML = hasSecured
        ? `<div class="card" style="margin-top:12px;"><div style="font-size:13px;color:var(--teal-600);font-weight:500;">All paid ✓</div></div>`
        : '';
    } else {
      payEl.innerHTML = owed.map(g => `
        <div class="card" style="margin-top:12px;">
          <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:10px;">
            <div style="font-weight:500;font-size:15px;">${g.go}</div>
            <div style="font-size:13px;">Owed: <strong style="font-family:var(--mono);">$${g.owed.toFixed(2)}</strong></div>
          </div>
          <div style="font-size:12px;color:var(--text2);margin-bottom:6px;">Send payment to one of <span style="color:var(--text3);">(no written note — an emoji is fine):</span></div>
          <div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:12px;">${handles}</div>
          <div class="field-row">
            <div class="field" style="margin-bottom:0;"><label>Method</label>
              <select id="pay-method-${g.go_id}">${PAYMENT_METHODS.map(p=>`<option>${p.method}</option>`).join('')}</select>
            </div>
            <div class="field" style="margin-bottom:0;"><label>Amount paid</label>
              <input type="number" id="pay-amount-${g.go_id}" step="0.01" value="${g.owed.toFixed(2)}">
            </div>
          </div>
          <div class="field" style="margin-top:8px;margin-bottom:8px;"><label>Transaction ID</label>
            <input type="text" id="pay-txid-${g.go_id}" placeholder="e.g. PayPal transaction ID">
          </div>
          <button class="btn btn-primary" style="width:100%;justify-content:center;" onclick="submitGoPayment('${g.go_id}','${u}')">I paid</button>
        </div>`).join('');
    }
  }
```

with this version — one card per GO the buyer has a financial position in, showing the Paid/Owed/Credit line, the send-payment form only when `owed > 0`, and a credit note when `credit > 0`:

```javascript
  const payEl = document.getElementById('lookup-pay-panels');
  if (payEl) {
    const handles = PAYMENT_METHODS.map(p =>
      `<span class="tag">${p.method}${p.note ? ' ' + p.note : ''}: ${p.handle}</span>`
    ).join(' ');
    // Every GO this buyer appears in (dedup by go_id), including the Shop pseudo-GO.
    const goList = [...new Map(rows.map(r => [r.go_id, { go_id: r.go_id, go: r.go }])).values()];
    const cards = goList.map(g => {
      const s = goPaymentSummary(u, g.go_id);
      // Nothing financial to show for this GO (only unsecured/unpaid claims) → skip.
      if (s.owed <= 0 && s.credit <= 0 && s.paid <= 0 && s.pendingSubmitted <= 0) return '';
      const summaryLine = `Paid $${s.paid.toFixed(2)} · Owed $${s.owed.toFixed(2)}`
        + (s.credit > 0 ? ` · Credit $${s.credit.toFixed(2)}` : '')
        + (s.pendingSubmitted > 0 ? ` · $${s.pendingSubmitted.toFixed(2)} awaiting confirmation` : '');
      const rightBadge = s.owed > 0
        ? `Owed: <strong style="font-family:var(--mono);">$${s.owed.toFixed(2)}</strong>`
        : s.credit > 0
          ? `<span style="color:var(--teal-600);">Credit: <strong style="font-family:var(--mono);">$${s.credit.toFixed(2)}</strong></span>`
          : `<span style="color:var(--teal-600);font-weight:500;">All paid ✓</span>`;
      const form = s.owed > 0 ? `
          <div style="font-size:12px;color:var(--text2);margin-bottom:6px;">Send payment to one of <span style="color:var(--text3);">(no written note — an emoji is fine):</span></div>
          <div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:12px;">${handles}</div>
          <div class="field-row">
            <div class="field" style="margin-bottom:0;"><label>Method</label>
              <select id="pay-method-${g.go_id}">${PAYMENT_METHODS.map(p=>`<option>${p.method}</option>`).join('')}</select>
            </div>
            <div class="field" style="margin-bottom:0;"><label>Amount paid</label>
              <input type="number" id="pay-amount-${g.go_id}" step="0.01" value="${s.owed.toFixed(2)}">
            </div>
          </div>
          <div class="field" style="margin-top:8px;margin-bottom:8px;"><label>Transaction ID</label>
            <input type="text" id="pay-txid-${g.go_id}" placeholder="e.g. PayPal transaction ID">
          </div>
          <button class="btn btn-primary" style="width:100%;justify-content:center;" onclick="submitGoPayment('${g.go_id}','${u}')">I paid</button>` : '';
      const creditNote = (s.owed <= 0 && s.credit > 0) ? `
          <div style="font-size:12px;color:var(--teal-600);background:var(--teal-50);border-radius:var(--radius);padding:8px 10px;">$${s.credit.toFixed(2)} is held as credit toward claims secured later.</div>` : '';
      return `
        <div class="card" style="margin-top:12px;">
          <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:6px;">
            <div style="font-weight:500;font-size:15px;">${g.go}</div>
            <div style="font-size:13px;">${rightBadge}</div>
          </div>
          <div style="font-size:12px;color:var(--text3);margin-bottom:10px;">${summaryLine}</div>
          ${form}${creditNote}
        </div>`;
    }).join('');
    payEl.innerHTML = cards;
  }
```

- [ ] **Step 2: JS-parse check**

Run the JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 3: Verify in browser**

Open My orders, look up a buyer who has (a) a GO with secured unpaid claims → card shows `Paid $0.00 · Owed $Y`, the send-payment form, and "Owed: $Y"; (b) a GO where they've paid more than their secured total → card shows `Credit $Z`, the teal "held as credit" note, no form, "Credit: $Z" on the right; (c) a fully-paid GO → `All paid ✓`. A GO where they only have unsecured, unpaid claims shows **no** card. If a payment is pending confirmation, the line ends with `· $P awaiting confirmation`.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "Payment credit: joiner My-orders shows per-GO Paid/Owed/Credit"
```

---

### Task 3: Admin confirm modal — Credit row + under/over messaging

**Files:**
- Modify: `index.html` — `confirmPayment`, the `matches` line and the summary/notice block inside its `showModal(...)` template.

**Interfaces:**
- Consumes: existing `securedTotal` and `totalPaid` locals in `confirmPayment` (after Task 1, `securedTotal` already equals `goPaymentSummary.securedValue`).

- [ ] **Step 1: Compute credit/owed and replace the mismatch notice**

In `confirmPayment`, replace this line:

```javascript
  const matches = Math.abs(acc - securedTotal) < eps && Math.abs(totalPaid - securedTotal) < eps;
```

with:

```javascript
  const credit = Math.max(0, totalPaid - securedTotal);
  const under = Math.max(0, securedTotal - totalPaid);
```

- [ ] **Step 2: Add the Credit row to the summary block**

In the `showModal` template, immediately after the "Will mark paid" row (the `<div>…Will mark paid…</div>` line), add a Credit row shown only when `credit > 0`:

```javascript
      <div style="display:flex;justify-content:space-between;border-top:0.5px solid var(--border);padding-top:6px;"><span style="color:var(--text2);">Will mark paid</span><strong style="font-family:var(--mono);color:var(--teal-600);">${paid.length} of ${units.length} items · $${acc.toFixed(2)}</strong></div>
      ${credit > 0 ? `<div style="display:flex;justify-content:space-between;"><span style="color:var(--text2);">Credit (held for later)</span><strong style="font-family:var(--mono);color:var(--teal-600);">$${credit.toFixed(2)}</strong></div>` : ''}
```

- [ ] **Step 3: Replace the single amber notice with under/over branches**

Replace this line:

```javascript
    ${matches ? '' : `<div style="font-size:12px;color:var(--amber-800);background:var(--amber-50);border-radius:var(--radius);padding:8px 10px;margin-bottom:12px;">Amount doesn't fully cover the secured total — only the ${paid.length} item(s) that $${totalPaid.toFixed(2)} adds up to will be marked paid.</div>`}
```

with:

```javascript
    ${under > eps ? `<div style="font-size:12px;color:var(--amber-800);background:var(--amber-50);border-radius:var(--radius);padding:8px 10px;margin-bottom:12px;">Amount doesn't fully cover the secured total — only the ${paid.length} item(s) that $${totalPaid.toFixed(2)} adds up to will be marked paid.</div>`
      : credit > eps ? `<div style="font-size:12px;color:var(--teal-600);background:var(--teal-50);border-radius:var(--radius);padding:8px 10px;margin-bottom:12px;">$${credit.toFixed(2)} will be held as credit for claims secured later.</div>` : ''}
```

- [ ] **Step 4: JS-parse check**

Run the JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 5: Verify in browser**

Admin → Payments → Confirm on a pending proof. Confirm the modal shows a **Credit (held for later): $Z** row when the buyer's total paid exceeds their secured total, with a teal "$Z will be held as credit…" note (not the amber warning). An underpayment still shows the amber warning; an exact match shows no note.

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "Payment credit: admin confirm modal shows Credit row + under/over messaging"
```

---

### Task 4: Shared-transaction-id hint in the admin payment list

**Files:**
- Modify: `index.html` — `renderPaymentProofs`, the pending-proof row map.

**Interfaces:**
- Consumes: `paymentProofs` (global).

- [ ] **Step 1: Add the txid hint to the transaction cell**

In `renderPaymentProofs`, replace the transaction-id cell:

```javascript
      <td style="font-size:11px;color:var(--text3);font-family:var(--mono);">${p.transaction_id||'—'}</td>
```

with a version that appends a hint when the same non-empty `transaction_id` appears on another payment record (different `payment_id`), naming the other GO(s):

```javascript
      <td style="font-size:11px;color:var(--text3);font-family:var(--mono);">${p.transaction_id||'—'}${(() => {
        if (!p.transaction_id) return '';
        const others = paymentProofs.filter(o => o.payment_id !== p.payment_id && o.transaction_id && o.transaction_id === p.transaction_id);
        const names = [...new Set(others.map(o => o.go_name).filter(Boolean))];
        return names.length ? `<span style="color:var(--amber-800);"> · same txid on ${names.join(', ')}</span>` : '';
      })()}</td>
```

- [ ] **Step 2: JS-parse check**

Run the JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 3: Verify in browser**

With two pending payments sharing one transaction id across different GOs, confirm each row's Transaction cell shows "· same txid on <other GO name>". A unique txid shows no hint.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "Payment credit: flag shared transaction ids across payment records"
```

---

## Self-Review

**Spec coverage:**
- Derived credit, no storage, no backend → Task 1 (`goPaymentSummary`), Global Constraints ✓
- Single shared helper feeding both sides; securedValue via `paymentOwedUnits` → Task 1 ✓
- Batch-consistency fix so allocation matches securedValue → Task 1 Step 1 ✓
- Joiner "Paid · Owed · Credit" + awaiting + credit note → Task 2 ✓
- Admin Credit row + under/over messaging split → Task 3 ✓
- Shared-txid hint → Task 4 ✓
- Per-GO scope only; no apply button / auto-apply → nothing implements cross-GO or apply logic ✓

**Placeholder scan:** No TBD/TODO — every code step shows exact code.

**Type/name consistency:** `goPaymentSummary(username, goId)` returns `{paid, securedValue, owed, credit, pendingSubmitted}`, produced in Task 1 and consumed in Task 2 with those exact field names. `paymentOwedUnits` signature unchanged; only its claims-branch filter changes (Task 1). Task 3 uses `credit`/`under`/`securedTotal`/`totalPaid`/`eps`/`acc`/`paid`/`units` — all locals already in `confirmPayment` except `credit`/`under` which Task 3 Step 1 defines. Copy strings match the spec's Global Constraints verbatim.
