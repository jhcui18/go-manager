# Refund a Payment — TODO / agreed design (not yet built)

**Date:** 2026-07-27
**Status:** Design agreed, PARKED — build later.

## Need

The admin sometimes refunds a payment (money sent back externally via Venmo/PayPal)
and wants to **label that payment as refunded** in the app, with the money math
updating accordingly.

## Agreed decisions

1. **Refund changes the money math** (not just a label): a refunded amount stops
   counting toward what the joiner has paid, so Owed/Credit recompute correctly.
2. **Support both full and partial** refunds → model it as a **refund amount**, not a
   yes/no flag.

## Design

- **`refund_amount` field** on each payment (default 0). A payment's **net paid =
  amount − refund_amount**. Paid total = Σ(confirmed amounts) − Σ(refund_amounts).
  - Full refund → `refund_amount` = full amount → nets to $0.
  - Partial → `refund_amount` = the part sent back; the remainder still counts.
- **Reachability:** confirmed payments aren't in the "Pending payment proofs" table
  today. Add a **"Show confirmed" toggle** to that section so confirmed (and refunded)
  payments appear, each with a **Refund** button.
- **Refund flow:** Refund button → prompt for the **amount** (pre-filled to the full
  payment amount; edit down for partial) + optional **note** (reuse the existing
  `note` field, e.g. "refunded via Venmo") → persist.
- **Labels:** `refund_amount > 0` → **"Refunded $R"** badge ("Refunded" when it's the
  full amount), shown to the admin in the table and to the joiner in their
  "Your payments" list, with the note.

## Implementation outline

- **Backend (redeploy):** add `refund_amount` column to the `payments` sheet
  (auto-migrated by `ensureSheet`); add `refund_amount` to the `updatePayment`
  writable-fields whitelist. `getPayments` returns it automatically (`sheetToObjects`).
- **Frontend:**
  - `syncFromBackend` payment map: **carry `refund_amount` through** (the sync
    rebuilds each proof object explicitly — remember the `note` bug where a field was
    dropped; add `refund_amount: p.refund_amount || 0`).
  - `goPaymentSummary`: `paid = mine.filter(confirmed).reduce((a,p) => a + amount −
    (parseFloat(p.refund_amount)||0), 0)`.
  - `renderPaymentProofs`: "Show confirmed" toggle; Refund button on confirmed rows;
    Refunded badge on refunded rows.
  - `myPaymentsSection` (joiner): show the Refunded badge + note.

## Effort

Small–moderate; frontend + one backend column + redeploy + bootstrap (same pattern as
the `note` column added on 2026-07-25).
