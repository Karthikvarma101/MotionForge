import { useEffect, useMemo, useState } from "react";
import { ago, api, date, explain, type Customer } from "../api";
import { Avatar, Empty, ErrorNote, PlanBadge } from "../components/ui";
import { CustomerPanel } from "./CustomerPanel";

const FILTERS = [["all", "All"], ["pro", "Pro"], ["trial", "Trial"], ["free", "Free"], ["blocked", "Blocked"]] as const;
type Filter = (typeof FILTERS)[number][0];
const matches = (c: Customer, f: Filter) =>
  f === "all" || (f === "pro" && c.pro && c.source !== "trial") || (f === "trial" && c.source === "trial") ||
  (f === "free" && !c.pro) || (f === "blocked" && !!c.banned_until);

export function Customers() {
  const [all, setAll] = useState<Customer[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [open, setOpen] = useState<string | null>(null);

  const load = () => api<{ customers: Customer[] }>("customers").then((r) => setAll(r.customers), (e) => setError(explain(e)));
  useEffect(() => { load(); }, []);

  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (all ?? []).filter((c) =>
      (!q || c.email.toLowerCase().includes(q) || c.name.toLowerCase().includes(q) || c.id === q) && matches(c, filter));
  }, [all, search, filter]);

  return (
    <div className="stack">
      <div className="toolbar">
        <input className="search" placeholder="Search name, email or user id" value={search} onChange={(e) => setSearch(e.target.value)} autoFocus />
        <div className="segmented">
          {FILTERS.map(([k, label]) => (
            <button key={k} className={filter === k ? "on" : ""} onClick={() => setFilter(k)}>
              {label}{all && <span className="count">{all.filter((c) => matches(c, k)).length}</span>}
            </button>
          ))}
        </div>
        <button onClick={load}>Refresh</button>
      </div>
      <ErrorNote message={error} />
      {!all ? <div className="loading">Loading…</div> : shown.length === 0 ? (
        <Empty>{all.length === 0 ? "No customers yet. Anyone who signs in to MotionForge with Google shows up here." : "No customers match."}</Empty>
      ) : (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr><th>Customer</th><th>Plan</th><th>Renews / ends</th><th>Joined</th><th>Last sign-in</th></tr>
            </thead>
            <tbody>
              {shown.map((c) => (
                <tr key={c.id} onClick={() => setOpen(c.id)} className={open === c.id ? "selected" : ""} tabIndex={0}
                    onKeyDown={(e) => e.key === "Enter" && setOpen(c.id)}>
                  <td>
                    <div className="who">
                      <Avatar c={c} />
                      <div><div className="who-name">{c.name}</div><div className="who-email">{c.email}</div></div>
                    </div>
                  </td>
                  <td><PlanBadge c={c} /></td>
                  <td>{c.source === "grant" || c.source === "trial" ? (c.grant_until ? `${c.source === "trial" ? "trial ends" : "until"} ${date(c.grant_until)}` : "no end") : c.pro ? `${c.cancel_at_period_end ? "ends" : "renews"} ${date(c.current_end)}` : "—"}</td>
                  <td>{date(c.created_at)}</td>
                  <td>{ago(c.last_sign_in_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {open && <CustomerPanel userId={open} onClose={() => setOpen(null)} onChanged={load} />}
    </div>
  );
}
