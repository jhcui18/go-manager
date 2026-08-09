# Cross-GO Credit (minimal) — Apply credit across GOs

**Date:** 2026-08-09
**Status:** Design — pending user review

## Goal

Let a joiner use **credit sitting in one GO toward what they owe in another GO**,
with the **smallest possible change** to the app joiners already know. The per-GO
My Orders layout (Paid / Owed / Credit per GO) stays exactly as-is; we add one
button where it's useful. The bigger wallet re-architecture is parked
(`2026-08-09-wallet-model-NOTES.md`).

**Decisions (locked in brainstorming):** explicit apply (not an automatic global
pool); immediate self-service (no admin approval step); recorded as paired credit
entries in the existing payments table. Surplus is surfaced as a single **Account
balance** (derived, not stored) at the top of My Orders, and spent via a **"Use
account balance"** option inside the existing per-GO payment form; per-GO
Paid/Owed entries are unchanged.

## Current model (unchanged foundation)

- Each payment row has `go_id`, `amount`, `status`, `method`, `note`,
  `transaction_id`.
- `goPaymentSummary(u, goId)` → `securedValue` (owed units for that GO),
  `paid` (sum of confirmed payment amounts for that GO), `owed = max(0, secured − paid)`,
  `credit = max(0, paid − secured)`. Credit is derived, trapped per-GO.
- `confirmPayment` marks individual claim units paid (greedy fill in display order,
  via `setUnitPaid` + `updateClaim` persisting `payment_status`) up to the GO's
  total confirmed paid.

## The mechanism — paired credit entries

Applying **$Y** to a target GO **B**, drawn from one or more source GOs, writes
confirmed payment rows sharing a link id (`transaction_id = 'cr_<ts>_<rand>'`),
`method: 'credit'`:

- **Per source GO S** (one row each): `{ go_id:S, amount:−d, method:'credit',
  status:'confirmed', transaction_id:link, note:'Credit applied to <B name>' }`,
  where `d` = amount drawn from S.
- **Target GO B** (one row): `{ go_id:B, amount:+Y, method:'credit',
  status:'confirmed', transaction_id:link, note:'Credit from <source GO name(s)>' }`,
  where `Y = Σ d`.

Because `goPaymentSummary` sums confirmed amounts, the −d rows shrink each source's
`credit` and the +Y row shrinks B's `owed` — **`goPaymentSummary` needs no change.**
Net of all amounts is zero (money conserved). Everything is auditable via the link id.

**Why sources stay consistent:** each `d` is capped at that source's *current
credit* (its surplus above `securedValue`), so reducing a source's paid by `d`
never drops it below `securedValue` — the source's secured claims stay fully paid.
Only surplus moves.

## Account balance (derived — no new store)

Presented to the joiner as a single **Account balance**, but computed, not stored:

`accountBalance(u) = Σ over ALL the joiner's GOs g of goPaymentSummary(u, g).credit`
(Shop included as a pseudo-GO exactly as today's summary treats it.)

Because it's the sum of per-GO surplus, the balance updates automatically as
payments are confirmed (surplus appears) and as balance is spent (the paired
−entries reduce source surplus). No stored balance, no migration. A real stored
credit ledger is deferred to the wallet model.

## Joiner flow (My Orders)

**Keep every per-GO block as-is (Paid / Owed), but stop showing a trapped per-GO
"Credit" line** — surplus now rolls up into one balance shown once at the top:

> 👛 **Account balance: $Z**  (from overpayments — usable on any GO below)

Then in the **existing** per-GO payment form (shown when `owed > 0`), add a
**"Use account balance"** option next to the PayPal methods. It offers to pay up
to `min(Z, thisGO owed)` from the balance (amount editable), instead of / before a
new PayPal transfer.

On **Pay with balance** for target GO **B**, amount `Y`:
1. `Y = min(entered, accountBalance(u), owed_B)` (guarded > 0).
2. Draw `Y` from the joiner's *other* GOs **largest-credit-first**, each draw capped
   at that GO's credit → `sources: [{go_id, go_name, amount}]` summing to `Y`.
3. `await applyCredit({ username:u, target_go_id:B, target_go_name, sources, link })`
   (writes the paired rows — see mechanism above).
4. On success, mirror `confirmPayment`'s target-side allocation: mark GO-B claim
   units paid (greedy, display order) up to B's new total confirmed paid, via
   `setUnitPaid` + persist `payment_status` with `updateClaim` — so B's items show
   **Paid**, not just a reduced total. (Source GOs need no re-marking; only surplus moved.)
5. Re-render / resync: the balance drops by `Y`, B's owed drops, B's items show Paid,
   and a "Paid with account balance" note appears in B's payment history.

A client in-flight guard (`creditApplyInFlight`) blocks double-clicks.

## Admin visibility & reversal

- Credit rows appear in the payments list tagged `method: credit` (the −source and
  +target rows share the link id). `renderPaymentProofs` / "Your payments" show them
  as `−$d` / `+$Y` with their notes — informative, not editable like a normal proof.
- **Reverse:** a `reverseCredit(link)` backend action deletes **all** rows with that
  `transaction_id` (never half a pair), then recomputes the **target GO's** per-claim
  `payment_status` by resetting its claims to unpaid and re-marking up to its now-lower
  confirmed paid (mirror of confirm, so items that were paid *by the reversed credit*
  revert). Sources need no recompute (their surplus simply returns).

## Guardrails / honest limitations

- Cap the total at `min(availableCredit, owed)`; per-source draw capped at that
  source's credit. Never creates pointless target credit, never over-draws a source.
- **Backend can't independently re-verify available credit** — `owed`/`credit` are
  computed on the frontend from claims + prices, which the backend doesn't replicate.
  `applyCredit` therefore trusts the client-computed `sources`/`Y`. Acceptable because
  it only reallocates already-confirmed cash and is fully reversible. (A stale client
  could over-apply; the admin sees it in the payments list and reverses.)

## Backend (Apps Script — REQUIRES REDEPLOY)

- `applyCredit(data)` — under `LockService`, append the source `−d` rows and the
  target `+Y` row (all `method:'credit'`, `status:'confirmed'`, shared
  `transaction_id`). Return `{ ok:true, link, rows:[…] }`.
- `reverseCredit(data)` — under `LockService`, delete all joiner rows with
  `transaction_id === data.link`; return `{ ok:true }`. (Frontend triggers the
  target-GO re-mark on the next confirm/allocate pass, or the reverse handler
  returns enough for the client to recompute.)
- No change to `submitPayment`/`updatePayment`; `deletePayment` still works per-row
  but reversal should use `reverseCredit` so a pair never half-deletes.

## Frontend touch-points

- My Orders header (`doLookup`/`doLookupRender`): show `👛 Account balance: $Z`
  when `accountBalance(u) > 0`.
- Per-GO block renderer: **remove the per-GO "Credit" line** (rolled into the
  balance); keep Paid / Owed. In the payment form (rendered when `owed>0`), add the
  "Use account balance" control offering `min(balance, owed)`.
- `renderPaymentProofs` / "Your payments": show `method:'credit'` rows (−source /
  +target) with their notes.
- New helpers: `accountBalance(u)`, `drawSources(u, exceptGoId, Y)` (largest-first,
  capped), `payWithBalance(u, goId, amount)`.
- Reuse `goPaymentSummary`, `paymentOwedUnits`, `setUnitPaid`, and the existing
  greedy target-allocation from `confirmPayment` (factor it into a shared helper so
  pay-with-balance and confirm-payment mark items identically).

## Testing

- **Node harness:** given synthetic payments/owed for a joiner across GOs, after
  `applyCredit`: source credit drops by its draw, target owed drops by `Y`, global
  sum of confirmed amounts unchanged; over-draw and over-owed are capped; a source
  is never drawn below its `securedValue`; `reverseCredit` restores the exact prior
  state including target per-claim paid flags.
- **JS-parse** the script blocks; **`node --check`** the backend copy.
- **Live:** after redeploy, curl `applyCredit` for a test joiner, confirm the paired
  rows land with the shared link id and correct signs; `reverseCredit` removes them.

## Out of scope (parked / YAGNI)

- The wallet re-architecture (`2026-08-09-wallet-model-NOTES.md`).
- Applying credit to **shipping** fees (shipping is admin-entered / paid off-app
  today; it enters the paid/owed math only under the wallet model).
- Admin-initiated "apply on the joiner's behalf" button (self-service only for v1;
  admin can still reverse). Add later if needed.
- Letting the joiner choose *which* source GO to draw from (auto largest-first only).

## Redeploy note

`applyCredit` + `reverseCredit` require redeploying the Apps Script Web App.
Pre-redeploy the button can be hidden (or 404s handled) so nothing breaks before deploy.
