create or replace function app_private.clean_po_token(value text, fallback text)
returns text
language sql
immutable
as $$
  select coalesce(nullif(upper(regexp_replace(coalesce(value, ''), '[^A-Za-z0-9]+', '', 'g')), ''), fallback);
$$;

create or replace function app_private.initials_from_text(value text, fallback text)
returns text
language sql
immutable
as $$
  select coalesce(
    nullif((
      select string_agg(left(word, 1), '' order by ord)
      from regexp_split_to_table(upper(coalesce(value, '')), '[^A-Z0-9]+') with ordinality as words(word, ord)
      where word <> ''
    ), ''),
    fallback
  );
$$;

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
  limit 1;

  if current_staff_id is null then
    raise exception 'Cannot create PO because the signed-in email does not match a staff record';
  end if;

  new.requester_id := current_staff_id;
  return new;
end;
$$;

drop trigger if exists purchase_orders_assign_requester on public.purchase_orders;
create trigger purchase_orders_assign_requester
before insert on public.purchase_orders
for each row execute function app_private.assign_current_requester();

create or replace function app_private.generate_po_number()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  project_ref text;
  supplier_ref text;
  requester_ref text;
  sequence_number int;
begin
  if new.po_number is null or btrim(new.po_number) = '' then
    select app_private.clean_po_token(coalesce(nullif(cost_centre_code, ''), nullif(project_code, '')), 'PROJECT')
    into project_ref
    from public.projects
    where id = new.project_id;

    select app_private.initials_from_text(supplier_name, 'SUP')
    into supplier_ref
    from public.suppliers
    where id = new.supplier_id;

    select app_private.clean_po_token(coalesce(nullif(initials, ''), app_private.initials_from_text(full_name, 'REQ')), 'REQ')
    into requester_ref
    from public.staff_members
    where id = new.requester_id;

    if project_ref is null then
      raise exception 'Cannot generate PO number without a valid project';
    end if;

    if supplier_ref is null then
      raise exception 'Cannot generate PO number without a valid supplier';
    end if;

    if requester_ref is null then
      raise exception 'Cannot generate PO number without a valid requester';
    end if;

    insert into public.po_sequences(project_id, po_year, last_number)
    values (new.project_id, 0, 1)
    on conflict (project_id, po_year)
    do update set
      last_number = public.po_sequences.last_number + 1,
      updated_at = now()
    returning last_number into sequence_number;

    new.po_number := project_ref || '-' || supplier_ref || '-' || requester_ref || '-' || lpad(sequence_number::text, 4, '0');
  end if;

  return new;
end;
$$;

insert into public.app_settings(setting_key, setting_value, description)
values (
  'po_numbering',
  '{"format":"PROJECTCOSTCENTRE-SUPPLIERINITIALS-REQUESTERINITIALS-####","example":"660-L-ER-0001"}',
  'Automatic purchase order number convention'
)
on conflict (setting_key)
do update set
  setting_value = excluded.setting_value,
  description = excluded.description,
  updated_at = now();
