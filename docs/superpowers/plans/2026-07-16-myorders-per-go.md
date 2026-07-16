# My-orders Grouped Per GO — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the buyer "My orders" lookup so claims are grouped into per-GO blocks, each showing that GO's claims followed by that GO's payment section.

**Architecture:** Single-file browser app (`index.html`). Replace the flat all-claims table + separate pay panels with a `#lookup-go-blocks` container. A new `renderMyOrderGoBlock(g, goRows, u)` builds one collapsible card (claims table + payment section) per GO, reusing `goPaymentSummary` and the existing send-payment markup/handlers. `doLookup` groups its `rows` by `go_id` and renders the blocks (newest GO first, Shop last).

**Tech Stack:** Vanilla JS in one HTML file. Backend (Apps Script) unchanged.

## Global Constraints

- All edits in `/Users/jinghancui/Gitproj/Go-manager/index.html`. No backend change, no redeploy.
- Reuse `goPaymentSummary(u, go_id)` and the EXACT existing send-payment field ids (`pay-method-${go_id}`, `pay-amount-${go_id}`, `pay-txid-${go_id}`) and handler `submitGoPayment('${go_id}','${u}')` — payment submission must be unchanged.
- Per-GO blocks only; **no cross-GO grand total**. `#result-count` keeps its current meaning (count of non-"Not fulfilled" claims across all GOs).
- Blocks collapsible, **default expanded** (missing state key = open). Shop pseudo-GO (`go_id: 'shop'`) is its own block, placed last. Other GOs newest-first via `goCreatedTs`.
- Claims table columns: *Item · Version/Member · Qty · Price · Claim · Payment · Fulfillment* (no GO column). Badges unchanged (`Secured`/`Pending`/`Not fulfilled`; `Paid`/`Unpaid`; `fulfillBadge`).
- `#lookup-ship-panel` + `renderShipPanel(u)` unchanged (cross-GO shipping stays).
- No automated test harness. Verify with the JS-parse check plus manual browser check. JS-parse:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after the task.

---

### Task 1: Per-GO blocks in My orders

**Files:**
- Modify: `index.html` — the `#lookup-result` HTML (the `.table-wrap` table + `#lookup-pay-panels`); the tail of `doLookup` (from `const activeRows = ...` through `payEl.innerHTML = cards;`); add `renderMyOrderGoBlock` + `myOrderGoOpen`/`toggleMyOrderGo` near `doLookup`.

**Interfaces:**
- Consumes: `goPaymentSummary`, `PAYMENT_METHODS`, `fulfillBadge`, `goCreatedTs`, `submitGoPayment`, `renderShipPanel`, the `rows` array built earlier in `doLookup` (`{ go_id, go, item, detail, qty, price, claim, payment, fulfillment }`).
- Produces: `renderMyOrderGoBlock(g, goRows, u)` → block HTML string; `toggleMyOrderGo(goId)`.

- [ ] **Step 1: Swap the flat table for a blocks container in the result HTML**

Replace this block (inside `#lookup-result`):

```html
        <button class="btn btn-ghost btn-sm" onclick="resetLookup()">← Back</button>
      </div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>GO</th><th>Item</th><th>Version/Member</th><th>Qty</th><th>Price</th><th>Claim</th><th>Payment</th><th>Fulfillment</th></tr></thead>
          <tbody id="lookup-tbody"></tbody>
        </table>
      </div>
    </div>
    <div id="lookup-pay-panels"></div>
    <div id="lookup-ship-panel"></div>
```

with (the header card now closes right after the buttons; the flat table and pay-panels div are gone):

```html
        <button class="btn btn-ghost btn-sm" onclick="resetLookup()">← Back</button>
      </div>
    </div>
    <div id="lookup-go-blocks"></div>
    <div id="lookup-ship-panel"></div>
```

- [ ] **Step 2: Replace the `doLookup` render tail with per-GO block rendering**

In `doLookup`, replace the entire span from `const activeRows = rows.filter(r => r.claim !== 'Not fulfilled');` through the pay-panels block ending at `payEl.innerHTML = cards;` and its closing `}` — i.e. this current code:

```javascript
  const activeRows = rows.filter(r => r.claim !== 'Not fulfilled');
  document.getElementById('result-count').textContent = activeRows.length + ' active claim' + (activeRows.length!==1?'s':'');
  const tbody = document.getElementById('lookup-tbody');
  const grandTotal = activeRows.reduce((a, r) => a + (r.price * r.qty), 0);
  const paidTotal = activeRows.filter(r => r.payment === 'paid').reduce((a, r) => a + (r.price * r.qty), 0);
  const unpaidTotal = grandTotal - paidTotal;
  tbody.innerHTML = rows.length ? rows.map(r => `<tr>
    <td style="font-weight:500;">${r.go}</td>
    <td>${r.item}</td>
    <td style="color:var(--text2);">${r.detail}</td>
    <td>${r.qty}</td>
    <td style="font-family:var(--mono);font-size:12px;">${r.price > 0 ? '$' + (r.price * r.qty).toFixed(2) : '—'}</td>
    <td><span class="badge ${r.claim==='Secured'?'badge-secured':r.claim==='Not fulfilled'?'badge-dropped':'badge-pending'}">${r.claim}</span></td>
    <td><span class="badge ${r.payment==='paid'?'badge-paid':'badge-unpaid'}">${r.payment==='paid'?'Paid':'Unpaid'}</span></td>
    <td><span class="badge ${fulfillBadge(r.fulfillment)}">${r.fulfillment}</span></td>
  </tr>`).join('')
  + (grandTotal > 0 ? `
  <tr style="border-top:1.5px solid var(--border);">
    <td colspan="8" style="padding:12px 8px;">
      <div style="display:flex;gap:20px;font-size:13px;">
        <div><span style="color:var(--text2);">Total</span> <strong style="font-family:var(--mono);">$${grandTotal.toFixed(2)}</strong></div>
        <div><span style="color:var(--teal-600);">Paid</span> <strong style="font-family:var(--mono);color:var(--teal-600);">$${paidTotal.toFixed(2)}</strong></div>
        <div><span style="color:var(--red-400);">Unpaid</span> <strong style="font-family:var(--mono);color:var(--red-400);">$${unpaidTotal.toFixed(2)}</strong></div>
        <div style="font-size:11px;color:var(--text3);align-self:center;">excl. shipping</div>
      </div>
    </td>
  </tr>` : '')
  : '<tr><td colspan="8" style="text-align:center;color:var(--text3);padding:20px;">No claims found for ' + u + '.</td></tr>';
  document.getElementById('lookup-form').style.display = 'none';
  document.getElementById('lookup-result').style.display = 'block';
  // ── Pay panels (one per GO with an unpaid balance) ──
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

with this (keeps `#result-count` and form show/hide; renders per-GO blocks; no flat table, no grand total):

```javascript
  const activeRows = rows.filter(r => r.claim !== 'Not fulfilled');
  document.getElementById('result-count').textContent = activeRows.length + ' active claim' + (activeRows.length!==1?'s':'');
  document.getElementById('lookup-form').style.display = 'none';
  document.getElementById('lookup-result').style.display = 'block';
  // One block per GO: that GO's claims + its payment section. Newest GO first, Shop last.
  const blocksEl = document.getElementById('lookup-go-blocks');
  if (blocksEl) {
    if (!rows.length) {
      blocksEl.innerHTML = `<div class="card"><div style="text-align:center;color:var(--text3);padding:20px;">No claims found for ${u}.</div></div>`;
    } else {
      const goList = [...new Map(rows.map(r => [r.go_id, { go_id: r.go_id, go: r.go }])).values()];
      goList.sort((a, b) => {
        if (a.go_id === 'shop') return 1;
        if (b.go_id === 'shop') return -1;
        return goCreatedTs({ id: b.go_id }) - goCreatedTs({ id: a.go_id });
      });
      blocksEl.innerHTML = goList.map(g => renderMyOrderGoBlock(g, rows.filter(r => r.go_id === g.go_id), u)).join('');
    }
  }
```

(The `renderShipPanel(u);` line immediately after this block stays unchanged.)

- [ ] **Step 3: Add the block renderer + collapse state/handler**

Immediately after `doLookup`'s closing brace, add:

```javascript
let myOrderGoOpen = {};  // go_id -> bool; default OPEN (a missing key renders expanded)
function toggleMyOrderGo(gid) {
  myOrderGoOpen[gid] = myOrderGoOpen[gid] === false ? true : false;
  const isOpen = myOrderGoOpen[gid] !== false;
  const body = document.getElementById('myo-body-' + gid);
  const chev = document.getElementById('myo-chev-' + gid);
  if (body) body.style.display = isOpen ? 'block' : 'none';
  if (chev) chev.textContent = isOpen ? '▾' : '▸';
}

// One collapsible card for a GO: claims table + payment section (Paid/Owed/Credit + form).
function renderMyOrderGoBlock(g, goRows, u) {
  const s = goPaymentSummary(u, g.go_id);
  const open = myOrderGoOpen[g.go_id] !== false;
  const rightBadge = s.owed > 0
    ? `Owed: <strong style="font-family:var(--mono);">$${s.owed.toFixed(2)}</strong>`
    : s.credit > 0
      ? `<span style="color:var(--teal-600);">Credit: <strong style="font-family:var(--mono);">$${s.credit.toFixed(2)}</strong></span>`
      : (s.paid > 0 ? `<span style="color:var(--teal-600);font-weight:500;">All paid ✓</span>` : '');
  const claimRows = goRows.map(r => `<tr>
    <td>${r.item}</td>
    <td style="color:var(--text2);">${r.detail}</td>
    <td>${r.qty}</td>
    <td style="font-family:var(--mono);font-size:12px;">${r.price > 0 ? '$' + (r.price * r.qty).toFixed(2) : '—'}</td>
    <td><span class="badge ${r.claim==='Secured'?'badge-secured':r.claim==='Not fulfilled'?'badge-dropped':'badge-pending'}">${r.claim}</span></td>
    <td><span class="badge ${r.payment==='paid'?'badge-paid':'badge-unpaid'}">${r.payment==='paid'?'Paid':'Unpaid'}</span></td>
    <td><span class="badge ${fulfillBadge(r.fulfillment)}">${r.fulfillment}</span></td>
  </tr>`).join('');
  const summaryLine = `Paid $${s.paid.toFixed(2)} · Owed $${s.owed.toFixed(2)}`
    + (s.credit > 0 ? ` · Credit $${s.credit.toFixed(2)}` : '')
    + (s.pendingSubmitted > 0 ? ` · $${s.pendingSubmitted.toFixed(2)} awaiting confirmation` : '');
  const handles = PAYMENT_METHODS.map(p => `<span class="tag">${p.method}${p.note ? ' ' + p.note : ''}: ${p.handle}</span>`).join(' ');
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
  return `<div class="card" style="margin-bottom:12px;">
    <div style="display:flex;align-items:center;gap:8px;cursor:pointer;user-select:none;" onclick="toggleMyOrderGo('${g.go_id}')">
      <span id="myo-chev-${g.go_id}" style="width:12px;color:var(--text3);">${open ? '▾' : '▸'}</span>
      <div style="font-weight:500;font-size:15px;flex:1;">${g.go}</div>
      <div style="font-size:13px;">${rightBadge}</div>
    </div>
    <div id="myo-body-${g.go_id}" style="display:${open ? 'block' : 'none'};margin-top:12px;">
      <div class="table-wrap"><table>
        <thead><tr><th>Item</th><th>Version/Member</th><th>Qty</th><th>Price</th><th>Claim</th><th>Payment</th><th>Fulfillment</th></tr></thead>
        <tbody>${claimRows}</tbody>
      </table></div>
      <div style="font-size:12px;color:var(--text3);margin:10px 0;">${summaryLine}</div>
      ${form}${creditNote}
    </div>
  </div>`;
}
```

- [ ] **Step 4: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`. Also confirm no dangling references:

```bash
grep -n "lookup-tbody\|lookup-pay-panels\|grandTotal\|paidTotal\|unpaidTotal" index.html
```

Expected: no matches (all removed).

- [ ] **Step 5: Verify in browser**

Open My orders, look up a buyer with claims across 2+ GOs (ideally one with a secured unpaid claim, one paid-ahead with credit, and a Shop order). Confirm:
- One card per GO, newest first, Shop last; each header shows the GO name + right-side `Owed`/`Credit`/`All paid ✓`.
- Each card body: the GO's claims table (no GO column) then `Paid · Owed · Credit` and, when owed > 0, the send-payment form; paying still works (submit a small amount, confirm it posts as before).
- Clicking a header collapses/expands that GO only; others keep their state on re-render within the session.
- The "Request shipping" panel still appears once at the bottom. A lookup with no claims shows "No claims found".

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "My orders: group claims into per-GO blocks with each GO's payment section"
```

---

## Self-Review

**Spec coverage:**
- Per-GO blocks replace flat table + pay panels → Steps 1–2 ✓
- Claims table (no GO column) + payment section per block → Step 3 `renderMyOrderGoBlock` ✓
- Collapsible, default expanded → Step 3 `myOrderGoOpen`/`toggleMyOrderGo` ✓
- Newest-first, Shop last → Step 2 sort ✓
- No grand total; `#result-count` preserved → Step 2 ✓
- Reuse `goPaymentSummary` + exact pay-form ids/handler → Step 3 ✓
- Shipping unchanged → `renderShipPanel(u)` left in place ✓
- Frontend-only → Global Constraints ✓

**Placeholder scan:** No TBD/TODO — every step shows exact code.

**Type/name consistency:** `renderMyOrderGoBlock(g, goRows, u)` defined in Step 3, called in Step 2 with `(g, rows.filter(...), u)` — matching arity. `toggleMyOrderGo(goId)` defined Step 3, referenced in the block's header `onclick`. `myo-body-${g.go_id}` / `myo-chev-${g.go_id}` ids match between the block markup and `toggleMyOrderGo`. Pay-form ids (`pay-method/amount/txid-${g.go_id}`) and `submitGoPayment('${g.go_id}','${u}')` identical to the removed pay-panel code, so submission is unchanged.
