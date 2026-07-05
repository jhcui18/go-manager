# Delete Shop Orders & Payment Records — Design

Date: 2026-07-05
App: GO Manager (`index.html` + `go-manager-backend.gs`)

## Goal

Let the admin delete a **shop order** (returning its stock) and delete a **payment
record** entirely. (GO claims already have delete — FCFS/merch via the × button, and
photocard slots via the slot's Edit → "Remove claim"; no change there.)

## Decisions (locked)

- **Shop order delete restores stock:** deleting an order adds its `qty` back — to
  the ordered variant if it's a variant listing, else to the listing's `qty`.
- **Payment delete just removes the record:** it erases the payment row; it does NOT
  change any claim's paid/unpaid status. (Reject keeps the row as `rejected`; Delete
  erases it — for mistakes/duplicates.)
- Both are admin actions with a confirm() prompt.

## Backend (`go-manager-backend.gs`) — new endpoints, need redeploy

- `deleteShopOrder(order_id)`:
  1. Read the `shop_orders` row for `order_id` → get `listing_id`, `qty`, `variant`.
  2. Restore stock in `listings`: if `variant` is set, parse that listing's
     `variants` JSON, add `qty` back to the matching variant, write it back; else add
     `qty` back to the listing's `qty` column.
  3. `deleteRowWhere(shop_orders, 'order_id', order_id)`.
- `deletePayment(payment_id)`: `deleteRowWhere(payments, 'payment_id', payment_id)`.
- Route both in `doPost`.

Uses the existing `deleteRowWhere(sheet, keyCol, keyVal)` helper.

## Frontend (`index.html`)

- **Shop orders table** (`renderShopOrders`): add a **×** button per row →
  `deleteShopOrder(orderId)`: confirm; locally remove the order from `shopOrders` and
  restore stock on the local `listings` object (variant or `qty`); `apiPost
  ('deleteShopOrder', {order_id})`; re-render Shop orders, admin listings, Shop page.
- **Pending payment proofs table** (`renderPaymentProofs`): add a **Delete** button
  next to Reject → `deletePaymentProof(id)`: confirm; remove from local
  `paymentProofs`; `apiPost('deletePayment', {payment_id})`; re-render.

## Out of scope

- Undo/restore of deleted records.
- Deleting GO claims (already exists).
- Payment delete altering claim paid status (explicitly not done).

## Edge cases

- **Deleting a shop order for a hidden/edited listing:** stock restore still finds the
  listing by `listing_id`; if the listing no longer exists, skip the restore (just
  delete the order).
- **Variant no longer in the listing's variant list:** if the ordered `variant` isn't
  found, skip restoring that variant (delete the order without error).
- **Deleting a confirmed payment:** allowed; it only removes the payment record (claim
  paid status is untouched, per the decision above).
