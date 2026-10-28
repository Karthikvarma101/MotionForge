// Talking to the MotionForge Supabase project: Google sign-in (Google Identity Services ID token →
// Supabase session) and the `admin-api` Edge Function, which does everything privileged on the server.
import { createClient, type Session } from "@supabase/supabase-js";

export const SUPABASE_URL = "https://hknpofgdsqqsnztriguy.supabase.co";
export const PUBLISHABLE_KEY = "sb_publishable_TJ1my7LWwC18zgnKHEXMZA_lKdBmSBC";
/** "MotionForge Admin" web client in the MotionForge Google Cloud project (JavaScript origins: this console). */
export const GOOGLE_CLIENT_ID = "142670089612-kvk58g704j4behg211etfa7c6nq5u1o1.apps.googleusercontent.com";

export const supabase = createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: "motionforge-admin" },
});

// ---- Google sign-in ------------------------------------------------------------------------------

declare global {
  interface Window {
    google?: {
      accounts: {
        id: {
          initialize(o: Record<string, unknown>): void;
          renderButton(el: HTMLElement, o: Record<string, unknown>): void;
          disableAutoSelect(): void;
        };
      };
    };
  }
}

const sha256Hex = async (s: string) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))]
    .map((b) => b.toString(16).padStart(2, "0")).join("");

let gisReady: Promise<void> | null = null;
let gisError: (m: string) => void = () => {};

/** Renders Google's button into `el`; resolves sign-in through Supabase when it is used. */
export async function mountGoogleButton(el: HTMLElement, onError: (m: string) => void) {
  for (let i = 0; i < 100 && !window.google?.accounts?.id; i++) await new Promise((r) => setTimeout(r, 100));
  const gis = window.google?.accounts?.id;
  if (!gis) return onError("Google sign-in didn't load. Check your connection or blockers and reload.");
  // Google gets the hash of a one-time nonce and Supabase the nonce itself, so a token can't be replayed.
  // One configuration per page load: React's dev double-mount must not re-initialise with a second nonce.
  gisError = onError;
  gisReady ??= (async () => {
    const nonce = crypto.randomUUID();
    gis.initialize({
      client_id: GOOGLE_CLIENT_ID,
      nonce: await sha256Hex(nonce),
      callback: async ({ credential }: { credential?: string }) => {
        if (!credential) return gisError("Google didn't return a sign-in.");
        console.info("[admin] Google sign-in received; exchanging it with Supabase");
        const { error } = await supabase.auth.signInWithIdToken({ provider: "google", token: credential, nonce });
        if (error) {
          console.error("[admin] Supabase refused the Google sign-in:", error.message);
          gisError(error.message);
        } else {
          console.info("[admin] signed in");
        }
      },
    });
  })();
  await gisReady;
  gis.renderButton(el, { theme: "filled_black", size: "large", shape: "pill", text: "signin_with", width: 280 });
}

export async function signOut() {
  window.google?.accounts?.id.disableAutoSelect();
  await supabase.auth.signOut();
}

// ---- admin API -----------------------------------------------------------------------------------

export class ApiError extends Error {
  constructor(public code: string, public status: number) { super(code); }
}

let currentSession: Session | null = null;
supabase.auth.onAuthStateChange((_e, s) => { currentSession = s; });

export async function api<T = Record<string, unknown>>(action: string, args: Record<string, unknown> = {}): Promise<T> {
  const session = currentSession ?? (await supabase.auth.getSession()).data.session;
  if (!session) throw new ApiError("not_signed_in", 401);
  const res = await fetch(`${SUPABASE_URL}/functions/v1/admin-api`, {
    method: "POST",
    // The user's token goes in x-user-jwt (the function checks it); the publishable key gets past the gateway.
    headers: { apikey: PUBLISHABLE_KEY, "x-user-jwt": session.access_token, "Content-Type": "application/json" },
    body: JSON.stringify({ action, ...args }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    console.warn(`[admin] ${action}: ${res.status} ${body.error ?? ""}`);
    throw new ApiError(body.error ?? `HTTP ${res.status}`, res.status);
  }
  return body as T;
}

/** Readable text for an API error code. */
export function explain(e: unknown): string {
  const code = e instanceof ApiError ? e.code : e instanceof Error ? e.message : String(e);
  const known: Record<string, string> = {
    not_signed_in: "Your session ended — sign in again.",
    not_an_admin: "This Google account isn't an admin.",
    payments_not_configured: "Razorpay keys aren't set in Supabase yet, so payment actions are off.",
    has_live_subscription_without_payment_keys: "This customer has a live subscription and Razorpay keys aren't set, so it can't be stopped — add the keys first.",
    cannot_delete_yourself: "You can't delete your own account from here.",
    cannot_remove_yourself: "You can't remove yourself as an admin.",
    bad_amount: "Prices must be between ₹1 and ₹1,00,000.",
    bad_days: "Choose a length between 1 day and 100 years.",
    announcement_too_long: "Announcements can be at most 280 characters.",
    bad_trial_days: "The trial can be 0 to 365 days.",
    offer_too_long: "The offer text can be at most 500 characters.",
    bad_email: "That email address doesn't look right.",
  };
  return known[code] ?? code;
}

// ---- shapes ----------------------------------------------------------------------------------------

export interface Customer {
  id: string; email: string; name: string; avatar_url: string | null; created_at: string; last_sign_in_at: string | null;
  banned_until: string | null; providers: string[]; pro: boolean; source: "subscription" | "grant" | "trial" | null; plan_id: string | null;
  status: string | null; current_end: string | null; cancel_at_period_end: boolean; grant_until: string | null; subscriptions: number;
}
export interface Subscription {
  id: string; user_id: string; plan_id: string; razorpay_subscription_id: string; status: string; short_url: string | null;
  current_start: string | null; current_end: string | null; cancel_at_period_end: boolean; amount_paise: number | null;
  created_at: string; updated_at: string;
}
export interface Grant { id: string; user_id: string; until: string | null; reason: string | null; granted_by: string; created_at: string; revoked_at: string | null; revoked_by: string | null }
export interface Invoice { id: string; subscription: string; amount_paise: number; status: string; paid_at: string | null; payment_id: string | null; short_url: string | null }
export interface Plan { id: string; name: string; amount_paise: number; period: "monthly" | "yearly"; razorpay_plan_id: string | null; razorpay_mode: string | null; active: boolean }
export interface DayCount { day: string; count: number }
export interface Overview {
  customers: number; pro: number; pro_paid: number; pro_granted: number; on_trial: number; blocked: number; active_7d: number;
  by_plan: Record<string, number>; mrr_paise: number; signups: DayCount[]; subscriptions_started: DayCount[];
  cancellations: DayCount[]; recent: { at: string; kind: string; email: string; plan_id?: string; by?: string }[];
  payments_configured: boolean; config: Record<string, unknown>;
}
export interface AuditEntry { id: number; admin_email: string; action: string; target: string | null; target_email: string | null; detail: unknown; at: string }

// ---- formatting -----------------------------------------------------------------------------------

export const rupees = (paise: number) =>
  "₹" + (paise / 100).toLocaleString("en-IN", { maximumFractionDigits: paise % 100 ? 2 : 0 });
export const date = (s: string | null | undefined) =>
  s ? new Date(s).toLocaleDateString("en-IN", { day: "numeric", month: "short", year: "numeric" }) : "—";
export const dateTime = (s: string | null | undefined) =>
  s ? new Date(s).toLocaleString("en-IN", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "—";
export function ago(s: string | null | undefined) {
  if (!s) return "never";
  const m = Math.round((Date.now() - Date.parse(s)) / 60000);
  if (m < 1) return "just now";
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} h ago`;
  const d = Math.round(h / 24);
  return d < 60 ? `${d} days ago` : date(s);
}
export const planName = (id: string | null) =>
  id === "pro_monthly" ? "Monthly" : id === "pro_yearly" ? "Yearly" : id === "grant" ? "Complimentary" : id ?? "—";
