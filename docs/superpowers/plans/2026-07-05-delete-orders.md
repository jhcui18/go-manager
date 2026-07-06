# Delete Shop Orders & Payment Records Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add admin delete for shop orders (returning stock) and for payment records.

**Architecture:** Backend adds `deleteShopOrder` (reads the order, restores stock to the listing/variant, deletes the row) and `deletePayment` (deletes the row), using the existing `deleteRowWhere` helper. Frontend adds a × on each shop-order row and a Delete on each payment-proof row. GO claim delete already exists — untouched.

**Tech Stack:** Vanilla single-file HTML/CSS/JS (`index.html`), Apps Script + Sheets (`go-manager-backend.gs`).

**Spec:** `docs/superpowers/specs/2026-07-05-delete-orders-design.md`

---

## Verification approach (read first)

No test framework. Verify with syntax checks:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
```
Manual check after deploy (Task 4). Backend changes need an **Apps Script redeploy**.

---

## Task 1: Backend — deleteShopOrder (restore stock) + deletePayment

**Files:** Modify `go-manager-backend.gs`

- [ ] **Step 1: Add the functions**

Add just above `function deleteRowWhere(sheet, col, val) {`:
```javascript
function deleteShopOrder(order_id) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const orderSheet = ss.getSheetByName(SHEET_SHOP_ORDERS);
  const rows = orderSheet.getDataRange().getValues();
  const headers = rows[0];
  const oidCol = headers.indexOf('order_id');
  const lidCol = headers.indexOf('listing_id');
  const qtyCol = headers.indexOf('qty');
  const varCol = headers.indexOf('variant');
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][oidCol] === order_id) {
      restoreListingStock(ss, rows[i][lidCol], parseInt(rows[i][qtyCol]) || 0, rows[i][varCol]);
      break;
    }
  }
  deleteRowWhere(orderSheet, 'order_id', order_id);
  return { ok: true };
}

function restoreListingStock(ss, listing_id, qty, variant) {
  const listSheet = ss.getSheetByName(SHEET_LISTINGS);
  if (!listSheet) return;
  const rows = listSheet.getDataRange().getValues();
  const headers = rows[0];
  const idCol = headers.indexOf('listing_id');
  const qtyCol = headers.indexOf('qty');
  const varCol = headers.indexOf('variants');
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][idCol] === listing_id) {
      if (variant) {
        let variants = [];
        try { variants = JSON.parse(rows[i][varCol] || '[]'); } catch (e) { variants = []; }
        const v = variants.find(x => x.name === variant);
        if (v) {
          v.qty = (parseInt(v.qty) || 0) + qty;
          listSheet.getRange(i+1, varCol+1).setValue(JSON.stringify(variants));
        }
      } else {
        listSheet.getRange(i+1, qtyCol+1).setValue((parseInt(rows[i][qtyCol]) || 0) + qty);
      }
      return;
    }
  }
}

function deletePayment(payment_id) {
  deleteRowWhere(SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_PAYMENTS), 'payment_id', payment_id);
  return { ok: true };
}
```

- [ ] **Step 2: Route them**

Find:
```javascript
    else if (action === 'updateShopOrder')   result = updateShopOrder(body.data);
```
Replace with:
```javascript
    else if (action === 'updateShopOrder')   result = updateShopOrder(body.data);
    else if (action === 'deleteShopOrder')   result = deleteShopOrder(body.data.order_id);
    else if (action === 'deletePayment')     result = deletePayment(body.data.payment_id);
```

- [ ] **Step 3: Syntax check + commit**

```bash
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
git add go-manager-backend.gs && git commit -m "Backend: deleteShopOrder (restore stock) + deletePayment"
```

---

## Task 2: Frontend — delete shop order

**Files:** Modify `index.html`

- [ ] **Step 1: Add a × button to the shop-order row's fulfillment cell**

Find:
```javascript
      <td><div style="display:flex;align-items:center;gap:6px;">
        <span class="badge ${fulfillBadge(o.fulfillment)}">${o.fulfillment}</span>
        ${pf ? `<button class="btn btn-sm btn-ghost" style="font-size:11px;padding:3px 8px;" title="Back to ${pf}" onclick="advanceShopFulfill('${o.order_id}','prev')">←</button>` : ''}
        ${nf ? `<button class="btn btn-sm btn-ghost" style="font-size:11px;padding:3px 8px;" onclick="advanceShopFulfill('${o.order_id}')">→ ${nf}</button>` : ''}
      </div></td>
```
Replace with:
```javascript
      <td><div style="display:flex;align-items:center;gap:6px;">
        <span class="badge ${fulfillBadge(o.fulfillment)}">${o.fulfillment}</span>
        ${pf ? `<button class="btn btn-sm btn-ghost" style="font-size:11px;padding:3px 8px;" title="Back to ${pf}" onclick="advanceShopFulfill('${o.order_id}','prev')">←</button>` : ''}
        ${nf ? `<button class="btn btn-sm btn-ghost" style="font-size:11px;padding:3px 8px;" onclick="advanceShopFulfill('${o.order_id}')">→ ${nf}</button>` : ''}
        <button class="btn btn-sm btn-ghost" style="font-size:11px;padding:3px 8px;color:var(--red-400);" title="Delete order (returns stock)" onclick="deleteShopOrder('${o.order_id}')">×</button>
      </div></td>
```

- [ ] **Step 2: Add the deleteShopOrder handler**

Find the function `toggleShopOrderPayment` and add BEFORE it:
```javascript
function deleteShopOrder(orderId) {
  const o = shopOrders.find(x => x.order_id === orderId);
  if (!o) return;
  if (!confirm('Delete this shop order and return its stock?')) return;
  // Restore stock on the local listing (variant or single qty).
  const l = listings.find(x => x.listing_id === o.listing_id);
  if (l) {
    if (o.variant && l.variants && l.variants.length) {
      const v = l.variants.find(x => x.name === o.variant);
      if (v) v.qty = (parseInt(v.qty) || 0) + (parseInt(o.qty) || 0);
    } else {
      l.qty = (parseInt(l.qty) || 0) + (parseInt(o.qty) || 0);
    }
  }
  shopOrders = shopOrders.filter(x => x.order_id !== orderId);
  if (API_URL) apiPost('deleteShopOrder', { order_id: orderId }).catch(()=>{});
  renderShopOrders();
  renderAdminListings();
  renderShopPage();
  toast('Shop order deleted.');
}

```

- [ ] **Step 3: Syntax check + commit**

```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
git add index.html && git commit -m "Frontend: delete shop order (returns stock)"
```

---

## Task 3: Frontend — delete payment record

**Files:** Modify `index.html`

- [ ] **Step 1: Add a Delete button to the payment-proof row**

Find:
```javascript
          <button class="btn btn-sm btn-ghost" style="color:var(--red-400);" onclick="rejectPayment('${p.payment_id}')">Reject</button>
          <button class="btn btn-sm btn-ghost" onclick="openEditProofModal('${p.payment_id}')">Edit</button>
```
Replace with:
```javascript
          <button class="btn btn-sm btn-ghost" style="color:var(--red-400);" onclick="rejectPayment('${p.payment_id}')">Reject</button>
          <button class="btn btn-sm btn-ghost" onclick="openEditProofModal('${p.payment_id}')">Edit</button>
          <button class="btn btn-sm btn-ghost" style="color:var(--red-400);" onclick="deletePaymentProof('${p.payment_id}')">Delete</button>
```

- [ ] **Step 2: Add the deletePaymentProof handler**

Find the function `rejectPayment` and add BEFORE it:
```javascript
function deletePaymentProof(id) {
  if (!confirm('Delete this payment record? This cannot be undone.')) return;
  paymentProofs = paymentProofs.filter(p => p.payment_id !== id);
  if (API_URL) apiPost('deletePayment', { payment_id: id }).catch(()=>{});
  renderPaymentProofs();
  toast('Payment record deleted.');
}

```

- [ ] **Step 3: Syntax check + commit**

```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
git add index.html && git commit -m "Frontend: delete payment record"
```

---

## Task 4: Deploy, redeploy, manual verification

**Files:** none.

- [ ] **Step 1: Push**

```bash
git push
```

- [ ] **Step 2: Redeploy the Apps Script backend**

Paste updated `go-manager-backend.gs` → Deploy → Manage deployments → edit → New version → Deploy. (User action.)

- [ ] **Step 3: Wait for the live frontend deploy**

```bash
for i in $(seq 1 25); do n=$(curl -s "https://jhcui18.github.io/go-manager/index.html?cb=$(date +%s%N)" | grep -c "function deleteShopOrder"); if [ "$n" -gt 0 ]; then echo "LIVE after ~$((i*10))s"; break; fi; sleep 10; done
```
Expected: `LIVE after ~Ns`

- [ ] **Step 4: Manual — delete a shop order restores stock**

Admin. Note a listing's stock (e.g. Ver A = 1 after an order). In Shop orders, click **×** on that order → confirm. The order disappears; the listing's stock goes back up (Ver A = 2) in admin listings and on the Shop card.

- [ ] **Step 5: Manual — delete a payment record**

Admin → Pending payment proofs → click **Delete** on a proof → confirm. It disappears from the list and (after a sync) does not come back. A separate claim's Paid status is unchanged.

- [ ] **Step 6: Final commit (only if a fix was needed)**

```bash
git add index.html go-manager-backend.gs && git commit -m "Fix delete-orders issue found in verification" && git push
```

---

## Notes

- GO claim delete already exists (FCFS × / photocard slot Edit → Remove claim) — untouched.
- Payment delete only removes the record; it does not change claim paid status.
- Uses the existing `deleteRowWhere(sheet, col, val)` helper.
