create extension if not exists pgcrypto;

create type public.app_role as enum ('admin', 'standard', 'viewer');
create type public.po_status as enum ('draft', 'issued', 'approved', 'cancelled', 'archived');

create schema if not exists app_private;

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  supplier_name text not null,
  account_code text,
  contact_name text,
  email text,
  phone text,
  address text,
  vat_number text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint suppliers_account_code_unique unique (account_code)
);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  project_name text not null,
  project_code text not null,
  site_address text,
  cost_centre_code text,
  default_delivery_address text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint projects_project_code_unique unique (project_code)
);

create table public.staff_members (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  initials text,
  email text not null,
  role public.app_role not null default 'standard',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint staff_members_email_unique unique (email),
  constraint staff_members_initials_unique unique (initials)
);

create table public.cost_categories (
  id uuid primary key default gen_random_uuid(),
  category_name text not null,
  category_code text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cost_categories_code_unique unique (category_code)
);

create table public.app_settings (
  setting_key text primary key,
  setting_value jsonb not null default '{}'::jsonb,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.po_sequences (
  project_id uuid not null references public.projects(id) on delete cascade,
  po_year int not null,
  last_number int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (project_id, po_year)
);

create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  po_number text not null,
  project_id uuid not null references public.projects(id),
  supplier_id uuid not null references public.suppliers(id),
  requester_id uuid references public.staff_members(id),
  approver_id uuid references public.staff_members(id),
  category_id uuid references public.cost_categories(id),
  status public.po_status not null default 'draft',
  po_date date not null default current_date,
  delivery_date date,
  delivery_address text,
  supplier_contact_name text,
  supplier_email text,
  supplier_phone text,
  supplier_address text,
  site_contact text,
  vehicle_requirements text,
  offloading_instructions text,
  delivery_instructions text,
  subtotal numeric(12,2) not null default 0,
  vat_total numeric(12,2) not null default 0,
  grand_total numeric(12,2) not null default 0,
  notes text,
  issued_at timestamptz,
  approved_at timestamptz,
  cancelled_at timestamptz,
  archived_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchase_orders_po_number_unique unique (po_number)
);

create table public.purchase_order_line_items (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  sort_order int not null default 1,
  description text not null,
  quantity numeric(12,3) not null default 1,
  unit text not null default 'each',
  rate numeric(12,2) not null default 0,
  vat_rate numeric(5,2) not null default 20,
  line_total numeric(12,2) generated always as (round((quantity * rate)::numeric, 2)) stored,
  line_vat numeric(12,2) generated always as (round(((quantity * rate) * vat_rate / 100)::numeric, 2)) stored,
  gross_total numeric(12,2) generated always as (round(((quantity * rate) * (1 + vat_rate / 100))::numeric, 2)) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchase_order_line_items_quantity_positive check (quantity > 0),
  constraint purchase_order_line_items_rate_nonnegative check (rate >= 0),
  constraint purchase_order_line_items_vat_valid check (vat_rate in (0, 5, 20))
);

create index purchase_orders_project_id_idx on public.purchase_orders(project_id);
create index purchase_orders_supplier_id_idx on public.purchase_orders(supplier_id);
create index purchase_orders_status_idx on public.purchase_orders(status);
create index purchase_orders_po_date_idx on public.purchase_orders(po_date);
create index purchase_order_line_items_po_id_idx on public.purchase_order_line_items(purchase_order_id);

create or replace function app_private.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger suppliers_touch_updated_at before update on public.suppliers
for each row execute function app_private.touch_updated_at();
create trigger projects_touch_updated_at before update on public.projects
for each row execute function app_private.touch_updated_at();
create trigger staff_members_touch_updated_at before update on public.staff_members
for each row execute function app_private.touch_updated_at();
create trigger cost_categories_touch_updated_at before update on public.cost_categories
for each row execute function app_private.touch_updated_at();
create trigger app_settings_touch_updated_at before update on public.app_settings
for each row execute function app_private.touch_updated_at();
create trigger purchase_orders_touch_updated_at before update on public.purchase_orders
for each row execute function app_private.touch_updated_at();
create trigger purchase_order_line_items_touch_updated_at before update on public.purchase_order_line_items
for each row execute function app_private.touch_updated_at();

create or replace function app_private.generate_po_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  project_ref text;
  sequence_number int;
  sequence_year int;
  year_code text;
begin
  if new.po_number is null or btrim(new.po_number) = '' then
    select project_code into project_ref
    from public.projects
    where id = new.project_id;

    if project_ref is null then
      raise exception 'Cannot generate PO number without a valid project';
    end if;

    sequence_year := extract(year from coalesce(new.po_date, current_date))::int;
    year_code := to_char(coalesce(new.po_date, current_date), 'YY');

    insert into public.po_sequences(project_id, po_year, last_number)
    values (new.project_id, sequence_year, 1)
    on conflict (project_id, po_year)
    do update set
      last_number = public.po_sequences.last_number + 1,
      updated_at = now()
    returning last_number into sequence_number;

    new.po_number := upper(regexp_replace(project_ref, '[^A-Za-z0-9-]+', '-', 'g')) || '-' || year_code || '-' || lpad(sequence_number::text, 4, '0');
  end if;

  return new;
end;
$$;

create trigger purchase_orders_generate_po_number before insert on public.purchase_orders
for each row execute function app_private.generate_po_number();

create or replace function app_private.set_po_status_timestamps()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'issued' and new.issued_at is null then
      new.issued_at = now();
    elsif new.status = 'approved' and new.approved_at is null then
      new.approved_at = now();
    elsif new.status = 'cancelled' and new.cancelled_at is null then
      new.cancelled_at = now();
    elsif new.status = 'archived' and new.archived_at is null then
      new.archived_at = now();
    end if;
  end if;
  return new;
end;
$$;

create trigger purchase_orders_set_status_timestamps before update on public.purchase_orders
for each row execute function app_private.set_po_status_timestamps();

create or replace function app_private.recalculate_purchase_order_totals()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  target_po_id uuid;
begin
  if tg_op = 'DELETE' then
    target_po_id := old.purchase_order_id;
  else
    target_po_id := new.purchase_order_id;
  end if;

  update public.purchase_orders po
  set
    subtotal = coalesce(t.subtotal, 0),
    vat_total = coalesce(t.vat_total, 0),
    grand_total = coalesce(t.grand_total, 0),
    updated_at = now()
  from (
    select
      purchase_order_id,
      sum(line_total) as subtotal,
      sum(line_vat) as vat_total,
      sum(gross_total) as grand_total
    from public.purchase_order_line_items
    where purchase_order_id = target_po_id
    group by purchase_order_id
  ) t
  where po.id = target_po_id
    and po.id = t.purchase_order_id;

  update public.purchase_orders
  set subtotal = 0, vat_total = 0, grand_total = 0, updated_at = now()
  where id = target_po_id
    and not exists (
      select 1 from public.purchase_order_line_items
      where purchase_order_id = target_po_id
    );

  return null;
end;
$$;

create trigger purchase_order_line_items_recalculate_totals
after insert or update or delete on public.purchase_order_line_items
for each row execute function app_private.recalculate_purchase_order_totals();

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
      where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
        and is_active
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
  select app_private.current_staff_role() in ('admin'::public.app_role, 'standard'::public.app_role);
$$;

create or replace function app_private.has_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.staff_members);
$$;

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage on schema app_private to authenticated;
grant execute on all functions in schema app_private to authenticated;

alter table public.suppliers enable row level security;
alter table public.projects enable row level security;
alter table public.staff_members enable row level security;
alter table public.cost_categories enable row level security;
alter table public.app_settings enable row level security;
alter table public.po_sequences enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_line_items enable row level security;

create policy "authenticated can read suppliers" on public.suppliers
for select to authenticated using (true);
create policy "admins can manage suppliers" on public.suppliers
for all to authenticated using (app_private.is_admin()) with check (app_private.is_admin());

create policy "authenticated can read projects" on public.projects
for select to authenticated using (true);
create policy "admins can manage projects" on public.projects
for all to authenticated using (app_private.is_admin()) with check (app_private.is_admin());

create policy "authenticated can read staff" on public.staff_members
for select to authenticated using (true);
create policy "admins can manage staff" on public.staff_members
for all to authenticated
using (app_private.is_admin() or not app_private.has_staff())
with check (app_private.is_admin() or not app_private.has_staff());

create policy "authenticated can read cost categories" on public.cost_categories
for select to authenticated using (true);
create policy "admins can manage cost categories" on public.cost_categories
for all to authenticated using (app_private.is_admin()) with check (app_private.is_admin());

create policy "authenticated can read app settings" on public.app_settings
for select to authenticated using (true);
create policy "admins can manage app settings" on public.app_settings
for all to authenticated using (app_private.is_admin()) with check (app_private.is_admin());

create policy "authenticated can read po sequences" on public.po_sequences
for select to authenticated using (true);
create policy "po sequence writes are internal admin only" on public.po_sequences
for all to authenticated using (app_private.is_admin()) with check (app_private.is_admin());

create policy "authenticated can read purchase orders" on public.purchase_orders
for select to authenticated using (true);
create policy "standard users can create purchase orders" on public.purchase_orders
for insert to authenticated with check (app_private.can_write_pos());
create policy "standard users can update purchase orders" on public.purchase_orders
for update to authenticated using (app_private.can_write_pos()) with check (app_private.can_write_pos());
create policy "admins can delete purchase orders" on public.purchase_orders
for delete to authenticated using (app_private.is_admin());

create policy "authenticated can read line items" on public.purchase_order_line_items
for select to authenticated using (true);
create policy "standard users can create line items" on public.purchase_order_line_items
for insert to authenticated with check (app_private.can_write_pos());
create policy "standard users can update line items" on public.purchase_order_line_items
for update to authenticated using (app_private.can_write_pos()) with check (app_private.can_write_pos());
create policy "standard users can delete line items" on public.purchase_order_line_items
for delete to authenticated using (app_private.can_write_pos());

insert into public.app_settings(setting_key, setting_value, description)
values
  ('company', '{"name":"Legendre UK Limited","address":"Ground Floor, Peer House, 8-14 Verulam Street, London, WC1X 8LZ","phone":"+44 (0) 2035 538420","email":"uk@groupe-legendre.com","accounts_email":"leguk.accounts@groupe-legendre.com"}', 'Company details shown on purchase orders'),
  ('po_numbering', '{"format":"PROJECTCODE-YY-####","example":"CDA-26-0001"}', 'Automatic purchase order number convention')
on conflict (setting_key) do nothing;
