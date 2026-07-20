# Reassign Unpaid-Past-Deadline Claims to Waitlist — REQUIREMENTS NOTES

**Status:** requirements gathered 2026-07-19, NOT yet designed. Build AFTER the
per-GO payment deadline feature (depends on it). Do a full brainstorm → spec → plan.

## What the user wants

A button (per GO) the admin initiates, with a **review step before applying**, that:

- Finds claims that are **secured but unpaid** where the GO's **payment deadline has
  passed**.
- **Drops** each such claim (`claim_status:'dropped'`), and **passes the spot to the
  next joiner who claimed the same thing but isn't secured** (the waitlist).
  - Replacement = the **earliest** (by created_at) unsecured claimant for the SAME
    thing.
  - **Set-based:** same member.
  - **Batch:** same member/card ("same number").
  - **FCFS / versioned:** unsecured claims for the same item/version.
- **If no waitlister exists for a dropped slot: drop it anyway** (slot becomes
  open/unfilled; set un-secures). Do NOT skip.
- On apply, the promoted waitlister becomes **secured** (and now owes for it).

## Review-first

A button opens a review modal listing each unpaid-past-deadline claim → its proposed
replacement (or "no waitlister — dropped, slot opens"), and the admin confirms before
anything is written.

## Open design questions (resolve in the real brainstorm)

- Exact data-model mechanics of "promote waitlister into the secured slot" for each
  kind (move their claim into the slot vs mark their existing claim secured).
- Does the promoted joiner get a fresh payment deadline / how are they notified.
- Whether the admin can deselect individual rows in the review before applying.
- Reuse: builds on `claim_status:'dropped'` (drop feature), the payment deadline,
  and a review-then-confirm modal (like the close-GO drop modal).
