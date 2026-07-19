# My-orders Combined "Total to Pay" — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a combined "Total to pay across all GOs" summary at the top of My orders so buyers can send one consolidated transfer.

**Architecture:** Single-file `index.html`. In `doLookup`'s block render, sum each GO's `goPaymentSummary(u, go_id).owed` and prepend a summary card when the total is > 0.

**Tech Stack:** Vanilla JS single-file app. No backend change.

## Global Constraints

- Edit `/Users/jinghancui/Gitproj/Go-manager/index.html` only. No backend / no redeploy.
- Reuse `goPaymentSummary`; only the combined `owed` total is shown. Card hidden when total owed is 0. Per-GO blocks unchanged.
- Copy exact: `Total to pay across all GOs: $X`; note `You can send this in one transfer — just paste the same transaction ID on each GO's payment below.`
- No test harness. Verify with JS-parse check + manual browser. JS-parse:
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('/Users/jinghancui/Gitproj/Go-manager/index.html','utf8');const m=[...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n');new Function(m);console.log('JS parses OK');"
  ```
- Commit after the task.

---

### Task 1: Prepend combined total-to-pay card

**Files:**
- Modify: `index.html` — `doLookup`, the `else` branch that builds `goList` and sets `blocksEl.innerHTML`.

**Interfaces:**
- Consumes: `goList`, `goPaymentSummary(u, go_id)`, `renderMyOrderGoBlock`.

- [ ] **Step 1: Compute the total and prepend the card**

Replace this current code:

```javascript
    } else {
      const goList = [...new Map(rows.map(r => [r.go_id, { go_id: r.go_id, go: r.go }])).values()];
      goList.sort((a, b) => {
        if (a.go_id === 'shop') return 1;
        if (b.go_id === 'shop') return -1;
        return goCreatedTs({ id: b.go_id }) - goCreatedTs({ id: a.go_id });
      });
      blocksEl.innerHTML = goList.map(g => renderMyOrderGoBlock(g, rows.filter(r => r.go_id === g.go_id), u)).join('');
    }
```

with:

```javascript
    } else {
      const goList = [...new Map(rows.map(r => [r.go_id, { go_id: r.go_id, go: r.go }])).values()];
      goList.sort((a, b) => {
        if (a.go_id === 'shop') return 1;
        if (b.go_id === 'shop') return -1;
        return goCreatedTs({ id: b.go_id }) - goCreatedTs({ id: a.go_id });
      });
      const totalOwed = goList.reduce((a, g) => a + goPaymentSummary(u, g.go_id).owed, 0);
      const totalCard = totalOwed > 0 ? `<div class="card" style="margin-bottom:12px;">
        <div style="font-size:15px;font-weight:500;">Total to pay across all GOs: <span style="font-family:var(--mono);">$${totalOwed.toFixed(2)}</span></div>
        <div style="font-size:12px;color:var(--text3);margin-top:4px;">You can send this in one transfer — just paste the same transaction ID on each GO's payment below.</div>
      </div>` : '';
      blocksEl.innerHTML = totalCard + goList.map(g => renderMyOrderGoBlock(g, rows.filter(r => r.go_id === g.go_id), u)).join('');
    }
```

- [ ] **Step 2: JS-parse check**

Run the Global-Constraints JS-parse check. Expected: `JS parses OK`.

- [ ] **Step 3: Verify in browser**

Look up a buyer who owes across 2+ GOs: a card at the very top reads **Total to pay across all GOs: $X**, where X equals the sum of the per-GO **Owed** figures below, with the one-transfer/same-txid note. A buyer who owes nothing (all paid or only pending/credit) shows **no** total card, just their per-GO blocks. A lookup with no claims still shows "No claims found".

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "My orders: combined 'Total to pay across all GOs' summary for consolidated payment"
```

---

## Self-Review

**Spec coverage:** total owed summed from `goPaymentSummary`, prepended above blocks, hidden at 0, per-GO blocks unchanged → Step 1 ✓. Copy strings exact → Step 1 ✓. Frontend-only → Global Constraints ✓.

**Placeholder scan:** none.

**Type/name consistency:** `goPaymentSummary(u, g.go_id).owed` matches the helper's return field; `totalCard` prepended to the existing `goList.map(...renderMyOrderGoBlock...)` join — same call as before, only prefixed.
