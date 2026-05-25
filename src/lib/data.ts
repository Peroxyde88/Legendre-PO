import { supabase } from "./supabase";
import type {
  AppRole,
  AppSetting,
  CostCategory,
  Project,
  PurchaseOrder,
  PurchaseOrderLineItem,
  PurchaseOrderStatus,
  ReferenceData,
  StaffMember,
  Supplier,
} from "../types";

const poSelect = `
  *,
  supplier:suppliers(*),
  project:projects(*),
  requester:staff_members!purchase_orders_requester_id_fkey(*),
  approver:staff_members!purchase_orders_approver_id_fkey(*),
  category:cost_categories(*),
  line_items:purchase_order_line_items(*)
`;

function requireClient() {
  if (!supabase) throw new Error("Supabase environment variables are not configured.");
  return supabase;
}

export async function loadReferenceData(): Promise<ReferenceData> {
  const client = requireClient();
  const [suppliers, projects, staff, categories, settings] = await Promise.all([
    client.from("suppliers").select("*").order("supplier_name"),
    client.from("projects").select("*").order("project_name"),
    client.from("staff_members").select("*").order("full_name"),
    client.from("cost_categories").select("*").order("category_name"),
    client.from("app_settings").select("*").order("setting_key"),
  ]);

  for (const result of [suppliers, projects, staff, categories, settings]) {
    if (result.error) throw result.error;
  }

  return {
    suppliers: (suppliers.data ?? []) as Supplier[],
    projects: (projects.data ?? []) as Project[],
    staff: (staff.data ?? []) as StaffMember[],
    categories: (categories.data ?? []) as CostCategory[],
    settings: (settings.data ?? []) as AppSetting[],
  };
}

export async function loadPurchaseOrders(): Promise<PurchaseOrder[]> {
  const client = requireClient();
  const { data, error } = await client
    .from("purchase_orders")
    .select(poSelect)
    .order("po_date", { ascending: false })
    .order("created_at", { ascending: false });

  if (error) throw error;

  return (data ?? []).map((po) => ({
    ...po,
    line_items: [...(po.line_items ?? [])].sort((a, b) => a.sort_order - b.sort_order),
  })) as PurchaseOrder[];
}

export async function upsertSupplier(payload: Partial<Supplier>) {
  return upsertRow("suppliers", payload);
}

export async function upsertProject(payload: Partial<Project>) {
  return upsertRow("projects", payload);
}

export async function upsertStaff(payload: Partial<StaffMember>) {
  return upsertRow("staff_members", payload);
}

export async function upsertCategory(payload: Partial<CostCategory>) {
  return upsertRow("cost_categories", payload);
}

export async function upsertSetting(payload: Partial<AppSetting>) {
  return upsertRow("app_settings", payload, "setting_key");
}

export async function deleteRow(table: string, id: string, key = "id") {
  const client = requireClient();
  const { error } = await client.from(table).delete().eq(key, id);
  if (error) throw error;
}

async function upsertRow(table: string, payload: Record<string, unknown>, key = "id") {
  const client = requireClient();
  const cleanPayload = Object.fromEntries(
    Object.entries(payload).filter(([, value]) => value !== undefined),
  );
  const query = cleanPayload[key]
    ? client.from(table).update(cleanPayload).eq(key, cleanPayload[key] as string)
    : client.from(table).insert(cleanPayload);
  const { error } = await query;
  if (error) throw error;
}

export type PurchaseOrderDraft = {
  project_id: string;
  supplier_id: string;
  requester_id: string | null;
  approver_id: string | null;
  category_id: string | null;
  status: PurchaseOrderStatus;
  po_date: string;
  delivery_date: string | null;
  delivery_address: string | null;
  supplier_contact_name: string | null;
  supplier_email: string | null;
  supplier_phone: string | null;
  supplier_address: string | null;
  site_contact: string | null;
  vehicle_requirements: string | null;
  offloading_instructions: string | null;
  delivery_instructions: string | null;
  notes: string | null;
  line_items: PurchaseOrderLineItem[];
};

export async function createPurchaseOrder(draft: PurchaseOrderDraft) {
  const client = requireClient();
  const { data: userData } = await client.auth.getUser();
  const { line_items, ...po } = draft;

  const { data, error } = await client
    .from("purchase_orders")
    .insert({
      ...po,
      created_by: userData.user?.id ?? null,
    })
    .select("id")
    .single();

  if (error) throw error;

  const rows = line_items.map((item, index) => ({
    purchase_order_id: data.id,
    sort_order: index + 1,
    description: item.description,
    quantity: item.quantity,
    unit: item.unit,
    rate: item.rate,
    vat_rate: item.vat_rate,
  }));

  const { error: lineError } = await client.from("purchase_order_line_items").insert(rows);
  if (lineError) throw lineError;

  return data.id as string;
}

export async function updatePurchaseOrderStatus(id: string, status: PurchaseOrderStatus) {
  const client = requireClient();
  const { error } = await client.from("purchase_orders").update({ status }).eq("id", id);
  if (error) throw error;
}

export function roleCanAdmin(role: AppRole | null | undefined) {
  return role === "admin";
}

export function roleCanWritePo(role: AppRole | null | undefined) {
  return role === "admin" || role === "standard";
}
