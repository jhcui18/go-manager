# GO Manager — Admin Handbook

For a second admin. This explains how a group order (GO) runs from idea to delivered package, and which button does what on the site. The site is https://jhcui18.github.io/go-manager/. Carol owns the money, the Instagram channel and the final say; when unsure, ask her before acting.

_Last updated 2026-11-08._

---

## 1. The lifecycle at a glance

```
Plan → Create GO on site → Announce → Claims come in → Secure sets → Close
→ Order from seller → Payments confirmed → Items arrive → Mark Ready
→ Joiner requests shipping → Pack, charge fees, mark Shipped
```

A GO is one buying round (an album, a pop-up store haul, a POB set). Inside it are **items** (the site calls them POBs or sub-items): "Tokyo Dome Day1", "Sealed Fanclub ver", "Hug plush keyring". Joiners claim items. Every claim belongs to one Instagram username.

Three statuses matter everywhere:

| Thing | States | Meaning |
|---|---|---|
| Claim | pending → secured → (dropped) | Secured = we will buy it and the joiner owes money. Pending = waiting to fill a set. Dropped = cancelled, kept for history. |
| Payment mark | unpaid / paid | Per claim. Set by confirming a payment record, never by hand unless Carol says so. |
| Fulfillment | Pending → Ordered → On the way → Ready → Shipped | Where the physical item is. |

---

## 2. Logging in and what your account can do

1. Open the site, click **Admin** top right, enter your email and password (Carol creates the account in Supabase).
2. The **Admin** tab appears with five sections: **GOs**, **Shop**, **Store**, **Payments**, **Shipping**.
3. Click **Log out** when done on a shared device.

Both admin accounts have identical full rights. Every insert, update and delete you make is written to an audit log with your email, so it is always possible to see who changed what. Act as if Carol will read it, because she can.

Deletes on the site are permanent. Deleted claims keep a "before" copy in the log, so they can be restored by Carol in SQL. Deleted admin notes, payment records and shipping requests keep nothing. Read the confirm box before clicking OK.

---

## 3. Planning and creating a GO

### Decide the shape
- **GO type:** `photocard` (POB cards, set-based), `album` (versions, inclusions, sealed), `merch` (pop-up goods).
- **Item kinds:**
  - **member / photocard, set mode** — a set has one slot per member. Joiners claim one member each; a set is bought when it is full (or when you flag it secured). This is how POBs and member-ver albums work.
  - **batch mode** — no sets; claims secure in blocks of N (the batch size). Used for shop-style items with a minimum order.
  - **versioned** — first come first served per version (Limited A / Limited B).
  - **single** — quantity only.
- **OT price:** a joiner can claim a full OT8 set as one unit at a flat price. Set it on the item if the seller gives a set discount.
- **Deadlines:** GO close date, GO payment deadline, and optional per-item **close** and **pay by** dates. The pay-by date drives which items a payment covers first (see §6).
- **Min secure:** how many sets must fill before the item is worth ordering. Leave as GO default unless Carol says otherwise.

### Create it
1. Admin → **+ New GO**. Fill name, artist, type, dates, description (joiners see this), **admin note** (private, joiners never see it).
2. Add items. For each: name, kind, price, OT price, members or versions, image, description, admin note.
3. **Create GO.** It is live immediately with status open.

Name items exactly how you will refer to them in chats. Joiners search by these names.

### Rules that bite
- **Never rename a member in the GO editor.** The editor adds a new member row and hides the claims on the old one. Ask Carol; she renames in SQL.
- **Never rename a joiner's username in the editor either.** Same reason. Username fixes (typos, handle changes) are SQL jobs for Carol.
- Removing an item that has claims cancels those claims. The site warns you.

### Announce
Carol posts planned and open GOs on her Instagram channel and the GO Lounge chat. Use the standing template:

> 📢 **Planned GOs** 💛
> - **[GO name]** – opens **[date]**, est. **[$X]**. [1-line what's included]
> Want in? Drop a 🙋 or DM me. Updates in the GO Lounge: https://ig.me/j/h-5rHQsQUJUOjTM3/

---

## 4. While the GO is open: claims and sets

Admin → **GOs** → click the GO. The detail page shows each item as a board.

### Reading a set board
- Each column is a set (set 1, set 2 …), each row a member.
- A slot shows the joiner handle, a payment badge and a fulfillment badge.
- **OT** marks a full-set claim; those slots belong to one person and move together.
- A set is **secured** when every slot is filled, or when an admin flagged it. Flagged-but-not-full sets show holes; those holes are members we will buy with no joiner attached, so only flag when Carol agrees to eat the extra.

### Everyday actions
| Want to | Do |
|---|---|
| Secure a set early | Click the set header → **Secure anyway**. All its claims become secured and owed. |
| Move a claim to another member | Click the slot → change member → Save. If the target spot is taken the site offers to move it to the first free set. |
| Mark a claim Not fulfilled | Slot menu → "Not fulfilled". Stays in history, not ordered, not charged. Use for "seller sold out". |
| Remove a claim | Slot menu → **Remove claim**. Permanent (logged). Use for "joiner backed out" on a pending claim. |
| Drop a batch/FCFS claim | **Drop** on the claim row. |
| Add a joiner to the group chat | GC section at the bottom of the GO page → **Add to GC** next to their handle. Only joiners with at least one secured claim are listed. |

### Transferring a claim between joiners
Joiners often ask "give my Lee Know to @someone". The rule Carol set:

1. The claim moves to the new joiner.
2. If it was paid, the paid mark resets to **unpaid**. The new joiner pays fresh.
3. The old joiner's payment record stays where it is and shows as **credit** on that GO. Carol refunds it or applies it to their later claims.

Never move a payment record and never carry a paid mark across joiners. Do transfers through Carol (she does them in SQL with a log entry) until the site has a button for it.

### Joiner passcodes
Joiners see and edit their own orders on the site with a passcode they created. If someone forgets it: Admin → GOs tab → **Reset passcode** box, type their handle. They create a new one on their next visit. Reset only after you are sure it is them.

---

## 5. Closing the GO or an item

Closing stops new claims and decides what happens to pending ones.

1. On the GO page, click **Close** on an item (or **Close GO** for everything).
2. A review list opens: every unsecured claim, grouped by set. For each incomplete set you can **Secure anyway** (buy it with holes) or leave it.
3. Click **Drop remaining**. Everything still pending is dropped, the item or GO flips to closed, and joiners see their dropped claims as "not secured".
4. **Keep open** backs out with no change.

Check the pay-by dates first: a joiner who paid for a set that then drops is owed a refund or credit.

After closing, Carol places the real orders. Track what was bought under Admin → **Store** → **+ Add store order** (seller, item, member, quantity, status Ordered → Warehouse → Shipped → Received). This is how we reconcile "ordered vs secured" later, so enter every order, including re-orders and proxy pickups.

---

## 6. Payments

### How money arrives
Joiners pay PayPal F&F to **@tzhu123 (Tian Zhu)**, Venmo or Zelle, then submit a payment record on the site (**I paid** on their orders page: amount, method, transaction id). We never take goods-and-services payments.

### Confirming
Admin → **Payments**. The tab shows a dot when records are waiting.

1. Match the record to the real transfer in PayPal/Venmo/Zelle. Amount, name and transaction id must agree. Zelle duplicates are flagged by the site.
2. Click **Confirm**. A box shows: secured total owed, this payment, total paid for this GO, and how many items will be marked paid.
3. The site pays **earliest pay-by date first**, then page order. A too-big item is skipped so smaller ones can still be covered. Money left over is **credit** on that GO and is used automatically when more of their claims secure.
4. Confirm. Or **Reject** with a reason the joiner will see (wrong amount, no transfer found, G&S instead of F&F).

Things to know:
- Totals, not items, are the truth. If a joiner's paid marks look odd but their paid total equals their owed total, nothing is wrong.
- The **View receipt** link shows the proof image if the joiner uploaded one.
- **Delete** on a payment record is permanent. Reject instead.
- Credit on one GO can be applied to another GO by Carol; ask her rather than editing marks.

---

## 7. Fulfillment: tracking the physical items

On the GO page, each slot and claim has a fulfillment dropdown: **Pending → Ordered → On the way → Ready → Shipped**.

- **Ordered** when Carol has placed the seller order.
- **On the way** when the seller has shipped to Carol (or the proxy).
- **Ready** when the item is in Carol's hands, sorted, and can be shipped to the joiner. The first time you mark an item Ready the site asks for its **EMS cost per unit** (what international shipping to Carol cost per piece). Photocards default to $0.65 each. Enter the real number; it pre-fills shipping fees later.
- **Shipped** is set for you when you mark a shipping request shipped (§8). Do not set it by hand.

Sorting forms (joiners rank preferences for random pulls) live in Google Forms, not on the site. Carol allocates those; the rule is "defensible in the group chat beats best average", and nobody gets two of the same member.

---

## 8. Shipping

Joiners request shipping from their orders page once items are **paid and Ready**. They pick which items to bundle and give an address.

Admin → **Shipping** shows the queue. For each request:

1. Open it. Check the items match what is on the shelf.
2. Fees: **EMS** (pre-filled from the per-unit EMS costs × quantity) plus **domestic** (USPS to the joiner). Edit either, the total updates. The joiner sees the total and pays it like any other payment, under the same GO.
3. Pack. Enter the **tracking number**.
4. **Mark shipped**. Every item in the bundle flips to Shipped.

Other buttons: **Unship** moves a request back to the queue if you clicked too early. **×** deletes the request; the items go back to requestable, the request itself is gone for good.

Shop orders (§9) never carry EMS: that stock is already here.

---

## 9. Shop and Store

- **Shop** (Admin → Shop) sells leftover stock. Each **listing** has variants (member, version) with price and quantity. Joiners place shop orders, pay, and request shipping the same way. **Hide** takes a listing off the shop without deleting history. Deleting a shop order returns its stock. Unpaid shop orders are held 7 days before Carol releases them.
- **Store** (Admin → Store) is Carol's purchase log, see §5. It is for our bookkeeping only; joiners never see it.

---

## 10. Group chats and community

- Every GO gets a group chat on Instagram, except recurring ones (monthly Collector Supplies) which use the channel and the GO Lounge instead.
- Mark joiners **In GC** on the GO page as you add them so neither admin adds twice.
- Welcome message template (fill the brackets):

> Hi everyone, thanks for joining the **[GO name]** GO! 💛
> This chat is for updates, announcements, and any questions you have about this GO.
> 📅 **Key dates** — Claims close: **[date]** · Payment due: **[date]**
> - Check your claims anytime on the website under **My orders**.
> - Submit the payment record on the website after sending payment.
> 📢 Channel: https://www.instagram.com/channel/Fhs_kb3xhylhomBm/ · 💬 GO Lounge: https://ig.me/j/h-5rHQsQUJUOjTM3/

- Post progress ("ordered", "arrived", "sorting", "shipping this week") in the GC and the channel. Joiners ask less when they can see the stage.

---

## 11. Problem joiners

Admin → GOs tab has a **Block** control. A blocked handle cannot claim or order; existing claims stay. **Unblock** reverses it. Block for unpaid-and-ghosting after the pay-by date passed and reminders were sent, or for abuse. Tell Carol when you block someone.

---

## 12. Things only Carol does

Ask her instead of improvising:

- Username renames and merges, claim transfers between joiners, restoring deleted claims.
- Anything in Supabase directly (SQL), including fixing data the editor cannot.
- Refunds and credit moves between GOs.
- Changing the PayPal/Venmo/Zelle handles shown on the site.
- Code changes to the site.

---

## 13. Daily routine

1. **Payments** tab: confirm or reject everything waiting.
2. **Shipping** tab: process requests, enter tracking, mark shipped.
3. **GOs** tab: anything with a close or pay-by date today? Run the close review. Chase unpaid secured claims past their pay-by.
4. Update fulfillment for anything that arrived; set EMS costs when prompted.
5. Post a progress line in active GCs if a stage changed.
6. Log anything you were unsure about and tell Carol.
