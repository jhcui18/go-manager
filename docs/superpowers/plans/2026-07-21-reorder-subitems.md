# Reorder Sub-items (drag) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drag-to-reorder sub-items in the Edit GO list (pointer events, mouse+touch); the new order applies on Save. Frontend-only.

**Architecture:** Add a drag handle per sub-item row in `renderEditSubItems` + three pointer handlers that live-reorder the DOM during a drag and, on release, reorder `currentGO.subItems` to match. `saveGOEdits`/`updateGO` already persist in array order.

**Tech Stack:** Vanilla JS single-file `index.html`.

## Global Constraints

- Edit `index.html` only. No backend change / no redeploy.
- Pointer events (not HTML5 drag); handle has `touch-action:none` so dragging doesn't scroll.
- Dragging moves DOM nodes (never re-renders mid-drag) so in-progress typed edits are preserved. On release, reorder the array by DOM order; do not re-render.
- Only existing sub-items (`edit-wrap-<id>` rows) are reordered; unsaved new-item rows are ignored (they save last, as today).
- Works for all GO types.
- No test harness. Verify with JS-parse + manual browser (incl. touch). JS-parse:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after the task.

---

### Task 1: Drag-reorder sub-items in Edit GO

**Files:**
- Modify: `index.html` — add drag state + handlers immediately before `function renderEditSubItems()` (line ~2718); add a drag handle in the row's right-column block (line ~2779).

**Interfaces:**
- Consumes: `currentGO.subItems`, the `#edit-sub-items-list` container, per-row wrapper ids `edit-wrap-<si.id>`.
- Produces: `onSubItemDragStart(e, siId)`, `onSubItemDragMove(e)`, `onSubItemDragEnd()`.

- [ ] **Step 1: Add drag state + handlers**

Immediately before `function renderEditSubItems() {`, add:

```javascript
// Drag-to-reorder sub-items in Edit GO (pointer events; order applied on Save).
let dragWrapId = null;
function onSubItemDragStart(e, siId) {
  const wrap = document.getElementById('edit-wrap-' + siId);
  if (!wrap) return;
  dragWrapId = siId;
  wrap.style.opacity = '0.5';
  document.addEventListener('pointermove', onSubItemDragMove);
  document.addEventListener('pointerup', onSubItemDragEnd);
  e.preventDefault();
}
function onSubItemDragMove(e) {
  if (!dragWrapId) return;
  const container = document.getElementById('edit-sub-items-list');
  const dragEl = document.getElementById('edit-wrap-' + dragWrapId);
  if (!container || !dragEl) return;
  const siblings = [...container.children].filter(w => w !== dragEl);
  let target = null;
  for (const w of siblings) {
    const r = w.getBoundingClientRect();
    if (e.clientY < r.top + r.height / 2) { target = w; break; }
  }
  if (target) container.insertBefore(dragEl, target);
  else container.appendChild(dragEl);
}
function onSubItemDragEnd() {
  document.removeEventListener('pointermove', onSubItemDragMove);
  document.removeEventListener('pointerup', onSubItemDragEnd);
  const dragEl = dragWrapId && document.getElementById('edit-wrap-' + dragWrapId);
  if (dragEl) dragEl.style.opacity = '';
  const container = document.getElementById('edit-sub-items-list');
  if (container && currentGO && currentGO.subItems) {
    const order = [...container.children]
      .filter(w => w.id.indexOf('edit-wrap-') === 0)
      .map(w => w.id.slice('edit-wrap-'.length));
    currentGO.subItems.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
  }
  dragWrapId = null;
}
```

- [ ] **Step 2: Add the drag handle to each row**

In `renderEditSubItems`, replace the right-column block:

```javascript
    inner += `</div>
      <div style="display:flex;flex-direction:column;align-items:flex-end;gap:6px;padding-top:20px;">
        ${claimCount > 0 ? `<span style="font-size:11px;color:var(--text3);">${claimCount} claim${claimCount!==1?'s':''}</span>` : ''}
        <button class="btn btn-sm btn-ghost" style="color:var(--red-400);" onclick="removeEditSubItem('${si.id}',${hasClaims})">Remove</button>
      </div>
    </div>`;
```

with (adds a grip handle above the claim count):

```javascript
    inner += `</div>
      <div style="display:flex;flex-direction:column;align-items:flex-end;gap:6px;padding-top:20px;">
        <span onpointerdown="onSubItemDragStart(event,'${si.id}')" title="Drag to reorder" style="cursor:grab;touch-action:none;font-size:18px;line-height:1;color:var(--text3);user-select:none;">⠿</span>
        ${claimCount > 0 ? `<span style="font-size:11px;color:var(--text3);">${claimCount} claim${claimCount!==1?'s':''}</span>` : ''}
        <button class="btn btn-sm btn-ghost" style="color:var(--red-400);" onclick="removeEditSubItem('${si.id}',${hasClaims})">Remove</button>
      </div>
    </div>`;
```

- [ ] **Step 3: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 4: Verify in browser**

Open Edit GO on a GO with 3+ sub-items (a merch GO). Drag a row by its ⠿ handle up/down — the list live-shuffles and the dragged row follows; on release it stays in the new spot. Type something in a field, then drag another row — the typed value is preserved (no re-render). Click **Save changes**, reopen Edit GO (or Manage) — the new order persisted. On mobile, dragging the handle reorders without scrolling the page.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "Edit GO: drag-to-reorder sub-items (pointer events, applied on save)"
```

---

## Self-Review

**Spec coverage:** drag handle + pointer handlers → Steps 1–2 ✓; live DOM reorder preserving edits, array reordered on release, persisted on Save via existing updateGO → Steps 1 + spec ✓; all GO types (handle added unconditionally) ✓; frontend-only ✓.

**Placeholder scan:** none.

**Type/name consistency:** `onSubItemDragStart(event,'<si.id>')` in the handle matches the handler signature; `edit-wrap-<si.id>` ids match between `renderEditSubItems` (existing `wrap.id = 'edit-wrap-' + si.id`) and all three handlers; the array reorder keys on `si.id` present in `currentGO.subItems`.
