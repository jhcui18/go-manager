-- 031: per-unit EMS cost for non-photocard POBs (albums, plushies, merch).
-- Photocards are a flat EMS_PER_CARD each (frontend constant); everything else
-- depends on size and weight, so the admin is prompted for it the first time an
-- item of that POB is marked Ready. NULL = not entered yet (prompt again).
-- The shipping queue's EMS pre-fill = cards x per-card + sum(ems_fee x qty).
alter table sub_items add column if not exists ems_fee numeric(10,2);
