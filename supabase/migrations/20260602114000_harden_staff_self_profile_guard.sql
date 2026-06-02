create or replace function app_private.protect_staff_self_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app_private.is_admin() then
    return new;
  end if;

  if new.id is distinct from old.id
    or new.email is distinct from old.email
    or new.role is distinct from old.role
    or new.is_active is distinct from old.is_active
    or new.created_at is distinct from old.created_at
    or new.updated_at is distinct from old.updated_at then
    raise exception 'Only admins can update staff access fields';
  end if;

  return new;
end;
$$;
