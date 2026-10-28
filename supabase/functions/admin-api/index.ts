// admin-api: everything the MotionForge admin console does, for signed-in admins only.
//
// POST { "action": "<name>", ...args }  →  JSON. The caller's Supabase access token comes as x-user-jwt (or
// Authorization: Bearer); its email must be in `admins`. Every change is written to `admin_audit`.
//
//   me                                   who you are
//   overview                             counts, MRR, sign-ups / subscriptions / cancellations per day, recent events
//   customers { search?, filter? }       filter: all | pro | free | blocked
//   customer { user_id }                 profile, subscriptions, grants, Razorpay invoices
//   grant_pro { user_id, days?, reason } complimentary Pro (days omitted = no end)
//   revoke_grant { grant_id }
//   cancel_subscription { razorpay_subscription_id, immediately }
//   sync_subscription { razorpay_subscription_id }
//   block_user | unblock_user | delete_user { user_id }
//   plans | update_plan { id, name?, amount_paise?, active? }
//   config | set_config { key, value }
//   admins | add_admin { email } | remove_admin { email }
//   audit { limit? }
//
// Single file on purpose (the dashboard editor can't follow shared imports). Deploy with --no-verify-jwt; it
// checks the token itself. Secrets: RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET (optional; payments features need them).
import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2.118.0";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-user-jwt",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS } });

class Fail extends Error {
  constructor(public code: string, public status = 400) { super(code); }
}

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

async function signedInUser(db: SupabaseClient, req: Request): Promise<User | null> {
  const token = req.headers.get("x-user-jwt") || (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data: { user }, error } = await db.auth.getUser(token);
  return error ? null : user;
}

// ---- Razorpay ----------------------------------------------------------------------------------

interface RazorpayConfig { keyId: string; keySecret: string }
function razorpayConfig(): RazorpayConfig | null {
  const keyId = Deno.env.get("RAZORPAY_KEY_ID")?.trim(), keySecret = Deno.env.get("RAZORPAY_KEY_SECRET")?.trim();
  return keyId && keySecret ? { keyId, keySecret } : null;
}
async function rzp<T>(cfg: RazorpayConfig, method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const res = await fetch(`https://api.razorpay.com/v1${path}`, {
    method,
    headers: { Authorization: `Basic ${btoa(`${cfg.keyId}:${cfg.keySecret}`)}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Fail(`razorpay: ${data?.error?.description ?? res.status}`, 502);
  return data as T;
}
interface RzpSubscription { id: string; status: string; current_start: number | null; current_end: number | null; ended_at: number | null }
const iso = (unix: number | null | undefined) => (unix ? new Date(unix * 1000).toISOString() : null);

// ---- data ---------------------------------------------------------------------------------------

interface SubRow {
  id: string; user_id: string; plan_id: string; razorpay_subscription_id: string; status: string; short_url: string | null;
  current_start: string | null; current_end: string | null; cancel_at_period_end: boolean; amount_paise: number | null;
  created_at: string; updated_at: string;
}
interface GrantRow { id: string; user_id: string; until: string | null; reason: string | null; granted_by: string; created_at: string; revoked_at: string | null; revoked_by: string | null }
interface PlanRow { id: string; name: string; amount_paise: number; period: "monthly" | "yearly"; razorpay_plan_id: string | null; razorpay_mode: string | null; active: boolean }

const PAID = ["active", "authenticated", "pending"];
const now = () => Date.now();
const isPaid = (s: SubRow) => PAID.includes(s.status) ||
  (["cancelled", "halted", "completed"].includes(s.status) && !!s.current_end && Date.parse(s.current_end) > now());
const isLiveGrant = (g: GrantRow) => !g.revoked_at && (!g.until || Date.parse(g.until) > now());
const isBlocked = (u: User) => !!u.banned_until && Date.parse(u.banned_until) > now();

async function allUsers(db: SupabaseClient): Promise<User[]> {
  const out: User[] = [];
  for (let page = 1; page <= 100; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw new Fail(error.message, 500);
    out.push(...data.users);
    if (data.users.length < 1000) break;
  }
  return out;
}

async function rows<T>(q: PromiseLike<{ data: T[] | null; error: { message: string } | null }>): Promise<T[]> {
  const { data, error } = await q;
  if (error) throw new Fail(error.message, 500);
  return data ?? [];
}

function profile(u: User) {
  const m = (u.user_metadata ?? {}) as Record<string, string>;
  return {
    id: u.id, email: u.email ?? "", name: m.full_name ?? m.name ?? u.email ?? "", avatar_url: m.avatar_url ?? m.picture ?? null,
    created_at: u.created_at, last_sign_in_at: u.last_sign_in_at ?? null, banned_until: isBlocked(u) ? u.banned_until : null,
    providers: (u.app_metadata?.providers as string[] | undefined) ?? [],
  };
}

/** One line per customer: who, and what they have. */
function summarize(u: User, subs: SubRow[], grants: GrantRow[]) {
  const mine = subs.filter((s) => s.user_id === u.id).sort((a, b) => b.created_at.localeCompare(a.created_at));
  const paid = mine.find(isPaid);
  const grant = grants.filter((g) => g.user_id === u.id && isLiveGrant(g)).sort((a, b) => (b.until ?? "9").localeCompare(a.until ?? "9"))[0];
  const shown = paid ?? mine[0];
  return {
    ...profile(u),
    pro: !!paid || !!grant,
    source: paid ? "subscription" : grant ? "grant" : null,
    plan_id: shown?.plan_id ?? null,
    status: shown?.status ?? null,
    current_end: shown?.current_end ?? null,
    cancel_at_period_end: shown?.cancel_at_period_end ?? false,
    grant_until: grant ? grant.until : null,
    subscriptions: mine.length,
  };
}

function perDay(dates: string[], days = 30) {
  const start = new Date();
  start.setUTCHours(0, 0, 0, 0);
  start.setUTCDate(start.getUTCDate() - (days - 1));
  const counts = new Map<string, number>();
  for (let i = 0; i < days; i++) counts.set(new Date(start.getTime() + i * 86_400_000).toISOString().slice(0, 10), 0);
  for (const d of dates) {
    const k = d.slice(0, 10);
    if (counts.has(k)) counts.set(k, counts.get(k)! + 1);
  }
  return [...counts].map(([day, count]) => ({ day, count }));
}

// ---- actions ------------------------------------------------------------------------------------

type Args = Record<string, unknown>;
const str = (v: unknown, name: string) => {
  if (typeof v !== "string" || !v.trim()) throw new Fail(`missing_${name}`);
  return v.trim();
};

async function handle(db: SupabaseClient, me: string, action: string, a: Args) {
  const audit = (what: string, target: string | null, detail: unknown = null) =>
    db.from("admin_audit").insert({ admin_email: me, action: what, target, detail });
  const cfg = razorpayConfig();

  switch (action) {
    case "me":
      return { email: me, payments_configured: !!cfg };

    case "overview": {
      const [users, subs, grants, plans] = await Promise.all([
        allUsers(db), rows<SubRow>(db.from("subscriptions").select("*")), rows<GrantRow>(db.from("pro_grants").select("*")),
        rows<PlanRow>(db.from("plans").select("*")),
      ]);
      const price = new Map(plans.map((p) => [p.id, p]));
      const list = users.map((u) => summarize(u, subs, grants));
      let mrr = 0;
      const byPlan: Record<string, number> = {};
      for (const s of subs) {
        // Renewing subscriptions only: one cancelled at the period end won't bring money next month.
        if (!PAID.includes(s.status) || s.cancel_at_period_end) continue;
        const p = price.get(s.plan_id);
        const amount = s.amount_paise ?? p?.amount_paise ?? 0;
        mrr += p?.period === "yearly" ? amount / 12 : amount;
        byPlan[s.plan_id] = (byPlan[s.plan_id] ?? 0) + 1;
      }
      const events = [
        ...users.map((u) => ({ at: u.created_at, kind: "signed_up", email: u.email ?? "" })),
        ...subs.map((s) => ({ at: s.created_at, kind: s.status === "created" ? "checkout_started" : "subscribed", email: users.find((u) => u.id === s.user_id)?.email ?? "", plan_id: s.plan_id })),
        ...grants.map((g) => ({ at: g.created_at, kind: "pro_granted", email: users.find((u) => u.id === g.user_id)?.email ?? "", by: g.granted_by })),
      ].sort((x, y) => y.at.localeCompare(x.at)).slice(0, 12);
      const cancelled = subs.filter((s) => s.cancel_at_period_end || s.status === "cancelled").map((s) => s.updated_at);
      const { data: cfgRows } = await db.from("app_config").select("key,value");
      return {
        customers: list.length,
        pro: list.filter((c) => c.pro).length,
        pro_paid: list.filter((c) => c.source === "subscription").length,
        pro_granted: list.filter((c) => c.source === "grant").length,
        blocked: list.filter((c) => c.banned_until).length,
        active_7d: users.filter((u) => u.last_sign_in_at && now() - Date.parse(u.last_sign_in_at) < 7 * 86_400_000).length,
        by_plan: byPlan,
        mrr_paise: Math.round(mrr),
        signups: perDay(users.map((u) => u.created_at)),
        subscriptions_started: perDay(subs.filter((s) => s.status !== "created").map((s) => s.created_at)),
        cancellations: perDay(cancelled),
        recent: events,
        payments_configured: !!cfg,
        config: Object.fromEntries((cfgRows ?? []).map((r) => [r.key, r.value])),
      };
    }

    case "customers": {
      const [users, subs, grants] = await Promise.all([
        allUsers(db), rows<SubRow>(db.from("subscriptions").select("*")), rows<GrantRow>(db.from("pro_grants").select("*")),
      ]);
      const q = typeof a.search === "string" ? a.search.trim().toLowerCase() : "";
      const filter = typeof a.filter === "string" ? a.filter : "all";
      const list = users.map((u) => summarize(u, subs, grants))
        .filter((c) => !q || c.email.toLowerCase().includes(q) || c.name.toLowerCase().includes(q) || c.id === q)
        .filter((c) => filter === "all" || (filter === "pro" && c.pro) || (filter === "free" && !c.pro) || (filter === "blocked" && c.banned_until))
        .sort((x, y) => y.created_at.localeCompare(x.created_at));
      return { customers: list, total: users.length };
    }

    case "customer": {
      const id = str(a.user_id, "user_id");
      const { data: { user }, error } = await db.auth.admin.getUserById(id);
      if (error || !user) throw new Fail("no_such_customer", 404);
      const subs = await rows<SubRow>(db.from("subscriptions").select("*").eq("user_id", id).order("created_at", { ascending: false }));
      const grants = await rows<GrantRow>(db.from("pro_grants").select("*").eq("user_id", id).order("created_at", { ascending: false }));
      let invoices: unknown[] | null = null;
      if (cfg) {
        invoices = [];
        for (const s of subs) {
          try {
            const r = await rzp<{ items: Record<string, unknown>[] }>(cfg, "GET", `/invoices?subscription_id=${s.razorpay_subscription_id}&count=50`);
            for (const i of r.items ?? []) {
              invoices.push({ id: i.id, subscription: s.razorpay_subscription_id, amount_paise: i.amount, status: i.status,
                paid_at: iso(i.paid_at as number), payment_id: i.payment_id, short_url: i.short_url });
            }
          } catch { /* a subscription Razorpay no longer knows */ }
        }
      }
      return { customer: summarize(user, subs, grants), subscriptions: subs, grants, invoices, payments_configured: !!cfg };
    }

    case "grant_pro": {
      const id = str(a.user_id, "user_id");
      const days = a.days == null || a.days === "" ? null : Number(a.days);
      if (days != null && (!Number.isFinite(days) || days <= 0 || days > 36_500)) throw new Fail("bad_days");
      const until = days == null ? null : new Date(now() + days * 86_400_000).toISOString();
      const reason = typeof a.reason === "string" ? a.reason.trim().slice(0, 200) : null;
      const { data, error } = await db.from("pro_grants").insert({ user_id: id, until, reason, granted_by: me }).select().single();
      if (error) throw new Fail(error.message, 500);
      await audit("grant_pro", id, { until, reason });
      return { grant: data };
    }

    case "revoke_grant": {
      const id = str(a.grant_id, "grant_id");
      const { data, error } = await db.from("pro_grants").update({ revoked_at: new Date().toISOString(), revoked_by: me }).eq("id", id).select().single();
      if (error) throw new Fail(error.message, 500);
      await audit("revoke_grant", data.user_id, { grant_id: id });
      return { grant: data };
    }

    case "cancel_subscription":
    case "sync_subscription": {
      if (!cfg) throw new Fail("payments_not_configured", 503);
      const sid = str(a.razorpay_subscription_id, "razorpay_subscription_id");
      if (action === "cancel_subscription") {
        await rzp(cfg, "POST", `/subscriptions/${sid}/cancel`, { cancel_at_cycle_end: a.immediately ? 0 : 1 });
      }
      const s = await rzp<RzpSubscription>(cfg, "GET", `/subscriptions/${sid}`);
      const fields: Record<string, unknown> = {
        status: s.status, current_start: iso(s.current_start), current_end: iso(s.ended_at ?? s.current_end), updated_at: new Date().toISOString(),
      };
      if (action === "cancel_subscription") fields.cancel_at_period_end = !a.immediately;
      const { data, error } = await db.from("subscriptions").update(fields).eq("razorpay_subscription_id", sid).select().single();
      if (error) throw new Fail(error.message, 500);
      if (action === "cancel_subscription") await audit("cancel_subscription", data.user_id, { subscription: sid, immediately: !!a.immediately });
      return { subscription: data };
    }

    case "block_user":
    case "unblock_user": {
      const id = str(a.user_id, "user_id");
      // About 100 years; "none" lifts it. A blocked customer can't sign in or refresh their session.
      const { error } = await db.auth.admin.updateUserById(id, { ban_duration: action === "block_user" ? "876000h" : "none" });
      if (error) throw new Fail(error.message, 500);
      await audit(action, id);
      return { ok: true };
    }

    case "delete_user": {
      const id = str(a.user_id, "user_id");
      const { data: { user } } = await db.auth.admin.getUserById(id);
      if (user?.email?.toLowerCase() === me) throw new Fail("cannot_delete_yourself");
      // Stop future charges before the account (and its subscription rows) disappears.
      const subs = await rows<SubRow>(db.from("subscriptions").select("*").eq("user_id", id));
      if (cfg) {
        for (const s of subs.filter((s) => PAID.includes(s.status))) {
          try { await rzp(cfg, "POST", `/subscriptions/${s.razorpay_subscription_id}/cancel`, { cancel_at_cycle_end: 0 }); } catch { /* already over */ }
        }
      } else if (subs.some((s) => PAID.includes(s.status))) {
        throw new Fail("has_live_subscription_without_payment_keys", 409);
      }
      const { error } = await db.auth.admin.deleteUser(id);
      if (error) throw new Fail(error.message, 500);
      await audit("delete_user", id, { email: user?.email ?? null });
      return { ok: true };
    }

    case "plans":
      return { plans: await rows<PlanRow>(db.from("plans").select("*").order("amount_paise")) };

    case "update_plan": {
      const id = str(a.id, "id");
      const { data: cur } = await db.from("plans").select("*").eq("id", id).maybeSingle<PlanRow>();
      if (!cur) throw new Fail("no_such_plan", 404);
      const fields: Partial<PlanRow> = {};
      if (typeof a.name === "string" && a.name.trim()) fields.name = a.name.trim().slice(0, 80);
      if (typeof a.active === "boolean") fields.active = a.active;
      if (a.amount_paise != null) {
        const amount = Math.round(Number(a.amount_paise));
        if (!Number.isFinite(amount) || amount < 100 || amount > 10_000_000) throw new Fail("bad_amount");
        if (amount !== cur.amount_paise) {
          fields.amount_paise = amount;
          // A new Razorpay plan is made at the new price on the next checkout; current subscribers keep theirs.
          fields.razorpay_plan_id = null;
          fields.razorpay_mode = null;
        }
      }
      const { data, error } = await db.from("plans").update(fields).eq("id", id).select().single();
      if (error) throw new Fail(error.message, 500);
      await audit("update_plan", id, { before: { name: cur.name, amount_paise: cur.amount_paise, active: cur.active }, after: fields });
      return { plan: data };
    }

    case "config": {
      const { data } = await db.from("app_config").select("*").order("key");
      return { config: data ?? [] };
    }

    case "set_config": {
      const key = str(a.key, "key");
      if (!["export_requires_pro", "announcement"].includes(key)) throw new Fail("unknown_setting");
      const value = a.value;
      if (key === "export_requires_pro" && typeof value !== "boolean") throw new Fail("bad_value");
      if (key === "announcement") {
        const v = value as { text?: unknown; style?: unknown };
        if (typeof v?.text !== "string" || !["info", "success", "warning"].includes(String(v.style))) throw new Fail("bad_value");
        if (v.text.length > 280) throw new Fail("announcement_too_long");
      }
      const { data, error } = await db.from("app_config").upsert({ key, value, updated_at: new Date().toISOString(), updated_by: me }).select().single();
      if (error) throw new Fail(error.message, 500);
      await audit("set_config", key, { value });
      return { setting: data };
    }

    case "admins":
      return { admins: await rows(db.from("admins").select("*").order("created_at")) };

    case "add_admin": {
      const email = str(a.email, "email").toLowerCase();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Fail("bad_email");
      const { error } = await db.from("admins").upsert({ email, added_by: me });
      if (error) throw new Fail(error.message, 500);
      await audit("add_admin", email);
      return { ok: true };
    }

    case "remove_admin": {
      const email = str(a.email, "email").toLowerCase();
      if (email === me) throw new Fail("cannot_remove_yourself");
      const { error } = await db.from("admins").delete().eq("email", email);
      if (error) throw new Fail(error.message, 500);
      await audit("remove_admin", email);
      return { ok: true };
    }

    case "audit": {
      const limit = Math.min(500, Math.max(1, Number(a.limit ?? 100)));
      const entries = await rows<{ target: string | null }>(db.from("admin_audit").select("*").order("at", { ascending: false }).limit(limit));
      // Customer actions store the user id; show who that is.
      const emails = new Map((await allUsers(db)).map((u) => [u.id, u.email ?? ""]));
      return { audit: entries.map((e) => ({ ...e, target_email: e.target ? emails.get(e.target) ?? null : null })) };
    }

    default:
      throw new Fail("unknown_action");
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const db = adminClient();
  const user = await signedInUser(db, req);
  if (!user?.email) return json({ error: "not_signed_in" }, 401);
  const email = user.email.toLowerCase();
  const { data: isAdmin } = await db.from("admins").select("email").eq("email", email).maybeSingle();
  if (!isAdmin) return json({ error: "not_an_admin", email }, 403);
  const body = await req.json().catch(() => ({})) as Args;
  try {
    return json(await handle(db, email, String(body.action ?? ""), body));
  } catch (e) {
    if (e instanceof Fail) return json({ error: e.code }, e.status);
    const message = e instanceof Error ? e.message : String(e);
    console.error(`admin-api ${email} ${body.action}:`, message);
    return json({ error: message }, 500);
  }
});
