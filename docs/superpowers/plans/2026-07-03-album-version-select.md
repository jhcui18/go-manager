# Buyer-Selectable Album Versions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let buyers tap to choose specific versions (with per-version quantity) for album "Other ver" sub-items, instead of the current quantity-only auto-assign.

**Architecture:** Frontend-only. Replace `renderVersionedSubItemPublic` (album `versioned` only) with a version tile picker mirroring the photocard member picker; add a `version-select` claim state with per-version quantities; handle it in `updateClaimSummary` and `submitClaim`, storing each selected version as a claim tagged `member_or_version=<version>`. Merch "random ver" (which shares `assignVersions`/the qty path) is untouched. No backend/sheet change, no redeploy.

**Tech Stack:** Vanilla single-file HTML/CSS/JS (`index.html`), GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-07-03-album-version-select-design.md`

---

## Verification approach (read first)

No test framework. Verify each task by extracting inline JS and running `node --check`:
```bash
python3 -c "import re;h=open('index.html').read();open('/tmp/go_check.js','w').write('\n;\n'.join(re.findall(r'<script>(.*?)</script>',h,re.S)))" && node --check /tmp/go_check.js && echo "JS OK"
```
Then manual browser check after deploy (Task 5). Do not add a test framework or split the file.

## Naming (keep consistent)

- Claim state for album versioned: `claimState[siId] = { type:'version-select', selected:{ [versionName]: qty } }`.
- Tile element ids: `vtile-<siId>-<key>`, `vsub-<siId>-<key>`, `vdec-<siId>-<key>` where `key = version.replace(/\s/g,'_')`.
- Handlers: `incVersion(siId, version, goId)`, `decVersion(...)`, `updateVersionTile(...)`.

---

## Task 1: Version picker render + claim-state init

**Files:** Modify `index.html`

- [ ] **Step 1: Pre-init album versioned claim state as version-select**

Find:
```javascript
    } else {
      claimState[si.id] = { type:'versioned', qty:0 };
    }
  });
}
```
Replace with:
```javascript
    } else if (kind === 'versioned') {
      claimState[si.id] = { type:'version-select', selected:{} };
    } else {
      claimState[si.id] = { type:'versioned', qty:0 };
    }
  });
}
```

- [ ] **Step 2: Replace renderVersionedSubItemPublic with a version picker**

Find the entire function:
```javascript
function renderVersionedSubItemPublic(si, goId) {
  const totalClaimed = si.claims.reduce((a,c)=>a+c.qty,0);
  const verDisplay = si.versions && si.versions.length ? si.versions.join(' / ') : '';
  return `<div class="card" style="margin-bottom:12px;">
    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px;">
      <div style="font-weight:500;font-size:15px;">${si.name}</div>
      <span class="badge badge-fcfs">FCFS</span>
    </div>
    <div style="font-size:12px;color:var(--text3);margin-bottom:12px;">${verDisplay ? 'Versions: ' + verDisplay + ' &nbsp;·&nbsp; ' : ''}$${si.price.toFixed(2)} per copy &nbsp;·&nbsp; ${totalClaimed} claimed</div>
    <div style="font-size:12px;color:var(--text2);margin-bottom:10px;">1 copy → random ver &nbsp;·&nbsp; 2 copies → 1A + 1B &nbsp;·&nbsp; 3+ → A+B then random</div>
    <div class="qty-row">
      <button class="qty-btn" onclick="adjustVersionedQty('${si.id}','${goId}',-1)">−</button>
      <span style="font-size:15px;font-weight:500;min-width:24px;text-align:center;" id="qty-val-${si.id}">0</span>
      <button class="qty-btn" onclick="adjustVersionedQty('${si.id}','${goId}',1)">+</button>
      <span style="font-size:12px;color:var(--text3);margin-left:4px;" id="qty-ver-${si.id}"></span>
    </div>
  </div>`;
}
```
Replace with:
```javascript
function renderVersionedSubItemPublic(si, goId) {
  const totalClaimed = si.claims.reduce((a,c)=>a+c.qty,0);
  const versions = (si.versions && si.versions.length) ? si.versions : ['Default'];
  let html = `<div class="card" style="margin-bottom:12px;">
    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px;">
      <div style="font-weight:500;font-size:15px;">${si.name}</div>
      <span class="badge badge-fcfs">FCFS</span>
    </div>
    <div style="font-size:12px;color:var(--text3);margin-bottom:12px;">$${(si.price||0).toFixed(2)} per copy &nbsp;·&nbsp; ${totalClaimed} claimed</div>
    <div style="font-size:12px;color:var(--text2);margin-bottom:10px;">Tap a version to add one &nbsp;·&nbsp; tap again for more &nbsp;·&nbsp; − to reduce</div>
    <div class="member-grid" id="vpicker-${si.id}">`;
  versions.forEach(version => {
    const key = version.replace(/\s/g,'_');
    html += `<div class="member-tile" id="vtile-${si.id}-${key}" style="position:relative;" onclick="incVersion('${si.id}','${version}','${goId}')">
      <button id="vdec-${si.id}-${key}" onclick="event.stopPropagation();decVersion('${si.id}','${version}','${goId}')" style="display:none;align-items:center;justify-content:center;position:absolute;top:2px;right:2px;width:22px;height:22px;padding:0;border:none;border-radius:6px;background:transparent;color:var(--accent);font-size:18px;font-weight:600;line-height:1;cursor:pointer;">−</button>
      <div class="member-tile-name">${version}</div>
      <div class="member-tile-sub" id="vsub-${si.id}-${key}" data-label="tap to add" style="color:var(--accent);">tap to add</div>
    </div>`;
  });
  html += `</div>
    <div id="qty-display-${si.id}" style="margin-top:10px;font-size:12px;color:var(--text3);"></div>
  </div>`;
  return html;
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
git commit -m "Album versioned: version tile picker + version-select claim state"
```

---

## Task 2: Version picker handlers

**Files:** Modify `index.html`

- [ ] **Step 1: Add incVersion/decVersion/updateVersionTile**

Find the function `updateMemberTile` and its closing. It ends with:
```javascript
  const display = document.getElementById('qty-display-' + siId);
  if (display) {
    const parts = Object.keys(sm).map(m => m + ' ×' + sm[m]);
    display.textContent = parts.length ? 'Selected: ' + parts.join(', ') : '';
  }
  updateClaimSummary(goId);
}
```
Insert AFTER that closing `}` (a new block):
```javascript

function incVersion(siId, version, goId) {
  if (!claimState[siId] || claimState[siId].type !== 'version-select') claimState[siId] = { type:'version-select', selected:{} };
  const sel = claimState[siId].selected;
  sel[version] = (sel[version] || 0) + 1;
  updateVersionTile(siId, version, goId);
}

function decVersion(siId, version, goId) {
  const st = claimState[siId];
  if (!st || !st.selected) return;
  const sel = st.selected;
  if (sel[version]) { sel[version] -= 1; if (sel[version] <= 0) delete sel[version]; }
  updateVersionTile(siId, version, goId);
}

function updateVersionTile(siId, version, goId) {
  const key = version.replace(/\s/g,'_');
  const sel = (claimState[siId] && claimState[siId].selected) || {};
  const qty = sel[version] || 0;
  const tile = document.getElementById('vtile-' + siId + '-' + key);
  const sub = document.getElementById('vsub-' + siId + '-' + key);
  const dec = document.getElementById('vdec-' + siId + '-' + key);
  if (tile) tile.classList.toggle('selected', qty > 0);
  if (dec) dec.style.display = qty > 0 ? 'flex' : 'none';
  if (sub) sub.textContent = qty > 0 ? '×' + qty : (sub.dataset.label || '');
  const display = document.getElementById('qty-display-' + siId);
  if (display) {
    const parts = Object.keys(sel).map(v => v + ' ×' + sel[v]);
    display.textContent = parts.length ? 'Selected: ' + parts.join(', ') : '';
  }
  updateClaimSummary(goId);
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
git commit -m "Add version picker handlers (incVersion/decVersion/updateVersionTile)"
```

---

## Task 3: Claim summary for version-select

**Files:** Modify `index.html`

- [ ] **Step 1: Add the version-select branch in updateClaimSummary**

Find (in `updateClaimSummary`):
```javascript
    } else if (state.type === 'merch-member') {
      const selected = Object.keys(state.selectedMembers || {});
      const qty = state.qty || 1;
      if (selected.length) {
        lines.push(si.name + ': ' + selected.map(m => m + ' ×' + qty).join(', ') + (price ? ` ($${(price * selected.length * qty).toFixed(2)})` : ''));
        total += price * selected.length * qty;
      }
    } else {
```
Replace with (insert a `version-select` branch before the final `else`):
```javascript
    } else if (state.type === 'merch-member') {
      const selected = Object.keys(state.selectedMembers || {});
      const qty = state.qty || 1;
      if (selected.length) {
        lines.push(si.name + ': ' + selected.map(m => m + ' ×' + qty).join(', ') + (price ? ` ($${(price * selected.length * qty).toFixed(2)})` : ''));
        total += price * selected.length * qty;
      }
    } else if (state.type === 'version-select') {
      const sel = state.selected || {};
      const versions = Object.keys(sel);
      if (versions.length) {
        const totalQty = versions.reduce((a, v) => a + sel[v], 0);
        lines.push(si.name + ': ' + versions.map(v => v + ' ×' + sel[v]).join(', ') + (price ? ` ($${(price * totalQty).toFixed(2)})` : ''));
        total += price * totalQty;
      }
    } else {
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
git commit -m "Claim summary: version-select line (per-version qty)"
```

---

## Task 4: Submit version-select claims

**Files:** Modify `index.html`

- [ ] **Step 1: Add the version-select branch in submitClaim**

Find:
```javascript
    } else if (state.qty > 0) {
      const assigned = si.versions ? assignVersions(state.qty, si.versions) : [];
      si.claims.push({ user:u, qty:state.qty, assignedVers:assigned, payment:'unpaid', fulfillment:'Pending' });
      claimsToWrite.push({ go_id:goId, go_name:go.name, sub_item_id:si.id, sub_item_name:si.name, sub_item_kind:si.kind||go.type, username:u, email, member_or_version:'', set_num:'', qty:state.qty, assigned_vers:assigned.join('+') });
      placed = true;
```
Replace with (insert a `version-select` branch before it):
```javascript
    } else if (state.type === 'version-select') {
      const sel = state.selected || {};
      const versions = Object.keys(sel);
      if (!versions.length) return;
      versions.forEach(version => {
        const qty = sel[version];
        si.claims.push({ user:u, qty, member:version, assignedVers:[version], payment:'unpaid', fulfillment:'Pending' });
        claimsToWrite.push({ go_id:goId, go_name:go.name, sub_item_id:si.id, sub_item_name:si.name, sub_item_kind:si.kind||go.type, username:u, email, member_or_version:version, set_num:'', qty, assigned_vers:version });
        placed = true;
      });
    } else if (state.qty > 0) {
      const assigned = si.versions ? assignVersions(state.qty, si.versions) : [];
      si.claims.push({ user:u, qty:state.qty, assignedVers:assigned, payment:'unpaid', fulfillment:'Pending' });
      claimsToWrite.push({ go_id:goId, go_name:go.name, sub_item_id:si.id, sub_item_name:si.name, sub_item_kind:si.kind||go.type, username:u, email, member_or_version:'', set_num:'', qty:state.qty, assigned_vers:assigned.join('+') });
      placed = true;
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
git commit -m "Submit: version-select creates one claim per chosen version"
```

---

## Task 5: Deploy + manual verification

**Files:** none (deploy + manual). No backend redeploy needed.

- [ ] **Step 1: Push**

```bash
git push
```

- [ ] **Step 2: Wait for the live deploy**

```bash
for i in $(seq 1 25); do n=$(curl -s "https://jhcui18.github.io/go-manager/index.html?cb=$(date +%s%N)" | grep -c "function incVersion"); if [ "$n" -gt 0 ]; then echo "LIVE after ~$((i*10))s"; break; fi; sleep 10; done
```
Expected: `LIVE after ~Ns`

- [ ] **Step 3: Manual — admin sets up a mixed album GO**

Hard-refresh. Admin → New GO → type Album. Add two sub-items:
- "Photobook ver" → Kind **Other ver** → versions `A,B`
- "Accordion ver" → Kind **Member ver** → a member list
Save.

- [ ] **Step 4: Manual — buyer selects versions**

Open the album GO (Group orders). On "Photobook ver", tap **A** (shows ×1), tap **A** again (×2), tap **B** (×1); confirm the claim summary reads "Photobook ver: A ×2, B ×1" with the right total. On "Accordion ver", pick a member. Enter a username → Submit.

- [ ] **Step 5: Manual — verify displays**

In My orders (look up that username): confirm rows show "A", "A", "B" (or A ×2, B ×1) for the photobook, and the member for the accordion. In Admin → GO detail, the FCFS table shows the chosen versions. Confirm merch "random ver" on a separate merch GO still uses its quantity stepper (unchanged).

- [ ] **Step 6: Final commit (only if manual checks surfaced a fix)**

```bash
git add index.html && git commit -m "Fix album version-select issue found in verification" && git push
```

---

## Notes

- **Scope:** only album `versioned` sub-items change. `assignVersions`, `adjustVersionedQty`, and the `state.qty` submit branch remain for merch "random ver".
- **No backend change / redeploy** — versions store in the existing `member_or_version` column; `buildVersionedClaims` already carries it as `member` on sync.
- **Known limitation (same as members today):** a version name containing a single quote would break the inline `onclick`; version names are plain text (A, B, POB, etc.).
