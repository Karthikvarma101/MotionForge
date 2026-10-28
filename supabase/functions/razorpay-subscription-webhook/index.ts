// razorpay-subscription-webhook: Razorpay's server-to-server notices for MotionForge subscriptions
// (subscription.authenticated / activated / charged / pending / halted / cancelled / completed / updated). Keeps
// `subscriptions` in step even when the app is closed. Set it up in Razorpay Dashboard › Webhooks with the same secret
// as the RAZORPAY_WEBHOOK_SECRET function secret.
//
// Single file on purpose (the dashboard editor can't follow shared imports). Deploy with --no-verify-jwt: Razorpay
// sends no Supabase key; the request is trusted only if its HMAC signature matches.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const APP_TAG = "motionforge";
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function serverKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}") as Record<string, string>;
    const key = keys.default ?? Object.values(keys)[0];
    if (key) return key;
  } catch { /* fall back to the legacy key */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
}

async function validSignature(secret: string, message: string, signature: string): Promise<boolean> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message)));
  const expected = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  const given = signature.trim().toLowerCase();
  if (given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

const iso = (unix: number | null | undefined) => (unix ? new Date(unix * 1000).toISOString() : null);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const secret = Deno.env.get("RAZORPAY_WEBHOOK_SECRET")?.trim();
  const keyId = Deno.env.get("RAZORPAY_KEY_ID")?.trim(), keySecret = Deno.env.get("RAZORPAY_KEY_SECRET")?.trim();
  if (!secret || !keyId || !keySecret) return json({ error: "payments_not_configured" }, 503);

  const raw = await req.text();
  if (!await validSignature(secret, raw, req.headers.get("x-razorpay-signature") ?? "")) return json({ error: "signature_mismatch" }, 401);
  // deno-lint-ignore no-explicit-any
  let event: any;
  try {
    event = JSON.parse(raw);
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  if (typeof event.event !== "string" || !event.event.startsWith("subscription.")) return json({ ignored: event.event });
  const id = event.payload?.subscription?.entity?.id;
  if (typeof id !== "string") return json({ ignored: "no_subscription" });

  try {
    // Re-read the subscription instead of trusting the event body alone.
    const res = await fetch(`https://api.razorpay.com/v1/subscriptions/${id}`, {
      headers: { Authorization: `Basic ${btoa(`${keyId}:${keySecret}`)}` },
    });
    const s = await res.json();
    if (!res.ok) throw new Error(`razorpay_${s?.error?.code ?? res.status}`);
    const notes = Array.isArray(s.notes) ? {} : (s.notes ?? {});
    if (notes.app !== APP_TAG) return json({ ignored: "not_motionforge" });  // a Razorpay account shared with other apps

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, serverKey(), { auth: { persistSession: false, autoRefreshToken: false } });
    const fields = {
      status: s.status, current_start: iso(s.current_start), current_end: iso(s.current_end ?? s.ended_at),
      updated_at: new Date().toISOString(),
    };
    const { data: updated } = await admin.from("subscriptions").update(fields).eq("razorpay_subscription_id", id).select("id");
    if (!updated?.length && notes.user_id && notes.plan_id) {
      // Created outside the app (e.g. from the Razorpay dashboard): record it from its notes.
      await admin.from("subscriptions").insert({
        ...fields, user_id: notes.user_id, plan_id: notes.plan_id, razorpay_subscription_id: id, short_url: s.short_url ?? null,
      });
    }
    return json({ ok: true, status: s.status });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error(`razorpay-subscription-webhook ${id}:`, message);
    return json({ error: message }, 500);  // Razorpay retries
  }
});
