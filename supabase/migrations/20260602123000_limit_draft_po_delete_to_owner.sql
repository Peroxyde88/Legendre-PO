drop policy if exists "staff can delete draft accessible purchase orders" on public.purchase_orders;
drop policy if exists "staff can delete own draft purchase orders" on public.purchase_orders;

create policy "staff can delete own draft purchase orders"
on public.purchase_orders
for delete
to authenticated
using (
  status = 'draft'
  and requester_id = app_private.current_staff_id()
  and app_private.has_current_project_access(project_id)
);
