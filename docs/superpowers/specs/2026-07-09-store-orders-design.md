# Store-order tracker — Design

## Goal
Give the admin a place to record orders they placed with stores/proxies to fulfill a GO's
POBs: **which store**, **which album version**, **quantity + cost**, and a **status** through
Ordered → Warehouse → Shipped → Received. Each entry is **linked to a GO sub-item** (the POB).
Surfaced in two places: a **dedicated admin panel** (all store orders across GOs) and a
**per-GO section** inside Manage GO (filtered to that GO).

## Data model — new sheet `store_orders`
Columns:
`order_id, go_id, go_name, sub_item_id, sub_item_name, store, album_version, qty, unit_cost,
status, notes, created_at, updated_at`
- `status` ∈ `Ordered | Warehouse | Shipped | Received` (default `Ordered`).
- `go_name` / `sub_item_name` denormalized for display without cross-lookups.

## Backend (`go-manager-backend.gs`) — needs redeploy
- Add `const SHEET_STORE_ORDERS = 'store_orders';` and an `ensureSheet` line with the columns.
- `getStoreOrders()` → `{ store_orders: sheetToObjects(sheet) }`.
- `createStoreOrder(data)` → append row with a fresh `sto_<ts>_<rand>` id + timestamps; return `order_id`.
- `updateStoreOrder(data)` → `updateRowWhere('order_id', ...)` for any of
  `go_id, go_name, sub_item_id, sub_item_name, store, album_version, qty, unit_cost, status, notes`
  (+ `updated_at`).
- `deleteStoreOrder(order_id)` → `deleteRowWhere` (hard delete — GOM's own record, no dependents).
- Wire into the doGet router (`getStoreOrders`) and doPost router (`createStoreOrder`/
  `updateStoreOrder`/`deleteStoreOrder`).

## Frontend (`index.html`) — no redeploy for these, but depends on the backend above
- State `let storeOrders = [];` and `const STORE_STATUS = ['Ordered','Warehouse','Shipped','Received'];`.
- **Sync:** add `apiGet('getStoreOrders')` to the `Promise.all` in `syncFromBackend`; set
  `storeOrders = res.store_orders || []`.
- **Dedicated panel:** a "Store orders" `admin-section` on the admin home (near Shop orders /
  Shipping queue) with a `+ Add store order` button and `renderStoreOrders()` — a compact list
  grouped by GO: each row shows `sub-item · store · album version · qty · $cost · status`, a
  status control (advance ▸ / dropdown), Edit, and Delete.
- **Add/edit modal** `openStoreOrderModal(orderId?, prefillGoId?, prefillSiId?)`:
  GO `<select>` → sub-item `<select>` (cascades from the chosen GO's `subItems`), store (text),
  album version (text), qty (number), unit cost (number), status (select), notes (text).
  Save → `createStoreOrder` or `updateStoreOrder` (optimistic local update + `apiPost`).
- **Per-GO section:** in `renderDetailContent`, a collapsible "Store orders" block listing
  `storeOrders.filter(o => o.go_id === go.id)` with `+ Add` prefilled to this GO, plus inline
  status/edit/delete. Reuses `renderStoreOrders` row markup scoped to one GO.
- Status advance helper `storeNextStatus(status)`; a small `storeStatusBadge(status)` for color.

## Scope / non-goals
- Admin-only; buyers never see store orders.
- No automatic linkage to buyer claims/fulfillment (informational tracker only).
- Cost is for the admin's own bookkeeping; no totals/reporting beyond per-row display (a simple
  per-GO subtotal is a cheap add if wanted later).

## Verification
- Backend (post-redeploy): create/update/delete a store order via the app; confirm the
  `store_orders` sheet row appears/updates/removes; `getStoreOrders` returns it on sync.
- Frontend: add an order from the dedicated panel (pick GO → sub-item) and from within Manage GO
  (GO prefilled); it shows in both places; advancing status persists; delete removes it.
