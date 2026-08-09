# Joiner Wallet Model — PARKED (future direction)

**Date:** 2026-08-09
**Status:** PARKED — good long-term architecture, deferred. Too disruptive to roll
out mid-season while many GOs are active and joiners are used to the current
per-GO flow. Superseded for now by the minimal cross-GO credit feature
(`2026-08-09-cross-go-credit-design.md`).

## The idea

Each joiner has a **wallet**. A confirmed payment is a **deposit** to the wallet
(GO-agnostic — it stops being tied to a `go_id`). The wallet balance is then
spent to pay off owed items (claims **and** shipping) across any GO. Overpayment,
pay-ahead, refunds, and cross-GO credit all collapse into one concept: a balance.

## Why it's the right long-term model

- **Cross-GO credit is native** — credit is just wallet balance, GO-agnostic by
  definition. No paired-entry bookkeeping.
- **Matches the real workflow** — a joiner sends one combined PayPal transfer →
  one deposit → covers whatever they owe across GOs. Today the admin splits one
  transfer across GOs by hand.
- **Shipping folds in** — a shipping fee is just another owed item the wallet
  pays (shipping is currently entered by admin and paid off-app; the wallet would
  bring it into the paid/owed math).
- **Unifies special cases** — overpayment, pay-ahead, and refund all become
  wallet balance movements instead of three separate mechanisms.

## The real cost (why it's parked)

- **Re-architecture, not a feature.** Today every payment carries a `go_id` and
  `goPaymentSummary` matches paid-vs-owed per GO. A wallet decouples "money in"
  from "which GO," touching everything that computes paid/owed: `goPaymentSummary`,
  `confirmPayment` allocation, the admin "collected of expected" view, My Orders.
- **One-time migration** of existing confirmed payments into wallet deposits (+
  allocations to what they were paying for), so live balances don't reset.
- **Retraining risk** — changing how paid/owed reads mid-season confuses joiners
  who know the current per-GO layout. This is the deciding reason to defer.

## The open design fork (decide when unparked): "money out"

How wallet balance marks a claim/shipping as **paid**:

- **Auto-cover** — wallet balance automatically covers owed items across all GOs
  (e.g. secured/oldest first) until it runs dry; leftover stays as visible
  balance. Simplest; generalizes today's greedy `confirmPayment` allocation to
  global. Joiner just keeps the wallet funded; the system marks items paid.
- **Explicit allocation** — joiner/admin picks which specific claims/shipping the
  wallet pays; each is a recorded allocation. Precise + auditable, but a new
  allocation entity and more clicks.
- **Hybrid** — auto-cover by default, allow manual re-allocation override. Most
  flexible, most to build.

Joiner-side sketch (auto-cover): My Orders shows a wallet balance at top; a
confirmed deposit raises it; owed items across GOs show ✓ "paid from wallet" as
the balance covers them, with any remainder still owed. (Explicit: each owed item
gets a "Pay from wallet" button.)

## When to revisit

Between seasons / during a lull with few active GOs, when a migration + a changed
paid/owed model won't disrupt in-flight orders. Revisit the money-out fork above,
then run it through brainstorm → spec → plan like any project.
