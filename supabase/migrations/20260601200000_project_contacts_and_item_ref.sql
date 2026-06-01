alter table public.projects
add column if not exists site_contact_name text,
add column if not exists site_contact_phone text;

alter table public.purchase_order_line_items
add column if not exists item_ref text;
