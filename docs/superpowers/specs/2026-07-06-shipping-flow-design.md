# Unified Shipping Flow — Design

Date: 2026-07-06
App: GO Manager (`index.html` + `go-manager-backend.gs`)

## Goal

Let a buyer request shipping for their ready items — group-order claims and shop
orders together — in one shipment with one address, entered by the buyer in My
orders. The admin sees each request in a shipping queue, records a shipping fee (paid
off-app), and marks it shipped, which flips the bundled items to their shipped state.

## Prerequisite change — shop order status ladder

Shop items are **in stock** (not preorders), so they use their own status ladder
**Pending → Ready → Shipped** instead of the GO 5-stage ladder
(Pending → Ordered → On the way → Ready → Dispatched). Payment stays a separate
Paid/Unpaid toggle. GO claims keep their 5-stage ladder.

- Add `SHOP_FULFILLMENT = ['Pending','Ready','Shipped']`.
- `advanceShopFulfill` steps through `SHOP_FULFILLMENT` (not the global one).
- Badge: 'Shipped' shows teal (reuse `badge-secured`); 'Ready' `badge-ready`;
  'Pending' `badge-pending`.
- New shop orders still start at `Pending` (backend already writes that).

## Ship-eligibility (uniform rule)

An item is ready to ship — and appears in a buyer's Request-shipping bundle — only
when it is **Paid AND Ready**, and **not already in a shipping request**:

- GO claim: `payment_status === 'paid'` AND `fulfillment === 'Ready'`.
- Shop order: `payment_status === 'paid'` AND `fulfillment === 'Ready'`.

"Not already in a request" = its id doesn't appear in any existing shipping request's
`items` list (so re-requesting won't double-bundle it).

## Data model

### `shipping` sheet — add one column
Existing: `request_id, username, go_ids, full_name, address1, address2, city, state,
postal, country, notes, email, card_count, ems_fee, dom_fee, total_fee, shipped,
created_at`. Add:
- `items`: JSON array of the bundled items:
  `[{"type":"claim","id":"c_...","label":"GO — Karina"},{"type":"shop","id":"sho_...","label":"Album — Ver A"}]`.

`shipped` (existing boolean) marks the request complete. Address + fee fields reuse
existing columns.

### Item identity
- GO claim item id = the claim's `claim_id` (each set slot / FCFS claim has one).
- Shop order item id = `order_id`.

## Backend (`go-manager-backend.gs`) — needs redeploy

- `bootstrapSheets`: add `items` to the `shipping` headers (ensureSheet now
  auto-migrates the column onto the existing sheet).
- `submitShipping(data)`: append a request row — `request_id = 'ship_<ts>_<rand>'`,
  `username`, address fields, `items` (JSON), `shipped = false`, `created_at`.
  Returns `{ ok:true, request_id }`.
- `getShipping()`: return all shipping requests (`{ shipping:[...] }`).
- `updateShipping(data)`: set fee fields (`ems_fee`/`dom_fee`/`total_fee`) and/or
  `shipped`. **When `shipped` becomes true**, mark each bundled item shipped:
  - `type:'claim'` → set that `claim_id`'s `fulfillment = 'Dispatched'` in `joiners`.
  - `type:'shop'` → set that `order_id`'s `fulfillment = 'Shipped'` in `shop_orders`.
- Routes for `getShipping` / `submitShipping` / `updateShipping` already exist — the
  functions just need updating (`submitShipping` to store `items`; `updateShipping` to
  mark bundled items shipped; `getShipping` unchanged).

## Frontend (`index.html`)

### Buyer — Request shipping (in My orders)
- After `doLookup`, compute the buyer's **ship-eligible** items (paid+Ready, not
  already requested) across GO claims (from `allGOs`) and shop orders (from
  `shopOrders`).
- If any, show a **Request shipping** panel below the claims table: the list of
  items to be shipped + an **address form** (full name, address 1/2, city, state,
  postal, country, notes) + **Submit shipping request**.
- Submit → `submitShipping({ username, ...address, items })`; on success show a
  confirmation, add the request to local `shippingRequests` (so the items drop out of
  the eligible list), and re-render.

### Admin — shipping queue (rework `#page-shipping`)
- Replace the auto-populate (`refreshShippingQueue`) with rendering **buyer-submitted
  requests** from `shippingRequests` (loaded via `getShipping` on sync).
- Each open request (`shipped` false): buyer, bundled items (labels), full address,
  editable **shipping fee** field(s), and a **Mark shipped** button.
- **Mark shipped** → `updateShipping({ request_id, ems_fee/dom_fee/total_fee,
  shipped:true })`; locally mark the request shipped and flip its items
  (GO→Dispatched, shop→Shipped); re-render queue, GO detail, shop orders.

### Sync
- `syncFromBackend` also fetches `getShipping` (in the existing `Promise.all`) and
  populates `shippingRequests`; renders the shipping queue.

## Out of scope

- In-app shipping **payment** (buyer pays the fee off-app; app only records the fee).
- Auto-calculated fees (admin enters them).
- Editing/cancelling a submitted request by the buyer (admin can mark shipped; buyer
  re-requests only remaining eligible items).
- Remembering a buyer's address across requests (they enter it each time).

## Edge cases

- **No eligible items:** no Request-shipping panel shown.
- **Partial readiness:** only paid+Ready items are bundled; the rest stay in My orders
  and can be requested later in a second shipment.
- **Item already requested:** excluded from the eligible list (matched by id in any
  request's `items`).
- **Marking shipped with missing item ids:** if a bundled `claim_id`/`order_id` no
  longer exists, skip it (no error) and still complete the request.
