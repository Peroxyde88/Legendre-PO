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

  if new.email is distinct from old.email
    or new.role is distinct from old.role
    or new.is_active is distinct from old.is_active then
    raise exception 'Only admins can update staff access fields';
  end if;

  return new;
end;
$$;

drop trigger if exists staff_members_protect_self_update on public.staff_members;
create trigger staff_members_protect_self_update
before update on public.staff_members
for each row
execute function app_private.protect_staff_self_update();

drop policy if exists "staff can update own profile" on public.staff_members;
create policy "staff can update own profile"
on public.staff_members
for update
to authenticated
using (email = lower((select auth.email())))
with check (email = lower((select auth.email())));
