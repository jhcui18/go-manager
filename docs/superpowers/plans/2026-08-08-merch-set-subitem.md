# Merch Set-Based Sub-Item Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin add a set-based sub-item (new kind `member-set`) to a merch GO that behaves exactly like a photocard sub-item — set-based with an optional batch toggle.

**Architecture:** Purely additive (Approach A). Introduce the kind `member-set` and, at each place that already detects "set-based" (`kind === 'member' || kind === 'photocard'`), *add* recognition of `member-set`. The whole set engine (`buildSetsFromClaims`, `renderSetSubItemPublic`/`renderBatchSubItemPublic`, securing, batch mode, owed math) is reused unchanged. Existing `member`/`random`/`photocard`/album behavior is never modified.

**Tech Stack:** Single-file vanilla-JS `index.html` (inline `<script>` blocks) + Google Apps Script `go-manager-backend.gs` + Google Sheets. No test framework — verification is JS-parse of the script blocks, `node --check` on a `.js` copy of the backend, and a Node logic harness for pure functions.

## Global Constraints

- New kind string is exactly `member-set` (hyphen, lowercase) everywhere — sheet `sub_item_kind`, in-memory `si.kind`, form `<option value>`, and every detection check.
- `member-set` is offered ONLY in merch GOs. Album keeps `member`/`versioned`/`single`; merch keeps `random`/`member` (FCFS) plus the new `member-set`.
- Set mode: `minSecure = members.length` (secure-when-full). Batch mode: `minSecure = -batchSize` (`< 0`). These match photocard exactly.
- Additive only: do NOT alter any existing `kind === 'member'`, `kind === 'photocard'`, `kind === 'random'`, or album branch. Only ADD `member-set` recognition.
- The set submit branch, `buildSetsFromClaims`, `renderSetSubItemPublic`, `renderBatchSubItemPublic`, securing endpoints, and `paymentOwedUnits` (shape-based on `si.sets`/`si.claims`) need NO change — they become correct for `member-set` automatically once reconstruction shapes the sub-item as a set and `isBatch` recognizes the kind.
- Backend change requires redeploying the Apps Script Web App. Frontend + backend ship together.
- After each task: JS-parse the script blocks; the change must parse before commit.

**Reusable verification commands** (run from repo root `/Users/jinghancui/Gitproj/Go-manager`):

- JS-parse all inline scripts:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Backend syntax check (copy `.gs` to `.js` first; Apps Script is JS syntax):
  ```bash
  cp go-manager-backend.gs /tmp/gmb.js && node --check /tmp/gmb.js && echo "backend OK"
  ```

---

### Task 1: Recognize `member-set` across the read / claim / owed engine + backend

**Files:**
- Modify: `index.html` — lines ~585 (`isBatch`), ~1025 (claimState init), ~1283 (`renderMerchPublic`), ~1722 (buyer owed `isSetKind`), ~4069 & ~4078 (`ownedUnitsFromClaims`), ~4530 (reconstruction routing)
- Modify: `go-manager-backend.gs` — line ~342 (`isSet`)
- Test: `/private/tmp/claude-501/-Users-jinghancui/96b57dba-e91a-4bf3-a521-0b65a82da0bf/scratchpad/test-merch-set-owed.js`

**Interfaces:**
- Consumes: existing `buildSetsFromClaims(claims, siId, members)`, `buildBatchClaims(claims, siId)`, `renderSetSubItemPublic(si, goId)`, `renderBatchSubItemPublic(si, goId)`, `claimCollapsible(goId, si, innerHtml)`, `isBatch(si)`.
- Produces: after this task, any sub-item with `kind:'member-set'` reconstructs into `si.sets` (or batch `si.claims` when `minSecure < 0`), renders as a set/batch board inside a merch GO, is billed at `price` per secured slot (`otPrice` for an OT full set), and the backend assigns its `set_num`. Tasks 2–3 rely on producing sub-item objects shaped as `{ id, name, kind:'member-set', members, minSecure, price, otPrice, sets:[…] }` (set mode) or `{ …, minSecure:-bs, claims:[] }` (batch mode).

- [ ] **Step 1: Write the failing owed test**

`ownedUnitsFromClaims(claims, siMeta)` is the buyer flat-claims owed calc. It must bill a secured `member-set` normal set at `price` per slot and an OT full set at one `otPrice`. Before the code change, `member-set` fails the `isSetKind` guard and falls through to the flat branch — an OT set of 4 slots would be billed 4 × `price` instead of 1 × `otPrice`, and unsecured slots would be wrongly billed. This test pins the correct behavior.

Create `/private/tmp/claude-501/-Users-jinghancui/96b57dba-e91a-4bf3-a521-0b65a82da0bf/scratchpad/test-merch-set-owed.js`:

```javascript
const fs = require('fs');
const assert = require('assert');

// Extract a single top-level `function NAME(...) { ... }` from index.html by brace-matching.
function extractFn(src, name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('function not found: ' + name);
  let i = src.indexOf('{', start), depth = 0;
  for (let j = i; j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}') { depth--; if (depth === 0) return src.slice(start, j + 1); }
  }
  throw new Error('unbalanced braces for ' + name);
}

const html = fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html', 'utf8');
const ownedUnitsFromClaims = new Function('return (' + extractFn(html, 'ownedUnitsFromClaims') + ')')();

const siMeta = { S: { price: 20, otPrice: 70, kind: 'member-set', minSecure: 4 } };
const members = ['Karina', 'Winter', 'Giselle', 'Ningning'];

// Normal secured set of 4 slots -> 4 units at $20 = $80
const normalSet = members.map((m, k) => ({
  sub_item_id: 'S', member_or_version: m, set_num: 1, assigned_vers: '',
  claim_status: 'secured', qty: 1
}));
// OT secured full set -> ONE unit at $70
const otSet = members.map((m) => ({
  sub_item_id: 'S', member_or_version: m, set_num: 2, assigned_vers: 'OT',
  claim_status: 'secured', qty: 1
}));
// Unsecured (open) normal slot -> NOT owed
const openSlot = [{
  sub_item_id: 'S', member_or_version: 'Karina', set_num: 3, assigned_vers: '',
  claim_status: 'open', qty: 1
}];

const normalUnits = ownedUnitsFromClaims(normalSet, siMeta);
assert.strictEqual(normalUnits.reduce((a, u) => a + u.value, 0), 80, 'normal set owed should be $80');

const otUnits = ownedUnitsFromClaims(otSet, siMeta);
assert.strictEqual(otUnits.length, 1, 'OT full set = exactly one owed unit');
assert.strictEqual(otUnits[0].value, 70, 'OT full set owed should be $70');

const openUnits = ownedUnitsFromClaims(openSlot, siMeta);
assert.strictEqual(openUnits.reduce((a, u) => a + u.value, 0), 0, 'open set slot not owed');

// Batch member-set (minSecure < 0): only secured cards owed at price*qty
const batchMeta = { B: { price: 15, otPrice: 0, kind: 'member-set', minSecure: -8 } };
const batchClaims = [
  { sub_item_id: 'B', member_or_version: 'Karina', set_num: '', claim_status: 'secured', qty: 2 },
  { sub_item_id: 'B', member_or_version: 'Winter', set_num: '', claim_status: 'pending', qty: 1 },
];
const batchUnits = ownedUnitsFromClaims(batchClaims, batchMeta);
assert.strictEqual(batchUnits.reduce((a, u) => a + u.value, 0), 30, 'batch: only secured 2x$15=$30');

console.log('ALL PASS');
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
node "/private/tmp/claude-501/-Users-jinghancui/96b57dba-e91a-4bf3-a521-0b65a82da0bf/scratchpad/test-merch-set-owed.js"
```
Expected: FAIL — an `AssertionError`, most clearly `OT full set = exactly one owed unit` (before the fix an OT `member-set` set is billed as four flat units), or the open-slot assertion.

- [ ] **Step 3: Backend — teach `isSet` the new kind**

In `go-manager-backend.gs` (~line 342), inside `submitClaim`:

Old:
```javascript
      const isSet = (c.sub_item_kind === 'member' || c.sub_item_kind === 'photocard') && c.member_or_version;
```
New:
```javascript
      const isSet = (c.sub_item_kind === 'member' || c.sub_item_kind === 'photocard' || c.sub_item_kind === 'member-set') && c.member_or_version;
```

Verify backend syntax:
```bash
cp go-manager-backend.gs /tmp/gmb.js && node --check /tmp/gmb.js && echo "backend OK"
```
Expected: `backend OK`.

- [ ] **Step 4: Frontend — `isBatch` recognizes `member-set`**

In `index.html` (~line 585):

Old:
```javascript
function isBatch(si) { return !!si && (si.kind === 'member' || si.kind === 'photocard') && parseInt(si.minSecure) < 0; }
```
New:
```javascript
function isBatch(si) { return !!si && (si.kind === 'member' || si.kind === 'photocard' || si.kind === 'member-set') && parseInt(si.minSecure) < 0; }
```

- [ ] **Step 5: Frontend — claimState init routes `member-set` to a set**

In `index.html` (~line 1025), the claimState init in `renderClaimPage`:

Old:
```javascript
    } else if (kind === 'photocard' || kind === 'member' && go.type !== 'merch') {
      claimState[si.id] = { type:'set', selectedMembers:{} };
```
New:
```javascript
    } else if (kind === 'photocard' || kind === 'member-set' || kind === 'member' && go.type !== 'merch') {
      claimState[si.id] = { type:'set', selectedMembers:{} };
```
(The `isBatch(si)` branch above this already handles batch-mode `member-set` first, so no batch change is needed here.)

- [ ] **Step 6: Frontend — `renderMerchPublic` renders `member-set` as a set/batch board**

In `index.html` `renderMerchPublic(go)` (~line 1281), the per-sub-item loop begins:
```javascript
    const kind = si.kind || 'random';
    const totalClaimed = (si.claims||[]).reduce((a,c)=>a+c.qty,0);
    if (kind === 'member') {
```
Insert a `member-set` branch immediately BEFORE `if (kind === 'member') {`:
```javascript
    const kind = si.kind || 'random';
    const totalClaimed = (si.claims||[]).reduce((a,c)=>a+c.qty,0);
    if (kind === 'member-set') {
      html += claimCollapsible(go.id, si, isBatch(si) ? renderBatchSubItemPublic(si, go.id) : renderSetSubItemPublic(si, go.id));
      return; // next sub-item — reuse the same set/batch board the album path uses
    }
    if (kind === 'member') {
```
(The loop is a `forEach`, so `return` skips to the next sub-item.)

- [ ] **Step 7: Frontend — buyer owed guard (`isSetKind` at ~1722)**

In `index.html` (~line 1722):

Old:
```javascript
      const isSetKind = meta && (meta.kind === 'member' || meta.kind === 'photocard') && parseInt(meta.minSecure) >= 0 && c.member_or_version && c.set_num !== '' && c.set_num !== undefined && c.set_num !== null;
```
New:
```javascript
      const isSetKind = meta && (meta.kind === 'member' || meta.kind === 'photocard' || meta.kind === 'member-set') && parseInt(meta.minSecure) >= 0 && c.member_or_version && c.set_num !== '' && c.set_num !== undefined && c.set_num !== null;
```

- [ ] **Step 8: Frontend — `ownedUnitsFromClaims` guards (~4069 and ~4078)**

In `index.html` (~line 4069):

Old:
```javascript
    const isSetKind = (meta.kind === 'member' || meta.kind === 'photocard') && (parseInt(meta.minSecure) >= 0) && c.member_or_version && c.set_num !== '' && c.set_num !== undefined && c.set_num !== null;
```
New:
```javascript
    const isSetKind = (meta.kind === 'member' || meta.kind === 'photocard' || meta.kind === 'member-set') && (parseInt(meta.minSecure) >= 0) && c.member_or_version && c.set_num !== '' && c.set_num !== undefined && c.set_num !== null;
```

In `index.html` (~line 4078):

Old:
```javascript
      const isBatchKind = (meta.kind === 'member' || meta.kind === 'photocard') && parseInt(meta.minSecure) < 0;
```
New:
```javascript
      const isBatchKind = (meta.kind === 'member' || meta.kind === 'photocard' || meta.kind === 'member-set') && parseInt(meta.minSecure) < 0;
```

- [ ] **Step 9: Frontend — reconstruction routes merch `member-set` into the set build**

In `index.html` (~line 4530), the set-based reconstruction gate:

Old:
```javascript
          if (rebuilt.type === 'photocard' || (rebuilt.type === 'album' && kind === 'member')) {
```
New:
```javascript
          if (rebuilt.type === 'photocard' || (rebuilt.type === 'album' && kind === 'member') || (rebuilt.type === 'merch' && kind === 'member-set')) {
```
This sends merch `member-set` sub-items into the same block that reads `min_secure` and builds `sets` via `buildSetsFromClaims` (or batch `claims` via `buildBatchClaims` when `min_secure < 0`). The `else if (rebuilt.type === 'merch')` branch below now only handles `member` (FCFS) and `random`, unchanged.

- [ ] **Step 10: Run the owed test to verify it passes**

Run:
```bash
node "/private/tmp/claude-501/-Users-jinghancui/96b57dba-e91a-4bf3-a521-0b65a82da0bf/scratchpad/test-merch-set-owed.js"
```
Expected: `ALL PASS`.

- [ ] **Step 11: JS-parse + backend check**

Run the JS-parse command and the backend check from Global Constraints. Expected: `JS parses OK` and `backend OK`.

- [ ] **Step 12: Commit**

```bash
git add index.html go-manager-backend.gs
git commit -m "Merch member-set: recognize new set-based kind in read/claim/owed engine + backend

Additive: isBatch, claimState, renderMerchPublic, buyer+flat owed guards,
reconstruction routing, and backend set_num assignment now recognize kind
'member-set'. Set engine reused unchanged. Backend needs redeploy.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Create-GO form — add the `member-set` option

**Files:**
- Modify: `index.html` — `addSubItem` merch template (~2822–2838), `onMerchKindChange` (~2845–2849), `createGO` merch branch (~2922–2932)

**Interfaces:**
- Consumes: nothing new; produces the sub-item object shape Task 1 documented.
- Produces: selecting "Member set" in the New GO merch form and saving creates a sub-item `{ id, name, kind:'member-set', members, minSecure:members.length, price, otPrice, sets:[emptySet] }` (set mode) or `{ …, minSecure:-bs, claims:[] }` (batch mode, when the batch-size field > 0).

- [ ] **Step 1: Add the `member-set` option to the merch kind dropdown**

In `index.html` `addSubItem` (~line 2826–2830), the merch `<select>`:

Old:
```javascript
        <select id="si-kind-${id}" onchange="onMerchKindChange('${id}')">
          <option value="random">Random ver</option>
          <option value="member">Member ver</option>
        </select>
```
New:
```javascript
        <select id="si-kind-${id}" onchange="onMerchKindChange('${id}')">
          <option value="random">Random ver</option>
          <option value="member">Member ver</option>
          <option value="member-set">Member set (order by set)</option>
        </select>
```

- [ ] **Step 2: Rewrite `onMerchKindChange` to render kind-specific fields**

The merch-extra block currently holds only a members textarea shown for `member`. `member-set` also needs OT-price and batch-size inputs. Rewrite `onMerchKindChange` (~line 2845) to populate the block's `innerHTML` per kind (mirroring the album `onSubItemKindChange` pattern):

Old:
```javascript
function onMerchKindChange(id) {
  const kind = document.getElementById('si-kind-' + id).value;
  const extra = document.getElementById('si-merch-extra-' + id);
  if (extra) extra.style.display = kind === 'member' ? 'block' : 'none';
}
```
New:
```javascript
function onMerchKindChange(id) {
  const kind = document.getElementById('si-kind-' + id).value;
  const extra = document.getElementById('si-merch-extra-' + id);
  if (!extra) return;
  if (kind === 'member') {
    extra.style.display = 'block';
    extra.innerHTML = `<div class="field" style="margin-bottom:0;"><label>Members (one per line)</label><textarea id="si-members-${id}" placeholder="Karina\nWinter\nGiselle\nNingning" style="min-height:80px;font-family:var(--mono);font-size:12px;"></textarea></div>`;
  } else if (kind === 'member-set') {
    extra.style.display = 'block';
    extra.innerHTML = `<div class="field" style="margin-bottom:0;"><label>Members (one per line)</label><textarea id="si-members-${id}" placeholder="Karina\nWinter\nGiselle\nNingning" style="min-height:80px;font-family:var(--mono);font-size:12px;"></textarea></div>
      <div class="field" style="margin-top:8px;margin-bottom:0;"><label>Full set (OT) price (USD)</label><input type="number" id="si-otprice-${id}" placeholder="0.00" step="0.01"><div class="field-hint">Optional — offer a whole-set (OT) claim.</div></div>
      <div class="field" style="margin-top:8px;margin-bottom:0;"><label>Order size — cards per batch (blank = full sets)</label><input type="number" id="si-batchsize-${id}" min="0" step="1" placeholder="blank = full sets"><div class="field-hint">Set e.g. 8 or 16 to order in batches of any members (repeats OK).</div></div>`;
  } else {
    extra.style.display = 'none';
    extra.innerHTML = '';
  }
}
```

Because the block is now filled on change, make the static merch-extra block empty. In `addSubItem` (~line 2836–2838):

Old:
```javascript
    <div id="si-merch-extra-${id}" style="display:none;margin-top:8px;">
      <div class="field" style="margin-bottom:0;"><label>Members (one per line)</label><textarea id="si-members-${id}" placeholder="Karina\nWinter\nGiselle\nNingning" style="min-height:80px;font-family:var(--mono);font-size:12px;"></textarea></div>
    </div>`;
```
New:
```javascript
    <div id="si-merch-extra-${id}" style="display:none;margin-top:8px;"></div>`;
```
(Default kind is `random` → empty block, matching prior behavior. Selecting `member` re-creates the same members textarea.)

- [ ] **Step 3: Handle `member-set` in `createGO`**

In `index.html` `createGO` merch branch (~line 2922–2932):

Old:
```javascript
    } else {
      const price = parseFloat((document.getElementById('si-price-' + siId)||{}).value) || 0;
      const kind = (document.getElementById('si-kind-' + siId)||{}).value || 'random';
      if (kind === 'member') {
        const membersRaw = (document.getElementById('si-members-' + siId)||{}).value || '';
        const members = membersRaw.split('\n').map(m=>m.trim()).filter(Boolean);
        subItems.push({ id:siId, name:siName, kind:'member', members, price, claims:[] });
      } else {
        subItems.push({ id:siId, name:siName, kind:'random', price, claims:[] });
      }
    }
```
New:
```javascript
    } else {
      const price = parseFloat((document.getElementById('si-price-' + siId)||{}).value) || 0;
      const kind = (document.getElementById('si-kind-' + siId)||{}).value || 'random';
      if (kind === 'member') {
        const membersRaw = (document.getElementById('si-members-' + siId)||{}).value || '';
        const members = membersRaw.split('\n').map(m=>m.trim()).filter(Boolean);
        subItems.push({ id:siId, name:siName, kind:'member', members, price, claims:[] });
      } else if (kind === 'member-set') {
        const membersRaw = (document.getElementById('si-members-' + siId)||{}).value || '';
        const members = membersRaw.split('\n').map(m=>m.trim()).filter(Boolean);
        if (!members.length) return;
        const otPrice = parseFloat((document.getElementById('si-otprice-' + siId)||{}).value) || 0;
        const bs = parseInt((document.getElementById('si-batchsize-' + siId)||{}).value) || 0;
        if (bs > 0) {
          subItems.push({ id:siId, name:siName, kind:'member-set', members, minSecure:-bs, price, otPrice, claims:[] });
        } else {
          const emptySet = { status:'open', slots:{}, num:1 };
          members.forEach(m => emptySet.slots[m] = null);
          subItems.push({ id:siId, name:siName, kind:'member-set', members, minSecure:members.length, price, otPrice, sets:[emptySet] });
        }
      } else {
        subItems.push({ id:siId, name:siName, kind:'random', price, claims:[] });
      }
    }
```

- [ ] **Step 4: JS-parse**

Run the JS-parse command from Global Constraints. Expected: `JS parses OK`.

- [ ] **Step 5: Manual verification (documented, no automated harness — DOM form)**

In a browser against the app: New GO → type Merch → add an item → Kind = "Member set" → the members textarea, OT price, and batch-size fields appear. Leave batch-size blank, enter members, save → the created GO's sub-item is set-based (a set board renders in the buyer view). Then repeat with batch-size = 8 → renders as a batch board. Existing "Random ver" / "Member ver" options are unaffected.

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "Merch member-set: add 'Member set' option to the New GO merch form

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Edit-GO form — edit and add `member-set` items

**Files:**
- Modify: `index.html` — `renderEditSubItems` merch branch (~3155–3170), `addEditSubItem` merch template (~3223–3239), `onEditMerchKindChange` (~3263–3267), `saveGOEdits` (`canBatch` ~3307, batch→set convert ~3318–3324, set-update gate ~3326, no-existing-sets gate ~3352, new-item merch branch ~3388–3394)

**Interfaces:**
- Consumes: the sub-item shape from Tasks 1–2.
- Produces: an admin can edit an existing `member-set` item (members, price, OT price, batch toggle) and add a new `member-set` item from the Edit GO screen, producing the same shapes as `createGO`.

- [ ] **Step 1: Render fields for an existing `member-set` item**

In `index.html` `renderEditSubItems`, the merch (`else`) branch (~line 3155–3170) currently shows a members textarea only for `si.kind === 'member'`. Replace that trailing ternary to also handle `member-set` with members + OT + batch-size (like the album member block).

Old:
```javascript
        ${si.kind === 'member' ? `<div class="field" style="margin-bottom:0;"><label>Members (one per line)</label>
          <textarea id="edit-si-members-${si.id}" style="min-height:70px;font-family:var(--mono);font-size:12px;">${(si.members||[]).join('\n')}</textarea>
        </div>` : `<div style="font-size:11px;color:var(--text3);">Random ver — no member list needed.</div>`}`;
```
New:
```javascript
        ${si.kind === 'member' ? `<div class="field" style="margin-bottom:0;"><label>Members (one per line)</label>
          <textarea id="edit-si-members-${si.id}" style="min-height:70px;font-family:var(--mono);font-size:12px;">${(si.members||[]).join('\n')}</textarea>
        </div>` : si.kind === 'member-set' ? `<div class="field" style="margin-bottom:0;"><label>Members (one per line)</label>
          <textarea id="edit-si-members-${si.id}" style="min-height:70px;font-family:var(--mono);font-size:12px;">${(si.members||[]).join('\n')}</textarea>
          ${hasClaims ? '<div class="field-hint" style="color:var(--amber-800);">New members added will appear as open slots in existing sets.</div>' : ''}
        </div>
        <div class="field" style="margin-top:8px;margin-bottom:0;"><label>Full set (OT) price (USD)</label>
          <input type="number" id="edit-si-otprice-${si.id}" value="${si.otPrice || 0}" step="0.01">
          <div class="field-hint">Optional — offer a whole-set (OT) claim.</div>
        </div>
        <div class="field" style="margin-top:8px;margin-bottom:0;"><label>Order size — cards per batch (blank = full sets)</label>
          <input type="number" id="edit-si-batchsize-${si.id}" min="0" step="1" value="${isBatch(si) ? batchSize(si) : ''}">
          <div class="field-hint">Set e.g. 8 or 16 to order in batches of any members (repeats OK).</div>
        </div>` : `<div style="font-size:11px;color:var(--text3);">Random ver — no member list needed.</div>`}`;
```

- [ ] **Step 2: Add `member-set` option + extras to `addEditSubItem` (new item in edit)**

In `index.html` `addEditSubItem` merch branch (~line 3227–3239):

Old:
```javascript
        <select id="edit-si-kind-${id}" onchange="onEditMerchKindChange('${id}')">
          <option value="random">Random ver</option>
          <option value="member">Member ver</option>
        </select>
```
New:
```javascript
        <select id="edit-si-kind-${id}" onchange="onEditMerchKindChange('${id}')">
          <option value="random">Random ver</option>
          <option value="member">Member ver</option>
          <option value="member-set">Member set (order by set)</option>
        </select>
```

And make the merch-extra block empty (filled on change), replacing (~line 3237–3239):

Old:
```javascript
    <div id="edit-si-merch-extra-${id}" style="display:none;margin-top:8px;">
      <div class="field" style="margin-bottom:0;"><label>Members (one per line)</label><textarea id="edit-si-members-${id}" placeholder="Karina&#10;Winter&#10;Giselle&#10;Ningning" style="min-height:80px;font-family:var(--mono);font-size:12px;"></textarea></div>
    </div>`;
```
New:
```javascript
    <div id="edit-si-merch-extra-${id}" style="display:none;margin-top:8px;"></div>`;
```

- [ ] **Step 3: Rewrite `onEditMerchKindChange` to render kind-specific fields**

In `index.html` (~line 3263):

Old:
```javascript
function onEditMerchKindChange(id) {
  const kind = document.getElementById('edit-si-kind-' + id).value;
  const extra = document.getElementById('edit-si-merch-extra-' + id);
  if (extra) extra.style.display = kind === 'member' ? 'block' : 'none';
}
```
New:
```javascript
function onEditMerchKindChange(id) {
  const kind = document.getElementById('edit-si-kind-' + id).value;
  const extra = document.getElementById('edit-si-merch-extra-' + id);
  if (!extra) return;
  if (kind === 'member') {
    extra.style.display = 'block';
    extra.innerHTML = `<div class="field" style="margin-bottom:0;"><label>Members (one per line)</label><textarea id="edit-si-members-${id}" placeholder="Karina&#10;Winter&#10;Giselle&#10;Ningning" style="min-height:80px;font-family:var(--mono);font-size:12px;"></textarea></div>`;
  } else if (kind === 'member-set') {
    extra.style.display = 'block';
    extra.innerHTML = `<div class="field" style="margin-bottom:0;"><label>Members (one per line)</label><textarea id="edit-si-members-${id}" placeholder="Karina&#10;Winter&#10;Giselle&#10;Ningning" style="min-height:80px;font-family:var(--mono);font-size:12px;"></textarea></div>
      <div class="field" style="margin-top:8px;margin-bottom:0;"><label>Full set (OT) price (USD)</label><input type="number" id="edit-si-otprice-${id}" placeholder="0.00" step="0.01" value="0"><div class="field-hint">Optional — offer a whole-set (OT) claim.</div></div>
      <div class="field" style="margin-top:8px;margin-bottom:0;"><label>Order size — cards per batch (blank = full sets)</label><input type="number" id="edit-si-batchsize-${id}" min="0" step="1" placeholder="blank = full sets"><div class="field-hint">Set e.g. 8 or 16 to order in batches.</div></div>`;
  } else {
    extra.style.display = 'none';
    extra.innerHTML = '';
  }
}
```

- [ ] **Step 4: `saveGOEdits` — allow batch toggle + set-size for merch `member-set`**

In `index.html` `saveGOEdits`, the `canBatch` line (~3307):

Old:
```javascript
    const canBatch = go.type === 'photocard' || (si.kind === 'member' && go.type === 'album');
```
New:
```javascript
    const canBatch = go.type === 'photocard' || (si.kind === 'member' && go.type === 'album') || (si.kind === 'member-set' && go.type === 'merch');
```

In the batch→set conversion inside that block (~3318–3324), the merch GO has no `edit-go-min-secure` field (`minSecure` is `NaN`), so a converted `member-set` must fall back to its member count, not 7:

Old:
```javascript
      } else if (isBatch(si)) {
        if (newMembers0.length) si.members = newMembers0;
        si.sets = batchClaimsToSets(si);
        delete si.claims;
        si.minSecure = minSecure || 7;
        return;
      }
```
New:
```javascript
      } else if (isBatch(si)) {
        if (newMembers0.length) si.members = newMembers0;
        si.sets = batchClaimsToSets(si);
        delete si.claims;
        si.minSecure = (si.kind === 'member-set') ? (si.members.length || 7) : (minSecure || 7);
        return;
      }
```

- [ ] **Step 5: `saveGOEdits` — include `member-set` in the set-update and new-empty-set gates**

In `index.html` `saveGOEdits` (~line 3326), the members-diff-into-sets gate:

Old:
```javascript
    if (go.type === 'photocard' || (si.kind === 'member' && si.sets)) {
      si.minSecure = minSecure || si.minSecure;
```
New:
```javascript
    if (go.type === 'photocard' || (si.kind === 'member' && si.sets) || (si.kind === 'member-set' && si.sets)) {
      si.minSecure = minSecure || si.minSecure;
```
(For merch `member-set`, `minSecure` is `NaN` here, so `NaN || si.minSecure` preserves the stored member-count threshold — correct.)

And the newly-added-empty-set gate (~line 3352):

Old:
```javascript
    if ((go.type === 'photocard' || (si.kind === 'member' && si.sets)) && si.sets.length === 1 && Object.keys(si.sets[0].slots).length === 0) {
```
New:
```javascript
    if ((go.type === 'photocard' || (si.kind === 'member' && si.sets) || (si.kind === 'member-set' && si.sets)) && si.sets.length === 1 && Object.keys(si.sets[0].slots).length === 0) {
```

- [ ] **Step 6: `saveGOEdits` — build a new `member-set` item in the merch collection branch**

In `index.html` `saveGOEdits`, the new-item merch (`else`) branch (~line 3388–3394):

Old:
```javascript
    } else {
      if (kind === 'member') {
        const members = ((document.getElementById('edit-si-members-' + id)||{}).value||'').split('\n').map(m=>m.trim()).filter(Boolean);
        go.subItems.push({ id, name, kind:'member', members, price, claims:[] });
      } else {
        go.subItems.push({ id, name, kind:'random', price, claims:[] });
      }
    }
```
New:
```javascript
    } else {
      if (kind === 'member') {
        const members = ((document.getElementById('edit-si-members-' + id)||{}).value||'').split('\n').map(m=>m.trim()).filter(Boolean);
        go.subItems.push({ id, name, kind:'member', members, price, claims:[] });
      } else if (kind === 'member-set') {
        const members = ((document.getElementById('edit-si-members-' + id)||{}).value||'').split('\n').map(m=>m.trim()).filter(Boolean);
        const bs = parseInt((document.getElementById('edit-si-batchsize-' + id)||{}).value) || 0;
        if (bs > 0) {
          go.subItems.push({ id, name, kind:'member-set', members, minSecure:-bs, price, otPrice, claims:[] });
        } else {
          const slots = {}; members.forEach(m => slots[m] = null);
          go.subItems.push({ id, name, kind:'member-set', members, minSecure:members.length, price, otPrice, sets:[{ status:'open', slots, num:1 }], claims:[] });
        }
      } else {
        go.subItems.push({ id, name, kind:'random', price, claims:[] });
      }
    }
```

- [ ] **Step 7: JS-parse**

Run the JS-parse command from Global Constraints. Expected: `JS parses OK`.

- [ ] **Step 8: Manual verification (documented — DOM form)**

Edit an existing merch GO: add a new item, Kind = "Member set", enter members, save → new set-based item appears and renders as a set board. Reopen Edit → the item shows members + OT + batch-size fields prefilled. Set batch-size = 8, save → converts to a batch board; clear batch-size, save → converts back to a set board. Existing Random/Member-ver items on the same GO edit unchanged.

- [ ] **Step 9: Commit**

```bash
git add index.html
git commit -m "Merch member-set: edit + add set-based items in the Edit GO form

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Post-implementation

- **Redeploy** the Apps Script Web App (backend `isSet` changed) — user does this manually and reports "redeployed". Then live-curl a `member-set` submit and confirm the response includes an assigned `set_num`.
- **Push** `main` (frontend GitHub Pages) once the user approves; hard-refresh to bypass cache.
- End-to-end manual: create a merch GO with one `member-set` item + one existing Member-ver item; a buyer claims a member slot in the set; the set secures when full and when individually secured; owed/credit is correct in both admin and buyer (My Orders) views; the existing Member-ver item is unaffected.
