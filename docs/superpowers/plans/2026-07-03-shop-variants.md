# Shop Listing Variants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Shop listing offer named variants (album versions / members), each with its own stock; buyers pick a variant to order. Simple single-quantity listings still work.

**Architecture:** Add a `variants` column (JSON) to `listings` and a `variant` column to `shop_orders`; `placeShopOrder` decrements the chosen variant's stock server-side. Frontend adds a variants textarea to the listing form and a variant tile picker to the order view. New columns go at the END of each sheet schema so positional appends stay aligned.

**Tech Stack:** Vanilla single-file HTML/CSS/JS (`index.html`), Apps Script + Sheets (`go-manager-backend.gs`), GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-07-03-shop-variants-design.md`

---

## Verification approach (read first)

No test framework. Verify each task with syntax checks:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
```
Manual browser check after deploy (Task 6). Backend changes need an **Apps Script redeploy**. (The Shop backend is new/likely not deployed yet, so fresh `bootstrapSheets` creates the sheets with the full schema; if the `listings`/`shop_orders` sheets already exist without the new columns, add a `variants` / `variant` header cell to each, or delete those tabs so bootstrap recreates them.)

## Naming (keep consistent)

- Listing object gains `variants`: array `[{name, qty}]` (parsed from JSON on the frontend).
- Order gains `variant`: the chosen variant name (string; empty for simple listings).
- Helper: `listingStock(l)` = sum of variant qtys if `l.variants` non-empty, else `parseInt(l.qty)`.
- Buyer selection state: module var `shopOrderVariant` (selected variant name or '').

---

## Task 1: Backend — listings `variants` column + CRUD

**Files:** Modify `go-manager-backend.gs`

- [ ] **Step 1: Add `variants` to the listings schema (end)**

Find:
```javascript
  ensureSheet(ss, SHEET_LISTINGS,    ['listing_id','name','category','price','image_url','qty','note','status','created_at']);
```
Replace with:
```javascript
  ensureSheet(ss, SHEET_LISTINGS,    ['listing_id','name','category','price','image_url','qty','note','status','created_at','variants']);
```

- [ ] **Step 2: Persist variants in createListing**

Find:
```javascript
  sheet.appendRow([
    id, data.name || '', data.category || '', data.price || 0, data.image_url || '',
    data.qty || 0, data.note || '', 'active', new Date().toISOString()
  ]);
  return { ok: true, listing_id: id };
```
Replace with:
```javascript
  sheet.appendRow([
    id, data.name || '', data.category || '', data.price || 0, data.image_url || '',
    data.qty || 0, data.note || '', 'active', new Date().toISOString(),
    JSON.stringify(data.variants || [])
  ]);
  return { ok: true, listing_id: id };
```

- [ ] **Step 3: Persist variants in updateListing**

Find:
```javascript
function updateListing(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_LISTINGS);
  const fields = {};
  ['name','category','price','image_url','qty','note','status'].forEach(k => {
    if (data[k] !== undefined) fields[k] = data[k];
  });
  updateRowWhere(sheet, 'listing_id', data.listing_id, fields);
  return { ok: true };
}
```
Replace with:
```javascript
function updateListing(data) {
  const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SHEET_LISTINGS);
  const fields = {};
  ['name','category','price','image_url','qty','note','status'].forEach(k => {
    if (data[k] !== undefined) fields[k] = data[k];
  });
  if (data.variants !== undefined) fields.variants = JSON.stringify(data.variants);
  updateRowWhere(sheet, 'listing_id', data.listing_id, fields);
  return { ok: true };
}
```

- [ ] **Step 4: Syntax check + commit**

```bash
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
git add go-manager-backend.gs && git commit -m "Backend: listings variants column + CRUD"
```

---

## Task 2: Backend — variant-aware placeShopOrder + shop_orders variant column

**Files:** Modify `go-manager-backend.gs`

- [ ] **Step 1: Add `variant` to shop_orders schema (end)**

Find:
```javascript
  ensureSheet(ss, SHEET_SHOP_ORDERS, ['order_id','listing_id','listing_name','username','email','qty','unit_price','payment_status','fulfillment','created_at','updated_at']);
```
Replace with:
```javascript
  ensureSheet(ss, SHEET_SHOP_ORDERS, ['order_id','listing_id','listing_name','username','email','qty','unit_price','payment_status','fulfillment','created_at','updated_at','variant']);
```

- [ ] **Step 2: Make placeShopOrder variant-aware**

Find the whole `for` loop body inside `placeShopOrder`:
```javascript
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
```
Replace with:
```javascript
  const varCol = headers.indexOf('variants');
  for (let i = 1; i < rows.length; i++) {
    if (rows[i][idCol] === data.listing_id) {
      const orderSheet = ss.getSheetByName(SHEET_SHOP_ORDERS);
      const oid = 'sho_' + Date.now() + '_' + Math.random().toString(36).slice(2,6);
      const now = new Date().toISOString();
      if (data.variant) {
        // Variant listing: guard + decrement the chosen variant's stock.
        let variants = [];
        try { variants = JSON.parse(rows[i][varCol] || '[]'); } catch (e) { variants = []; }
        const v = variants.find(x => x.name === data.variant);
        const avail = v ? (parseInt(v.qty) || 0) : 0;
        if (!v || avail < want) return { ok: false, error: 'oversold', available: avail };
        v.qty = avail - want;
        listSheet.getRange(i+1, varCol+1).setValue(JSON.stringify(variants));
        orderSheet.appendRow([
          oid, data.listing_id, rows[i][nameCol], data.username, data.email || '',
          want, rows[i][priceCol], 'unpaid', 'Pending', now, now, data.variant
        ]);
        return { ok: true, order_id: oid };
      }
      // Simple listing: single qty column.
      const have = parseInt(rows[i][qtyCol]) || 0;
      if (have < want) return { ok: false, error: 'oversold', available: have };
      listSheet.getRange(i+1, qtyCol+1).setValue(have - want);
      orderSheet.appendRow([
        oid, data.listing_id, rows[i][nameCol], data.username, data.email || '',
        want, rows[i][priceCol], 'unpaid', 'Pending', now, now, ''
      ]);
      return { ok: true, order_id: oid };
    }
  }
```

- [ ] **Step 3: Syntax check + commit**

```bash
cp go-manager-backend.gs /tmp/go_backend.js && node --check /tmp/go_backend.js && echo "GS OK"
git add go-manager-backend.gs && git commit -m "Backend: variant-aware placeShopOrder + shop_orders variant column"
```

---

## Task 3: Frontend — parse variants on sync + admin listing form

**Files:** Modify `index.html`

- [ ] **Step 1: Parse `variants` JSON when loading listings**

Find:
```javascript
    if (listResult && Array.isArray(listResult.listings)) {
      listings = listResult.listings.filter(l => l && l.listing_id);
    }
```
Replace with:
```javascript
    if (listResult && Array.isArray(listResult.listings)) {
      listings = listResult.listings.filter(l => l && l.listing_id)
        .map(l => ({ ...l, variants: tryParse(l.variants, []) }));
    }
```

- [ ] **Step 2: Add a stock helper + variant-line parser**

Directly ABOVE `function renderShopPage() {`, add:
```javascript
// Total remaining stock for a listing: per-variant sum, or the single qty.
function listingStock(l) {
  if (l.variants && l.variants.length) return l.variants.reduce((a, v) => a + (parseInt(v.qty) || 0), 0);
  return parseInt(l.qty) || 0;
}
// Parse the admin Variants textarea: one per line "Name, stock". Bad lines dropped.
function parseVariantLines(text) {
  return (text || '').split('\n').map(line => {
    const t = line.trim();
    if (!t) return null;
    const idx = t.lastIndexOf(',');
    if (idx < 0) return null;
    const name = t.slice(0, idx).trim();
    const qty = parseInt(t.slice(idx + 1).trim());
    if (!name || isNaN(qty)) return null;
    return { name, qty };
  }).filter(Boolean);
}
```

- [ ] **Step 3: Add a Variants textarea to the listing form**

Find:
```javascript
    <div class="field-row">
      <div class="field"><label>Quantity</label><input type="number" id="lst-qty" min="0" value="${l ? l.qty : 1}"></div>
      <div class="field"><label>Image URL</label><input type="text" id="lst-image" placeholder="https://..." value="${l ? (l.image_url||'') : ''}"></div>
    </div>
    <div class="field"><label>Note (optional)</label><input type="text" id="lst-note" value="${l ? (l.note||'') : ''}"></div>
```
Replace with:
```javascript
    <div class="field-row">
      <div class="field"><label>Quantity (if no variants)</label><input type="number" id="lst-qty" min="0" value="${l ? l.qty : 1}"></div>
      <div class="field"><label>Image URL</label><input type="text" id="lst-image" placeholder="https://..." value="${l ? (l.image_url||'') : ''}"></div>
    </div>
    <div class="field"><label>Variants (optional)</label>
      <textarea id="lst-variants" placeholder="One per line: Name, stock&#10;Ver A, 2&#10;Ver B, 1" style="min-height:70px;font-family:var(--mono);font-size:12px;">${l && l.variants && l.variants.length ? l.variants.map(v => v.name + ', ' + v.qty).join('\n') : ''}</textarea>
      <div class="field-hint">Leave empty for a single-quantity listing. With variants, each has its own stock and buyers pick one.</div>
    </div>
    <div class="field"><label>Note (optional)</label><input type="text" id="lst-note" value="${l ? (l.note||'') : ''}"></div>
```

- [ ] **Step 4: Send variants in saveListing**

Find:
```javascript
  const data = {
    name: document.getElementById('lst-name').value.trim(),
    category: document.getElementById('lst-category').value,
    price: parseFloat(document.getElementById('lst-price').value) || 0,
    qty: parseInt(document.getElementById('lst-qty').value) || 0,
    image_url: document.getElementById('lst-image').value.trim(),
    note: document.getElementById('lst-note').value.trim()
  };
```
Replace with:
```javascript
  const variants = parseVariantLines(document.getElementById('lst-variants').value);
  const data = {
    name: document.getElementById('lst-name').value.trim(),
    category: document.getElementById('lst-category').value,
    price: parseFloat(document.getElementById('lst-price').value) || 0,
    qty: variants.length ? 0 : (parseInt(document.getElementById('lst-qty').value) || 0),
    image_url: document.getElementById('lst-image').value.trim(),
    note: document.getElementById('lst-note').value.trim(),
    variants: variants
  };
```

- [ ] **Step 5: Show variant stock in the admin listings list**

Find:
```javascript
        <div style="font-size:12px;color:var(--text3);">$${(parseFloat(l.price)||0).toFixed(2)} · ${parseInt(l.qty)||0} in stock</div>
```
Replace with:
```javascript
        <div style="font-size:12px;color:var(--text3);">$${(parseFloat(l.price)||0).toFixed(2)} · ${(l.variants&&l.variants.length) ? l.variants.map(v=>v.name+' ('+(parseInt(v.qty)||0)+')').join(', ') : (parseInt(l.qty)||0) + ' in stock'}</div>
```

- [ ] **Step 6: Syntax check + commit**

```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
git add index.html && git commit -m "Frontend: shop listing variants (parse, form, admin list)"
```

---

## Task 4: Frontend — buyer variant picker + submit

**Files:** Modify `index.html`

- [ ] **Step 1: Shop card uses total variant stock**

Find:
```javascript
  active.forEach(l => {
    const qty = parseInt(l.qty) || 0;
    const sold = qty <= 0;
```
Replace with:
```javascript
  active.forEach(l => {
    const qty = listingStock(l);
    const sold = qty <= 0;
```

- [ ] **Step 2: Variant-aware order view**

Find the whole `openShopListing` function:
```javascript
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
Replace with:
```javascript
let shopOrderQty = 1;
let shopOrderVariant = '';
function shopSelectedMax(l) {
  if (l.variants && l.variants.length) {
    const v = l.variants.find(x => x.name === shopOrderVariant);
    return v ? (parseInt(v.qty) || 0) : 0;
  }
  return parseInt(l.qty) || 0;
}
function openShopListing(listingId) {
  const l = listings.find(x => x.listing_id === listingId);
  if (!l) return;
  const hasVariants = !!(l.variants && l.variants.length);
  shopOrderQty = 1;
  shopOrderVariant = '';
  let variantHtml = '';
  if (hasVariants) {
    variantHtml = `<div style="font-size:12px;color:var(--text2);margin:6px 0;">Pick a version:</div>
      <div class="member-grid" id="shop-variant-grid">` +
      l.variants.map(v => {
        const vq = parseInt(v.qty) || 0;
        const key = v.name.replace(/\s/g,'_');
        return `<div class="member-tile" id="shop-vtile-${key}" ${vq>0?`onclick="selectShopVariant('${listingId}','${v.name}')"`:'style="opacity:0.5;"'}>
          <div class="member-tile-name">${v.name}</div>
          <div class="member-tile-sub" style="color:${vq>0?'var(--teal-600)':'var(--text3)'};">${vq>0?vq+' left':'Sold out'}</div>
        </div>`;
      }).join('') + `</div>`;
  }
  showModal(`
    <div style="font-size:16px;font-weight:500;margin-bottom:4px;">${l.name}</div>
    <div style="font-size:12px;color:var(--text3);margin-bottom:12px;">${l.category || ''} · $${(parseFloat(l.price)||0).toFixed(2)} · ${listingStock(l)} left</div>
    ${l.image_url ? `<img src="${l.image_url}" style="width:100%;border-radius:var(--radius);margin-bottom:12px;" onerror="this.style.display='none'">` : ''}
    ${l.note ? `<div style="font-size:12px;color:var(--text2);margin-bottom:12px;">${l.note}</div>` : ''}
    ${variantHtml}
    <div class="field" style="margin-top:10px;"><label>Your username</label><input type="text" id="shop-order-user" placeholder="@username"></div>
    <div style="display:flex;align-items:center;gap:10px;margin:10px 0;">
      <span style="font-size:12px;color:var(--text2);">Qty:</span>
      <div class="qty-row">
        <button class="qty-btn" onclick="adjustShopQty('${listingId}',-1)">−</button>
        <span id="shop-qty-val" style="min-width:24px;text-align:center;font-weight:500;">1</span>
        <button class="qty-btn" onclick="adjustShopQty('${listingId}',1)">+</button>
      </div>
    </div>
    <div style="display:flex;gap:8px;margin-top:8px;">
      <button class="btn btn-primary" style="flex:1;justify-content:center;" onclick="submitShopOrder('${l.listing_id}')">Place order</button>
      <button class="btn btn-ghost" onclick="closeModal()">Cancel</button>
    </div>`);
}

function selectShopVariant(listingId, name) {
  shopOrderVariant = name;
  shopOrderQty = 1;
  const l = listings.find(x => x.listing_id === listingId);
  (l.variants || []).forEach(v => {
    const tile = document.getElementById('shop-vtile-' + v.name.replace(/\s/g,'_'));
    if (tile) tile.classList.toggle('selected', v.name === name);
  });
  const el = document.getElementById('shop-qty-val');
  if (el) el.textContent = shopOrderQty;
}

function adjustShopQty(listingId, delta) {
  const l = listings.find(x => x.listing_id === listingId);
  const max = shopSelectedMax(l);
  shopOrderQty = Math.max(1, Math.min(max || 1, shopOrderQty + delta));
  const el = document.getElementById('shop-qty-val');
  if (el) el.textContent = shopOrderQty;
}
```

- [ ] **Step 3: submitShopOrder sends the variant + updates local stock**

Find the whole `submitShopOrder` function:
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
Replace with:
```javascript
function submitShopOrder(listingId) {
  const rawUser = (document.getElementById('shop-order-user')||{}).value || '';
  const username = rawUser.trim();
  if (!username) { toast('Enter your username.'); return; }
  const u = username.startsWith('@') ? username : '@' + username;
  const l = listings.find(x => x.listing_id === listingId);
  if (!l) return;
  const hasVariants = !!(l.variants && l.variants.length);
  if (hasVariants && !shopOrderVariant) { toast('Pick a version first.'); return; }
  const qty = shopOrderQty;
  if (!API_URL) { toast('Shop needs the backend configured.'); return; }
  const payload = { listing_id: listingId, username: u, qty };
  if (hasVariants) payload.variant = shopOrderVariant;
  apiPost('placeShopOrder', payload).then(res => {
    if (res && res.ok) {
      // Reflect stock locally so the grid updates without a full sync.
      if (hasVariants) {
        const v = l.variants.find(x => x.name === shopOrderVariant);
        if (v) v.qty = (parseInt(v.qty) || 0) - qty;
      } else {
        l.qty = (parseInt(l.qty) || 0) - qty;
      }
      closeModal();
      renderShopPage();
      toast('Order placed — pay in My orders.');
      document.getElementById('lookup-input').value = u;
      showPage('lookup');
      doLookup();
    } else if (res && res.error === 'oversold') {
      toast('Only ' + (res.available || 0) + ' left — please retry.');
      if (hasVariants) { const v = l.variants.find(x => x.name === shopOrderVariant); if (v) v.qty = res.available || 0; }
      else l.qty = res.available || 0;
      renderShopPage();
    } else {
      toast('Could not place order.');
    }
  }).catch(() => toast('Could not place order.'));
}
```

- [ ] **Step 4: Syntax check + commit**

```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
git add index.html && git commit -m "Frontend: buyer variant picker + submit chosen variant"
```

---

## Task 5: Frontend — show variant in orders + My orders

**Files:** Modify `index.html`

- [ ] **Step 1: Admin Shop orders table shows the variant**

Find:
```javascript
      <td style="font-size:12px;">${o.listing_name}</td>
      <td>${o.qty}</td>
```
Replace with:
```javascript
      <td style="font-size:12px;">${o.listing_name}${o.variant ? ' — ' + o.variant : ''}</td>
      <td>${o.qty}</td>
```

- [ ] **Step 2: My orders row shows the variant**

Find:
```javascript
      go_id: 'shop', go: 'Shop', item: o.listing_name, detail: '',
```
Replace with:
```javascript
      go_id: 'shop', go: 'Shop', item: o.listing_name, detail: o.variant || '',
```

- [ ] **Step 3: Syntax check + commit**

```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
git add index.html && git commit -m "Frontend: show variant in admin orders + My orders"
```

---

## Task 6: Deploy, redeploy, manual verification

**Files:** none.

- [ ] **Step 1: Push**

```bash
git push
```

- [ ] **Step 2: Redeploy the Apps Script backend**

Paste the updated `go-manager-backend.gs` → Deploy → Manage deployments → edit → New version → Deploy. (User action.) If the `listings`/`shop_orders` sheets already exist without the new columns, add a `variants` header to `listings` and a `variant` header to `shop_orders` (or delete those tabs so bootstrap recreates them).

- [ ] **Step 3: Wait for the live frontend deploy**

```bash
for i in $(seq 1 25); do n=$(curl -s "https://jhcui18.github.io/go-manager/index.html?cb=$(date +%s%N)" | grep -c "function selectShopVariant"); if [ "$n" -gt 0 ]; then echo "LIVE after ~$((i*10))s"; break; fi; sleep 10; done
```
Expected: `LIVE after ~Ns`

- [ ] **Step 4: Manual — create a variant listing**

Admin → + New listing → name, category Album, price → in **Variants** type:
```
Ver A, 2
Ver B, 1
```
Save. Confirm the admin list shows "Ver A (2), Ver B (1)" and the Shop card shows "3 left".

- [ ] **Step 5: Manual — buyer orders a variant**

Shop → open the listing → tap **Ver A** → qty 1 → enter username → Place order. Confirm routed to My orders showing "Ver A", and the Shop card now shows "2 left"; re-open → Ver A shows "1 left", Ver B "1 left". Order Ver A twice more to hit 0 → Ver A greys out "Sold out"; when both are 0 the card shows "Sold out".

- [ ] **Step 6: Manual — admin sees variant + simple listing still works**

Admin Shop orders → row shows "Album — Ver A". Create a second listing with NO variants + a Quantity, order it → confirm the plain single-qty flow still works.

- [ ] **Step 7: Final commit (only if a fix was needed)**

```bash
git add index.html go-manager-backend.gs && git commit -m "Fix shop variant issue found in verification" && git push
```

---

## Notes / deferred (from spec)

- Per-variant price/photo — out of scope (shared per listing).
- One variant per order (no multi-variant cart).
- New sheet columns are appended at the END of each schema so positional appends stay aligned; reads are header-keyed so column order doesn't matter for display.
