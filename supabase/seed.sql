insert into public.cost_categories (category_name, category_code, description)
values
  ('Materials', 'MAT', 'Construction materials and consumables'),
  ('Plant and Equipment', 'PLANT', 'Plant hire, tools, equipment, and machinery'),
  ('Subcontractors', 'SUB', 'Subcontracted works and packages'),
  ('Preliminaries', 'PRELIM', 'Site preliminaries and temporary works')
on conflict (category_code) do nothing;

-- After creating your first Supabase Auth user, run a row like this with the same email.
-- insert into public.staff_members (full_name, initials, email, role)
-- values ('Your Name', 'YN', 'you@example.com', 'admin')
-- on conflict (email) do update set role = excluded.role, is_active = true;
