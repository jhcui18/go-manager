# Picture per Sub-item — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One optional image URL per sub-item, set by the admin in Create/Edit GO, shown on the buyer claim page and as a thumbnail in the admin GO detail.

**Architecture:** Add an `image_url` column to the sub-item sheet (backend, redeploy). Frontend carries `imageUrl` on each sub-item; one image field per sub-item form, `imageUrl` set in a single post-pass on create/save, reconstructed on sync via an id→url map, and displayed via a `siImg(si,size)` helper. Reuses the shop-listing image pattern.

**Tech Stack:** Vanilla JS `index.html`; Apps Script `go-manager-backend.gs`.

## Global Constraints

- Frontend edits in `index.html`; backend in `go-manager-backend.gs`.
- Task 1 (backend) REQUIRES the user to redeploy. Frontend degrades gracefully before then (`imageUrl` empty → no image; setting one won't persist until redeploy).
- Frontend field `imageUrl` (camelCase); backend column/payload `image_url`. Backend reads `si.imageUrl` when writing rows (same as it reads `si.otPrice`).
- Direct URL only; broken links hidden via `onerror="this.style.display='none'"`. One image per sub-item.
- No test harness. Verify frontend with JS-parse; backend with `node --check` on a `.js` copy. JS-parse:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after each task.

---

### Task 1: Backend — `image_url` column + create/update wiring

**Files:**
- Modify: `go-manager-backend.gs` — `createGO` ensureSheet header (line ~145) + appendRow (line ~147); `updateGO` HEADERS (line ~178) + grid.push (line ~187).

- [ ] **Step 1: createGO — add column to the sub-item sheet header**

Change the `ensureSheet('go_' + goId, [...])` header array to end with `'image_url'`:

```javascript
  const siSheet = ensureSheet(ss, 'go_' + goId, ['sub_item_id','name','kind','members','versions','price','ot_price','min_secure','image_url']);
```

- [ ] **Step 2: createGO — write image_url in the appendRow**

```javascript
    siSheet.appendRow([si.id, si.name, si.kind || data.type, JSON.stringify(si.members || []), JSON.stringify(si.versions || []), si.price || 0, si.otPrice || 0, si.minSecure || data.min_secure || 7, si.imageUrl || '']);
```

- [ ] **Step 3: updateGO — add to HEADERS and grid**

```javascript
      const HEADERS = ['sub_item_id','name','kind','members','versions','price','ot_price','min_secure','image_url'];
```

```javascript
        grid.push([si.id, si.name || '', si.kind || '', JSON.stringify(si.members || []), JSON.stringify(si.versions || []), si.price || 0, si.otPrice || 0, si.minSecure || 7, si.imageUrl || '']);
```

- [ ] **Step 4: Syntax-check**

```bash
cp go-manager-backend.gs /tmp/img.js && node --check /tmp/img.js && echo "backend syntax OK"
```

- [ ] **Step 5: Commit**

```bash
git add go-manager-backend.gs
git commit -m "Backend: image_url column on sub-items + create/update wiring. REQUIRES REDEPLOY"
```

---

### Task 2: Admin plumbing — input field, save post-pass, sync

**Files:**
- Modify: `index.html` — add `imgFieldHtml` helper; add the field in `addSubItem`, `renderEditSubItems`, `addEditSubItem`; post-pass in `createGO` and `saveGOEdits`; id→url map in `syncFromBackend`.

**Interfaces:**
- Produces: `imgFieldHtml(fieldId, current)`; `si.imageUrl` on every sub-item after create/save/sync.

- [ ] **Step 1: Add the `imgFieldHtml` helper**

Add near `fmtDate` (any top-level spot, e.g. just before `function renderEditSubItems`):

```javascript
// One "Image URL" field for a sub-item form (create + edit). fieldId is the full input id.
function imgFieldHtml(fieldId, current) {
  return `<div class="field" style="margin-top:8px;margin-bottom:0;"><label>Image URL</label>
    <input type="text" id="${fieldId}" placeholder="https://… (direct image link)" value="${current || ''}">
    <div class="field-hint">Optional — shown to buyers on the claim page.</div></div>`;
}
```

- [ ] **Step 2: Create-GO form field (`addSubItem`)**

`addSubItem` builds `inner` per type then does `wrap.innerHTML = inner;`. Immediately before that function's `wrap.innerHTML = inner;` (anchor with its surrounding lines to hit the one in `addSubItem`), append the field:

```javascript
  inner += imgFieldHtml('si-img-' + id, '');
  wrap.innerHTML = inner;
```

- [ ] **Step 3: Edit-GO existing-item field (`renderEditSubItems`)**

In `renderEditSubItems`, the type branches append to `inner`, then this line closes the flex column and opens the right column:

```javascript
    inner += `</div>
      <div style="display:flex;flex-direction:column;align-items:flex-end;gap:6px;padding-top:20px;">
```

Insert the image field just before it (so it sits at the end of the item's field column):

```javascript
    inner += imgFieldHtml('edit-si-img-' + si.id, si.imageUrl || '');
    inner += `</div>
      <div style="display:flex;flex-direction:column;align-items:flex-end;gap:6px;padding-top:20px;">
```

- [ ] **Step 4: Edit-GO new-item field (`addEditSubItem`)**

Immediately before `addEditSubItem`'s `wrap.innerHTML = inner;` (anchor uniquely within that function):

```javascript
  inner += imgFieldHtml('edit-si-img-' + id, '');
  wrap.innerHTML = inner;
```

- [ ] **Step 5: `createGO` — set imageUrl on each sub-item (post-pass)**

After the sub-item assembly loop closes and before `allGOs[id] = { ... }`:

```javascript
  if (!subItems.length) { toast('Add at least one item.'); return; }
  subItems.forEach(si => { const el = document.getElementById('si-img-' + si.id); si.imageUrl = el ? el.value.trim() : ''; });
  allGOs[id] = { id, name, type, deadline, paymentDeadline, status: 'open', subItems };
```

- [ ] **Step 6: `saveGOEdits` — set imageUrl on each sub-item (post-pass)**

After the dedupe/name-filter block (the `{ const seenIds = {}; ... }` block) and before the `// AWAIT the write` comment, add:

```javascript
  go.subItems.forEach(si => { const el = document.getElementById('edit-si-img-' + si.id); if (el) si.imageUrl = el.value.trim(); });
```

- [ ] **Step 7: `syncFromBackend` — reconstruct imageUrl via id→url map**

In `syncFromBackend`, just before the `(go.subItems || []).forEach(si => {` reconstruction loop, declare a map; inside the loop (right after the blank-row guard) record it; after the loop and before `allGOs[go.go_id] = rebuilt;`, apply it.

Before the loop:

```javascript
        const imgById = {};
        (go.subItems || []).forEach(si => {
          if (!si || !si.sub_item_id || !si.name) return; // skip blank/ghost sub-item rows
          imgById[si.sub_item_id] = si.image_url || '';
```

After the loop (replace `allGOs[go.go_id] = rebuilt;`):

```javascript
        });
        rebuilt.subItems.forEach(s => { s.imageUrl = imgById[s.id] || ''; });
        allGOs[go.go_id] = rebuilt;
```

- [ ] **Step 8: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 9: Verify in browser**

Create GO with an item + image URL (after redeploy), or Edit an existing GO's item and paste a direct image URL, Save, reopen Edit GO — the URL persists in the field. In console, `allGOs['<goId>'].subItems.map(s=>s.imageUrl)` shows the saved URLs. (Before redeploy: the field shows and posts, but won't persist — expected.)

- [ ] **Step 10: Commit**

```bash
git add index.html
git commit -m "Sub-item images: admin image field (create/edit) + save + sync reconstruction"
```

---

### Task 3: Display — buyer claim cards + admin thumbnail

**Files:**
- Modify: `index.html` — add `siImg` helper; insert in `renderSetSubItemPublic`, `renderVersionedSubItemPublic`, `renderBatchSubItemPublic`, `renderSingleSubItemPublic`, `renderMerchPublic` (member + random branches); admin `renderDetailContent` body.

**Interfaces:**
- Consumes: `si.imageUrl` (Task 2). Produces: `siImg(si, size)`.

- [ ] **Step 1: Add the `siImg` helper**

Add near the buyer render functions (e.g. just before `function renderSetSubItemPublic`):

```javascript
// Sub-item image tag (or '' when none). size 'card' = full-width top of card; 'thumb' = small inline.
function siImg(si, size) {
  if (!si || !si.imageUrl) return '';
  const style = size === 'thumb'
    ? 'width:44px;height:44px;object-fit:cover;border-radius:6px;flex:none;'
    : 'width:100%;max-height:220px;object-fit:cover;border-radius:var(--radius);margin-bottom:10px;display:block;';
  return `<img src="${si.imageUrl}" loading="lazy" style="${style}" onerror="this.style.display='none'">`;
}
```

- [ ] **Step 2: Buyer cards — insert `${siImg(si,'card')}` at the top of each card**

In each of these functions, the card opens with `` `<div class="card" style="margin-bottom:12px;"> `` immediately followed by a header `<div style="display:flex;...`. Insert `${siImg(si,'card')}` right after the card-open and before the header, for:
- `renderSetSubItemPublic` (`let html = \`<div class="card" style="margin-bottom:12px;">${siImg(si,'card')}` …)
- `renderVersionedSubItemPublic` (same edit)
- `renderBatchSubItemPublic` (same edit)
- `renderSingleSubItemPublic` (this one uses `return \`<div class="card" …` — same insertion)
- `renderMerchPublic` **member branch** (`html += \`<div class="card" style="margin-bottom:12px;">${siImg(si,'card')}` …)
- `renderMerchPublic` **random branch** (the `// Random ver — just qty` block's `html += \`<div class="card" style="margin-bottom:12px;">${siImg(si,'card')}` …)

Each is the same change: put `${siImg(si,'card')}` immediately after `<div class="card" style="margin-bottom:12px;">`.

- [ ] **Step 3: Admin detail — thumbnail at the top of each sub-item body**

In `renderDetailContent`, the sub-item body opens with:

```javascript
    html += `<div id="adm-body-${si.id}" style="display:${siOpen ? 'block' : 'none'};">`;
```

Append the thumbnail right after it:

```javascript
    html += `<div id="adm-body-${si.id}" style="display:${siOpen ? 'block' : 'none'};">`;
    if (si.imageUrl) html += `<div style="margin-bottom:10px;">${siImg(si,'thumb')}</div>`;
```

- [ ] **Step 4: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 5: Verify in browser**

On a GO whose sub-items have image URLs: the buyer **Group orders** page shows each item's picture at the top of its card; broken/empty URLs show no image (no broken-image icon). In admin **Manage**, expanding a POB/item shows its thumbnail. Items without an image render exactly as before.

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "Sub-item images: show on buyer claim cards + admin detail thumbnail"
```

---

## Self-Review

**Spec coverage:** backend column + create/update → Task 1 ✓. Admin field (create/edit/new) + save post-pass + sync map → Task 2 ✓. Buyer cards + admin thumbnail via `siImg` → Task 3 ✓. Graceful pre-redeploy degradation (empty imageUrl → no image) ✓.

**Placeholder scan:** none.

**Type/name consistency:** frontend `imageUrl` set in `createGO`/`saveGOEdits`/`syncFromBackend` and read by `siImg`; backend `image_url` column read/written as `si.imageUrl` (Task 1) and returned by `getAllGOs` → mapped via `imgById` (Task 2 Step 7). Field ids: `si-img-${id}` (create, read in createGO), `edit-si-img-${si.id}`/`edit-si-img-${id}` (edit existing/new, read in saveGOEdits). `imgFieldHtml(fieldId,current)` and `siImg(si,size)` signatures match all call sites.
