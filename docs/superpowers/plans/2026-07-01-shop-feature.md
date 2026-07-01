# Shop (Leftover Sales) Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Shop where the manager sells leftover stock as photo listings with per-listing stock; buyers place instant orders (server-side stock guard) and pay through the existing My orders → Pay flow.

**Architecture:** Backend adds two sheets (`listings`, `shop_orders`) + endpoints and extends `updatePayment` for a `shop` pseudo-GO. Frontend adds a public Shop tab, an admin Shop-management area, and folds shop orders into the existing My orders lookup + Pay panel by grouping them under a `go_id:'shop'` pseudo-GO.

**Tech Stack:** Vanilla single-file HTML/CSS/JS (`index.html`), Google Apps Script + Sheets backend (`go-manager-backend.gs`), GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-06-30-shop-feature-design.md`

---

## Verification approach (read first)

No automated test framework; this is a single-file app. Established verification:

1. **Frontend syntax check** — extract inline JS and `node --check`:
   ```bash
   python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
   ```
2. **Backend syntax check** — copy to `.js` and `node --check`:
   ```bash
   cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
   ```
3. **Manual browser check** after deploy (steps in Task 12). Backend changes require an
   **Apps Script redeploy** before the shop works end-to-end.

Do not add a test framework or split the file.

---

## File structure

- **Modify:** `go-manager-backend.gs` — sheet consts, `bootstrapSheets`, new endpoints,
  routing, `updatePayment` extension.
- **Modify:** `index.html` — state vars, nav tab + `#page-shop`, sync loaders, public
  Shop render + order flow, admin listings + orders, `doLookup` shop rows,
  `submitGoPayment`/`confirmPayment` shop handling.

## Naming (used across tasks — keep consistent)

- Sheets: `listings`, `shop_orders`.
- Listing object: `{ listing_id, name, category, price, image_url, qty, note, status, created_at }`.
- Order object: `{ order_id, listing_id, listing_name, username, email, qty, unit_price, payment_status, fulfillment, created_at, updated_at }`.
- Frontend state: `listings` (array), `shopOrders` (array).
- Pseudo-GO for payment: `go_id:'shop'`, display name `'Shop'`.

---

## Task 1: Backend — sheets + read endpoints

**Files:** Modify `go-manager-backend.gs`

- [ ] **Step 1: Add sheet name constants**

After the line `const SHEET_PAYMENTS  = 'payments';    // payment proof submissions`, add:
```javascript
const SHEET_LISTINGS   = 'listings';     // shop listings (leftover stock)
const SHEET_SHOP_ORDERS = 'shop_orders'; // shop purchase orders
```

- [ ] **Step 2: Bootstrap the two sheets**

In `bootstrapSheets`, after the `ensureSheet(ss, SHEET_PAYMENTS, ...)` line, add:
```javascript
  ensureSheet(ss, SHEET_LISTINGS,    ['listing_id','name','category','price','image_url','qty','note','status','created_at']);
  ensureSheet(ss, SHEET_SHOP_ORDERS, ['order_id','listing_id','listing_name','username','email','qty','unit_price','payment_status','fulfillment','created_at','updated_at']);
```

- [ ] **Step 3: Add read functions**

Add near `getPayments` (after that function):
```javascript
function getListings() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_LISTINGS);
  return { listings: sheet ? sheetToObjects(sheet) : [] };
}

function getShopOrders() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHOP_ORDERS);
  return { shop_orders: sheet ? sheetToObjects(sheet) : [] };
}
```

- [ ] **Step 4: Route the read endpoints**

In `doGet`, after `else if (action === 'getPayments')       result = getPayments();`, add:
```javascript
    else if (action === 'getListings')     result = getListings();
    else if (action === 'getShopOrders')   result = getShopOrders();
```

- [ ] **Step 5: Syntax check**

Run:
```bash
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
```
Expected: `GS OK`

- [ ] **Step 6: Commit**

```bash
git add go-manager-backend.gs
git commit -m "Backend: add listings + shop_orders sheets and read endpoints"
```

---

## Task 2: Backend — listing CRUD

**Files:** Modify `go-manager-backend.gs`

- [ ] **Step 1: Add CRUD functions**

Add after `getShopOrders`:
```javascript
function createListing(data) {
  bootstrapSheets();
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_LISTINGS);
  const id = 'lst_' + Date.now() + '_' + Math.random().toString(36).slice(2,6);
  sheet.appendRow([
    id, data.name || '', data.category || '', data.price || 0, data.image_url || '',
    data.qty || 0, data.note || '', 'active', new Date().toISOString()
  ]);
  return { ok: true, listing_id: id };
}

function updateListing(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_LISTINGS);
  const fields = {};
  ['name','category','price','image_url','qty','note','status'].forEach(k => {
    if (data[k] !== undefined) fields[k] = data[k];
  });
  updateRowWhere(sheet, 'listing_id', data.listing_id, fields);
  return { ok: true };
}

function deleteListing(listing_id) {
  // Soft-delete: hide it, preserve order history.
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_LISTINGS);
  updateRowWhere(sheet, 'listing_id', listing_id, { status: 'hidden' });
  return { ok: true };
}
```

- [ ] **Step 2: Route them**

In `doPost`, after `else if (action === 'updatePayment')     result = updatePayment(body.data);`, add:
```javascript
    else if (action === 'createListing')     result = createListing(body.data);
    else if (action === 'updateListing')     result = updateListing(body.data);
    else if (action === 'deleteListing')     result = deleteListing(body.data.listing_id);
```

- [ ] **Step 3: Syntax check**

Run:
```bash
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
```
Expected: `GS OK`

- [ ] **Step 4: Commit**

```bash
git add go-manager-backend.gs
git commit -m "Backend: listing CRUD endpoints"
```

---

## Task 3: Backend — place/track shop orders (stock guard)

**Files:** Modify `go-manager-backend.gs`

- [ ] **Step 1: Add order functions**

Add after `deleteListing`:
```javascript
function placeShopOrder(data) {
  bootstrapSheets();
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const listSheet = ss.getSheetByName(SHEET_LISTINGS);
  const rows = listSheet.getDataRange().getValues();
  const headers = rows[0];
  const idCol = headers.indexOf('listing_id');
  const qtyCol = headers.indexOf('qty');
  const nameCol = headers.indexOf('name');
  const priceCol = headers.indexOf('price');
  const want = parseInt(data.qty) || 1;
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][idCol] === data.listing_id) {
      const have = parseInt(rows[i][qtyCol]) || 0;
      if (have < want) return { ok: false, error: 'oversold', available: have };
      // Decrement stock authoritatively, then append the order.
      listSheet.getRange(i+1, qtyCol+1).setValue(have - want);
      const orderSheet = ss.getSheetByName(SHEET_SHOP_ORDERS);
      const oid = 'sho_' + Date.now() + '_' + Math.random().toString(36).slice(2,6);
      const now = new Date().toISOString();
      orderSheet.appendRow([
        oid, data.listing_id, rows[i][nameCol], data.username, data.email || '',
        want, rows[i][priceCol], 'unpaid', 'Pending', now, now
      ]);
      return { ok: true, order_id: oid };
    }
  }
  return { ok: false, error: 'not_found' };
}

function updateShopOrder(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_SHOP_ORDERS);
  const fields = {};
  if (data.payment_status !== undefined) fields.payment_status = data.payment_status;
  if (data.fulfillment !== undefined)    fields.fulfillment = data.fulfillment;
  fields.updated_at = new Date().toISOString();
  updateRowWhere(sheet, 'order_id', data.order_id, fields);
  return { ok: true };
}
```

- [ ] **Step 2: Route them**

In `doPost`, after the `deleteListing` route line added in Task 2, add:
```javascript
    else if (action === 'placeShopOrder')    result = placeShopOrder(body.data);
    else if (action === 'updateShopOrder')   result = updateShopOrder(body.data);
```

- [ ] **Step 3: Syntax check**

Run:
```bash
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
```
Expected: `GS OK`

- [ ] **Step 4: Commit**

```bash
git add go-manager-backend.gs
git commit -m "Backend: placeShopOrder (stock guard) + updateShopOrder"
```

---

## Task 4: Backend — mark shop orders paid on confirm

**Files:** Modify `go-manager-backend.gs`

**Context:** `updatePayment` marks `joiners` claims paid when a GO payment is confirmed.
For a `shop` pseudo-GO payment, it must mark `shop_orders` rows for that user paid.

- [ ] **Step 1: Extend updatePayment**

In `updatePayment`, replace the whole `if (data.status === 'confirmed') { ... }` block with:
```javascript
  if (data.status === 'confirmed') {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    if (data.go_id === 'shop') {
      // Mark this user's shop orders paid.
      const orderSheet = ss.getSheetByName(SHEET_SHOP_ORDERS);
      const rows = orderSheet.getDataRange().getValues();
      const headers = rows[0];
      const uCol = headers.indexOf('username');
      const payCol = headers.indexOf('payment_status');
      const updCol = headers.indexOf('updated_at');
      for (let i = 1; i < rows.length; i++) {
        if (rows[i][uCol] === data.username) {
          orderSheet.getRange(i+1, payCol+1).setValue('paid');
          orderSheet.getRange(i+1, updCol+1).setValue(new Date().toISOString());
        }
      }
    } else {
      // Mark all matching GO claims as paid.
      const claimSheet = ss.getSheetByName(SHEET_JOINERS);
      const rows = claimSheet.getDataRange().getValues();
      const headers = rows[0];
      for (let i = 1; i < rows.length; i++) {
        if (rows[i][headers.indexOf('username')] === data.username && rows[i][headers.indexOf('go_id')] === data.go_id) {
          claimSheet.getRange(i+1, headers.indexOf('payment_status')+1).setValue('paid');
          claimSheet.getRange(i+1, headers.indexOf('updated_at')+1).setValue(new Date().toISOString());
        }
      }
    }
  }
```

- [ ] **Step 2: Syntax check**

Run:
```bash
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
```
Expected: `GS OK`

- [ ] **Step 3: Commit**

```bash
git add go-manager-backend.gs
git commit -m "Backend: confirm shop payments mark shop_orders paid"
```

---

## Task 5: Frontend — state + sync loaders

**Files:** Modify `index.html`

- [ ] **Step 1: Add state variables**

Find `let paymentProofs = [];` and add right after it:
```javascript
let listings = [];    // shop listings from backend
let shopOrders = [];  // shop orders from backend
```

- [ ] **Step 2: Fetch listings + orders in the sync Promise.all**

Find:
```javascript
    const [result, payResult] = await Promise.all([apiGet('getAllGOs'), apiGet('getPayments')]);
```
Replace with:
```javascript
    const [result, payResult, listResult, orderResult] = await Promise.all([
      apiGet('getAllGOs'), apiGet('getPayments'), apiGet('getListings'), apiGet('getShopOrders')
    ]);
```

- [ ] **Step 3: Populate state + render after the payments block**

Find (inside `syncFromBackend`, the payments block end):
```javascript
      renderPaymentProofs();
    }
  } catch(e) {
```
Replace with:
```javascript
      renderPaymentProofs();
    }
    if (listResult && Array.isArray(listResult.listings)) {
      listings = listResult.listings.filter(l => l && l.listing_id);
    }
    if (orderResult && Array.isArray(orderResult.shop_orders)) {
      shopOrders = orderResult.shop_orders.filter(o => o && o.order_id);
    }
    renderShopPage();
    renderAdminListings();
    renderShopOrders();
  } catch(e) {
```

- [ ] **Step 4: Syntax check**

Run:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
```
Expected: `JS OK` (functions `renderShopPage`/`renderAdminListings`/`renderShopOrders` are defined in later tasks; that's fine for syntax — they're referenced, not called at parse time. If runtime errors before those tasks land, they are added in Tasks 6/8/9.)

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "Frontend: load shop listings + orders on sync"
```

---

## Task 6: Frontend — Shop nav tab, page, and public render

**Files:** Modify `index.html`

- [ ] **Step 1: Add the nav tab**

Find:
```html
    <div class="nav-tab active" onclick="showPage('orders')">Group orders</div>
    <div class="nav-tab" onclick="showPage('lookup')">My orders</div>
```
Replace with:
```html
    <div class="nav-tab active" onclick="showPage('orders')">Group orders</div>
    <div class="nav-tab" onclick="showPage('shop')">Shop</div>
    <div class="nav-tab" onclick="showPage('lookup')">My orders</div>
```

- [ ] **Step 2: Add the page container**

Find `<div class="page active" id="page-orders"></div>` and add right after it:
```html
<div class="page" id="page-shop"></div>
```

- [ ] **Step 3: Update pageMap + route render**

Find:
```javascript
  const pageMap = { orders:0, lookup:1, rules:2, admin:3 };
```
Replace with:
```javascript
  const pageMap = { orders:0, shop:1, lookup:2, rules:3, admin:4 };
```
Then find:
```javascript
    if (id === 'orders') renderOrdersList();
```
Replace with:
```javascript
    if (id === 'orders') renderOrdersList();
    if (id === 'shop') renderShopPage();
```

- [ ] **Step 4: Add renderShopPage + order-view functions**

Add just before `function renderGoPreview(goId) {`:
```javascript
function renderShopPage() {
  const el = document.getElementById('page-shop');
  if (!el) return;
  const active = listings.filter(l => (l.status || 'active') === 'active');
  let html = '<p class="page-title">Shop</p><p class="page-sub">Leftover photocards, merch & albums. First come, first served.</p>';
  if (!active.length) {
    html += '<div style="text-align:center;color:var(--text3);padding:30px;">Nothing for sale right now.</div>';
    el.innerHTML = html;
    return;
  }
  html += '<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;">';
  active.forEach(l => {
    const qty = parseInt(l.qty) || 0;
    const sold = qty <= 0;
    html += `<div class="card" style="padding:0;overflow:hidden;${sold?'opacity:0.6;':'cursor:pointer;'}" ${sold?'':`onclick="openShopListing('${l.listing_id}')"`}>
      ${l.image_url ? `<img src="${l.image_url}" loading="lazy" style="width:100%;aspect-ratio:1;object-fit:cover;display:block;" onerror="this.style.display='none'">` : '<div style="width:100%;aspect-ratio:1;background:var(--surface2);"></div>'}
      <div style="padding:8px 10px;">
        <div style="font-size:11px;color:var(--text3);">${l.category || ''}</div>
        <div style="font-size:13px;font-weight:500;">${l.name}</div>
        <div style="display:flex;align-items:center;justify-content:space-between;margin-top:4px;">
          <span style="font-size:13px;font-weight:500;font-family:var(--mono);">$${(parseFloat(l.price)||0).toFixed(2)}</span>
          ${sold ? '<span class="badge badge-unpaid" style="font-size:10px;">Sold out</span>' : `<span style="font-size:11px;color:var(--teal-600);">${qty} left</span>`}
        </div>
      </div>
    </div>`;
  });
  html += '</div>';
  el.innerHTML = html;
}

let shopOrderQty = 1;
function openShopListing(listingId) {
  const l = listings.find(x => x.listing_id === listingId);
  if (!l) return;
  const max = parseInt(l.qty) || 0;
  shopOrderQty = 1;
  showModal(`
    <div style="font-size:16px;font-weight:500;margin-bottom:4px;">${l.name}</div>
    <div style="font-size:12px;color:var(--text3);margin-bottom:12px;">${l.category || ''} · $${(parseFloat(l.price)||0).toFixed(2)} · ${max} left</div>
    ${l.image_url ? `<img src="${l.image_url}" style="width:100%;border-radius:var(--radius);margin-bottom:12px;" onerror="this.style.display='none'">` : ''}
    ${l.note ? `<div style="font-size:12px;color:var(--text2);margin-bottom:12px;">${l.note}</div>` : ''}
    <div class="field"><label>Your username</label><input type="text" id="shop-order-user" placeholder="@username"></div>
    <div style="display:flex;align-items:center;gap:10px;margin:10px 0;">
      <span style="font-size:12px;color:var(--text2);">Qty:</span>
      <div class="qty-row">
        <button class="qty-btn" onclick="adjustShopQty(-1,${max})">−</button>
        <span id="shop-qty-val" style="min-width:24px;text-align:center;font-weight:500;">1</span>
        <button class="qty-btn" onclick="adjustShopQty(1,${max})">+</button>
      </div>
    </div>
    <div style="display:flex;gap:8px;margin-top:8px;">
      <button class="btn btn-primary" style="flex:1;justify-content:center;" onclick="submitShopOrder('${l.listing_id}')">Place order</button>
      <button class="btn btn-ghost" onclick="closeModal()">Cancel</button>
    </div>`);
}

function adjustShopQty(delta, max) {
  shopOrderQty = Math.max(1, Math.min(max, shopOrderQty + delta));
  const el = document.getElementById('shop-qty-val');
  if (el) el.textContent = shopOrderQty;
}
```

- [ ] **Step 5: Syntax check**

Run:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
```
Expected: `JS OK`

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "Frontend: Shop tab + public listing grid + order modal"
```

---

## Task 7: Frontend — submit shop order

**Files:** Modify `index.html`

- [ ] **Step 1: Add submitShopOrder**

Add right after `adjustShopQty` (from Task 6):
```javascript
function submitShopOrder(listingId) {
  const rawUser = (document.getElementById('shop-order-user')||{}).value || '';
  const username = rawUser.trim();
  if (!username) { toast('Enter your username.'); return; }
  const u = username.startsWith('@') ? username : '@' + username;
  const l = listings.find(x => x.listing_id === listingId);
  if (!l) return;
  const qty = shopOrderQty;
  if (!API_URL) { toast('Shop needs the backend configured.'); return; }
  apiPost('placeShopOrder', { listing_id: listingId, username: u, qty }).then(res => {
    if (res && res.ok) {
      // Reflect stock locally so the grid updates without a full sync.
      l.qty = (parseInt(l.qty) || 0) - qty;
      closeModal();
      renderShopPage();
      toast('Order placed — pay in My orders.');
      document.getElementById('lookup-input').value = u;
      showPage('lookup');
      doLookup();
    } else if (res && res.error === 'oversold') {
      toast('Only ' + (res.available || 0) + ' left — please retry.');
      l.qty = res.available || 0;
      renderShopPage();
    } else {
      toast('Could not place order.');
    }
  }).catch(() => toast('Could not place order.'));
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
git commit -m "Frontend: submit shop order with server-side stock guard"
```

---

## Task 8: Frontend — My orders integration (shop rows + pay)

**Files:** Modify `index.html`

**Context:** `doLookup` builds `rows` from GO claims. Add the buyer's shop-order rows so
they show in the table and feed `computeOwedByGO` (tagged `claim:'Secured'`,
`go_id:'shop'`). `submitGoPayment` must record `go_name:'Shop'` for shop payments, and
`confirmPayment` must mark local shop orders paid.

- [ ] **Step 1: Add shop rows in doLookup**

The shop rows MUST be added to `rows` **after** the `Object.values(allGOs).forEach(...)`
loop closes but **before** the table/owed are computed from `rows`. Find the line that
runs right after that loop:
```javascript
  document.getElementById('result-count').textContent = rows.length + ' active claim' + (rows.length!==1?'s':'');
```
Insert immediately BEFORE that line:
```javascript
  // Shop orders for this user — grouped under a "Shop" pseudo-GO.
  shopOrders.filter(o => o.username === u).forEach(o => {
    rows.push({
      go_id: 'shop', go: 'Shop', item: o.listing_name, detail: '',
      qty: parseInt(o.qty) || 1, price: parseFloat(o.unit_price) || 0,
      claim: 'Secured', payment: o.payment_status, fulfillment: o.fulfillment
    });
  });
```

- [ ] **Step 2: Record go_name for shop payments**

Find in `submitGoPayment`:
```javascript
    go_name: go ? go.name : '',
```
Replace with:
```javascript
    go_name: go ? go.name : (goId === 'shop' ? 'Shop' : ''),
```

- [ ] **Step 3: Mark local shop orders paid on confirm**

Find in `confirmPayment`, the block:
```javascript
  const go = Object.values(allGOs).find(g => g.name === p.go_name || g.id === p.go_id);
  if (go) {
    go.subItems.forEach(si => {
      if (si.sets) si.sets.forEach(s => Object.values(s.slots).forEach(slot => { if (slot && slot.user === p.username) slot.payment = 'paid'; }));
      if (si.claims) si.claims.forEach(c => { if (c.user === p.username) c.payment = 'paid'; });
    });
  }
```
Insert right after that block:
```javascript
  if (p.go_id === 'shop') {
    shopOrders.forEach(o => { if (o.username === p.username) o.payment_status = 'paid'; });
    renderShopOrders();
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
git commit -m "Frontend: shop orders in My orders + Pay panel (shop pseudo-GO)"
```

---

## Task 9: Frontend — admin listings management

**Files:** Modify `index.html`

- [ ] **Step 1: Add admin-home sections**

Find (in the admin home block):
```html
    <div class="admin-section">
      <div class="section-label">Active group orders</div>
      <div id="admin-go-list"></div>
    </div>
```
Insert right AFTER that `</div>`:
```html
    <div class="admin-section">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px;">
        <div class="section-label" style="margin:0;">Shop listings</div>
        <button class="btn btn-sm btn-primary" onclick="openListingModal()">+ New listing</button>
      </div>
      <div id="admin-listings-list"></div>
    </div>
    <div class="admin-section">
      <div class="admin-section-title">Shop orders</div>
      <div class="card"><div class="table-wrap"><table>
        <thead><tr><th>Buyer</th><th>Item</th><th>Qty</th><th>Amount</th><th>Payment</th><th>Fulfillment</th></tr></thead>
        <tbody id="shop-orders-tbody"><tr><td colspan="6" style="text-align:center;color:var(--text3);padding:20px;">No shop orders.</td></tr></tbody>
      </table></div></div>
    </div>
```

- [ ] **Step 2: Render listings + the new/edit modal + save/hide**

Add near `renderPaymentProofs` (after that function):
```javascript
function renderAdminListings() {
  const el = document.getElementById('admin-listings-list');
  if (!el) return;
  const active = listings.filter(l => (l.status || 'active') === 'active');
  if (!active.length) { el.innerHTML = '<div style="font-size:12px;color:var(--text3);padding:8px 0;">No listings yet.</div>'; return; }
  el.innerHTML = active.map(l => `
    <div class="card-sm" style="display:flex;align-items:center;gap:10px;margin-bottom:6px;">
      ${l.image_url ? `<img src="${l.image_url}" style="width:40px;height:40px;border-radius:6px;object-fit:cover;" onerror="this.style.display='none'">` : ''}
      <div style="flex:1;">
        <div style="font-size:13px;font-weight:500;">${l.name} <span style="font-size:11px;color:var(--text3);">${l.category||''}</span></div>
        <div style="font-size:12px;color:var(--text3);">$${(parseFloat(l.price)||0).toFixed(2)} · ${parseInt(l.qty)||0} in stock</div>
      </div>
      <button class="btn btn-sm btn-ghost" onclick="openListingModal('${l.listing_id}')">Edit</button>
      <button class="btn btn-sm btn-ghost" style="color:var(--red-400);" onclick="hideListing('${l.listing_id}')">Hide</button>
    </div>`).join('');
}

function openListingModal(listingId) {
  const l = listingId ? listings.find(x => x.listing_id === listingId) : null;
  showModal(`
    <div style="font-size:16px;font-weight:500;margin-bottom:16px;">${l ? 'Edit' : 'New'} listing</div>
    <div class="field"><label>Name</label><input type="text" id="lst-name" value="${l ? l.name : ''}"></div>
    <div class="field-row">
      <div class="field"><label>Category</label>
        <select id="lst-category">
          ${['Photocard','Merch','Album'].map(c => `<option ${l && l.category===c?'selected':''}>${c}</option>`).join('')}
        </select>
      </div>
      <div class="field"><label>Price (USD)</label><input type="number" id="lst-price" step="0.01" value="${l ? l.price : 0}"></div>
    </div>
    <div class="field-row">
      <div class="field"><label>Quantity</label><input type="number" id="lst-qty" min="0" value="${l ? l.qty : 1}"></div>
      <div class="field"><label>Image URL</label><input type="text" id="lst-image" placeholder="https://..." value="${l ? (l.image_url||'') : ''}"></div>
    </div>
    <div class="field"><label>Note (optional)</label><input type="text" id="lst-note" value="${l ? (l.note||'') : ''}"></div>
    <div style="display:flex;gap:8px;margin-top:8px;">
      <button class="btn btn-primary" style="flex:1;justify-content:center;" onclick="saveListing(${l ? `'${l.listing_id}'` : 'null'})">Save</button>
      <button class="btn btn-ghost" onclick="closeModal()">Cancel</button>
    </div>`);
}

function saveListing(listingId) {
  const data = {
    name: document.getElementById('lst-name').value.trim(),
    category: document.getElementById('lst-category').value,
    price: parseFloat(document.getElementById('lst-price').value) || 0,
    qty: parseInt(document.getElementById('lst-qty').value) || 0,
    image_url: document.getElementById('lst-image').value.trim(),
    note: document.getElementById('lst-note').value.trim()
  };
  if (!data.name) { toast('Enter a name.'); return; }
  if (listingId) {
    data.listing_id = listingId;
    const local = listings.find(x => x.listing_id === listingId);
    if (local) Object.assign(local, data);
    if (API_URL) apiPost('updateListing', data).catch(()=>{});
  } else {
    const tempId = 'lst_' + Date.now();
    listings.push({ listing_id: tempId, status: 'active', created_at: new Date().toISOString(), ...data });
    if (API_URL) apiPost('createListing', data).catch(()=>{});
  }
  closeModal();
  renderAdminListings();
  renderShopPage();
  toast('Listing saved.');
}

function hideListing(listingId) {
  if (!confirm('Hide this listing from the shop?')) return;
  const local = listings.find(x => x.listing_id === listingId);
  if (local) local.status = 'hidden';
  if (API_URL) apiPost('deleteListing', { listing_id: listingId }).catch(()=>{});
  renderAdminListings();
  renderShopPage();
  toast('Listing hidden.');
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
git commit -m "Frontend: admin shop listings management (CRUD)"
```

---

## Task 10: Frontend — admin shop orders table

**Files:** Modify `index.html`

- [ ] **Step 1: Add renderShopOrders + handlers**

Add after `hideListing` (from Task 9):
```javascript
function renderShopOrders() {
  const tbody = document.getElementById('shop-orders-tbody');
  if (!tbody) return;
  if (!shopOrders.length) {
    tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;color:var(--text3);padding:20px;">No shop orders.</td></tr>';
    return;
  }
  tbody.innerHTML = shopOrders.map(o => {
    const amt = (parseFloat(o.unit_price)||0) * (parseInt(o.qty)||1);
    const nf = nextFulfillment(o.fulfillment);
    const pf = prevFulfillment(o.fulfillment);
    return `<tr>
      <td style="font-weight:500;">${o.username}</td>
      <td style="font-size:12px;">${o.listing_name}</td>
      <td>${o.qty}</td>
      <td style="font-family:var(--mono);">$${amt.toFixed(2)}</td>
      <td><span class="badge ${o.payment_status==='paid'?'badge-paid':'badge-unpaid'}" style="cursor:pointer;" onclick="toggleShopOrderPayment('${o.order_id}')">${o.payment_status==='paid'?'Paid':'Unpaid'}</span></td>
      <td><div style="display:flex;align-items:center;gap:6px;">
        <span class="badge ${fulfillBadge(o.fulfillment)}">${o.fulfillment}</span>
        ${pf ? `<button class="btn btn-sm btn-ghost" style="font-size:11px;padding:3px 8px;" title="Back to ${pf}" onclick="advanceShopFulfill('${o.order_id}','prev')">←</button>` : ''}
        ${nf ? `<button class="btn btn-sm btn-ghost" style="font-size:11px;padding:3px 8px;" onclick="advanceShopFulfill('${o.order_id}')">→ ${nf}</button>` : ''}
      </div></td>
    </tr>`;
  }).join('');
}

function toggleShopOrderPayment(orderId) {
  const o = shopOrders.find(x => x.order_id === orderId);
  if (!o) return;
  o.payment_status = o.payment_status === 'paid' ? 'unpaid' : 'paid';
  if (API_URL) apiPost('updateShopOrder', { order_id: orderId, payment_status: o.payment_status });
  renderShopOrders();
  toast(o.listing_name + ': ' + (o.payment_status==='paid'?'Paid':'Unpaid'));
}

function advanceShopFulfill(orderId, dir) {
  const o = shopOrders.find(x => x.order_id === orderId);
  if (!o) return;
  const nf = dir === 'prev' ? prevFulfillment(o.fulfillment) : nextFulfillment(o.fulfillment);
  if (!nf) return;
  o.fulfillment = nf;
  if (API_URL) apiPost('updateShopOrder', { order_id: orderId, fulfillment: nf });
  renderShopOrders();
  toast('Fulfillment: ' + nf);
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
git commit -m "Frontend: admin shop orders table (payment toggle + fulfillment)"
```

---

## Task 11: Frontend — render shop views when admin panel opens

**Files:** Modify `index.html`

**Context:** `showAdminPanel('home')` calls `renderAdminGOList()`. Add the shop renders so
the admin sections populate when the admin opens home.

- [ ] **Step 1: Render shop admin views on home**

Find:
```javascript
  if (panel === 'home') renderAdminGOList();
```
Replace with:
```javascript
  if (panel === 'home') { renderAdminGOList(); renderAdminListings(); renderShopOrders(); }
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
git commit -m "Frontend: populate shop admin views on admin home"
```

---

## Task 12: Redeploy backend, deploy frontend, manual verification

**Files:** none (deploy + manual).

- [ ] **Step 1: Push frontend**

```bash
git push
```

- [ ] **Step 2: Redeploy the Apps Script backend**

The backend has new endpoints and sheets. In the Apps Script editor: paste the updated
`go-manager-backend.gs`, then **Deploy → Manage deployments → edit → New version →
Deploy**. (User action.)

- [ ] **Step 3: Wait for the live frontend deploy**

```bash
for i in $(seq 1 25); do n=$(curl -s "https://jhcui18.github.io/go-manager/index.html?cb=$(date +%s%N)" | grep -c "function renderShopPage"); if [ "$n" -gt 0 ]; then echo "LIVE after ~$((i*10))s"; break; fi; sleep 10; done
```
Expected: `LIVE after ~Ns`

- [ ] **Step 4: Manual check — admin creates a listing**

Hard-refresh. Admin → **+ New listing** → fill name, category, price, qty=2, image URL →
Save. Confirm it appears in Shop listings and on the **Shop** tab with "2 left".

- [ ] **Step 5: Manual check — buyer orders**

On the **Shop** tab, open the listing → enter a username, qty 1 → **Place order**.
Confirm: toast, routed to My orders showing the shop item with an owed amount, and the
Shop tab now shows "1 left". Order once more to hit 0 → shows **Sold out**.

- [ ] **Step 6: Manual check — pay + confirm**

In My orders, use the **Shop** Pay panel → "I paid". Admin → Pending payment proofs →
**Confirm**. Verify the Shop order flips to **Paid** in the admin Shop orders table, and
the buyer's My orders shows Paid.

- [ ] **Step 7: Manual check — fulfillment + oversell**

In admin Shop orders, step fulfillment →/←. Optionally, in two tabs, order the last unit
in both to confirm the second gets the "Only N left" oversold message.

- [ ] **Step 8: Final commit (only if manual checks surfaced fixes)**

```bash
git add index.html go-manager-backend.gs && git commit -m "Fix shop issue found in manual verification" && git push
```

---

## Notes / deferred (from spec)

- No multi-item cart — each listing ordered separately; My orders sums for payment.
- No file upload — pasted image URL only.
- Shipping handled by the separate unified "Request shipping" flow (next project); shop
  orders carry a `fulfillment` status so they reach Ready and join the buyer's bundle.
- Soft-delete only (Hide); no hard-delete in v1.
