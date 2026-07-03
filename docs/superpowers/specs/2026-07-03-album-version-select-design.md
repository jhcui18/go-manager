# Buyer-Selectable Album Versions — Design

Date: 2026-07-03
App: GO Manager (`index.html` + `go-manager-backend.gs`)

## Goal

Let buyers explicitly choose which version of an album sub-item they want (e.g.
"Photobook A ×2, Photobook B ×1"), instead of the current behavior where the
"Other ver (A/B/random)" type only takes a quantity and auto-assigns versions.
Give the admin flexibility to name each album sub-item, pick its type, and list
its version options.

## Background (current behavior)

An album GO can already hold multiple sub-items, each independently of kind:
- **Member ver** (`kind:'member'`, set-based) — buyers pick a member; fills a set.
- **Other ver** (`kind:'versioned'`) — buyers pick a **quantity**; versions are
  **auto-assigned** by `assignVersions` (1 copy → random, 2 → A+B, 3+ → A+B then
  random). Buyers cannot choose a specific version.

This design changes the buyer flow for the `versioned` kind to explicit selection.

## Decisions (locked)

- **Admin inputs per album sub-item:** Name, Type (**Member** or **Version**),
  and Options (member list for Member; free-text version names for Version, e.g.
  `A, B` or `Version A, POB`). This is the existing create/edit form — no new
  fields needed; it already captures name + kind + members/versions.
- **Buyer selection (the change):** For a **Version** sub-item, buyers tap version
  tiles to select + quantity (tap "A" → ×1, tap again → ×2, "−" to reduce),
  exactly like the multi-quantity member picker. No more auto-assign.
- **Scope:** album `versioned` sub-items only. Member-type albums (already
  selectable) and merch "random ver" are unchanged.

## Approach — reuse the merch "member ver" picker

A Version-type album sub-item is structurally identical to the existing merch
**member ver**: a set of named options the buyer taps to select, with a quantity
per selection, stored as claims. The only difference is the option set is
`si.versions` instead of `si.members`.

So: generalize the merch member-ver selection UI to drive album `versioned`
sub-items with `versions` as the options, storing each selected version as a
claim tagged with that version name.

## Data / storage

- Each selected version becomes a claim: `member_or_version = <version name>`,
  `qty = <selected qty>`, `assigned_vers = <version name>`. (Reuses the existing
  joiners schema — no backend/sheet change.)
- Sync reconstruction (`buildVersionedClaims`) already carries `member_or_version`
  as the claim's `member`, so the chosen version round-trips through a sync.
- `claimState` for a Version sub-item: `{ type:'version-select', selected:{ [versionName]: qty } }`
  (mirrors the merch member-ver state).

## Frontend changes (`index.html`)

- **Buyer render** (`renderVersionedSubItemPublic` for album `versioned`): replace
  the quantity stepper + auto-assign note with a **version tile picker** (tap to
  add qty per version, "−" to reduce), reusing the member-picker markup/handlers.
- **Selection handlers:** version tiles use the same increment/decrement/summary
  pattern as the member picker (per-option quantity).
- **Claim summary** (`updateClaimSummary`): show "Name: A ×2, B ×1 ($…)" using
  price × total selected qty.
- **Submit** (`submitClaim`): add a `version-select` branch that, for each selected
  version, pushes a claim with `member_or_version = version`, `qty`,
  `assigned_vers = version`. Keep the existing quantity branch for merch random.
- **My orders** (`doLookup` claims-based rows) and **admin FCFS table**: already
  show `member_or_version` / assigned version — will display the chosen version.

### Scoping note — don't break merch "random ver"

`renderVersionedSubItemPublic` is used **only** by album `versioned` sub-items, so
changing it to a picker is safe. But the shared pieces `assignVersions`,
`adjustVersionedQty`, and the `state.qty` submit branch are **also used by merch
"random ver"** (which has no named versions) — those MUST stay. Only album
`versioned` moves to the picker; merch random keeps its quantity stepper +
auto-`'random'` assignment.

## No backend change

Claims already store `member_or_version` + `qty` + `assigned_vers`; the chosen
version fits those columns. No new endpoints, no sheet change, **no redeploy**.

## Out of scope

- Per-version stock limits (a version can't "sell out") — versioned is FCFS/
  unlimited like today. (YAGNI.)
- Changing member-type albums or merch random-ver.
- A built-in "random/any" choice — the admin can just include a version literally
  named "Random" in the options list.

## Edge cases

- **Version renamed after claims exist:** existing claims keep their stored version
  name; only new claims use the new list (same as members today).
- **Single version:** picker still works (one tile).
- **Buyer selects nothing:** submit ignores that sub-item (same as member picker).
