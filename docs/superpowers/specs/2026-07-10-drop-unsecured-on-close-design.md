# Drop Unsecured Claims on GO Close — Design

**Date:** 2026-07-10
**Status:** Design approved, pending spec review

## Problem

When a GO is Closed, some claims may never have reached **secured** status —
incomplete photocard sets, unfilled batches, or individually un-secured cards.
Today these dangling claims just sit there: buyers don't know whether their card
was ordered, and the admin has no defined way to close them out.

## Goal

Give the admin a controlled way, at close time, to mark unsecured claims as
**Dropped** (won't be ordered), while (a) never silently dropping a claim that
money was paid on, and (b) keeping the action reversible.

## Definitions

- **Scope: set-based and batch sub-items only.** Only `si.sets` items
  (photocard / album-member) and batch items (`isBatch(si)`, i.e. `minSecure < 0`)
  have an "unsecured" state. FCFS claims-based items — versioned, single-edition,
  random-merch, and album-member-FCFS — render as **Secured** in `doLookup` the
  moment they're claimed (their claims carry no `claim_status`, and
  `doLookup` treats a falsy `claim_status` as Secured). They are firm orders with
  no incompleteness, so they are never in the drop list.
- **Unsecured / droppable claim:** within a set-based or batch sub-item, a *filled*
  claim that is not yet secured and not paid:
  - **set-based slot:** `slot.claim_status !== 'secured'` **and** the parent
    `set.status !== 'secured'`.
  - **batch claim:** `claim.claim_status !== 'secured'`.
  - Empty slots are not claims and are irrelevant.
- **Secured is always kept.** A secured slot/claim (including a partial batch's
  individually-secured claims) is never dropped.
- **Paid is never auto-dropped.** A claim with `payment === 'paid'` is routed to
  the "Needs your attention" group instead. See "Paid claims" below.

## 1. Data model

Reuse the existing per-claim `claim_status` field (already used for
open / secured / paid by the batch & per-claim-secure work).

- Add one new value: **`claim_status: 'dropped'`**.
- `'dropped'` is a **soft status** — the claim row is never deleted. This is what
  lets the buyer still see "Not fulfilled" and what makes Restore possible.
- **No backend redeploy required.** `updateClaim` already persists `claim_status`,
  so writing `'dropped'` (or back to `'open'`) uses the existing endpoint.

Rationale: a single source of truth. A parallel boolean/table would let two
fields disagree.

## 2. Close → review → confirm flow

A GO is closed via the **Edit GO** form's status dropdown (`edit-go-status`,
Open/Closed) → `saveGOEdits`. Change `saveGOEdits` so that an **open → closed
transition** with unsecured claims routes through a review step instead of
silently flipping status.

**Trigger:** In `saveGOEdits`, detect `prevStatus !== 'closed' && newStatus ===
'closed'`. When that transition happens, count unsecured (filled, non-secured,
non-paid) claims across the GO's set-based and batch sub-items.
- **Not an open→closed transition** (or zero unsecured) → save normally, no modal.
- **Open→closed with > 0 unsecured** → complete the rest of the save, then open the
  **review modal** for the just-closed GO.

**Review modal contents:**
- Header: *"N claims across M items didn't reach secured. Closing will drop them."*
- **Droppable list**, grouped by sub-item. Each row: buyer handle · member/version ·
  set/batch it sat in. Each row has an inline **Secure anyway** button.
- **"Needs your attention" group** (only if any paid-but-unsecured claims exist):
  listed separately, NOT in the droppable list. These are never dropped by the
  confirm action (see below).
- Footer: **Cancel** (abort the close entirely) · **Close & drop remaining**.

**Secure anyway** (rescue path): secures **just that one claim** via the existing
per-claim Secure toggle. It does NOT secure the rest of the set/batch — other
buyers sharing the set stay in the drop list unless rescued individually.
Securing a row removes it from the drop list live and updates the count.

**On confirm ("Close & drop remaining"):**
1. Flip GO status to Closed.
2. For every still-unsecured, non-paid claim: set `claim_status = 'dropped'`.
3. All `updateClaim` calls are awaited before `saveLocal()` (existing invariant:
   destructive API calls must complete before local save).

## 3. Buyer & admin views + Restore

**Buyer (My orders / `doLookup`):**
- Dropped claim stays visible, greyed-out, with a **"Not fulfilled"** badge
  (subtitle: "didn't reach set").
- Excluded from everything actionable: no Pay panel, no shipping eligibility, not
  counted in owed totals. Purely informational.

**Admin (Manage detail / `renderDetailContent`):**
- Dropped slots/claims show a muted **"Dropped"** badge, distinct from
  secured/paid badges.
- Each has a **Restore** action → sets `claim_status` back to `'open'`
  (reactivates as unsecured/active). Restore only un-drops; it does not secure.
  To actually order a restored claim, the admin then per-claim Secures it.
- `setsSummary` / collapsible header counts treat dropped claims separately so
  "N sets · M secured" isn't skewed; append "· K dropped" only when K > 0.

## 4. Edge cases

- **Paid but unsecured:** never auto-dropped. Surfaced in the modal's "Needs your
  attention" group. The admin resolves each manually — either it's a *labeling
  error* (the claim was fine → Secure it / fix status), or it's *genuinely paid
  but unfulfillable* → admin sends the refund off-app, then explicitly drops it.
  The close action itself never drops a paid claim.
- **OT full sets:** an OT claim fills all member slots as one unit; it is secured
  or not as a whole, so it drops/rescues as a single unit. No special handling.
- **Batch runs:** batches are derived frontend from `created_at` into runs of N;
  they are not stored. An unsecured claim in an incomplete trailing batch is
  droppable like any other; secured claims in that batch are kept. Dropping does
  not renumber batches (no stored batch state to cascade).
- **Reopening a Closed GO:** dropped claims stay dropped (no auto-restore); the
  admin Restores individually if wanted. Keeps behavior predictable.
- **Empty slots:** not claims, untouched. Only filled unsecured slots drop.

## Out of scope (YAGNI)

- Carry-over / waitlist of dropped claims into a future GO.
- Automated buyer email/refund notifications.
- Bulk "drop everything unsecured" outside the close flow.

## Backend impact

None. All behavior rides on the existing `updateClaim` endpoint writing
`claim_status`. Frontend-only change.
