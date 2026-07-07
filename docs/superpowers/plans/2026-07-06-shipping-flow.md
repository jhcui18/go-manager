# Unified Shipping Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Buyers request shipping in My orders, bundling their paid+Ready items (GO claims + shop orders) into one request with one address; admins record a fee and mark it shipped, flipping items to Dispatched/Shipped. Shop orders get a Pending→Ready→Shipped status.

**Architecture:** Frontend adds a shop status ladder, a buyer Request-shipping panel in My orders (compute eligible items + address form + submit), and reworks the admin shipping queue from auto-populate to rendering buyer-submitted requests. Backend stores the bundled `items` on the shipping request and flips those items shipped on completion.

**Tech Stack:** Vanilla single-file HTML/CSS/JS (`index.html`), Apps Script + Sheets (`go-manager-backend.gs`), GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-07-06-shipping-flow-design.md`

---

## Verification approach (read first)

No test framework. Verify each task with syntax checks:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
```
Manual check after deploy (Task 6). Backend changes need an **Apps Script redeploy** (`ensureSheet` auto-adds the new `items` column on bootstrap).

## Naming (keep consistent)

- `SHOP_FULFILLMENT = ['Pending','Ready','Shipped']`; helpers `shopNextFulfillment`, `shopPrevFulfillment`.
- Shipping request item: `{ type:'claim'|'shop', id, label }`. `id` = claim_id or order_id.
- `shippingRequests` (frontend array, loaded from `getShipping` → `requests`).
- Eligible-items helper: `shipEligibleItems(username)`.
- Address form field ids: `ship-fullname`, `ship-addr1`, `ship-addr2`, `ship-city`, `ship-state`, `ship-postal`, `ship-country`, `ship-notes`.

---

## Task 1: Backend — items column, submitShipping, updateShipping

**Files:** Modify `go-manager-backend.gs`

- [ ] **Step 1: Add `items` to the shipping schema (end)**

Find:
```javascript
  ensureSheet(ss, SHEET_SHIPPING, ['request_id','username','go_ids','full_name','address1','address2','city','state','postal','country','notes','email','card_count','ems_fee','dom_fee','total_fee','shipped','created_at']);
```
Replace with:
```javascript
  ensureSheet(ss, SHEET_SHIPPING, ['request_id','username','go_ids','full_name','address1','address2','city','state','postal','country','notes','email','card_count','ems_fee','dom_fee','total_fee','shipped','created_at','items']);
```

- [ ] **Step 2: Store items in submitShipping**

Find:
```javascript
function submitShipping(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHIPPING);
  const id = 'ship_' + Date.now();
  sheet.appendRow([id, data.username, data.go_ids || '', data.full_name, data.address1, data.address2 || '', data.city, data.state, data.postal, data.country, data.notes || '', data.email || '', data.card_count || 0, '', '', '', false, new Date().toISOString()]);
  return { ok: true, request_id: id };
}
```
Replace with:
```javascript
function submitShipping(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHIPPING);
  const id = 'ship_' + Date.now() + '_' + Math.random().toString(36).slice(2,6);
  const items = data.items || [];
  sheet.appendRow([id, data.username, data.go_ids || '', data.full_name || '', data.address1 || '', data.address2 || '', data.city || '', data.state || '', data.postal || '', data.country || '', data.notes || '', data.email || '', items.length, '', '', '', false, new Date().toISOString(), JSON.stringify(items)]);
  return { ok: true, request_id: id };
}
```

- [ ] **Step 3: updateShipping marks bundled items shipped**

Find:
```javascript
function updateShipping(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHIPPING);
  updateRowWhere(sheet, 'request_id', data.request_id, {
    ems_fee: data.ems_fee,
    dom_fee: data.dom_fee,
    total_fee: data.total_fee,
    shipped: data.shipped
  });
  return { ok: true };
}
```
Replace with:
```javascript
function updateShipping(data) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const sheet = ss.getSheetByName(SHEET_SHIPPING);
  const fields = {};
  if (data.ems_fee !== undefined)   fields.ems_fee = data.ems_fee;
  if (data.dom_fee !== undefined)   fields.dom_fee = data.dom_fee;
  if (data.total_fee !== undefined) fields.total_fee = data.total_fee;
  if (data.shipped !== undefined)   fields.shipped = data.shipped;
  updateRowWhere(sheet, 'request_id', data.request_id, fields);
  if (data.shipped === true) {
    // Read the request's bundled items and mark each shipped.
    const rows = sheet.getDataRange().getValues();
    const headers = rows[0];
    const ridCol = headers.indexOf('request_id');
    const itemsCol = headers.indexOf('items');
    let items = [];
    for (let i = 1; i < rows.length; i++) {
      if (rows[i][ridCol] === data.request_id) {
        try { items = JSON.parse(rows[i][itemsCol] || '[]'); } catch (e) { items = []; }
        break;
      }
    }
    const claimIds = items.filter(it => it.type === 'claim').map(it => it.id);
    const orderIds = items.filter(it => it.type === 'shop').map(it => it.id);
    if (claimIds.length) setFulfillmentByIds(ss.getSheetByName(SHEET_JOINERS), 'claim_id', claimIds, 'Dispatched');
    if (orderIds.length) setFulfillmentByIds(ss.getSheetByName(SHEET_SHOP_ORDERS), 'order_id', orderIds, 'Shipped');
  }
  return { ok: true };
}

function setFulfillmentByIds(sheet, idCol, ids, value) {
  if (!sheet || !ids.length) return;
  const rows = sheet.getDataRange().getValues();
  const headers = rows[0];
  const iCol = headers.indexOf(idCol);
  const fCol = headers.indexOf('fulfillment');
  const uCol = headers.indexOf('updated_at');
  const idSet = {};
  ids.forEach(id => { idSet[id] = true; });
  for (let i = 1; i < rows.length; i++) {
    if (idSet[rows[i][iCol]]) {
      if (fCol >= 0) sheet.getRange(i+1, fCol+1).setValue(value);
      if (uCol >= 0) sheet.getRange(i+1, uCol+1).setValue(new Date().toISOString());
    }
  }
}
```

- [ ] **Step 4: Syntax check + commit**

```bash
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
git add go-manager-backend.gs && git commit -m "Backend: shipping items column + submit/update mark items shipped"
```

---

## Task 2: Frontend — shop order status ladder (Pending → Ready → Shipped)

**Files:** Modify `index.html`

- [ ] **Step 1: Add the shop ladder + helpers**

Find:
```javascript
function prevFulfillment(f) { const i = FULFILLMENT.indexOf(f); return i > 0 ? FULFILLMENT[i-1] : null; }
```
Add immediately after it:
```javascript
const SHOP_FULFILLMENT = ['Pending','Ready','Shipped'];
function shopNextFulfillment(f) { const i = SHOP_FULFILLMENT.indexOf(f); return (i >= 0 && i < SHOP_FULFILLMENT.length-1) ? SHOP_FULFILLMENT[i+1] : null; }
function shopPrevFulfillment(f) { const i = SHOP_FULFILLMENT.indexOf(f); return i > 0 ? SHOP_FULFILLMENT[i-1] : null; }
function shopFulfillBadge(f) { return f === 'Shipped' ? 'badge-secured' : f === 'Ready' ? 'badge-ready' : 'badge-pending'; }
```

- [ ] **Step 2: advanceShopFulfill uses the shop ladder**

Find:
```javascript
function advanceShopFulfill(orderId, dir) {
  const o = shopOrders.find(x => x.order_id === orderId);
  if (!o) return;
  const nf = dir === 'prev' ? prevFulfillment(o.fulfillment) : nextFulfillment(o.fulfillment);
```
Replace with:
```javascript
function advanceShopFulfill(orderId, dir) {
  const o = shopOrders.find(x => x.order_id === orderId);
  if (!o) return;
  const nf = dir === 'prev' ? shopPrevFulfillment(o.fulfillment) : shopNextFulfillment(o.fulfillment);
```

- [ ] **Step 3: renderShopOrders uses the shop ladder + badge**

Find:
```javascript
    const amt = (parseFloat(o.unit_price)||0) * (parseInt(o.qty)||1);
    const nf = nextFulfillment(o.fulfillment);
    const pf = prevFulfillment(o.fulfillment);
```
Replace with:
```javascript
    const amt = (parseFloat(o.unit_price)||0) * (parseInt(o.qty)||1);
    const nf = shopNextFulfillment(o.fulfillment);
    const pf = shopPrevFulfillment(o.fulfillment);
```
Then find (in the same row template):
```javascript
        <span class="badge ${fulfillBadge(o.fulfillment)}">${o.fulfillment}</span>
```
Replace with:
```javascript
        <span class="badge ${shopFulfillBadge(o.fulfillment)}">${o.fulfillment}</span>
```

- [ ] **Step 4: Syntax check + commit**

```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
git add index.html && git commit -m "Frontend: shop order status ladder Pending->Ready->Shipped"
```

---

## Task 3: Frontend — load shipping requests on sync

**Files:** Modify `index.html`

- [ ] **Step 1: Fetch getShipping in the sync Promise.all**

Find:
```javascript
    const [result, payResult, listResult, orderResult] = await Promise.all([
      apiGet('getAllGOs'), apiGet('getPayments'), apiGet('getListings'), apiGet('getShopOrders')
    ]);
```
Replace with:
```javascript
    const [result, payResult, listResult, orderResult, shipResult] = await Promise.all([
      apiGet('getAllGOs'), apiGet('getPayments'), apiGet('getListings'), apiGet('getShopOrders'), apiGet('getShipping')
    ]);
```

- [ ] **Step 2: Populate shippingRequests + render**

Find:
```javascript
    if (orderResult && Array.isArray(orderResult.shop_orders)) {
      shopOrders = orderResult.shop_orders.filter(o => o && o.order_id);
    }
    renderShopPage();
    renderAdminListings();
    renderShopOrders();
```
Replace with:
```javascript
    if (orderResult && Array.isArray(orderResult.shop_orders)) {
      shopOrders = orderResult.shop_orders.filter(o => o && o.order_id);
    }
    if (shipResult && Array.isArray(shipResult.requests)) {
      shippingRequests = shipResult.requests
        .filter(r => r && r.request_id)
        .map(r => ({ ...r, items: tryParse(r.items, []), shipped: r.shipped === true || r.shipped === 'true' }));
    }
    renderShopPage();
    renderAdminListings();
    renderShopOrders();
    renderShippingQueue();
```

- [ ] **Step 3: Syntax check + commit**

```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
git add index.html && git commit -m "Frontend: load shipping requests from backend on sync"
```

---

## Task 4: Frontend — buyer Request-shipping panel in My orders

**Files:** Modify `index.html`

- [ ] **Step 1: Add a container in the lookup result**

Find:
```html
    <div id="lookup-pay-panels"></div>
```
Replace with:
```html
    <div id="lookup-pay-panels"></div>
    <div id="lookup-ship-panel"></div>
```

- [ ] **Step 2: Add the eligible-items helper + render + submit**

Add directly ABOVE `function submitGoPayment(` :
```javascript
// A buyer's items that are Paid AND Ready and not already in a shipping request.
function shipEligibleItems(username) {
  const items = [];
  Object.values(allGOs).forEach(go => {
    (go.subItems || []).forEach(si => {
      if (si.sets) si.sets.forEach(set => (si.members || []).forEach(m => {
        const slot = set.slots[m];
        if (slot && slot.user === username && slot.payment === 'paid' && slot.fulfillment === 'Ready' && slot.claim_id) {
          items.push({ type: 'claim', id: slot.claim_id, label: go.name + ' — ' + si.name + ' ' + m });
        }
      }));
      if (si.claims) si.claims.forEach(c => {
        if (c.user === username && c.payment === 'paid' && c.fulfillment === 'Ready' && c.claim_id) {
          items.push({ type: 'claim', id: c.claim_id, label: go.name + ' — ' + si.name + (c.member ? (' ' + c.member) : '') });
        }
      });
    });
  });
  shopOrders.forEach(o => {
    if (o.username === username && o.payment_status === 'paid' && o.fulfillment === 'Ready') {
      items.push({ type: 'shop', id: o.order_id, label: o.listing_name + (o.variant ? (' — ' + o.variant) : '') });
    }
  });
  const requested = {};
  (shippingRequests || []).forEach(r => (r.items || []).forEach(it => { requested[it.id] = true; }));
  return items.filter(it => !requested[it.id]);
}

function renderShipPanel(username) {
  const el = document.getElementById('lookup-ship-panel');
  if (!el) return;
  const items = shipEligibleItems(username);
  if (!items.length) { el.innerHTML = ''; return; }
  el.innerHTML = `
    <div class="card" style="margin-top:12px;">
      <div style="font-weight:500;font-size:15px;margin-bottom:6px;">Request shipping</div>
      <div style="font-size:12px;color:var(--text2);margin-bottom:8px;">These items are ready to ship. Enter your address to request one shipment:</div>
      <div style="font-size:12px;color:var(--text2);margin-bottom:12px;">${items.map(it => '• ' + it.label).join('<br>')}</div>
      <div class="field"><label>Full name</label><input type="text" id="ship-fullname" placeholder="As on the label"></div>
      <div class="field"><label>Address line 1</label><input type="text" id="ship-addr1"></div>
      <div class="field"><label>Address line 2 (optional)</label><input type="text" id="ship-addr2" placeholder="Apt, unit..."></div>
      <div class="field-row">
        <div class="field"><label>City</label><input type="text" id="ship-city"></div>
        <div class="field"><label>State / Province</label><input type="text" id="ship-state"></div>
      </div>
      <div class="field-row">
        <div class="field"><label>Postal code</label><input type="text" id="ship-postal"></div>
        <div class="field"><label>Country</label><input type="text" id="ship-country" value="United States"></div>
      </div>
      <div class="field"><label>Notes (optional)</label><input type="text" id="ship-notes" placeholder="Special instructions"></div>
      <button class="btn btn-primary" style="width:100%;justify-content:center;" onclick="submitShippingRequest('${username}')">Submit shipping request</button>
    </div>`;
}

function submitShippingRequest(username) {
  const items = shipEligibleItems(username);
  if (!items.length) { toast('No items ready to ship.'); return; }
  const g = id => (document.getElementById(id) || {}).value || '';
  const full_name = g('ship-fullname').trim();
  const address1 = g('ship-addr1').trim();
  const city = g('ship-city').trim();
  if (!full_name || !address1 || !city) { toast('Please fill in name, address, and city.'); return; }
  const req = {
    request_id: 'ship_' + Date.now(), username,
    full_name, address1, address2: g('ship-addr2').trim(), city,
    state: g('ship-state').trim(), postal: g('ship-postal').trim(),
    country: g('ship-country').trim(), notes: g('ship-notes').trim(),
    items, shipped: false, ems_fee: '', dom_fee: '', total_fee: '', card_count: items.length
  };
  shippingRequests.push(req);
  if (API_URL) apiPost('submitShipping', req).catch(()=>{});
  renderShipPanel(username);
  renderShippingQueue();
  toast('Shipping request submitted!');
}
```

- [ ] **Step 3: Call renderShipPanel from doLookup**

Find (the end of the `doLookup` pay-panels block, immediately before `function submitGoPayment`):
```javascript
    }
  }
}

function submitGoPayment(goId, lookedUpUser) {
```
Replace with:
```javascript
    }
  }
  renderShipPanel(u);
}

function submitGoPayment(goId, lookedUpUser) {
```

- [ ] **Step 4: Syntax check + commit**

```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
git add index.html && git commit -m "Frontend: buyer Request-shipping panel in My orders"
```

---

## Task 5: Frontend — admin shipping queue (buyer-submitted requests)

**Files:** Modify `index.html`

- [ ] **Step 1: Replace refreshShippingQueue (re-sync instead of auto-populate)**

Find:
```javascript
function refreshShippingQueue() {
  // Auto-populate from joiners with all items Ready
  const readyByUser = {};
```
…through the end of that function:
```javascript
  renderShippingQueue();
}
```
Replace the ENTIRE `refreshShippingQueue` function with:
```javascript
function refreshShippingQueue() {
  if (API_URL) syncFromBackend(); else renderShippingQueue();
}
```

- [ ] **Step 2: Replace the whole old shipping-admin block**

The old admin-shipping helpers are a contiguous run of functions: `renderShippingQueue`, `updateShipFee`, `viewShippingAddress`, `markShipped`, `openEditShippingModal`, `saveShippingEdit`, `_origSubmitShipping`, `countUserCards`. **Delete the entire span** starting at the line `function renderShippingQueue() {` through the closing `}` of `function countUserCards(...)` (the block ends right before the `// ── INIT ──` comment). Replace that whole span with the following four functions:
```javascript
function renderShippingQueue() {
  const tbody = document.getElementById('shipping-queue-tbody');
  if (!tbody) return;
  const pending = (shippingRequests || []).filter(r => !r.shipped);
  if (!pending.length) {
    tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;color:var(--text3);padding:20px;">No shipping requests.</td></tr>';
    return;
  }
  tbody.innerHTML = pending.map(r => {
    const items = r.items || [];
    const ems = parseFloat(r.ems_fee) || 0;
    const dom = parseFloat(r.dom_fee) || 0;
    const total = (ems + dom) > 0 ? (ems + dom).toFixed(2) : '—';
    return `<tr>
      <td style="font-weight:500;">${r.username}</td>
      <td style="font-size:12px;color:var(--text2);">${items.map(it => it.label).join('<br>') || '—'}</td>
      <td>${items.length}</td>
      <td><input type="number" placeholder="0.00" step="0.01" value="${r.ems_fee||''}" oninput="updateShipFee('${r.request_id}','ems',this.value)" style="width:72px;padding:4px 8px;border:0.5px solid var(--border2);border-radius:6px;font-size:12px;font-family:var(--mono);"></td>
      <td><input type="number" placeholder="0.00" step="0.01" value="${r.dom_fee||''}" oninput="updateShipFee('${r.request_id}','dom',this.value)" style="width:72px;padding:4px 8px;border:0.5px solid var(--border2);border-radius:6px;font-size:12px;font-family:var(--mono);"></td>
      <td style="font-family:var(--mono);font-weight:500;" id="ship-total-${r.request_id}">${total !== '—' ? '$'+total : '—'}</td>
      <td><button class="btn btn-sm btn-ghost" onclick="viewShippingAddress('${r.request_id}')">View</button></td>
      <td><button class="btn btn-sm btn-primary" onclick="markShipped('${r.request_id}')">Mark shipped</button></td>
    </tr>`;
  }).join('');
}

function updateShipFee(requestId, which, val) {
  const r = shippingRequests.find(x => x.request_id === requestId);
  if (!r) return;
  if (which === 'ems') r.ems_fee = val; else r.dom_fee = val;
  const ems = parseFloat(r.ems_fee) || 0;
  const dom = parseFloat(r.dom_fee) || 0;
  r.total_fee = (ems + dom).toFixed(2);
  const el = document.getElementById('ship-total-' + requestId);
  if (el) el.textContent = (ems + dom) > 0 ? '$' + r.total_fee : '—';
}

function viewShippingAddress(requestId) {
  const r = shippingRequests.find(x => x.request_id === requestId);
  if (!r) return;
  const addr = [r.full_name, r.address1, r.address2, [r.city, r.state, r.postal].filter(Boolean).join(', '), r.country, r.notes ? ('Notes: ' + r.notes) : ''].filter(Boolean).join('\n');
  showModal(`
    <div style="font-size:16px;font-weight:500;margin-bottom:4px;">Shipping address</div>
    <div style="font-size:13px;font-weight:500;margin-bottom:8px;">${r.username}</div>
    <div style="font-size:13px;color:var(--text2);white-space:pre-line;margin-bottom:16px;">${addr || 'No address.'}</div>
    <div style="font-size:13px;font-weight:500;margin-bottom:6px;">Items:</div>
    <div style="font-size:12px;color:var(--text2);">${(r.items||[]).map(it => '• ' + it.label).join('<br>') || '—'}</div>
    <button class="btn btn-ghost" onclick="closeModal()" style="margin-top:20px;width:100%;justify-content:center;">Close</button>`);
}

function markShipped(requestId) {
  const r = shippingRequests.find(x => x.request_id === requestId);
  if (!r) return;
  if (!confirm('Mark shipped for ' + r.username + '? Their bundled items will be set to Dispatched/Shipped.')) return;
  r.shipped = true;
  // Flip bundled items locally.
  const claimIds = {}, orderIds = {};
  (r.items || []).forEach(it => { if (it.type === 'claim') claimIds[it.id] = true; else if (it.type === 'shop') orderIds[it.id] = true; });
  Object.values(allGOs).forEach(go => (go.subItems || []).forEach(si => {
    if (si.sets) si.sets.forEach(set => (si.members || []).forEach(m => {
      const slot = set.slots[m]; if (slot && slot.claim_id && claimIds[slot.claim_id]) slot.fulfillment = 'Dispatched';
    }));
    if (si.claims) si.claims.forEach(c => { if (c.claim_id && claimIds[c.claim_id]) c.fulfillment = 'Dispatched'; });
  }));
  shopOrders.forEach(o => { if (orderIds[o.order_id]) o.fulfillment = 'Shipped'; });
  if (API_URL) apiPost('updateShipping', { request_id: r.request_id, ems_fee: r.ems_fee || '', dom_fee: r.dom_fee || '', total_fee: r.total_fee || '', shipped: true }).catch(()=>{});
  renderShippingQueue();
  renderDetailContent();
  renderShopOrders();
  toast('Marked shipped for ' + r.username);
}
```

Note: this removes `_origSubmitShipping`, which the unreachable `#page-shipping` form button references (`onclick="_origSubmitShipping()"`). That page has no nav tab, so a now-undefined handler there is harmless (it can't be reached). Leave the `#page-shipping` HTML as-is.

- [ ] **Step 3: Syntax check + commit**

```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
git add index.html && git commit -m "Frontend: admin shipping queue renders buyer-submitted requests"
```

---

## Task 6: Deploy, redeploy, manual verification

**Files:** none.

- [ ] **Step 1: Push**

```bash
git push
```

- [ ] **Step 2: Redeploy the Apps Script backend** (User action)

Paste updated `go-manager-backend.gs` → Deploy → Manage deployments → edit → New version → Deploy. `ensureSheet` auto-adds the `items` column to the `shipping` sheet on the next backend call.

- [ ] **Step 3: Wait for the live frontend deploy**

```bash
for i in $(seq 1 25); do n=$(curl -s "https://jhcui18.github.io/go-manager/index.html?cb=$(date +%s%N)" | grep -c "function shipEligibleItems"); if [ "$n" -gt 0 ]; then echo "LIVE after ~$((i*10))s"; break; fi; sleep 10; done
```
Expected: `LIVE after ~Ns`

- [ ] **Step 4: Manual — make items paid+Ready**

Admin. For a GO claim: mark it Paid and advance fulfillment to **Ready**. For a shop order: mark it Paid and advance status to **Ready** (now Pending→Ready→Shipped).

- [ ] **Step 5: Manual — buyer requests shipping**

My orders → look up that buyer. A **Request shipping** panel lists the paid+Ready items (GO + shop). Fill name/address/city → **Submit shipping request** → toast; the panel clears (items now requested).

- [ ] **Step 6: Manual — admin ships**

Admin → **Shipping queue**: the request shows the buyer, item labels, address (View), fee inputs. Enter a domestic fee, then **Mark shipped**. Verify: the GO claim shows **Dispatched** and the shop order shows **Shipped**; the request leaves the queue. Re-lookup the buyer — the shipped items no longer appear as ship-eligible.

- [ ] **Step 7: Final commit (only if a fix was needed)**

```bash
git add index.html go-manager-backend.gs && git commit -m "Fix shipping-flow issue found in verification" && git push
```

---

## Notes / deferred (from spec)

- In-app shipping **payment** is out of scope — the admin records the fee; the buyer pays off-app.
- Fees are entered by the admin (no auto-calc).
- Buyers can't edit/cancel a submitted request; they can request remaining eligible items in a later shipment.
- Existing shop orders with old 5-stage statuses may not map onto the 3-stage ladder — recreate or ignore (few test orders).
