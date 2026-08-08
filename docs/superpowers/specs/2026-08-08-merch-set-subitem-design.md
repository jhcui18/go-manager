# Merch Set-Based Sub-Item — Design

**Date:** 2026-08-08
**Status:** Design — pending user review

## Problem

Merch-type GOs support only claims-based sub-item kinds: **Member ver** (FCFS
member-tile picker, no cap, no securing) and **Random ver**. Some merch items
are actually ordered **by set** (one slot per member, secured when the set fills
or is individually secured) — the same mechanic photocard GOs and album *member*
sub-items already use. Today there is no way to add such an item to a merch GO.

## Goal

Let the admin **add one new sub-item** to a merch GO that is ordered by set,
working exactly like a **photocard sub-item** — set-based by default, with the
same batch-size toggle that switches it into batch mode.

**Purely additive.** Existing merch sub-items (Member ver, Random ver) and all
existing GOs are untouched. Existing photocard/album set behavior is untouched.

## Approach

The set engine already exists end-to-end and is reused unchanged:
`buildSetsFromClaims`, `renderSetSubItemPublic` / `renderBatchSubItemPublic`,
set securing + individual-secure, batch mode (`min_secure < 0`), and the per-set
owed math. It is currently wired only to photocard GOs and album *member*
sub-items.

Introduce a distinct merch sub-item kind, **`member-set`**. At each place that
detects "set-based" (`kind === 'member' || kind === 'photocard'`), *add*
recognition of `member-set`. Existing `member`/`photocard`/`random` logic is
never modified, so nothing can regress — important because set-based sub-items
feed the money math.

Rejected alternatives:
- **Centralize into one `isSetSubItem()` predicate** — cleaner but rewrites the
  scattered existing checks, risking album/photocard/owed regressions. Bigger diff.
- **Reuse `member` kind + a `set:true` flag** — reintroduces the exact merch
  `member` FCFS-vs-set ambiguity we are avoiding.

## Data flow

Claim rows already store `sub_item_kind: si.kind || go.type` (set submit branch),
and the backend assigns `set_num`. So once each site recognizes `member-set`, a
`member-set` sub-item flows through the identical set pipeline photocard uses —
no change to `submitClaim`'s set branch itself.

## Touch-list (Approach A)

All line numbers are current `index.html` / `go-manager-backend.gs` references.

1. **Create form** (`index.html` ~2807, ~2848, ~2855, ~2902, ~2925) — add
   `<option value="member-set">Member set</option>` to the merch kind dropdown.
   When the selected merch kind is `member-set`, show the **members textarea**,
   a **set-size (`min_secure`)** input, and the **batch-size toggle** — the same
   fields a photocard sub-item shows (all currently hidden for merch). Build the
   sub-item with `members`, `minSecure`, and an initial empty `sets` structure
   (or batch claims when batch-size is set), mirroring the photocard add path.
2. **Edit form** (`index.html` ~3133, ~3159, ~3252, ~3266, ~3307, ~3326, ~3339,
   ~3352, ~3372–3389) — same field visibility and build/rebuild logic for
   `member-set` as photocard: allow editing members, set-size, and the
   batch toggle (`canBatch` at 3307 gains merch `member-set`).
3. **`isBatch`** (`index.html:585`) — add `'member-set'` to the kind check so
   `min_secure < 0` enables batch mode.
4. **claimState init** (`index.html:1025`) — `member-set` → `{ type:'set',
   selectedMembers:{} }` (batch already handled first by the `isBatch` branch).
5. **`renderMerchPublic`** (`index.html:1283`) — add a `member-set` branch:
   `claimCollapsible(goId, si, isBatch(si) ? renderBatchSubItemPublic(si, goId)
   : renderSetSubItemPublic(si, goId))`, mirroring the album set path.
6. **Reconstruction** (`index.html:4530` and the merch branch ~4553) — route
   merch + `member-set` into the **set-based build** (read `min_secure`; build
   `sets` via `buildSetsFromClaims`, or batch claims via `buildBatchClaims` when
   `min_secure < 0`) instead of the merch FCFS branch. The merch FCFS branch
   keeps handling `member`/`random` exactly as before.
7. **Owed math** — the three set-kind guards add `'member-set'`:
   - buyer owed `isSetKind` (`index.html:1722`)
   - admin owed `isSetKind` (`index.html:4069`)
   - admin batch guard `isBatchKind` (`index.html:4078`)
   so secured merch-set slots (and batch cards) are billed at `price` per slot
   exactly like photocard.
8. **Backend `submitClaim`** (`go-manager-backend.gs:342`, **REQUIRES REDEPLOY**)
   — `isSet` adds `'member-set'` so the server authoritatively assigns `set_num`
   for merch-set claims (same firstFreeSet / OT-full-set logic).

No change is required to the set submit branch (1558–1596), `buildSetsFromClaims`,
the set/batch renderers, securing endpoints, or the closed-POB handling — they
are kind-agnostic once the sub-item is shaped as a set.

## Edge cases

- **Existing merch items unchanged:** `member` (FCFS) and `random` never enter
  the set path; their branches are untouched.
- **No members configured:** the form blocks saving a `member-set` with an empty
  members list, the same guard photocard/album member sets use.
- **Closed / leftover slots:** claiming a leftover secured slot in a closed
  merch-set works via the same set code path (consistent with the closed-POB
  message fix already shipped).
- **Batch vs set:** a `member-set` with batch-size set (`min_secure < 0`) renders
  and bills through the batch path; blank batch-size keeps it set-based —
  identical to photocard.

## Testing

- **JS-parse:** `node -e` over the `<script>` blocks (existing harness pattern).
- **Backend:** `node --check` on the `.gs` copy; after redeploy, live curl a
  `member-set` submit and confirm the response carries an assigned `set_num`.
- **Node reconstruction harness:** build a synthetic merch GO with one
  `member-set` sub-item and assert:
  (a) set mode: `sets` build with exactly one slot per member;
  (b) owed = `price` per secured slot (matches photocard);
  (c) batch mode (`min_secure < 0`): claims group into batches of the batch size.
- **Manual:** add a `member-set` item to a merch GO; a buyer claims a member slot;
  the set secures when full and when individually secured; owed/credit is correct;
  existing Member-ver / Random items on the same GO still behave unchanged.

## Out of scope (YAGNI)

- Migrating existing merch `member` (FCFS) items to sets.
- Any change to album/photocard behavior.
- New set mechanics beyond what photocard already supports.

## Redeploy note

Only `go-manager-backend.gs:342` (`isSet`) changes on the backend — one added
kind. Requires redeploying the Apps Script Web App. The frontend degrades safely
pre-redeploy only in that `set_num` would be client-assigned (stale) until the
backend recognizes the kind; deploy backend with the frontend.
