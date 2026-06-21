# Payment Function — Design

Date: 2026-06-21
App: GO Manager (`index.html` + `go-manager-backend.gs`, Apps Script + Google Sheets)

## Goal

Let buyers see what they owe for a group order, pay the GO manager off-app
(PayPal/Venmo/Zelle/Wise), and log that payment. The manager confirms it, and the
buyer's claims in that GO flip to **Paid**. No card processing, no image upload,
no amount prefill.

## Scope

- **In scope:** Item-cost payment only (the payment tied to securing claims).
- **Out of scope (for now):** Shipping payment (stays manual/off-app), real online
  checkout / card processing, screenshot/image storage, prefilled payment links.

## Decisions (locked)

- **Payment type:** Track manual payments + show payment handles (no real checkout).
- **Amount owed:** Auto-calculated from the buyer's unpaid claims (price × qty,
  including OT full sets), shown prefilled in an **editable** field (allows partial
  payments or paying for a friend).
- **Proof:** Transaction ID / short note only — no screenshot upload.
- **No amount prefill** in payment links; handles shown as copyable text, owed
  amount shown on-screen for the buyer to enter in their own payment app.
- **Confirmation:** Manual by the admin.
- **Location:** Inside the **My Orders** lookup. The standalone "Submit payment"
  page is retired.
- **Payment unit:** One payment record per (buyer username, GO).

## Payment handles (single source of truth)

Reuse the four already on the rules page:

- PayPal F&F (no note): `@jinghanc`
- Venmo: `@Jinghan-Cui`
- Zelle: `jhcui1818@gmail.com`
- Wise: `@jinghanc3`

Define these once as a `PAYMENT_METHODS` constant in `index.html` and render both
the rules page block and the new Pay panel from it, so they never drift.

## Buyer flow (My Orders)

1. Buyer looks up their username (existing flow) → sees their claims table.
2. For each GO that has an **unpaid balance**, a **Pay panel** appears below the
   table:
   - **Amount owed** — auto-summed from that buyer's unpaid claims in that GO.
     Editable number field, prefilled with the computed total.
   - **Payment handles** — the four methods as copyable text.
   - **"I paid" form** — method dropdown (PayPal/Venmo/Zelle/Wise) + transaction
     ID/note + amount (defaults to the owed amount). Submit creates a payment
     record tagged with the correct **`go_id`**, `username`, `amount`, `method`,
     `transaction_id`, `status: 'pending'`.
3. Confirmation message: "Payment submitted — the manager will confirm it."

A GO with no unpaid balance shows a "Paid ✓" state instead of the panel.

## Admin flow (existing "Pending payment proofs" table)

- Each pending payment record shows buyer, GO, amount, method, txn ID, time.
- **Confirm** → `apiPost('updatePayment', { payment_id, status:'confirmed',
  username, go_id })`. Backend (`updatePayment`, already implemented) sets
  `payment_status = 'paid'` on every claim matching that username + go_id.
- **Reject** / **Edit** behave as today.
- After confirm/reject, refresh the proofs table and the GO detail so Paid status
  shows without a full reload.

## What changes in code

### Fix (root cause of the current broken confirm)
- The submit form currently reads inputs via fragile `querySelector`-by-placeholder
  and **never sets `go_id`**, so confirming can't match claims. Replace with the
  new per-GO panel that submits a real `go_id` and clean field reads.

### Build
- `PAYMENT_METHODS` constant.
- Per-GO **Pay panel** renderer inside the My Orders results (`doLookup` output):
  owed-amount calc, handles, "I paid" form, submit handler.
- A "Paid ✓" state for GOs with zero unpaid balance.

### Reuse (no change needed)
- Admin proofs table (`renderPaymentProofs`, confirm/reject/edit).
- Backend `submitPayment` (appends to payments sheet) and `updatePayment`
  (confirm → mark claims paid). No backend schema change; no redeploy required
  for this feature.

## Owed-amount calculation

Reuse the My Orders row logic already in `doLookup`: it already builds per-claim
rows with `price`, `qty`, and `payment` for the looked-up user. Sum
`price * qty` over that user's rows in a given GO where `payment !== 'paid'` to get
the owed amount per GO. Group the existing rows by GO to drive both the table and
the Pay panel.

Implementation note: the lookup rows currently carry only the GO **name**
(`go: go.name`), not `go_id`. Add `go_id` to each row so the Pay panel can submit
the real `go_id` (and group reliably even if two GOs share a name).

## Edge cases

- **Partial payment:** Editable amount lets the buyer pay less than owed. Confirming
  still marks all that buyer's claims in the GO paid (v1 limitation — admin can
  decline to confirm a short payment, or edit). Documented, not auto-enforced.
- **Already paid claims:** Excluded from the owed total; if all paid, show "Paid ✓".
- **No price set:** If a GO/claim has price 0, owed total is 0 → no Pay panel.
- **Duplicate submissions:** Allowed; each is a separate pending record for the
  admin to confirm or reject.

## Non-goals / explicitly deferred

- Shipping payment phase.
- Automated/online card checkout (would need a separate secure backend).
- Screenshot upload + storage.
- Enforced partial-payment accounting (paid-so-far vs remaining).
