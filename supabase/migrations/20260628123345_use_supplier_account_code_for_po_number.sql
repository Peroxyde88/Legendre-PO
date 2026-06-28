create or replace function app_private.supplier_po_ref(account_code text, supplier_name text)
returns text
language sql
immutable
as $$
  with words as (
    select word, ord
    from regexp_split_to_table(upper(coalesce(supplier_name, '')), '[^A-Z0-9]+') with ordinality as parts(word, ord)
    where word <> ''
  ),
  word_summary as (
    select
      count(*) as word_count,
      min(word) filter (where ord = 1) as first_word,
      string_agg(left(word, 1), '' order by ord) as all_initials,
      string_agg(left(word, 1), '' order by ord) filter (where ord > 1) as remaining_initials
    from words
  )
  select coalesce(
    nullif(app_private.clean_po_token(account_code, null), ''),
    case
      when word_count = 1 then left(app_private.clean_po_token(first_word, 'SUP'), 3)
      when length(first_word) between 2 and 5 and first_word = remaining_initials then first_word
      else nullif(all_initials, '')
    end,
    'SUP'
  )
  from word_summary;
$$;

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

    select app_private.supplier_po_ref(account_code, supplier_name)
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
  '{"format":"PROJECTCOSTCENTRE-SUPPLIERCODE-REQUESTERINITIALS-####","example":"660-JEW-ER-0001"}',
  'Automatic purchase order number convention'
)
on conflict (setting_key)
do update set
  setting_value = excluded.setting_value,
  description = excluded.description,
  updated_at = now();
