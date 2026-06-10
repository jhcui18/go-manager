# GO Manager — Developer Notes for Claude Code

## Overview
A single-file web app (`index.html`) for managing K-pop group orders (GOs).
- Joiners browse GOs, submit claims, upload payment proof, request shipping
- Admin creates/edits GOs, manages claims, confirms payments, handles shipping
- Backend: Google Apps Script Web App writing to Google Sheets
- Hosted: GitHub Pages at https://jhcui18.github.io/go-manager/

---

## File Structure
```
index.html              — entire app (HTML + CSS + JS, ~2100 lines)
go-manager-backend.gs   — Google Apps Script backend (paste into Apps Script editor)
NOTES.md                — this file
```

---

## Known Bugs to Fix

### 1. createGO does nothing (CRITICAL)
The API layer at the bottom of the script redefines several functions using
`async function functionName()` syntax. In JavaScript, function declarations
are hoisted, so the second declaration overrides the first — but the second
version calls `_createGOCore()` which is the renamed original. The issue is
that `_createGOCore` and `_saveGOEditsCore` were created by renaming the
originals, but during the rename the first line of `_createGOCore` got
accidentally truncated (was missing `const name = document.getElementById...`).
This has been partially fixed but the function may still have issues.

**Root cause:** The API patching approach (redefining functions) is fragile.
**Recommended fix:** Remove all function redefinitions from the API layer.
Instead, add `if (API_URL) apiPost(...)` calls directly inside the original
functions at the point where data changes. The functions to fix:
- `_createGOCore` → rename back to `createGO`, add API call at end
- `_saveGOEditsCore` → rename back to `saveGOEdits`, add API call at end
- `submitClaim` — defined twice, merge into one function
- `advanceSetFulfill` — defined twice, merge into one
- `advanceFCFSFulfill` — defined twice, merge into one
- `secureSet` — defined twice, merge into one

### 2. Data doesn't persist on refresh
`syncFromBackend()` is called on page load if `API_URL` is set (stored in
localStorage). This should pull all GOs from Google Sheets. The sync logic
in `buildSetsFromClaims` reconstructs set/slot state from the `joiners` sheet.
Needs testing to verify it fully reconstructs GO state correctly after a refresh.

---

## Data Model

### allGOs (in-memory, synced to/from Sheets)
```javascript
allGOs = {
  [go_id]: {
    id: string,
    name: string,
    type: 'photocard' | 'album' | 'merch',
    deadline: string (YYYY-MM-DD),
    status: 'open' | 'closed',
    subItems: SubItem[]
  }
}
```

### SubItem types
```javascript
// Photocard set OR Album member ver — set-based, needs minSecure to secure
{
  id, name,
  kind: 'photocard' | 'member',   // photocard for PC sets, member for album member ver
  members: string[],               // e.g. ['Karina','Winter','Giselle','Ningning']
  minSecure: number,               // e.g. 7 (out of 8 to secure)
  price: number,
  sets: Set[]
}

// Album versioned ver — FCFS, versions assigned by qty
{
  id, name,
  kind: 'versioned',
  versions: string[],              // e.g. ['A','B']
  price: number,
  claims: VersionedClaim[]
}

// Merch random ver — FCFS, version random
{
  id, name,
  kind: 'random',
  price: number,
  claims: MerchClaim[]
}

// Merch member ver — FCFS per member, no set logic, no cap
{
  id, name,
  kind: 'member',
  members: string[],
  price: number,
  claims: MerchMemberClaim[]
}
```

### Set structure
```javascript
{
  status: 'open' | 'secured',
  slots: {
    [memberName]: null | {
      user: string,        // '@username'
      payment: 'unpaid' | 'paid',
      fulfillment: 'Pending' | 'On the way' | 'Ready' | 'Dispatched',
      claim_id: string     // from Sheets, for updates
    }
  }
}
```

### Claims
```javascript
// Versioned / merch random
{ user, qty, assignedVers: string[], payment, fulfillment, claim_id }

// Merch member
{ user, qty, member: string, assignedVers: [], payment, fulfillment, claim_id }
```

### Version assignment logic
- qty 1 → ['random']
- qty 2 → ['A', 'B']
- qty 3+ → ['A', 'B', 'random', ...]  (A+B then random for remainder)

---

## Google Sheets Structure

| Sheet | Columns |
|-------|---------|
| `_gos` | go_id, name, type, deadline, status, min_secure, created_at |
| `joiners` | claim_id, go_id, go_name, sub_item_id, sub_item_name, sub_item_kind, username, email, member_or_version, set_num, qty, assigned_vers, claim_status, payment_status, fulfillment, created_at, updated_at |
| `payments` | payment_id, username, go_id, go_name, amount, method, transaction_id, proof_url, email, status, created_at |
| `shipping` | request_id, username, go_ids, full_name, address1, address2, city, state, postal, country, notes, email, card_count, ems_fee, dom_fee, total_fee, shipped, created_at |
| `go_{id}` | sub_item_id, name, kind, members (JSON), versions (JSON), price, min_secure |

---

## API Layer (Google Apps Script)

All requests go through `API_URL` (saved in localStorage as `go_api_url`).

```javascript
// GET actions
apiGet('getAllGOs')           → { gos: [...] }
apiGet('getJoiners', { username })  → { claims: [...] }
apiGet('getPayments')         → { payments: [...] }
apiGet('getShipping')         → { requests: [...] }
apiGet('ping')                → { ok: true }

// POST actions
apiPost('bootstrap', {})
apiPost('createGO', goData)
apiPost('updateGO', { go_id, name, deadline, status, subItems })
apiPost('deleteGO', { go_id })
apiPost('submitClaim', { claims: [...] })
apiPost('updateClaim', { claim_id, payment_status?, fulfillment?, claim_status? })
apiPost('deleteClaim', { claim_id })
apiPost('secureSet', { go_id, sub_item_id, set_num })
apiPost('submitPayment', paymentData)
apiPost('updatePayment', { payment_id, status, username?, go_id? })
apiPost('submitShipping', shippingData)
apiPost('updateShipping', { request_id, ems_fee, dom_fee, total_fee, shipped })
```

---

## Key Functions Reference

| Function | Purpose |
|----------|---------|
| `renderOrdersList()` | Renders public GO cards on orders page |
| `openClaimPage(goId)` | Navigates to claim page for a GO, inits claimState |
| `renderClaimPage(goId)` | Builds claim UI based on GO type |
| `submitClaim(goId)` | Processes claim submission, writes to Sheets |
| `renderDetailContent()` | Admin GO detail — sets, claims table, log input |
| `logSetClaim(goId, siId)` | Admin logs IG comment claim |
| `secureSet(goId, siId, setIdx)` | Marks set as secured |
| `syncFromBackend()` | Pulls all data from Sheets on page load |
| `renderAdminGOList()` | Admin home GO list |
| `showAdminPanel(panel)` | Switches between admin sub-panels |
| `showPage(id)` | Main page navigation |
| `createGO()` / `_createGOCore()` | Creates new GO — BUGGY, needs fix |
| `saveGOEdits()` / `_saveGOEditsCore()` | Saves GO edits — needs cleanup |

---

## CSS Variables (theming)
```css
--accent: #D4537E        /* pink — primary */
--teal-400: #1D9E75      /* secured/paid states */
--amber-800: #633806     /* pending states */
--red-400: #E24B4A       /* unpaid/error states */
--surface: #ffffff
--surface2: #F1EFE8
--bg: #faf9f7
--text: #2C2C2A
--text2: #5F5E5A
--text3: #888780
--radius: 10px
--radius-lg: 16px
--font: 'DM Sans', sans-serif
--mono: 'DM Mono', monospace
```

---

## Fulfillment States (linear, no backwards)
`Pending` → `On the way` → `Ready` → `Dispatched`

---

## Shipping Fee Logic
- Cards: $0.50 per card (EMS fee, auto-calculated)
- Albums/merch: domestic fee input manually per package
- Total = EMS fee + domestic fee

---

## What Still Needs Building
- [ ] Fix createGO / duplicate function bug (see Known Bugs)
- [ ] Email notifications via EmailJS (claim received, payment confirmed, item arrived, dispatched)
- [ ] Payment proof image upload that actually stores the image (currently no storage)
- [ ] Joiner-facing order status page shows live data from Sheets on lookup
- [ ] Admin: bulk fulfillment update (mark all items for a GO as "On the way" at once)
- [ ] Mobile responsiveness improvements
- [ ] Per-GO payment amount auto-calculation based on claimed items × price
