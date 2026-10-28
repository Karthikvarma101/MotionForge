// subscription-checkout: starts MotionForge Pro for the signed-in user.
//
// POST { "plan_id": "pro_monthly" | "pro_yearly" }  →  { subscription_id, short_url, status }
//
// Creates the Razorpay plan the first time a period is sold (and again if the key mode changes between test and
// live), then a Razorpay subscription, and returns Razorpay's hosted page (`short_url`) where the user pays the
// first period and sets up the mandate (UPI autopay or card). The app opens that page in the browser and asks
// `subscription-status` until the subscription is active.
//
// Single file on purpose (the dashboard editor can't follow shared imports). Deploy with --no-verify-jwt: the
// caller's access token is checked here (x-user-jwt, or Authorization: Bearer).
// Secrets: RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET (set by the project owner; never committed).
import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2.118.0";

const APP_TAG = "motionforge";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-user-jwt",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS } });

function serverKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}") as Record<string, string>;
    const key = keys.default ?? Object.values(keys)[0];
    if (key) return key;
  } catch { /* fall back to the legacy key */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
}
const adminClient = () =>
  createClient(Deno.env.get("SUPABASE_URL")!, serverKey(), { auth: { persistSession: false, autoRefreshToken: false } });

async function signedInUser(admin: SupabaseClient, req: Request): Promise<User | null> {
  const token = req.headers.get("x-user-jwt") || (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data: { user }, error } = await admin.auth.getUser(token);
  return error ? null : user;
}

interface RazorpayConfig { keyId: string; keySecret: string; mode: "live" | "test" }
function razorpayConfig(): RazorpayConfig | null {
  const keyId = Deno.env.get("RAZORPAY_KEY_ID")?.trim();
  const keySecret = Deno.env.get("RAZORPAY_KEY_SECRET")?.trim();
  if (!keyId || !keySecret) return null;
  return { keyId, keySecret, mode: keyId.startsWith("rzp_live_") ? "live" : "test" };
}
async function rzp<T>(cfg: RazorpayConfig, method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const res = await fetch(`https://api.razorpay.com/v1${path}`, {
    method,
    headers: {
      Authorization: `Basic ${btoa(`${cfg.keyId}:${cfg.keySecret}`)}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    if (res.status === 401) throw new Error("payments_not_configured: Razorpay rejected the key id or secret");
    throw new Error(`razorpay_${data?.error?.code ?? res.status}${data?.error?.description ? `: ${data.error.description}` : ""}`);
  }
  return data as T;
}

interface Plan { id: string; name: string; amount_paise: number; period: "monthly" | "yearly"; razorpay_plan_id: string | null; razorpay_mode: string | null }
interface RzpSubscription { id: string; status: string; short_url: string }

const PAID = ["active", "authenticated", "pending"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const cfg = razorpayConfig();
  if (!cfg) return json({ error: "payments_not_configured" }, 503);
  const admin = adminClient();
  const user = await signedInUser(admin, req);
  if (!user) return json({ error: "not_signed_in" }, 401);
  const { plan_id } = await req.json().catch(() => ({})) as { plan_id?: string };

  try {
    const { data: plan } = await admin.from("plans").select("*").eq("id", plan_id ?? "").eq("active", true).maybeSingle<Plan>();
    if (!plan) return json({ error: "unknown_plan" }, 400);

    // Already paid up: nothing to buy.
    const { data: subs } = await admin.from("subscriptions").select("plan_id,status,current_end,short_url,razorpay_subscription_id,created_at")
      .eq("user_id", user.id).order("created_at", { ascending: false });
    const now = Date.now();
    if ((subs ?? []).some((s) => PAID.includes(s.status) ||
        (["cancelled", "halted", "completed"].includes(s.status) && s.current_end && Date.parse(s.current_end) > now))) {
      return json({ error: "already_pro" }, 409);
    }
    // A checkout for the same plan started in the last day and never paid: send the user back to it.
    const open = (subs ?? []).find((s) => s.status === "created" && s.plan_id === plan.id && s.short_url &&
      now - Date.parse(s.created_at) < 86_400_000);
    if (open) return json({ subscription_id: open.razorpay_subscription_id, short_url: open.short_url, status: open.status });

    // The Razorpay plan for this period, created once per key mode.
    let razorpayPlan = plan.razorpay_mode === cfg.mode ? plan.razorpay_plan_id : null;
    if (!razorpayPlan) {
      const created = await rzp<{ id: string }>(cfg, "POST", "/plans", {
        period: plan.period, interval: 1,
        item: { name: plan.name, amount: plan.amount_paise, currency: "INR", description: "Export from MotionForge" },
        notes: { app: APP_TAG, plan_id: plan.id },
      });
      razorpayPlan = created.id;
      await admin.from("plans").update({ razorpay_plan_id: razorpayPlan, razorpay_mode: cfg.mode }).eq("id", plan.id);
    }

    const sub = await rzp<RzpSubscription>(cfg, "POST", "/subscriptions", {
      plan_id: razorpayPlan,
      total_count: plan.period === "monthly" ? 60 : 10,  // renews for 5 / 10 years unless cancelled
      quantity: 1,
      customer_notify: 1,
      notes: { app: APP_TAG, user_id: user.id, plan_id: plan.id, email: user.email ?? "" },
    });
    const { error } = await admin.from("subscriptions").insert({
      user_id: user.id, plan_id: plan.id, razorpay_subscription_id: sub.id, status: sub.status, short_url: sub.short_url,
      amount_paise: plan.amount_paise,
    });
    if (error) throw new Error(error.message);
    return json({ subscription_id: sub.id, short_url: sub.short_url, status: sub.status });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error(`subscription-checkout ${user.id}:`, message);
    return json({ error: message }, message.startsWith("payments_not_configured") ? 503 : 500);
  }
});
