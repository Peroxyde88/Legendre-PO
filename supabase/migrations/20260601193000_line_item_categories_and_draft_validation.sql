alter table public.purchase_order_line_items
add column if not exists category_id uuid references public.cost_categories(id) on delete set null;

update public.purchase_order_line_items line
set category_id = po.category_id
from public.purchase_orders po
where po.id = line.purchase_order_id
  and line.category_id is null
  and po.category_id is not null;

create index if not exists purchase_order_line_items_category_id_idx
on public.purchase_order_line_items(category_id);

alter table public.purchase_orders
alter column status drop default;

alter table public.purchase_orders
alter column status type text using case
  when status::text = 'draft' then 'draft'
  else 'validated'
end;

drop type if exists public.po_status;
create type public.po_status as enum ('draft', 'validated');

alter table public.purchase_orders
alter column status type public.po_status using status::public.po_status;

alter table public.purchase_orders
alter column status set default 'draft';

create or replace function app_private.set_po_status_timestamps()
returns trigger
language plpgsql
set search_path = app_private, public, pg_temp
as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'validated' and new.approved_at is null then
      new.approved_at := now();
    end if;
  end if;

  return new;
end;
$$;

drop policy if exists "staff can update owned accessible purchase orders" on public.purchase_orders;
drop policy if exists "admins can delete purchase orders" on public.purchase_orders;
drop policy if exists "staff can update draft accessible purchase orders" on public.purchase_orders;
drop policy if exists "staff can delete draft accessible purchase orders" on public.purchase_orders;

create policy "staff can update draft accessible purchase orders" on public.purchase_orders
for update to authenticated
using (app_private.can_manage_purchase_order(id) and status = 'draft')
with check (app_private.has_current_project_access(project_id));

create policy "staff can delete draft accessible purchase orders" on public.purchase_orders
for delete to authenticated
using (app_private.can_manage_purchase_order(id) and status = 'draft');

drop policy if exists "staff can create accessible line items" on public.purchase_order_line_items;
drop policy if exists "staff can update accessible line items" on public.purchase_order_line_items;
drop policy if exists "staff can delete accessible line items" on public.purchase_order_line_items;
drop policy if exists "staff can create draft line items" on public.purchase_order_line_items;
drop policy if exists "staff can update draft line items" on public.purchase_order_line_items;
drop policy if exists "staff can delete draft line items" on public.purchase_order_line_items;

create policy "staff can create draft line items" on public.purchase_order_line_items
for insert to authenticated
with check (
  exists (
    select 1 from public.purchase_orders po
    where po.id = purchase_order_id
      and po.status = 'draft'
      and app_private.can_manage_purchase_order(po.id)
  )
);

create policy "staff can update draft line items" on public.purchase_order_line_items
for update to authenticated
using (
  exists (
    select 1 from public.purchase_orders po
    where po.id = purchase_order_id
      and po.status = 'draft'
      and app_private.can_manage_purchase_order(po.id)
  )
)
with check (
  exists (
    select 1 from public.purchase_orders po
    where po.id = purchase_order_id
      and po.status = 'draft'
      and app_private.can_manage_purchase_order(po.id)
  )
);

create policy "staff can delete draft line items" on public.purchase_order_line_items
for delete to authenticated
using (
  exists (
    select 1 from public.purchase_orders po
    where po.id = purchase_order_id
      and po.status = 'draft'
      and app_private.can_manage_purchase_order(po.id)
  )
);
