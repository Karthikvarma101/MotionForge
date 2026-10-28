// subscription-status: whether the signed-in user has MotionForge Pro, after re-reading their open subscriptions
// from Razorpay (so it is right even before the webhook is set up, or if a webhook was missed).
//
// POST {}                     →  { pro, plan_id, status, current_end, cancel_at_period_end }
// POST { "action": "cancel" } →  cancels the paid subscription at the end of the period, then the same answer
//
// Single file on purpose (the dashboard editor can't follow shared imports). Deploy with --no-verify-jwt: the
// caller's access token is checked here. Secrets: RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET.
import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2.118.0";

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

interface RazorpayConfig { keyId: string; keySecret: string }
function razorpayConfig(): RazorpayConfig | null {
  const keyId = Deno.env.get("RAZORPAY_KEY_ID")?.trim();
  const keySecret = Deno.env.get("RAZORPAY_KEY_SECRET")?.trim();
  return keyId && keySecret ? { keyId, keySecret } : null;
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
  if (!res.ok) throw new Error(`razorpay_${data?.error?.code ?? res.status}${data?.error?.description ? `: ${data.error.description}` : ""}`);
  return data as T;
}

interface Row {
  razorpay_subscription_id: string; plan_id: string; status: string; current_end: string | null;
  cancel_at_period_end: boolean; created_at: string; updated_at: string;
}
interface RzpSubscription { id: string; status: string; current_start: number | null; current_end: number | null; ended_at: number | null }

const FINAL = ["cancelled", "completed", "expired"];
const iso = (unix: number | null) => (unix ? new Date(unix * 1000).toISOString() : null);
const paid = (r: Row) => ["active", "authenticated", "pending"].includes(r.status) ||
  (["cancelled", "halted", "completed"].includes(r.status) && !!r.current_end && Date.parse(r.current_end) > Date.now());

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const admin = adminClient();
  const user = await signedInUser(admin, req);
  if (!user) return json({ error: "not_signed_in" }, 401);
  const { action } = await req.json().catch(() => ({})) as { action?: string };
  const cfg = razorpayConfig();

  const read = async () =>
    ((await admin.from("subscriptions").select("*").eq("user_id", user.id).order("created_at", { ascending: false })).data ?? []) as Row[];
  let rows = await read();

  try {
    if (cfg) {
      // Re-read anything Razorpay may have moved on: open subscriptions, and cancelled ones still inside their period.
      for (const r of rows) {
        if (FINAL.includes(r.status) && !(r.current_end && Date.parse(r.current_end) > Date.now())) continue;
        const s = await rzp<RzpSubscription>(cfg, "GET", `/subscriptions/${r.razorpay_subscription_id}`);
        await admin.from("subscriptions").update({
          status: s.status, current_start: iso(s.current_start), current_end: iso(s.current_end ?? s.ended_at),
          updated_at: new Date().toISOString(),
        }).eq("razorpay_subscription_id", s.id);
      }
      if (action === "cancel") {
        const target = (await read()).find((r) => ["active", "authenticated", "pending"].includes(r.status) && !r.cancel_at_period_end);
        if (target) {
          await rzp(cfg, "POST", `/subscriptions/${target.razorpay_subscription_id}/cancel`, { cancel_at_cycle_end: 1 });
          await admin.from("subscriptions").update({ cancel_at_period_end: true, updated_at: new Date().toISOString() })
            .eq("razorpay_subscription_id", target.razorpay_subscription_id);
        }
      }
      rows = await read();
    }
  } catch (e) {
    // Answer from what is stored rather than failing: the app retries later.
    console.error(`subscription-status ${user.id}:`, e instanceof Error ? e.message : String(e));
  }

  const best = rows.find(paid) ?? rows[0];
  return json({
    pro: rows.some(paid),
    plan_id: best?.plan_id ?? null,
    status: best?.status ?? null,
    current_end: best?.current_end ?? null,
    cancel_at_period_end: best?.cancel_at_period_end ?? false,
    payments_configured: !!cfg,
  });
});
