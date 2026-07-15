# Pay-Ahead Credit & Overpayment Marking — Design

**Date:** 2026-07-14
**Status:** Design approved, pending spec review

## Problem

Owed is computed as **secured, unpaid claims only** — unsecured claims aren't
charged yet. But buyers legitimately pay *ahead*: they send one combined payment
(often one real-world PayPal transfer) covering claims that aren't secured yet,
and log it on the site (sometimes as multiple per-GO records sharing one
transaction id). Today the app has no notion of this: the excess over the
currently-secured total is silently ignored, the confirm modal mis-warns it as an
underpayment, and neither the buyer nor the admin can see the pay-ahead amount.

## Goal

Surface **pay-ahead credit** — money a buyer has paid beyond the value of their
currently-secured claims — per buyer per GO, on both the joiner and admin sides,
without refunds and without a separate ledger. When more of the buyer's claims
get secured later, the credit is naturally consumed the next time the admin
confirms a payment for them (existing allocation already sums all their confirmed
payments).

## Definitions (per buyer, per GO — all derived, nothing new stored)

- **Paid** = sum of the buyer's **confirmed** payment amounts for the GO
  (`paymentProofs` where `status === 'confirmed'`, `sameUser`, matching `go_id`).
  A submitted-but-not-yet-confirmed payment is **not** counted in Paid; it is
  shown separately as "awaiting confirmation."
- **Secured value** = sum of `price × qty` over the buyer's claims whose
  `claim === 'Secured'` (the `doLookup` row classification), for that GO.
- **Owed** = `max(0, Secured value − Paid)` — still to pay.
- **Credit** = `max(0, Paid − Secured value)` — pay-ahead money not yet matched
  to a secured claim.

Rationale for deriving rather than storing: Paid, Secured value, and the claim
paid-flags already live in the sheet. A separate credit field would be a second
source of truth that can drift. Credit is a pure function of existing data and
recomputes correctly as claims secure or payments are confirmed.

### Single shared helper (both sides use it)

To guarantee the joiner and admin never show different numbers, one helper is the
sole source of these values:

```
goPaymentSummary(username, goId) -> { paid, securedValue, owed, credit, pendingSubmitted }
```

- **securedValue** uses the same "Secured" classification as `doLookup`: a claim
  counts when it would render as `claim === 'Secured'` there — set-based slots in a
  secured set (or with `claim_status === 'secured'`), FCFS claims-based
  (versioned/single/random/member-FCFS) always, batch claims only when
  `claim_status === 'secured'`. Dropped claims never count.
- **paid** = confirmed payment amounts; **pendingSubmitted** = pending payment
  amounts (shown separately, not in paid).
- **owed** / **credit** as defined above.

The admin confirm modal's greedy allocation (`paymentOwedUnits` + `setUnitPaid`)
decides *which specific claims* to flag paid. The modal's *displayed* Owed/Credit
come from `goPaymentSummary`. For these two to agree, `paymentOwedUnits` must count
the same claims as `securedValue` — see the batch-consistency fix below.

### Batch-consistency fix to `paymentOwedUnits`

`paymentOwedUnits` currently counts every claims-based unit regardless of
`claim_status` (only `'dropped'` is filtered). For **set-based** items it already
counts only secured sets, and **FCFS** claims-based items (versioned/single/random/
member-FCFS) are firm the moment claimed — both correct. But **batch** items also
live in `si.claims`, so an *unsecured* batch card is currently counted as owed and
can be marked paid. That both contradicts `securedValue` (which excludes it) and
would mark a not-yet-secured card paid.

Fix: in the `si.claims` branch, skip a batch item's unsecured cards —

```
if (isBatch(si) && c.claim_status !== 'secured') return;  // batch: only secured cards are owed/payable
```

After this, a prepaid-but-unsecured batch card is held as **credit** (not marked
paid) until its batch is secured — identical to set-based behavior — and the
modal's "will mark paid" line matches the displayed Owed/Credit. This is the only
change to allocation; set-based and FCFS paths are unaffected.

## Scope: per-GO credit only

Credit stays within the GO it was paid under. A combined real-world transfer split
across GOs is recorded as one payment record **per GO** (each with its own amount
and `go_id`), so each GO's credit is computed from its own records. Cross-GO credit
transfer is explicitly out of scope.

## 1. Joiner side — My orders

Under each GO's claim rows, add a one-line summary:

> **Paid $X · Owed $Y · Credit $Z**

- Show **Credit $Z** only when `Z > 0`.
- If the buyer has a submitted-but-pending payment for the GO, append
  `· $P awaiting confirmation` (not counted in Paid).
- Numbers come from `goPaymentSummary(u, go_id)` (the shared helper), so they
  match the admin side exactly.

## 2. Admin side — confirm-payment modal (`confirmPayment`)

The modal already greedily allocates `totalPaid` (all confirmed payments for the
buyer+GO plus the one being confirmed) across secured items via `paymentOwedUnits`
+ `setUnitPaid`. Prior credit is therefore **already** taken into account when
confirming a new payment. Allocation logic is unchanged except for the
batch-consistency fix above (so it counts the same claims as `securedValue`).
Display changes, driven by `goPaymentSummary`:

- Show Owed/Paid/Secured value from `goPaymentSummary` (consistent with the joiner).
- Add a **"Credit (held for later): $Z"** row when `credit > 0`.
- Fix the mismatch messaging (currently one amber "doesn't fully cover" note that
  fires whenever amounts don't match):
  - `owed > 0` (underpaid) → keep the existing amber underpayment warning.
  - `credit > 0` (overpaid) → neutral note: "$Z will be held as credit for claims
    secured later." (Not a warning.)
  - Exact match → no note (unchanged).

No new "Apply credit" button and no auto-apply-on-secure: credit is absorbed the
next time a payment is confirmed for the buyer (the allocation already includes
all their confirmed payments).

## 3. Shared transaction id

Transaction id is a free-text field with no uniqueness constraint, so the same id
appearing on multiple per-GO payment records already works — no submission change.

- In the **admin payment list** (`renderPaymentProofs`), when a pending payment's
  `transaction_id` also appears on another payment record, show a subtle hint
  (e.g. "· same txid on <other GO name>") so the admin can see the records belong
  to one real transfer.

## Out of scope (YAGNI)

- Global (cross-GO) credit balance or transfer.
- A stored credit ledger / new sheet.
- "Apply credit" button or auto-apply when a claim is secured.
- Buyer-initiated use of credit; refunds.

## Backend impact

None. All three parts derive from existing `paymentProofs`, claims, and
`doLookup` data. Frontend-only, no redeploy.
