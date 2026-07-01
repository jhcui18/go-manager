# Shop (Leftover Sales) Feature — Design

Date: 2026-06-30
App: GO Manager (`index.html` + `go-manager-backend.gs`, Apps Script + Google Sheets)

## Goal

Let the manager sell leftover stock (photocards, merch, albums) through the site.
Buyers browse a Shop page, place an order for in-stock items, and pay via the same
payment flow used for group orders. The manager manages listings and tracks orders
(paid/unpaid, fulfillment) like a lightweight version of GOs.

## Decisions (locked)

- **Order flow:** Instant claim — buyer picks qty + enters username, order is placed
  immediately (first-come), stock decrements. Then they pay via the existing My
  orders → Pay flow.
- **Photos:** Each listing has an image shown to buyers, provided as a pasted image
  URL (no file upload — fits the Sheets backend). Lazy-loaded.
- **Stock:** Quantity per listing. Buyer can order 1+ (capped at stock). Stock
  decrements on order; at 0 the listing shows "Sold out". Decrement happens
  **server-side** to prevent overselling across sessions.
- **Payment:** Reuses the existing payment machinery. Shop orders appear in My
  orders alongside GO claims and are paid through the same Pay panel.

## Architecture

The shop is its own subsystem with clear boundaries, reusing existing UI/patterns:

- **Public Shop page** (new nav tab) — browse + order.
- **Admin Shop area** — manage listings (CRUD) + view/track orders.
- **My orders integration** — shop orders show for the looked-up username and feed
  the existing owed-amount + Pay panel.
- **Backend** — two new sheets (`listings`, `shop_orders`) + endpoints. One Apps
  Script redeploy required.

## Data model

### `listings` sheet
`listing_id, name, category, price, image_url, qty, note, status, created_at`

- `listing_id`: `lst_<timestamp>_<rand>` (unique, like claim_id).
- `category`: `Photocard | Merch | Album` (for grouping/labels).
- `price`: unit price (USD).
- `qty`: current stock (integer). Decrements on order.
- `note`: optional short description (condition, etc.).
- `status`: `active | hidden` (hidden = not shown to buyers; soft-delete/keep history).

### `shop_orders` sheet
`order_id, listing_id, listing_name, username, email, qty, unit_price, payment_status, fulfillment, created_at, updated_at`

- `order_id`: `sho_<timestamp>_<rand>` (unique).
- `payment_status`: `unpaid | paid`.
- `fulfillment`: same ladder as GOs (`Pending → Ordered → On the way → Ready → Dispatched`).

## Backend endpoints (new) — `go-manager-backend.gs`

- `getListings()` → `{ listings: [...] }` (all listings; frontend filters active).
- `getShopOrders()` → `{ shop_orders: [...] }`.
- `createListing(data)` / `updateListing(data)` / `deleteListing(listing_id)` —
  CRUD on `listings`. **delete = soft-delete** (set `status='hidden'`) to preserve
  order history; the listing disappears from the Shop page but existing orders stay
  intact. (No hard-delete in v1.)
- `placeShopOrder(data)` — **authoritative stock guard**: re-read the listing's
  current `qty`; if `qty >= requested`, append the order and set
  `qty = qty - requested`; else return `{ ok:false, error:'oversold',
  available:<n> }`. Returns `{ ok:true, order_id }`.
- `updateShopOrder(data)` — set `payment_status` and/or `fulfillment` by `order_id`.

Extend `updatePayment(data)`: when `data.go_id === 'shop'` and status becomes
`confirmed`, mark all `shop_orders` rows for that `username` as `payment_status='paid'`
(instead of touching the `joiners` sheet).

## Frontend

### Public Shop page (new `#page-shop` + nav tab "Shop")
- Grid of listing cards for `status==='active'`: lazy-loaded image, name, category
  chip, price, stock ("3 left" or red "Sold out" when `qty===0`).
- Tapping a card opens an order view: quantity stepper (max = `qty`), username
  input, **Place order** button.
- On order: call `placeShopOrder`. On success, decrement local stock, toast
  "Order placed — pay in My orders", route to My orders. On `oversold`, toast the
  available count and refresh.

### My orders integration (`doLookup`)
- Also pull the buyer's `shop_orders` (by username). Render them as rows (Item =
  listing name, qty, price, payment, fulfillment), grouped under a **"Shop"**
  pseudo-GO.
- Owed amount: shop orders are committed purchases, so they're **always owed when
  unpaid** (no "secured" gate). To pass the existing `computeOwedByGO` filter
  (which counts only `claim === 'Secured'` rows), shop-order rows are tagged
  `claim:'Secured'`. They group under the `shop` key (`go_id:'shop'`, `go:'Shop'`).
- The existing Pay panel renders for "Shop" like any GO; **I paid** submits a
  payment with `go_id='shop'`.

### Admin Shop area (new admin panel section)
- **Listings management:** list of all listings with Edit/Hide; a "New listing"
  form (name, category, price, image URL, qty, note). Edit updates any field
  (including restocking qty).
- **Shop orders:** table of orders — buyer, item, qty, amount, Paid/Unpaid (toggle,
  persists via `updateShopOrder`), fulfillment (→/← like GO claims). Reuses the
  fulfillment ladder + payment toggle patterns.

### Sync
- `syncFromBackend` fetches listings + shop_orders in the existing `Promise.all`
  (alongside `getAllGOs` + `getPayments`), and renders the Shop page, admin
  listings, and admin orders.

## Out of scope (v1)

- Multi-item cart / single checkout across listings — each listing is ordered
  separately; My orders sums them for payment. (YAGNI.)
- File/image upload — pasted URL only.
- Shipping integration for shop orders (can reuse later if needed).
- Buyer accounts / login — username-based like the rest of the app.

## Edge cases

- **Oversell race:** two buyers order the last item simultaneously — server-side
  qty re-check in `placeShopOrder` rejects the second with `oversold`.
- **Sold out:** `qty===0` → card shows "Sold out", order button disabled.
- **Hidden listing with existing orders:** orders remain valid and visible in My
  orders / admin; listing just isn't shown on the Shop page.
- **Editing price after orders:** existing orders keep their recorded `unit_price`;
  only new orders use the new price.
- **Stale client (listing sold out after page load):** handled by the server-side
  guard returning `oversold`; client refreshes.
