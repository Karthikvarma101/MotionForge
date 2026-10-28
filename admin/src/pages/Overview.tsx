import { useEffect, useState } from "react";
import { ago, api, explain, planName, rupees, type Overview as Data } from "../api";
import { DailyBars, Empty, ErrorNote, Section, StatTile } from "../components/ui";

const EVENTS: Record<string, string> = {
  signed_up: "signed up", subscribed: "subscribed", checkout_started: "started a checkout", pro_granted: "was given Pro", pro_trial: "started the free trial",
};

export function Overview({ go }: { go: (page: string) => void }) {
  const [data, setData] = useState<Data | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { api<Data>("overview").then(setData, (e) => setError(explain(e))); }, []);

  if (error) return <ErrorNote message={error} />;
  if (!data) return <div className="loading">Loading…</div>;
  const announcement = data.config.announcement as { text?: string } | undefined;
  const exportRequiresPro = data.config.export_requires_pro !== false;
  return (
    <div className="stack">
      {!data.payments_configured && (
        <div className="note note-warn">
          Razorpay keys aren't set, so customers can't subscribe yet and cancelling or reading invoices is off.
          Add <code>RAZORPAY_KEY_ID</code> and <code>RAZORPAY_KEY_SECRET</code> in Supabase → Edge Functions → Secrets.
        </div>
      )}
      <div className="hero">
        <div>
          <div className="tile-label">Monthly recurring revenue</div>
          <div className="hero-value">{rupees(data.mrr_paise)}</div>
          <div className="tile-detail">renewing subscriptions, yearly plans counted as ⅟₁₂ a month</div>
        </div>
        <div className="hero-side">
          <span>Exports {exportRequiresPro ? "need Pro" : <strong className="ok-text">are free for everyone</strong>}</span>
          <span>{announcement?.text ? `Announcement: “${announcement.text}”` : "No announcement"}</span>
          <button className="link" onClick={() => go("settings")}>Change in Settings →</button>
        </div>
      </div>
      <div className="tiles">
        <StatTile label="Customers" value={data.customers.toLocaleString("en-IN")} detail={`${data.active_7d} signed in this week`} />
        <StatTile label="Pro" value={data.pro} detail={`${data.pro_paid} paying · ${data.pro_granted} given · ${data.on_trial ?? 0} on trial`} />
        <StatTile label="Monthly plans" value={data.by_plan.pro_monthly ?? 0} detail="renewing" />
        <StatTile label="Yearly plans" value={data.by_plan.pro_yearly ?? 0} detail="renewing" />
        <StatTile label="Blocked" value={data.blocked} detail="can't sign in" />
      </div>
      <div className="charts">
        <DailyBars title="Sign-ups" unit="sign-ups" data={data.signups} />
        <DailyBars title="New subscriptions" unit="subscriptions" data={data.subscriptions_started} />
        <DailyBars title="Cancellations" unit="cancellations" data={data.cancellations} />
      </div>
      <Section title="Recent activity" actions={<button className="link" onClick={() => go("customers")}>All customers →</button>}>
        {data.recent.length === 0 ? <Empty>Nothing yet — customers appear here when they sign in to the app.</Empty> : (
          <ul className="events">
            {data.recent.map((e, i) => (
              <li key={i}>
                <span className={`dot dot-${e.kind}`} />
                <span><strong>{e.email || "someone"}</strong> {EVENTS[e.kind] ?? e.kind}{e.plan_id ? ` (${planName(e.plan_id)})` : ""}{e.by ? ` by ${e.by}` : ""}</span>
                <time>{ago(e.at)}</time>
              </li>
            ))}
          </ul>
        )}
      </Section>
    </div>
  );
}
