update public.staff_members
set role = 'user'::public.app_role
where role = 'standard'::public.app_role;

create table if not exists public.staff_project_access (
  id uuid primary key default gen_random_uuid(),
  staff_member_id uuid not null references public.staff_members(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint staff_project_access_unique unique (staff_member_id, project_id)
);

create index if not exists staff_project_access_staff_idx on public.staff_project_access(staff_member_id);
create index if not exists staff_project_access_project_idx on public.staff_project_access(project_id);

alter table public.staff_project_access enable row level security;

create or replace function app_private.current_staff_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id
  from public.staff_members
  where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    and is_active
  limit 1;
$$;

create or replace function app_private.current_staff_role()
returns public.app_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (
      select role
      from public.staff_members
      where id = app_private.current_staff_id()
      limit 1
    ),
    'viewer'::public.app_role
  );
$$;

create or replace function app_private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_private.current_staff_role() = 'admin'::public.app_role;
$$;

create or replace function app_private.can_write_pos()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_private.current_staff_role() in ('admin'::public.app_role, 'user'::public.app_role, 'standard'::public.app_role);
$$;

create or replace function app_private.has_current_project_access(target_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_private.is_admin()
    or exists (
      select 1
      from public.staff_project_access access
      where access.staff_member_id = app_private.current_staff_id()
        and access.project_id = target_project_id
    );
$$;

create or replace function app_private.can_manage_purchase_order(target_po_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.purchase_orders po
    where po.id = target_po_id
      and (
        app_private.is_admin()
        or (
          po.requester_id = app_private.current_staff_id()
          and app_private.has_current_project_access(po.project_id)
        )
      )
  );
$$;

create or replace function public.request_staff_access(
  request_email text,
  request_full_name text,
  request_initials text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  clean_email text := lower(btrim(request_email));
  clean_name text := btrim(request_full_name);
  clean_initials text := upper(btrim(request_initials));
begin
  if clean_email = '' or clean_name = '' or clean_initials = '' then
    raise exception 'Email, full name, and initials are required';
  end if;

  insert into public.staff_members(full_name, initials, email, role, is_active)
  values (clean_name, clean_initials, clean_email, 'user'::public.app_role, false)
  on conflict (email)
  do update set
    full_name = excluded.full_name,
    initials = excluded.initials,
    role = case
      when public.staff_members.role = 'admin'::public.app_role then public.staff_members.role
      else 'user'::public.app_role
    end,
    is_active = public.staff_members.is_active,
    updated_at = now();
end;
$$;

grant execute on function public.request_staff_access(text, text, text) to anon, authenticated;
grant select, insert, update, delete on public.staff_project_access to authenticated;

create or replace function app_private.assign_current_requester()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_email text;
  current_staff_id uuid;
begin
  if auth.uid() is null then
    return new;
  end if;

  select email into current_email
  from auth.users
  where id = auth.uid();

  select id into current_staff_id
  from public.staff_members
  where lower(email) = lower(current_email)
    and is_active
  limit 1;

  if current_staff_id is null then
    raise exception 'Cannot create PO because the signed-in email does not match an active staff record';
  end if;

  new.requester_id := current_staff_id;
  return new;
end;
$$;

drop policy if exists "authenticated can read suppliers" on public.suppliers;
drop policy if exists "admins can insert suppliers" on public.suppliers;
drop policy if exists "admins can update suppliers" on public.suppliers;
drop policy if exists "admins can delete suppliers" on public.suppliers;
create policy "active staff can read suppliers" on public.suppliers
for select to authenticated using (app_private.can_write_pos());
create policy "active staff can create suppliers" on public.suppliers
for insert to authenticated with check (app_private.can_write_pos());
create policy "admins can update suppliers" on public.suppliers
for update to authenticated using (app_private.is_admin()) with check (app_private.is_admin());
create policy "admins can delete suppliers" on public.suppliers
for delete to authenticated using (app_private.is_admin());

drop policy if exists "authenticated can read projects" on public.projects;
drop policy if exists "admins can insert projects" on public.projects;
drop policy if exists "admins can update projects" on public.projects;
drop policy if exists "admins can delete projects" on public.projects;
create policy "staff can read accessible projects" on public.projects
for select to authenticated using (app_private.has_current_project_access(id));
create policy "admins can insert projects" on public.projects
for insert to authenticated with check (app_private.is_admin());
create policy "admins can update projects" on public.projects
for update to authenticated using (app_private.is_admin()) with check (app_private.is_admin());
create policy "admins can delete projects" on public.projects
for delete to authenticated using (app_private.is_admin());

drop policy if exists "authenticated can read staff" on public.staff_members;
drop policy if exists "admins can insert staff" on public.staff_members;
drop policy if exists "admins can update staff" on public.staff_members;
drop policy if exists "admins can delete staff" on public.staff_members;
create policy "staff can read relevant staff" on public.staff_members
for select to authenticated using (
  app_private.can_write_pos()
  or lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
);
create policy "admins can insert staff" on public.staff_members
for insert to authenticated with check (app_private.is_admin() or not app_private.has_staff());
create policy "admins can update staff" on public.staff_members
for update to authenticated using (app_private.is_admin() or not app_private.has_staff()) with check (app_private.is_admin() or not app_private.has_staff());
create policy "admins can delete staff" on public.staff_members
for delete to authenticated using (app_private.is_admin());

drop policy if exists "authenticated can read cost categories" on public.cost_categories;
drop policy if exists "admins can insert cost categories" on public.cost_categories;
drop policy if exists "admins can update cost categories" on public.cost_categories;
drop policy if exists "admins can delete cost categories" on public.cost_categories;
create policy "active staff can read cost categories" on public.cost_categories
for select to authenticated using (app_private.can_write_pos());
create policy "admins can insert cost categories" on public.cost_categories
for insert to authenticated with check (app_private.is_admin());
create policy "admins can update cost categories" on public.cost_categories
for update to authenticated using (app_private.is_admin()) with check (app_private.is_admin());
create policy "admins can delete cost categories" on public.cost_categories
for delete to authenticated using (app_private.is_admin());

drop policy if exists "authenticated can read app settings" on public.app_settings;
drop policy if exists "admins can insert app settings" on public.app_settings;
drop policy if exists "admins can update app settings" on public.app_settings;
drop policy if exists "admins can delete app settings" on public.app_settings;
create policy "active staff can read app settings" on public.app_settings
for select to authenticated using (app_private.can_write_pos());
create policy "admins can insert app settings" on public.app_settings
for insert to authenticated with check (app_private.is_admin());
create policy "admins can update app settings" on public.app_settings
for update to authenticated using (app_private.is_admin()) with check (app_private.is_admin());
create policy "admins can delete app settings" on public.app_settings
for delete to authenticated using (app_private.is_admin());

drop policy if exists "authenticated can read po sequences" on public.po_sequences;
drop policy if exists "admins can insert po sequences" on public.po_sequences;
drop policy if exists "admins can update po sequences" on public.po_sequences;
drop policy if exists "admins can delete po sequences" on public.po_sequences;
create policy "admins can read po sequences" on public.po_sequences
for select to authenticated using (app_private.is_admin());
create policy "admins can insert po sequences" on public.po_sequences
for insert to authenticated with check (app_private.is_admin());
create policy "admins can update po sequences" on public.po_sequences
for update to authenticated using (app_private.is_admin()) with check (app_private.is_admin());
create policy "admins can delete po sequences" on public.po_sequences
for delete to authenticated using (app_private.is_admin());

drop policy if exists "authenticated can read purchase orders" on public.purchase_orders;
drop policy if exists "standard users can create purchase orders" on public.purchase_orders;
drop policy if exists "standard users can update purchase orders" on public.purchase_orders;
drop policy if exists "admins can delete purchase orders" on public.purchase_orders;
create policy "staff can read accessible purchase orders" on public.purchase_orders
for select to authenticated using (app_private.has_current_project_access(project_id));
create policy "staff can create accessible purchase orders" on public.purchase_orders
for insert to authenticated with check (app_private.has_current_project_access(project_id));
create policy "staff can update owned accessible purchase orders" on public.purchase_orders
for update to authenticated using (app_private.can_manage_purchase_order(id)) with check (app_private.has_current_project_access(project_id));
create policy "admins can delete purchase orders" on public.purchase_orders
for delete to authenticated using (app_private.is_admin());

drop policy if exists "authenticated can read line items" on public.purchase_order_line_items;
drop policy if exists "standard users can create line items" on public.purchase_order_line_items;
drop policy if exists "standard users can update line items" on public.purchase_order_line_items;
drop policy if exists "standard users can delete line items" on public.purchase_order_line_items;
create policy "staff can read accessible line items" on public.purchase_order_line_items
for select to authenticated using (
  exists (
    select 1 from public.purchase_orders po
    where po.id = purchase_order_id
      and app_private.has_current_project_access(po.project_id)
  )
);
create policy "staff can create accessible line items" on public.purchase_order_line_items
for insert to authenticated with check (app_private.can_manage_purchase_order(purchase_order_id));
create policy "staff can update accessible line items" on public.purchase_order_line_items
for update to authenticated using (app_private.can_manage_purchase_order(purchase_order_id)) with check (app_private.can_manage_purchase_order(purchase_order_id));
create policy "staff can delete accessible line items" on public.purchase_order_line_items
for delete to authenticated using (app_private.can_manage_purchase_order(purchase_order_id));

drop policy if exists "staff can read own project access" on public.staff_project_access;
drop policy if exists "admins can insert staff project access" on public.staff_project_access;
drop policy if exists "admins can update staff project access" on public.staff_project_access;
drop policy if exists "admins can delete staff project access" on public.staff_project_access;
create policy "staff can read own project access" on public.staff_project_access
for select to authenticated using (app_private.is_admin() or staff_member_id = app_private.current_staff_id());
create policy "admins can insert staff project access" on public.staff_project_access
for insert to authenticated with check (app_private.is_admin());
create policy "admins can update staff project access" on public.staff_project_access
for update to authenticated using (app_private.is_admin()) with check (app_private.is_admin());
create policy "admins can delete staff project access" on public.staff_project_access
for delete to authenticated using (app_private.is_admin());
