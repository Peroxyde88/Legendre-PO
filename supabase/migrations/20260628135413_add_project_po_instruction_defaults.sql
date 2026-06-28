alter table public.projects
add column if not exists default_vehicle_requirements text,
add column if not exists default_offloading_instructions text,
add column if not exists default_delivery_instructions text;

update public.projects
set
  default_vehicle_requirements = coalesce(default_vehicle_requirements, 'Vehicle to have accreditation FORS Silver as a minimum.'),
  default_offloading_instructions = coalesce(default_offloading_instructions, 'By hand during site delivery hours.'),
  default_delivery_instructions = coalesce(
    default_delivery_instructions,
    'Please call site contact 30 minutes prior to arrival. All drivers must be aware of the site and delivery rules as per the Driver''s Leaflet.'
  );
