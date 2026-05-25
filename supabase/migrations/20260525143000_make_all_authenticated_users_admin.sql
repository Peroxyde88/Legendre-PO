create or replace function app_private.current_staff_role()
returns public.app_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when auth.uid() is not null then 'admin'::public.app_role
    else 'viewer'::public.app_role
  end;
$$;
