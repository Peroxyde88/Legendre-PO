alter table public.purchase_orders
add column if not exists include_driver_leaflet boolean not null default true,
add column if not exists include_terms_conditions boolean not null default false;

update public.purchase_orders
set
  include_driver_leaflet = coalesce(include_driver_leaflet, true),
  include_terms_conditions = coalesce(include_terms_conditions, false);
