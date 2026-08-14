insert into storage.buckets (id, name, public)
values ('item-images', 'item-images', true)
on conflict (id) do nothing;

create policy "admin upload item-images" on storage.objects
  for insert to authenticated with check (bucket_id = 'item-images');
create policy "admin update item-images" on storage.objects
  for update to authenticated using (bucket_id = 'item-images');
create policy "admin delete item-images" on storage.objects
  for delete to authenticated using (bucket_id = 'item-images');
-- Public read comes from the bucket's public flag (served via /storage/v1/object/public/).
