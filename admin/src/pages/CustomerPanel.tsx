import { useEffect, useState } from "react";
import { ago, api, date, dateTime, explain, planName, rupees, type Customer, type Grant, type Invoice, type Subscription } from "../api";
import { Avatar, Badge, Empty, ErrorNote, PlanBadge } from "../components/ui";

interface Detail { customer: Customer; subscriptions: Subscription[]; grants: Grant[]; invoices: Invoice[] | null; payments_configured: boolean }

const LENGTHS = [["7", "7 days"], ["30", "30 days"], ["90", "3 months"], ["365", "1 year"], ["", "No end date"]] as const;

/** Everything about one customer, and every action on them. */
export function CustomerPanel({ userId, onClose, onChanged }: { userId: string; onClose: () => void; onChanged: () => void }) {
  const [d, setD] = useState<Detail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [days, setDays] = useState("30");
  const [reason, setReason] = useState("");

  const load = () => api<Detail>("customer", { user_id: userId }).then((r) => { setD(r); setError(null); }, (e) => setError(explain(e)));
  useEffect(() => { setD(null); load(); }, [userId]);
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onClose]);

  async function act(label: string, action: string, args: Record<string, unknown>, confirmText?: string) {
    if (confirmText && !window.confirm(confirmText)) return;
    setBusy(label);
    try {
      await api(action, args);
      if (action === "delete_user") { onChanged(); onClose(); return; }
      await load();
      onChanged();
    } catch (e) {
      setError(explain(e));
    } finally {
      setBusy(null);
    }
  }

  const c = d?.customer;
  const liveGrants = d?.grants.filter((g) => !g.revoked_at && (!g.until || Date.parse(g.until) > Date.now())) ?? [];
  return (
    <div className="panel-backdrop" onClick={onClose}>
      <aside className="panel" onClick={(e) => e.stopPropagation()} aria-label="Customer">
        <button className="panel-close" onClick={onClose} aria-label="Close">×</button>
        <ErrorNote message={error} />
        {!c || !d ? <div className="loading">Loading…</div> : (
          <div className="stack">
            <div className="panel-head">
              <Avatar c={c} size={56} />
              <div>
                <h2>{c.name}</h2>
                <div className="muted">{c.email}</div>
                <div className="row gap">
                  <PlanBadge c={c} />
                  {c.providers.map((p) => <Badge key={p} tone="muted">{p}</Badge>)}
                </div>
              </div>
            </div>
            <dl className="facts">
              <dt>Joined</dt><dd>{dateTime(c.created_at)}</dd>
              <dt>Last sign-in</dt><dd>{ago(c.last_sign_in_at)}</dd>
              <dt>User id</dt><dd><code className="copy" onClick={() => navigator.clipboard.writeText(c.id)} title="Copy">{c.id}</code></dd>
              {c.banned_until && <><dt>Blocked</dt><dd>until {date(c.banned_until)}</dd></>}
            </dl>

            <div className="block">
              <h3>Give Pro for free</h3>
              <p className="muted">Unlocks exporting without a subscription — for testers, partners, refunds or support.</p>
              <div className="row gap wrap">
                <select value={days} onChange={(e) => setDays(e.target.value)}>
                  {LENGTHS.map(([v, l]) => <option key={l} value={v}>{l}</option>)}
                </select>
                <input placeholder="Reason (optional)" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} />
                <button className="primary" disabled={!!busy}
                        onClick={() => act("grant", "grant_pro", { user_id: c.id, days: days || null, reason }).then(() => setReason(""))}>
                  {busy === "grant" ? "Giving…" : "Give Pro"}
                </button>
              </div>
              {liveGrants.length > 0 && (
                <ul className="list">
                  {liveGrants.map((g) => (
                    <li key={g.id}>
                      <span><Badge tone="grant">Pro</Badge> {g.until ? `until ${date(g.until)}` : "no end date"}{g.reason ? ` — ${g.reason}` : ""}
                        <span className="muted"> · by {g.granted_by}, {date(g.created_at)}</span></span>
                      <button disabled={!!busy} onClick={() => act(`revoke-${g.id}`, "revoke_grant", { grant_id: g.id }, "Take this free Pro away now?")}>Revoke</button>
                    </li>
                  ))}
                </ul>
              )}
            </div>

            <div className="block">
              <h3>Subscriptions</h3>
              {d.subscriptions.length === 0 ? <Empty>No subscriptions.</Empty> : (
                <ul className="list">
                  {d.subscriptions.map((s) => {
                    const live = ["active", "authenticated", "pending"].includes(s.status);
                    return (
                      <li key={s.id} className="sub">
                        <div>
                          <div><strong>{planName(s.plan_id)}</strong> {s.amount_paise ? rupees(s.amount_paise) : ""} · <Badge tone={live ? (s.cancel_at_period_end ? "warn" : "pro") : "muted"}>{s.cancel_at_period_end && live ? "cancels at period end" : s.status}</Badge></div>
                          <div className="muted small">{s.current_end ? `${live && !s.cancel_at_period_end ? "renews" : "access until"} ${date(s.current_end)} · ` : ""}started {date(s.created_at)} · <code>{s.razorpay_subscription_id}</code></div>
                        </div>
                        <div className="row gap">
                          <button disabled={!!busy || !d.payments_configured} onClick={() => act(`sync-${s.id}`, "sync_subscription", { razorpay_subscription_id: s.razorpay_subscription_id })}>Sync</button>
                          {live && !s.cancel_at_period_end && (
                            <button disabled={!!busy || !d.payments_configured}
                                    onClick={() => act(`cancel-${s.id}`, "cancel_subscription", { razorpay_subscription_id: s.razorpay_subscription_id, immediately: false },
                                      "Stop renewing? They keep Pro until the end of the period they paid for.")}>Cancel at period end</button>
                          )}
                          {live && (
                            <button className="danger" disabled={!!busy || !d.payments_configured}
                                    onClick={() => act(`stop-${s.id}`, "cancel_subscription", { razorpay_subscription_id: s.razorpay_subscription_id, immediately: true },
                                      "Cancel right now? Pro stops immediately and Razorpay won't charge again. Refunds are done in the Razorpay dashboard.")}>Cancel now</button>
                          )}
                        </div>
                      </li>
                    );
                  })}
                </ul>
              )}
              {!d.payments_configured && d.subscriptions.length > 0 && <p className="muted small">Razorpay keys aren't set, so subscriptions can't be synced or cancelled from here.</p>}
            </div>

            {d.invoices && (
              <div className="block">
                <h3>Payments</h3>
                {d.invoices.length === 0 ? <Empty>No invoices yet.</Empty> : (
                  <table className="table compact">
                    <thead><tr><th>Paid</th><th>Amount</th><th>Status</th><th>Payment</th></tr></thead>
                    <tbody>
                      {d.invoices.map((i) => (
                        <tr key={i.id}>
                          <td>{dateTime(i.paid_at)}</td><td>{rupees(i.amount_paise)}</td><td>{i.status}</td>
                          <td>{i.short_url ? <a href={i.short_url} target="_blank" rel="noreferrer">{i.payment_id ?? i.id}</a> : i.payment_id ?? "—"}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </div>
            )}

            <div className="block">
              <h3>Account</h3>
              <div className="row gap wrap">
                {c.banned_until ? (
                  <button disabled={!!busy} onClick={() => act("unblock", "unblock_user", { user_id: c.id })}>Unblock</button>
                ) : (
                  <button disabled={!!busy} onClick={() => act("block", "block_user", { user_id: c.id },
                    `Block ${c.email}? They can't sign in or renew their session until you unblock them. A paid subscription keeps billing — cancel it too if needed.`)}>Block</button>
                )}
                <button className="danger" disabled={!!busy} onClick={() => {
                  const typed = window.prompt(`Delete ${c.email} for good? Their account, subscriptions and grants are removed and live subscriptions are cancelled. Type the email to confirm.`);
                  if (typed?.trim().toLowerCase() === c.email.toLowerCase()) act("delete", "delete_user", { user_id: c.id });
                }}>Delete account</button>
              </div>
            </div>
          </div>
        )}
      </aside>
    </div>
  );
}
