alter table public.cost_categories
add column if not exists expense_type text;

update public.cost_categories
set expense_type = coalesce(expense_type, category_name)
where expense_type is null;

alter table public.cost_categories
alter column expense_type set not null;

alter table public.cost_categories
drop constraint if exists cost_categories_code_unique;

create index if not exists cost_categories_expense_type_idx
on public.cost_categories(expense_type);

create index if not exists cost_categories_code_idx
on public.cost_categories(category_code);
