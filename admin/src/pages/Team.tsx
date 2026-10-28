import { useEffect, useState } from "react";
import { api, date, dateTime, explain, rupees, type AuditEntry } from "../api";
import { Empty, ErrorNote, Section } from "../components/ui";

interface Admin { email: string; added_by: string | null; created_at: string }

export function Admins({ me }: { me: string }) {
  const [admins, setAdmins] = useState<Admin[] | null>(null);
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const load = () => api<{ admins: Admin[] }>("admins").then((r) => setAdmins(r.admins), (e) => setError(explain(e)));
  useEffect(() => { load(); }, []);

  async function run(action: string, args: Record<string, unknown>, confirmText?: string) {
    if (confirmText && !window.confirm(confirmText)) return;
    try {
      await api(action, args);
      setEmail("");
      setError(null);
      load();
    } catch (e) {
      setError(explain(e));
    }
  }

  return (
    <div className="stack">
      <p className="muted">Admins sign in here with Google. Anyone else who tries is turned away by the server.</p>
      <ErrorNote message={error} />
      <Section title="Admins">
        {!admins ? <div className="loading">Loading…</div> : (
          <ul className="list">
            {admins.map((a) => (
              <li key={a.email}>
                <span><strong>{a.email}</strong>{a.email === me ? " (you)" : ""} <span className="muted small">· added {date(a.created_at)}{a.added_by && a.added_by !== "setup" ? ` by ${a.added_by}` : ""}</span></span>
                {a.email !== me && <button onClick={() => run("remove_admin", { email: a.email }, `Remove ${a.email} as an admin?`)}>Remove</button>}
              </li>
            ))}
          </ul>
        )}
        <form className="row gap" onSubmit={(e) => { e.preventDefault(); run("add_admin", { email }, `Give ${email} full control of MotionForge customers, plans and settings?`); }}>
          <input type="email" required placeholder="Google account email" value={email} onChange={(e) => setEmail(e.target.value)} />
          <button className="primary" type="submit">Add admin</button>
        </form>
      </Section>
    </div>
  );
}

const ACTIONS: Record<string, string> = {
  grant_pro: "gave Pro to", revoke_grant: "revoked free Pro of", cancel_subscription: "cancelled a subscription of",
  block_user: "blocked", unblock_user: "unblocked", delete_user: "deleted", update_plan: "changed plan", set_config: "changed setting",
  add_admin: "added admin", remove_admin: "removed admin",
};

export function Activity() {
  const [rows, setRows] = useState<AuditEntry[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { api<{ audit: AuditEntry[] }>("audit", { limit: 300 }).then((r) => setRows(r.audit), (e) => setError(explain(e))); }, []);
  return (
    <div className="stack">
      <ErrorNote message={error} />
      {!rows ? <div className="loading">Loading…</div> : rows.length === 0 ? <Empty>No changes made from the console yet.</Empty> : (
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>When</th><th>Who</th><th>What</th><th>Details</th></tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td>{dateTime(r.at)}</td>
                  <td>{r.admin_email}</td>
                  <td>{ACTIONS[r.action] ?? r.action} <strong>{r.target_email || r.target}</strong></td>
                  <td className="muted small">{describe(r)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

/** The change in words: "₹399 → ₹49", "until 28 Nov 2026", "Exporting free"… */
function describe(r: AuditEntry): string {
  const d = (r.detail ?? {}) as Record<string, any>;
  switch (r.action) {
    case "grant_pro":
      return `${d.until ? `until ${date(d.until)}` : "no end date"}${d.reason ? ` — ${d.reason}` : ""}`;
    case "cancel_subscription":
      return `${d.subscription ?? ""} ${d.immediately ? "(right away)" : "(at period end)"}`;
    case "update_plan": {
      const b = d.before ?? {}, a = d.after ?? {};
      const parts: string[] = [];
      if (a.amount_paise != null && a.amount_paise !== b.amount_paise) parts.push(`${rupees(b.amount_paise)} → ${rupees(a.amount_paise)}`);
      if (a.active != null && a.active !== b.active) parts.push(a.active ? "put on sale" : "taken off sale");
      if (a.name && a.name !== b.name) parts.push(`renamed “${a.name}”`);
      return parts.join(", ") || "no change";
    }
    case "set_config":
      if (r.target === "export_requires_pro") return d.value ? "Exporting needs Pro" : "Exporting free for everyone";
      if (r.target === "announcement") return d.value?.text ? `“${d.value.text}”` : "announcement cleared";
      return JSON.stringify(d.value);
    case "delete_user":
      return d.email ?? "";
    default:
      return r.detail ? JSON.stringify(r.detail) : "";
  }
}
