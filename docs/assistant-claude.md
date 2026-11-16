# GO Manager — notes for the assistant's Claude

Read this together with `docs/admin-handbook.md`. The handbook explains the workflow; this file explains the database so Claude can answer questions like "pull X's claims" or "who has not paid for GO Y".

## Access

Your MCP connection uses the Postgres role `assistant_ro`. It can only SELECT. Any INSERT, UPDATE or DELETE fails. Fixes that need a write (renames, transfers, restoring claims, confirming payments in bulk) go to Carol.

Connection (password from Carol):

```
postgresql://assistant_ro.kkzmvuqfqbonsxebzaii:PASSWORD@aws-0-us-east-1.pooler.supabase.com:5432/postgres
```

Register it once:

```
claude mcp add godb -- npx -y @modelcontextprotocol/server-postgres "postgresql://assistant_ro.kkzmvuqfqbonsxebzaii:PASSWORD@aws-0-us-east-1.pooler.supabase.com:5432/postgres"
```

## Tables that matter

| Table | What it holds | Notes |
|---|---|---|
| `gos` | one row per group order | `name`, `artist`, `type` (photocard / album / merch), `status`, `deadline` (close date), `payment_deadline` |
| `sub_items` | items inside a GO | `go_id`, `name`, `kind` (member / photocard / versioned / single), `order_mode` (set / batch), `price`, `ot_price`, `closed`, `deadline`, `pay_due`, `ems_fee` |
| `members` | member rows of a member-kind item | `sub_item_id`, `name` |
| `versions` | version rows of a versioned item | `sub_item_id`, `name` |
| `claims` | one row per joiner per slot | `sub_item_id`, `username`, `member_id` (join `members`), `version_id` (join `versions`), `assigned_version` (text the site displays), `set_id`, `is_ot`, `qty`, `status` (pending / secured / dropped), `payment_status` (unpaid / paid), `fulfillment`, `price_override`, `archived` |
| `payments` | payment records joiners submit | `username`, `go_id`, `amount`, `method`, `transaction_id`, `status` (pending / confirmed / rejected), `is_shop`, `note`, `created_at`. No `updated_at`. |
| `gc_members` | who is marked In GC | only `go_id`, `username` |
| `blocked_users` | blocked handles | `username`, `reason` |
| `shipping_requests` | shipping queue | `username`, `ems_fee`, `dom_fee`, `total_fee`, `shipped`, `tracking_number` |
| `store_orders` | Carol's purchase log | `go_id`, `sub_item_id`, `store`, `album_version`, `qty`, `status` |
| `shop_orders`, `listings` | leftover-stock shop | |
| `admin_tasks` | the Today tab checklist | |
| `claim_edit_log` | every manual claim change Carol made in SQL | `action` rename / transfer / edit / delete, `before`, `after` |
| `admin_audit` | automatic log of every site write | `actor` (email), `tbl`, `op`, `before`, `after` |

## Quirks

- A GO's items are reached through `sub_items.go_id`. `claims` has no `go_id`; join `sub_items` first.
- Member name of a claim: `coalesce(members.name, claims.assigned_version)`. Versioned items (Sealed Member ver, album versions) keep the member in `assigned_version`, not `member_id`.
- An OT set is 8 claim rows (one per member) all with `is_ot = true`. Price it once with `ot_price`, not 8 times.
- Usernames are stored lowercase without `@`. If a joiner's claims look missing, search `ilike '%part%'` across `claims`, `payments`, `gc_members`, `joiner_passcodes`, `shipping_requests`, `shop_orders`, `blocked_users`.
- The server clock is UTC. "Today" after about 4 pm Pacific is already tomorrow in `current_date`; compare against an explicit date when it matters.
- Dropped claims stay in the table with `status = 'dropped'`. Deleted claims are gone; their `before` copy is in `claim_edit_log` or `admin_audit`.
- Count secured claims only when checking "how many to order". Pending claims may never secure.

## Standing rules (do not work around them)

- Never rename a member or a username in the GO editor; it forks the row. Carol does it in SQL.
- Claim transfer between joiners: username moves, paid mark resets to unpaid, the payment record stays with the old joiner as credit.
- Deletes on the site are permanent. Reject a payment instead of deleting it.

## Useful queries

Claims of one joiner on one GO:

```sql
select g.name as go, si.name as item, coalesce(m.name, c.assigned_version) as member,
       c.is_ot, c.qty, c.status, c.payment_status, c.fulfillment
from claims c
join sub_items si on si.id = c.sub_item_id
join gos g on g.id = si.go_id
left join members m on m.id = c.member_id
where c.username = 'handle' and g.name ilike '%part of go name%'
order by si.position, member;
```

Secured units per member on one item:

```sql
select coalesce(m.name, c.assigned_version) as member, sum(coalesce(c.qty, 1)) as n
from claims c left join members m on m.id = c.member_id
where c.sub_item_id = '<sub_item uuid>' and c.status = 'secured' and not coalesce(c.archived, false)
group by 1 order by 1;
```

Payments waiting for confirmation:

```sql
select p.created_at::date, p.username, g.name as go, p.amount, p.method, p.transaction_id
from payments p left join gos g on g.id = p.go_id
where p.status = 'pending' order by p.created_at;
```

Joiners with secured claims not yet in the GC:

```sql
select * from go_gc_pending where go_id = '<go uuid>';
```
