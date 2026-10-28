import { useEffect, useState } from "react";
import { api, explain, rupees, type Plan } from "../api";
import { Badge, ErrorNote, Section } from "../components/ui";

export function Plans() {
  const [plans, setPlans] = useState<Plan[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = () => api<{ plans: Plan[] }>("plans").then((r) => setPlans(r.plans), (e) => setError(explain(e)));
  useEffect(() => { load(); }, []);

  const monthly = plans?.find((p) => p.period === "monthly" && p.active);
  return (
    <div className="stack">
      <p className="muted">
        The app shows these prices in its Pro sheet (it re-reads them when it comes to the front). Changing a price
        applies to new subscriptions: people already subscribed keep paying what they signed up for. A plan that's
        switched off disappears from the app.
      </p>
      <ErrorNote message={error} />
      {!plans ? <div className="loading">Loading…</div> : (
        <div className="plans">
          {plans.map((p) => <PlanCard key={p.id} plan={p} monthly={monthly} onSaved={load} />)}
        </div>
      )}
    </div>
  );
}

function PlanCard({ plan, monthly, onSaved }: { plan: Plan; monthly?: Plan; onSaved: () => void }) {
  const [name, setName] = useState(plan.name);
  const [price, setPrice] = useState(String(plan.amount_paise / 100));
  const [active, setActive] = useState(plan.active);
  const [state, setState] = useState<{ busy?: boolean; error?: string; saved?: boolean }>({});
  const amount = Math.round(Number(price) * 100);
  const changed = name !== plan.name || amount !== plan.amount_paise || active !== plan.active;
  const saving = plan.period === "yearly" && monthly ? 1 - amount / (monthly.amount_paise * 12) : null;

  async function save() {
    if (amount !== plan.amount_paise &&
        !window.confirm(`Change ${plan.name} from ${rupees(plan.amount_paise)} to ${rupees(amount)}? New subscribers pay the new price; current ones keep theirs.`)) return;
    setState({ busy: true });
    try {
      await api("update_plan", { id: plan.id, name, amount_paise: amount, active });
      setState({ saved: true });
      onSaved();
    } catch (e) {
      setState({ error: explain(e) });
    }
  }

  return (
    <Section title={plan.period === "yearly" ? "Yearly" : "Monthly"} actions={active ? <Badge tone="ok">On sale</Badge> : <Badge tone="muted">Off</Badge>}>
      <div className="form">
        <label>Name<input value={name} onChange={(e) => setName(e.target.value)} maxLength={80} /></label>
        <label>Price (₹ per {plan.period === "yearly" ? "year" : "month"})
          <input type="number" min={1} step={1} value={price} onChange={(e) => setPrice(e.target.value)} />
        </label>
        {saving != null && saving > 0 && <div className="muted small">Shown in the app as “Save {Math.round(saving * 100)}% vs monthly”.</div>}
        <label className="check"><input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} /> On sale in the app</label>
        <div className="muted small">
          Razorpay plan: {plan.razorpay_plan_id ? <code>{plan.razorpay_plan_id}</code> : "made on the next checkout"}{plan.razorpay_mode ? ` (${plan.razorpay_mode} keys)` : ""}
        </div>
        <ErrorNote message={state.error ?? null} />
        <div className="row gap">
          <button className="primary" disabled={!changed || state.busy || !(amount >= 100)} onClick={save}>{state.busy ? "Saving…" : "Save"}</button>
          {state.saved && !changed && <span className="ok-text small">Saved</span>}
        </div>
      </div>
    </Section>
  );
}
