# Lazy Admin Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the admin panel load lazily — login fetches only light metadata (`getGOsList`) + background `getPayments`, each area loads its data when its sub-tab opens, and a GO's claims load when you open its Manage view. Eliminates the ~2.2 MB `getAllGOs` login read (slow + intermittently fails).

**Architecture:** Single-file `index.html` (vanilla JS). Frontend-only — reuses existing backend endpoints (`getGOsList`, `getPayments`, `getGOBoard`, `getListings`, `getShopOrders`, `getStoreOrders`, `getShipping`). No redeploy.

**Tech Stack:** Vanilla JS, Google Apps Script backend (unchanged), GitHub Pages.

## Global Constraints

- **Frontend-only. No backend edits, no redeploy.**
- Verify every change by JS-parsing all `<script>` blocks:
  `node -e "const fs=require('fs');const h=fs.readFileSync('index.html','utf8');const re=/<script>([\s\S]*?)<\/script>/g;let m,ok=true;while((m=re.exec(h))){try{new Function(m[1]);}catch(e){ok=false;console.log('PARSE ERROR:',e.message);}}console.log(ok?'JS parses OK':'FAILED');"`
- No test framework — JS-parse + logic reasoning are the gates. Browser/network checks are deferred to the human.
- Preserve existing behavior for buyers and for admin features not named here.
- `loadGOClaims(goId)` already exists, is reusable for admin as-is (rebuilds one GO's sub-items from `getGOBoard`, sets `claimsLoaded[goId]`), and must not be duplicated.
- The task ordering keeps the app working after each task: Tasks 1–2 change UI/rendering while login is still eager (so claims are present); Task 3 flips login to lazy last.

---

### Task 1: Admin sub-tab shell + lazy section loaders

**Files:**
- Modify: `index.html` — the `#admin-home` block (~lines 323–383), `showAdminPanel` (~3080).

**Interfaces:**
- Produces: `showAdminTab(name)`, `loadAdminShop()`, `loadAdminStore()`, `loadAdminShipping()`, and module vars `adminActiveTab`, `adminShopLoaded`, `adminStoreLoaded`, `adminShippingLoaded`. Later tasks rely on these lazy loaders being the data source for their tabs.

- [ ] **Step 1: Add tab-bar CSS**

Add near the other admin CSS (after `.admin-section-title { … }`, ~line 85):
```css
  .admin-tabs { display:flex; gap:4px; overflow-x:auto; border-bottom:1.5px solid var(--border); margin:8px 0 16px; }
  .admin-tab { flex:0 0 auto; background:none; border:none; padding:8px 12px; font-size:13px; font-weight:500; color:var(--text3); cursor:pointer; border-bottom:2px solid transparent; }
  .admin-tab.active { color:var(--text); border-bottom-color:var(--accent); }
```

- [ ] **Step 2: Restructure `#admin-home` into a tab bar + five tab panels**

Replace the six stacked `admin-section` blocks inside `#admin-home` (the "Active group orders", "Shop listings", "Shop orders", "My store orders", "Pending payment proofs", "Shipping queue" sections — everything after the `<p class="page-sub">…</p>` line and before the closing `</div>` of `#admin-home`) with:
```html
    <div class="admin-tabs">
      <button class="admin-tab" id="admin-tab-gos" onclick="showAdminTab('gos')">GOs</button>
      <button class="admin-tab" id="admin-tab-shop" onclick="showAdminTab('shop')">Shop</button>
      <button class="admin-tab" id="admin-tab-store" onclick="showAdminTab('store')">Store</button>
      <button class="admin-tab" id="admin-tab-payments" onclick="showAdminTab('payments')">Payments</button>
      <button class="admin-tab" id="admin-tab-shipping" onclick="showAdminTab('shipping')">Shipping</button>
    </div>

    <div class="admin-tabpanel" id="admin-tabpanel-gos">
      <div class="admin-section">
        <div class="section-label">Active group orders</div>
        <div id="admin-go-list"></div>
      </div>
    </div>

    <div class="admin-tabpanel" id="admin-tabpanel-shop" style="display:none;">
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
    </div>

    <div class="admin-tabpanel" id="admin-tabpanel-store" style="display:none;">
      <div class="admin-section">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px;">
          <div class="section-label" style="margin:0;">My store orders</div>
          <button class="btn btn-sm btn-primary" onclick="openStoreOrderModal()">+ Add store order</button>
        </div>
        <div id="store-orders-list"></div>
      </div>
    </div>

    <div class="admin-tabpanel" id="admin-tabpanel-payments" style="display:none;">
      <div class="admin-section">
        <div class="admin-section-title">Pending payment proofs</div>
        <div class="card"><div class="table-wrap"><table>
          <thead><tr><th>Username</th><th>GO</th><th>Amount</th><th>Method</th><th>Ref</th><th>Submitted</th><th>Action</th></tr></thead>
          <tbody id="payment-proofs-tbody"><tr><td colspan="7" style="text-align:center;color:var(--text3);padding:20px;">No pending proofs.</td></tr></tbody>
        </table></div></div>
      </div>
    </div>

    <div class="admin-tabpanel" id="admin-tabpanel-shipping" style="display:none;">
      <div class="admin-section">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px;">
          <div class="admin-section-title" style="margin:0;">Shipping queue</div>
          <button class="btn btn-sm" onclick="refreshShippingQueue()">↺ Refresh</button>
        </div>
        <div class="card"><div class="table-wrap"><table>
          <thead><tr><th>Username</th><th>Items ready</th><th>Cards</th><th>EMS fee</th><th>Dom. fee</th><th>Total</th><th>Address</th><th></th></tr></thead>
          <tbody id="shipping-queue-tbody"><tr><td colspan="8" style="text-align:center;color:var(--text3);padding:20px;">No shipping requests yet.</td></tr></tbody>
        </table></div></div>
      </div>
    </div>
```
(All element IDs — `admin-go-list`, `admin-listings-list`, `shop-orders-tbody`, `store-orders-list`, `payment-proofs-tbody`, `shipping-queue-tbody` — are unchanged, so existing render functions keep working.)

- [ ] **Step 3: Add tab controller + lazy loaders**

Add near `showAdminPanel` (~3080):
```javascript
let adminActiveTab = 'gos';
let adminShopLoaded = false, adminStoreLoaded = false, adminShippingLoaded = false;

function showAdminTab(name) {
  adminActiveTab = name;
  ['gos','shop','store','payments','shipping'].forEach(t => {
    const panel = document.getElementById('admin-tabpanel-' + t);
    if (panel) panel.style.display = t === name ? 'block' : 'none';
    const tab = document.getElementById('admin-tab-' + t);
    if (tab) tab.classList.toggle('active', t === name);
  });
  if (name === 'shop') loadAdminShop();
  else if (name === 'store') loadAdminStore();
  else if (name === 'shipping') loadAdminShipping();
  else if (name === 'payments') renderPaymentProofs(); // data arrives via background getPayments (Task 3)
  else if (name === 'gos') renderAdminGOList();
}

async function loadAdminShop() {
  renderAdminListings(); renderShopOrders();
  if (adminShopLoaded || !API_URL) return;
  try {
    const [lr, or] = await Promise.all([apiGet('getListings'), apiGet('getShopOrders')]);
    if (lr && Array.isArray(lr.listings)) listings = lr.listings.filter(l => l && l.listing_id).map(l => ({ ...l, variants: tryParse(l.variants, []) }));
    if (or && Array.isArray(or.shop_orders)) shopOrders = or.shop_orders.filter(o => o && o.order_id);
    adminShopLoaded = true;
    renderAdminListings(); renderShopOrders();
  } catch (e) { /* reopening the tab retries */ }
}

async function loadAdminStore() {
  renderStoreOrders();
  if (adminStoreLoaded || !API_URL) return;
  try {
    const sr = await apiGet('getStoreOrders');
    if (sr && Array.isArray(sr.store_orders)) { storeOrders = sr.store_orders.filter(o => o && o.order_id); adminStoreLoaded = true; renderStoreOrders(); }
  } catch (e) {}
}

async function loadAdminShipping() {
  renderShippingQueue();
  if (adminShippingLoaded || !API_URL) return;
  try {
    const sr = await apiGet('getShipping');
    if (sr && Array.isArray(sr.requests)) { shippingRequests = sr.requests.filter(r => r && r.request_id).map(r => ({ ...r, items: tryParse(r.items, []), shipped: r.shipped === true || r.shipped === 'true' })); adminShippingLoaded = true; renderShippingQueue(); }
  } catch (e) {}
}
```

- [ ] **Step 4: Point `showAdminPanel('home')` at the active tab**

Replace the `if (panel === 'home')` line in `showAdminPanel`:
```javascript
  if (panel === 'home') showAdminTab(adminActiveTab);
```
(Removes the eager `renderAdminGOList(); renderAdminListings(); renderShopOrders(); renderStoreOrders();` — each now renders when its tab is shown.)

- [ ] **Step 5: JS-parse**

Run the Global-Constraints JS-parse command. Expected: `JS parses OK`.

- [ ] **Step 6: Commit**
```bash
git add index.html
git commit -m "Admin: sub-tab layout (GOs/Shop/Store/Payments/Shipping) + lazy section loaders"
```

Note (manual, deferred to human): with login still eager (Task 3 not yet done), the tabs reorganize the existing data; lazy loaders are no-ops because the data is already present. Full lazy behavior lands in Task 3.

---

### Task 2: Collected-only GO cards + async GO Manage + async confirm payment

**Files:**
- Modify: `index.html` — `renderAdminGOList` (~2198), `openGODetail` (~2241), `refreshCurrentGO` (~2255), `confirmPayment` (~4451).

**Interfaces:**
- Consumes: `loadGOClaims(goId)` (existing), `claimsLoaded` map.
- These changes are safe while login is still eager (claims present → `loadGOClaims` is a quick reuse; `claimsLoaded[goId]` already true so it no-ops).

- [ ] **Step 1: `renderAdminGOList` — keep `collected`, drop counts + expected**

In `renderAdminGOList` (~2198), remove the per-type `meta` count computations and the `expected`/`goExpected` usage. Replace the card body so it shows only name, badges, closed flag, and collected:
```javascript
function renderAdminGOList() {
  const el = document.getElementById('admin-go-list');
  if (!el) return;
  el.innerHTML = Object.values(allGOs).map(go => {
    const typeLabel = go.type==='photocard'?'Photocard':go.type==='album'?'Album':'Merch';
    const badgeClass = go.type==='photocard'?'badge-set':go.type==='album'?'badge-fcfs':'badge-waitlist';
    const collected = (paymentProofs || []).filter(p => p.go_id === go.id && p.status === 'confirmed').reduce((a, p) => a + (parseFloat(p.amount) || 0), 0);
    const collectedHtml = collected > 0 ? ` · <span style="color:var(--teal-600);font-weight:500;">$${collected.toFixed(2)} collected</span>` : '';
    return `<div class="card-sm" style="margin-bottom:8px;">
      <div style="display:flex;align-items:center;justify-content:space-between;">
        <div>
          <div style="font-weight:500;font-size:13px;">${go.name}</div>
          <div style="font-size:11px;color:var(--text3);margin-top:2px;"><span class="badge ${badgeClass}" style="font-size:10px;padding:2px 7px;margin-right:6px;">${typeLabel}</span>${go.status==='closed'?'<span class="badge badge-waitlist" style="font-size:10px;padding:2px 7px;margin-right:6px;">Closed</span>':''}${collectedHtml}</div>
        </div>
        <button class="btn btn-sm" onclick="openGODetail('${go.id}')">Manage</button>
      </div>
    </div>`;
  }).join('');
}
```
(`goExpected` stays defined — it is now used only inside the Manage view, Step 2.)

- [ ] **Step 2: `openGODetail` — load that GO's claims first, show counts + expected in detail**

Make `openGODetail` async and load claims before rendering:
```javascript
async function openGODetail(goId) {
  if (!claimsLoaded[goId] && API_URL) {
    showLoadingOverlay(true, 'Loading group order…');
    try { await loadGOClaims(goId); }
    catch (e) { showLoadingOverlay(false); toast('Couldn’t load this group order — please try again.'); return; }
    showLoadingOverlay(false);
  }
  currentGO = allGOs[goId];
  document.getElementById('detail-breadcrumb').textContent = currentGO.name;
  document.getElementById('detail-go-title').textContent = currentGO.name;
  const typeLabel = currentGO.type==='photocard'?'Photocard':currentGO.type==='album'?'Album':'Merch';
  const badgeClass = currentGO.type==='photocard'?'badge-set':currentGO.type==='album'?'badge-fcfs':'badge-waitlist';
  document.getElementById('detail-badges').innerHTML = `<span class="badge ${badgeClass}">${typeLabel}</span>`;
  showAdminPanel('go-detail');
  renderDetailContent();
}
```

In `renderDetailContent` (find where the detail header renders — search for `detail-go-title` usage or the start of that function), add a one-line summary showing collected/expected for the current GO. Locate `function renderDetailContent()` and insert, at the top of its output (or into an existing header container), a computed line:
```javascript
  // Money summary for this GO (claims are loaded here, so goExpected is valid).
  const _exp = goExpected(currentGO);
  const _col = (paymentProofs || []).filter(p => p.go_id === currentGO.id && p.status === 'confirmed').reduce((a, p) => a + (parseFloat(p.amount) || 0), 0);
```
Then render `$_col collected of $_exp expected` in the detail header area (match the surrounding markup/style; place it near `detail-go-title`). If `renderDetailContent` writes into a known container element, append this as a small `<div style="font-size:12px;color:var(--text3);">`. Keep it minimal and consistent with existing detail styling.

- [ ] **Step 3: `refreshCurrentGO` — refresh just this GO, not a full sync**

Replace the body of `refreshCurrentGO` (~2255) so it reloads only the current GO's claims:
```javascript
async function refreshCurrentGO(silent) {
  if (!currentGO) return;
  const goId = currentGO.id;
  claimsLoaded[goId] = false;               // force a fresh getGOBoard (its cache is busted by writes)
  if (!silent) showLoadingOverlay(true, 'Refreshing…');
  try { await loadGOClaims(goId); } catch (e) {}
  if (!silent) showLoadingOverlay(false);
  currentGO = allGOs[goId] || currentGO;
  renderDetailContent();
}
```

- [ ] **Step 4: `confirmPayment` — ensure the target GO's claims are loaded first**

Make `confirmPayment` async and load the target GO's data before computing owed units:
```javascript
async function confirmPayment(id) {
  const p = findProof(id);
  if (!p) return;
  if (p.go_id !== 'shop' && !claimsLoaded[p.go_id] && API_URL) {
    showLoadingOverlay(true, 'Loading order…');
    try { await loadGOClaims(p.go_id); }
    catch (e) { showLoadingOverlay(false); toast('Couldn’t load this order — please try again.'); return; }
    showLoadingOverlay(false);
  } else if (p.go_id === 'shop' && !adminShopLoaded && API_URL) {
    showLoadingOverlay(true, 'Loading orders…');
    try { await loadAdminShop(); } catch (e) {}
    showLoadingOverlay(false);
  }
  const units = paymentOwedUnits(p.username, p.go_id);
  // …rest of the existing confirmPayment body unchanged (securedTotal, totalPaid, modal)…
}
```
Keep the entire remainder of `confirmPayment` (from `const securedTotal = …` through the `showModal(...)` call) exactly as it is today.

- [ ] **Step 5: JS-parse** → `JS parses OK`.

- [ ] **Step 6: Commit**
```bash
git add index.html
git commit -m "Admin: collected-only GO cards; load a GO's claims on Manage/confirm (async)"
```

---

### Task 3: Flip admin login to lazy (getGOsList + background getPayments)

**Files:**
- Modify: `index.html` — `syncFromBackend` (~4757 admin branch and the `!isAdmin` fallback ~4772).

**Interfaces:**
- Consumes: everything from Tasks 1–2 (tabs, lazy loaders, async Manage/confirm, collected-only cards).
- After this task the admin no longer loads `getAllGOs` at login.

- [ ] **Step 1: Admin branch fetches only `getGOsList`; background-load payments**

In `syncFromBackend`, change the admin branch so it mirrors the joiner branch (single `getGOsList`) and defers payments to a non-blocking follow-up. Replace the `if (isAdmin) { …11-call batch… } else { …getGOsList… }` structure so BOTH admin and joiner fetch `getGOsList`, and only the *post-processing* differs. Concretely, make the fetch:
```javascript
    let result, payResult, listResult, orderResult, shipResult, storeResult, gcResult, securedResult, closedResult, deadlineResult, payDueResult;
    // Admin and joiner both land on the light metadata call now. Admin's per-area data
    // (payments, shop, store, shipping, per-GO claims) loads lazily via the sub-tabs and
    // Manage view. Payments loads in the background just below (for the "collected" sums).
    try { result = await apiGet('getGOsList'); } catch (e) { result = undefined; }
```
Leave the existing `let gosData = result;` and the fallback line, but **un-gate the fallback for admin** so a missing `getGOsList` still recovers:
```javascript
    let gosData = result;
    if ((!gosData || !gosData.gos)) {
      try { gosData = await apiGet('getAllGOs'); } catch (e) {}
    }
```

- [ ] **Step 2: Kick off the background payments load**

After the GO-rebuild block completes and `renderAdminGOList()` is called (the sync already calls `renderOrdersList(); renderAdminGOList();` after building `allGOs`), add a non-blocking payments fetch for admin. Place this right after the existing `renderAdminGOList();` call inside `syncFromBackend`:
```javascript
      if (isAdmin && API_URL) {
        // Background: payments drive the "$X collected" card line + the Payments tab.
        apiGet('getPayments').then(pr => {
          if (pr && Array.isArray(pr.payments)) {
            paymentProofs = pr.payments.filter(p => p && p.payment_id).map(p => ({
              payment_id: p.payment_id, username: p.username, go_id: p.go_id, go_name: p.go_name,
              amount: p.amount, method: p.method, transaction_id: p.transaction_id,
              proof_url: p.proof_url, status: p.status || 'pending', created_at: p.created_at, note: p.note || ''
            }));
            renderAdminGOList();
            renderPaymentProofs();
          }
        }).catch(()=>{});
      }
```

- [ ] **Step 3: Confirm the eager batch is gone**

Verify the old admin 11-call `Promise.allSettled([...getAllGOs...])` no longer runs at login. The `payResult`/`listResult`/… destructured vars remain declared (so the downstream `if (payResult && …)` guards are harmless no-ops for admin now). Do not remove those guarded blocks — they still run for any path that populates those vars, and leaving them avoids touching buyer logic.

- [ ] **Step 4: JS-parse** → `JS parses OK`.

- [ ] **Step 5: Commit**
```bash
git add index.html
git commit -m "Admin login: fetch only getGOsList + background getPayments (drop 2.2MB getAllGOs)"
```

Note (manual, deferred to human): after this, verify in the browser — admin login renders the GOs tab in ~1s with no `getAllGOs` call; `$X collected` fills in a moment later; opening Shop/Store/Shipping tabs each fires one fetch; opening a GO's Manage loads its claims and shows counts + expected; confirming a payment for an un-opened GO still marks the right items.

---

## Post-implementation

- **Whole-branch review** (final), then push `main` (frontend-only, no redeploy).
- Live browser QA per the deferred notes above.
