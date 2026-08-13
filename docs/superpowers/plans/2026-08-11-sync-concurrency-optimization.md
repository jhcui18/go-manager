# Sync Concurrency Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut Apps Script execution-slot throttling by collapsing the joiner's My-Orders (4 calls) and GO-open (5 calls) into one endpoint each, and making client read-retries gentler.

**Architecture:** Two new read-only Apps Script endpoints (`getMyOrders(username)`, `getGOBoard(goId)`) that do in one execution what several calls do now, reusing the existing per-sheet reads. The frontend calls them and falls back to the existing multi-call paths if they 404 (pre-redeploy safe). `apiGet` retries fewer times with longer jittered backoff so clients don't storm a struggling server.

**Tech Stack:** Single-file vanilla-JS `index.html` (inline `<script>`) + Google Apps Script `go-manager-backend.gs` + Google Sheets. No test framework — verify with JS-parse of the script blocks, `node --check` on a `.js` copy of the backend, a Node unit check for the pure backoff helper, and post-redeploy live curl.

## Global Constraints

- New endpoints are **read-only** and **additive**; the existing endpoints (`getJoiners`, `getPayments`, `getShopOrders`, `getShipping`, `getGOClaims`, `getSecuredSets`, `getClosedSubItems`, `getSubItemDeadlines`, `getSubItemPayDue`) stay unchanged (admin path + fallback use them).
- `getMyOrders(username)` returns `{ claims, payments, shop_orders, shipping }`, each **filtered to that user** by `String(x).trim().toLowerCase().replace(/^@/,'')` (same case-insensitive match `getJoiners` uses).
- `getGOBoard(goId)` returns `{ claims, secured_sets, closed_subitems, subitem_deadlines, subitem_payment_due }` — `claims` filtered to that `go_id`, the four flag maps are whole-store reads.
- **Graceful degrade:** if a combined call throws or lacks its `claims` key (pre-redeploy 404), the frontend falls back to the existing parallel calls. The app must work before and after redeploy.
- Retry change: `apiGet` default attempts **3 → 2**; backoff `400*(i+1)` → **`1000*(i+1) + random(0..1000)`** via a shared `retryDelay(i)` helper. `apiPost` keeps its 404/429-only retry condition but uses the same jittered `retryDelay`.
- Backend endpoints REQUIRE a redeploy; frontend is safe to push first.
- Do not change the admin sync path (`getAllGOs` + secondaries).

**Reusable verification commands** (from repo root `/Users/jinghancui/Gitproj/Go-manager`):
- JS-parse: `node -e "const fs=require('fs');const h=fs.readFileSync('index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"`
- Backend check: `cp go-manager-backend.gs /tmp/gmb.js && node --check /tmp/gmb.js && echo "backend OK"`

Scratchpad for tests: `/private/tmp/claude-501/-Users-jinghancui/96b57dba-e91a-4bf3-a521-0b65a82da0bf/scratchpad`

---

### Task 1: Backend — getMyOrders + getGOBoard + routing

**Files:**
- Modify: `go-manager-backend.gs` — add `getMyOrders`, `getGOBoard` near the other read
  functions (after `getGOClaims`); route both in `doGet` (~line 81, after `getSubItemPayDue`).

**Interfaces:**
- Consumes: existing `sheetToObjects(sheet)` helper and the sheet-name constants
  `SHEET_JOINERS`, `SHEET_PAYMENTS`, `SHEET_SHOP_ORDERS`, `SHEET_SHIPPING`,
  `SHEET_SECURED_SETS`, `SHEET_CLOSED_SUBITEMS`, `SHEET_SUBITEM_DEADLINES`,
  `SHEET_SUBITEM_PAYDUE`.
- Produces: `getMyOrders(username)` → `{claims, payments, shop_orders, shipping}`;
  `getGOBoard(goId)` → `{claims, secured_sets, closed_subitems, subitem_deadlines, subitem_payment_due}`.

- [ ] **Step 1: Add the two functions**

In `go-manager-backend.gs`, after `getGOClaims`, add:
```javascript
// One-execution reads that replace the joiner's multi-call fan-out (fewer Apps Script
// execution slots = less concurrency throttling). Read-only; existing endpoints unchanged.
function getMyOrders(username) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const target = String(username || '').trim().toLowerCase().replace(/^@/, '');
  const rd = (name) => { const sh = ss.getSheetByName(name); return sh ? sheetToObjects(sh) : []; };
  const mine = (rows) => target ? rows.filter(r => String(r.username || '').trim().toLowerCase().replace(/^@/, '') === target) : rows;
  return {
    claims: mine(rd(SHEET_JOINERS)),
    payments: mine(rd(SHEET_PAYMENTS)),
    shop_orders: mine(rd(SHEET_SHOP_ORDERS)),
    shipping: mine(rd(SHEET_SHIPPING))
  };
}

function getGOBoard(goId) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const rd = (name) => { const sh = ss.getSheetByName(name); return sh ? sheetToObjects(sh) : []; };
  return {
    claims: rd(SHEET_JOINERS).filter(c => c.go_id === goId),
    secured_sets: rd(SHEET_SECURED_SETS),
    closed_subitems: rd(SHEET_CLOSED_SUBITEMS),
    subitem_deadlines: rd(SHEET_SUBITEM_DEADLINES),
    subitem_payment_due: rd(SHEET_SUBITEM_PAYDUE)
  };
}
```

- [ ] **Step 2: Route both in `doGet`**

In `go-manager-backend.gs` `doGet`, after the `getSubItemPayDue` line (~81), add:
```javascript
    else if (action === 'getMyOrders')     result = getMyOrders(e.parameter.username);
    else if (action === 'getGOBoard')      result = getGOBoard(e.parameter.go_id);
```

- [ ] **Step 3: Verify backend syntax**

Run: `cp go-manager-backend.gs /tmp/gmb.js && node --check /tmp/gmb.js && echo "backend OK"`
Expected: `backend OK`.

- [ ] **Step 4: Commit**

```bash
git add go-manager-backend.gs
git commit -m "Backend: getMyOrders + getGOBoard combined read endpoints (fewer executions)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 5: (Post-redeploy, manual) live verify** — after the user redeploys, curl
  `getMyOrders(<real @user>)` → `{claims,payments,shop_orders,shipping}` all scoped to that
  user (counts equal the old per-endpoint results filtered by username); curl
  `getGOBoard(<goId>)` → claims count equals `getGOClaims(goId)` and the four flag maps
  are present. Time 1 combined call vs the 4/5 separate calls. Deferred to the human; note in report.

---

### Task 2: Gentler retries — shared jittered backoff

**Files:**
- Modify: `index.html` — add `retryDelay`; change `apiGet` (attempts 3→2, use `retryDelay`)
  and `apiPost` (use `retryDelay`).
- Test: `scratchpad/test-retry-backoff.js`

**Interfaces:**
- Produces: `retryDelay(i)` → Number ms in `[1000*(i+1), 1000*(i+1)+1000)`.

- [ ] **Step 1: Write the failing test**

Create `scratchpad/test-retry-backoff.js`:
```javascript
const fs = require('fs'), assert = require('assert');
const html = fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');
function extractFn(src, name){const s=src.indexOf('function '+name+'(');if(s<0)throw new Error('missing '+name);let d=0;for(let j=src.indexOf('{',s);j<src.length;j++){if(src[j]==='{')d++;else if(src[j]==='}'){d--;if(d===0)return src.slice(s,j+1);}}throw new Error('brace');}
const retryDelay = new Function('return ('+extractFn(html,'retryDelay')+')')();
for (let i = 0; i < 3; i++) {
  for (let n = 0; n < 50; n++) {
    const d = retryDelay(i);
    assert.ok(d >= 1000*(i+1) && d < 1000*(i+1)+1000, 'attempt '+i+' delay '+d+' out of range');
  }
}
// jitter: not always the same value
const s = new Set(); for (let n=0;n<50;n++) s.add(retryDelay(0));
assert.ok(s.size > 1, 'expected jitter (varied delays)');
console.log('ALL PASS');
```

- [ ] **Step 2: Run — verify it fails**

Run: `node scratchpad/test-retry-backoff.js`
Expected: FAIL — `missing retryDelay` (not defined yet).

- [ ] **Step 3: Add `retryDelay` and wire it in**

In `index.html`, add `retryDelay` immediately before `async function apiGet`:
```javascript
// Retry backoff: longer + jittered so many clients don't retry in lockstep and hammer a
// throttled server. attempt i (0-based) waits 1..2s, 2..3s, ...
function retryDelay(i) { return 1000 * (i + 1) + Math.floor(Math.random() * 1000); }
```

Change `apiGet`'s signature and backoff — replace:
```javascript
async function apiGet(action, params = {}, attempts = 3) {
```
with:
```javascript
async function apiGet(action, params = {}, attempts = 2) {
```
and replace:
```javascript
      if (i < attempts - 1) await new Promise(r => setTimeout(r, 400 * (i + 1)));
```
with:
```javascript
      if (i < attempts - 1) await new Promise(r => setTimeout(r, retryDelay(i)));
```

Change `apiPost`'s backoff — replace:
```javascript
      await new Promise(res => setTimeout(res, 400 * (i + 1)));
```
with:
```javascript
      await new Promise(res => setTimeout(res, retryDelay(i)));
```

- [ ] **Step 4: Run — verify it passes**

Run: `node scratchpad/test-retry-backoff.js` → Expected: `ALL PASS`. Then JS-parse (Global Constraints) → `JS parses OK`.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "Gentler retries: 2 attempts + longer jittered backoff (no retry storm under throttle)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Frontend — My Orders via getMyOrders (with fallback)

**Files:**
- Modify: `index.html` — the buyer branch of `doLookup` (~1698–1708).

**Interfaces:**
- Consumes Task 1 `getMyOrders`. Falls back to `getJoiners`/`getPayments`/`getShopOrders`/`getShipping`.

- [ ] **Step 1: Replace the 4-call fetch with getMyOrders + fallback**

In `index.html` `doLookup`, the buyer branch currently:
```javascript
  if (!isAdmin && API_URL) {
    // Buyer lazy path: pull just this user's claims + payments/shop/shipping.
    showLoadingOverlay(true, 'Looking up your orders…');
    let jr, pr, so, sh;
    try {
      [jr, pr, so, sh] = await Promise.all([
        apiGet('getJoiners', { username: raw.trim() }), apiGet('getPayments'),
        apiGet('getShopOrders'), apiGet('getShipping')
      ]);
    } catch (e) {
      showLoadingOverlay(false);
      toast('Couldn’t load your orders — check your connection and try again.');
      return;
    }
    showLoadingOverlay(false);
    myLookupClaims = (jr && jr.claims) || [];
```
Replace the `try { [jr, pr, so, sh] = await Promise.all([...]); } catch {...}` block (keep the
`showLoadingOverlay(true,…)` before it and the `myLookupClaims = …` and later parsing after it):
```javascript
    showLoadingOverlay(true, 'Looking up your orders…');
    let jr, pr, so, sh;
    try {
      // One combined call (fewer Apps Script executions). Falls back to the 4 separate calls
      // if the endpoint isn't deployed yet (pre-redeploy 404 → apiGet throws → catch below).
      let mo = null;
      try { mo = await apiGet('getMyOrders', { username: raw.trim() }); } catch (e) { mo = null; }
      if (mo && mo.claims !== undefined) {
        jr = { claims: mo.claims }; pr = { payments: mo.payments };
        so = { shop_orders: mo.shop_orders }; sh = { requests: mo.shipping };
      } else {
        [jr, pr, so, sh] = await Promise.all([
          apiGet('getJoiners', { username: raw.trim() }), apiGet('getPayments'),
          apiGet('getShopOrders'), apiGet('getShipping')
        ]);
      }
    } catch (e) {
      showLoadingOverlay(false);
      toast('Couldn’t load your orders — check your connection and try again.');
      return;
    }
    showLoadingOverlay(false);
```
(The lines after — `myLookupClaims = (jr && jr.claims) || [];` and the `pr`/`so`/`sh` parsing —
stay exactly as they are; `jr/pr/so/sh` have the same shapes as before.)

- [ ] **Step 2: JS-parse** → `JS parses OK`.

- [ ] **Step 3: Manual (documented, DOM/network)** — as a buyer, look up a username: My Orders
  renders identically (claims, payments, shop orders, shipping). Confirm one `getMyOrders`
  request in the Network tab (post-redeploy) instead of four; pre-redeploy, it falls back to the
  four and still renders. Deferred to the human; note in report.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "My Orders: one getMyOrders call (fallback to 4) — fewer executions per lookup

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Frontend — GO open via getGOBoard (with fallback)

**Files:**
- Modify: `index.html` — `loadGOClaims` (~the `Promise.allSettled([...5 calls])`).

**Interfaces:**
- Consumes Task 1 `getGOBoard`. Falls back to `getGOClaims` + the four flag endpoints.

- [ ] **Step 1: Replace the 5-call fetch with getGOBoard + fallback**

In `index.html` `loadGOClaims`, the current fetch:
```javascript
  const settled = await Promise.allSettled([
    apiGet('getGOClaims', { go_id: goId }), apiGet('getSecuredSets'), apiGet('getClosedSubItems'),
    apiGet('getSubItemDeadlines'), apiGet('getSubItemPayDue')
  ]);
  const [claimsRes, sec, closed, deads, pdue] = settled.map(s => s.status === 'fulfilled' ? s.value : undefined);
```
Replace with:
```javascript
  // One combined call (fewer executions). Fall back to the 5 separate calls pre-redeploy.
  let claimsRes, sec, closed, deads, pdue;
  let bd = null;
  try { bd = await apiGet('getGOBoard', { go_id: goId }); } catch (e) { bd = null; }
  if (bd && bd.claims !== undefined) {
    claimsRes = { claims: bd.claims };
    sec = { secured_sets: bd.secured_sets };
    closed = { closed_subitems: bd.closed_subitems };
    deads = { subitem_deadlines: bd.subitem_deadlines };
    pdue = { subitem_payment_due: bd.subitem_payment_due };
  } else {
    const settled = await Promise.allSettled([
      apiGet('getGOClaims', { go_id: goId }), apiGet('getSecuredSets'), apiGet('getClosedSubItems'),
      apiGet('getSubItemDeadlines'), apiGet('getSubItemPayDue')
    ]);
    [claimsRes, sec, closed, deads, pdue] = settled.map(s => s.status === 'fulfilled' ? s.value : undefined);
  }
```
(Everything after — `if (!claimsRes || !claimsRes.claims) throw …` and the flag-map parsing and
sub-item rebuild — stays exactly as it is; `claimsRes/sec/closed/deads/pdue` have the same shapes.)

- [ ] **Step 2: JS-parse** → `JS parses OK`.

- [ ] **Step 3: Manual (documented)** — as a buyer, open a GO: the set/batch board, secured
  flags, closed badges, deadlines and pay-by dates all render identically. Network tab shows one
  `getGOBoard` request (post-redeploy) instead of five; pre-redeploy it falls back to the five.
  Deferred to the human; note in report.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "GO open: one getGOBoard call (fallback to 5) — fewer executions per open

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Post-implementation
- **Redeploy** the Apps Script Web App (`getMyOrders` + `getGOBoard`); user reports "redeployed".
- Run Task 1 Step 5 live verify (combined shape, user-scoped, timing vs 4/5 calls).
- **Push** `main` (frontend is fallback-safe pre-redeploy); hard-refresh.
- End-to-end: buyer My Orders + GO open each make one call; identical rendering; admin path unchanged.
