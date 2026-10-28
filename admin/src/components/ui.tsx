import { useMemo, useState, type ReactNode } from "react";
import type { Customer, DayCount } from "../api";

export function Avatar({ c, size = 32 }: { c: Pick<Customer, "name" | "email" | "avatar_url">; size?: number }) {
  const [failed, setFailed] = useState(false);
  const initial = (c.name || c.email || "?").slice(0, 1).toUpperCase();
  return c.avatar_url && !failed ? (
    <img className="avatar" src={c.avatar_url} alt="" width={size} height={size} referrerPolicy="no-referrer" onError={() => setFailed(true)} />
  ) : (
    <span className="avatar avatar-initial" style={{ width: size, height: size, fontSize: size * 0.42 }}>{initial}</span>
  );
}

export type Tone = "pro" | "grant" | "free" | "blocked" | "warn" | "muted" | "ok";
export function Badge({ tone, children }: { tone: Tone; children: ReactNode }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

/** What a customer has, as one badge. */
export function PlanBadge({ c }: { c: Customer }) {
  if (c.banned_until) return <Badge tone="blocked">Blocked</Badge>;
  if (c.source === "grant") return <Badge tone="grant">Pro · given</Badge>;
  if (c.source === "subscription") return <Badge tone="pro">Pro · {c.plan_id === "pro_yearly" ? "yearly" : "monthly"}</Badge>;
  if (c.status === "created") return <Badge tone="muted">Checkout started</Badge>;
  return <Badge tone="free">Free</Badge>;
}

export function StatTile({ label, value, detail }: { label: string; value: ReactNode; detail?: ReactNode }) {
  return (
    <div className="tile">
      <div className="tile-label">{label}</div>
      <div className="tile-value">{value}</div>
      {detail && <div className="tile-detail">{detail}</div>}
    </div>
  );
}

export function Section({ title, actions, children }: { title: string; actions?: ReactNode; children: ReactNode }) {
  return (
    <section className="card">
      <header className="card-head">
        <h2>{title}</h2>
        {actions}
      </header>
      {children}
    </section>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="empty">{children}</div>;
}

export function ErrorNote({ message }: { message: string | null }) {
  return message ? <div className="note note-error" role="alert">{message}</div> : null;
}

/**
 * One series of daily counts as columns: ≤ 24 px wide, rounded at the top, square on the baseline, 2 px apart,
 * hairline grid, a tooltip per column, and the same numbers as a table underneath.
 */
export function DailyBars({ title, data, unit }: { title: string; data: DayCount[]; unit: string }) {
  const [hover, setHover] = useState<number | null>(null);
  const W = 560, H = 150, padL = 28, padB = 22, padT = 8;
  const max = Math.max(1, ...data.map((d) => d.count));
  const ticks = useMemo(() => niceTicks(max), [max]);
  const top = ticks[ticks.length - 1];
  const slot = (W - padL) / Math.max(1, data.length);
  const bw = Math.min(24, slot - 2);
  const y = (v: number) => padT + (H - padT - padB) * (1 - v / top);
  const total = data.reduce((s, d) => s + d.count, 0);
  const label = (d: string) => new Date(d + "T00:00:00Z").toLocaleDateString("en-IN", { day: "numeric", month: "short", timeZone: "UTC" });
  return (
    <figure className="chart">
      <figcaption>
        <span className="chart-title">{title}</span>
        <span className="chart-sub">{total.toLocaleString("en-IN")} {unit} in 30 days</span>
      </figcaption>
      <div className="chart-plot">
        <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${title}: ${total} ${unit} in the last 30 days`} onMouseLeave={() => setHover(null)}>
          {ticks.map((t) => (
            <g key={t}>
              <line x1={padL} x2={W} y1={y(t)} y2={y(t)} className="grid" />
              <text x={padL - 6} y={y(t) + 3} className="axis" textAnchor="end">{t}</text>
            </g>
          ))}
          {data.map((d, i) => {
            const x = padL + i * slot + (slot - bw) / 2;
            const h = H - padB - y(d.count);
            return (
              <g key={d.day} onMouseEnter={() => setHover(i)}>
                <rect x={padL + i * slot} y={padT} width={slot} height={H - padT - padB} fill="transparent" />
                {d.count > 0 && <path d={columnPath(x, H - padB, bw, h)} className={hover === i ? "bar bar-hover" : "bar"} />}
              </g>
            );
          })}
          {[0, Math.floor(data.length / 2), data.length - 1].filter((i) => data[i]).map((i) => (
            <text key={i} x={padL + i * slot + slot / 2} y={H - 6} className="axis" textAnchor="middle">{label(data[i].day)}</text>
          ))}
        </svg>
        {hover != null && data[hover] && (
          <div className="tooltip" style={{ left: `${((padL + hover * slot + slot / 2) / W) * 100}%` }}>
            <strong>{data[hover].count}</strong> {unit}
            <span>{label(data[hover].day)}</span>
          </div>
        )}
      </div>
      <details className="chart-table">
        <summary>Table</summary>
        <table>
          <thead><tr><th>Day</th><th>{unit}</th></tr></thead>
          <tbody>{data.filter((d) => d.count).map((d) => <tr key={d.day}><td>{label(d.day)}</td><td>{d.count}</td></tr>)}</tbody>
        </table>
      </details>
    </figure>
  );
}

function columnPath(x: number, base: number, w: number, h: number) {
  const r = Math.min(4, w / 2, h);
  return `M${x},${base} V${base - h + r} Q${x},${base - h} ${x + r},${base - h} H${x + w - r} Q${x + w},${base - h} ${x + w},${base - h + r} V${base} Z`;
}

function niceTicks(max: number): number[] {
  const step = max <= 4 ? 1 : max <= 10 ? 2 : Math.pow(10, Math.floor(Math.log10(max))) * (max / Math.pow(10, Math.floor(Math.log10(max))) > 5 ? 2 : 1);
  const out = [0];
  while (out[out.length - 1] < max) out.push(out[out.length - 1] + step);
  return out;
}
