import { useEffect, useState } from "react";
import { api, dateTime, explain } from "../api";
import { ErrorNote, Section } from "../components/ui";

interface Row { key: string; value: unknown; updated_at: string; updated_by: string | null }
type Style = "info" | "success" | "warning";
interface Offer { enabled: boolean; email: string; text: string }

export function Settings() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [text, setText] = useState("");
  const [style, setStyle] = useState<Style>("info");
  const [busy, setBusy] = useState<string | null>(null);
  const [trialDays, setTrialDays] = useState("7");
  const [offer, setOffer] = useState<Offer>({ enabled: true, email: "", text: "" });

  const load = () => api<{ config: Row[] }>("config").then((r) => {
    setRows(r.config);
    const a = r.config.find((x) => x.key === "announcement")?.value as { text?: string; style?: Style } | undefined;
    setText(a?.text ?? "");
    setStyle(a?.style ?? "info");
    const t = r.config.find((x) => x.key === "trial_days")?.value;
    setTrialDays(String(typeof t === "number" ? t : 7));
    const o = r.config.find((x) => x.key === "free_access_offer")?.value as Offer | undefined;
    if (o) setOffer(o);
  }, (e) => setError(explain(e)));
  useEffect(() => { load(); }, []);

  const row = (k: string) => rows?.find((r) => r.key === k);
  const exportRequiresPro = row("export_requires_pro")?.value !== false;
  const saved = row("announcement")?.value as { text?: string; style?: string } | undefined;

  async function set(key: string, value: unknown, label: string) {
    setBusy(label);
    try {
      await api("set_config", { key, value });
      await load();
    } catch (e) {
      setError(explain(e));
    } finally {
      setBusy(null);
    }
  }

  if (!rows) return error ? <ErrorNote message={error} /> : <div className="loading">Loading…</div>;
  return (
    <div className="stack">
      <ErrorNote message={error} />
      <Section title="Exporting">
        <div className="setting">
          <div>
            <strong>{exportRequiresPro ? "Exporting needs MotionForge Pro" : "Exporting is free for everyone"}</strong>
            <p className="muted">
              Switch off to let every customer export without paying (a free weekend, a launch promotion). Apps pick it up when
              they come to the front, at most five minutes later.
            </p>
            <Updated row={row("export_requires_pro")} />
          </div>
          <button className={exportRequiresPro ? "" : "primary"} disabled={!!busy}
                  onClick={() => set("export_requires_pro", !exportRequiresPro, "export")}>
            {busy === "export" ? "Saving…" : exportRequiresPro ? "Make exporting free" : "Require Pro again"}
          </button>
        </div>
      </Section>
      <Section title="Free trial">
        <div className="setting">
          <div>
            <strong>{Number(trialDays) > 0 ? `New accounts get ${trialDays} days of Pro free` : "No free trial"}</strong>
            <p className="muted">
              Starts automatically when someone signs in for the first time. Changing it applies to accounts created
              from now on; to extend one person's trial, give them Pro from Customers.
            </p>
            <Updated row={row("trial_days")} />
          </div>
          <div className="row gap">
            <input type="number" min={0} max={365} value={trialDays} onChange={(e) => setTrialDays(e.target.value)} style={{ width: 80 }} />
            <span className="muted small">days</span>
            <button className="primary" disabled={!!busy || Number(trialDays) === (row("trial_days")?.value as number)}
                    onClick={() => set("trial_days", Math.round(Number(trialDays)), "trial")}>
              {busy === "trial" ? "Saving…" : "Save"}
            </button>
          </div>
        </div>
      </Section>
      <Section title="Free access for creators">
        <p className="muted">Shown in the app's Pro sheet and account menu (and on the website) with a button that emails you.
          Give Pro from Customers when you accept someone.</p>
        <div className="form">
          <label className="check">
            <input type="checkbox" checked={offer.enabled} onChange={(e) => setOffer({ ...offer, enabled: e.target.checked })} /> Show the offer
          </label>
          <label>Contact email<input type="email" value={offer.email} onChange={(e) => setOffer({ ...offer, email: e.target.value })} /></label>
          <label>Text ({offer.text.length}/500)
            <textarea rows={3} maxLength={500} value={offer.text} onChange={(e) => setOffer({ ...offer, text: e.target.value })} />
          </label>
          <div className="row gap">
            <span className="spacer" />
            <button className="primary" disabled={!!busy || JSON.stringify(offer) === JSON.stringify(row("free_access_offer")?.value)}
                    onClick={() => set("free_access_offer", { ...offer, email: offer.email.trim(), text: offer.text.trim() }, "offer")}>
              {busy === "offer" ? "Saving…" : "Save"}
            </button>
          </div>
          <Updated row={row("free_access_offer")} />
        </div>
      </Section>
      <Section title="Announcement">
        <p className="muted">Shown at the top of the app's Home window. Leave it empty to show nothing.</p>
        <div className="form">
          <textarea rows={3} maxLength={280} value={text} onChange={(e) => setText(e.target.value)}
                    placeholder="e.g. Exports are free this weekend — happy Diwali!" />
          <div className="row gap wrap">
            <select value={style} onChange={(e) => setStyle(e.target.value as Style)}>
              <option value="info">Info (blue)</option>
              <option value="success">Good news (green)</option>
              <option value="warning">Warning (amber)</option>
            </select>
            <span className="muted small">{text.length}/280</span>
            <span className="spacer" />
            <button disabled={!!busy || (!saved?.text && !text)} onClick={() => { setText(""); set("announcement", { text: "", style }, "clear"); }}>Clear</button>
            <button className="primary" disabled={!!busy || (text === (saved?.text ?? "") && style === (saved?.style ?? "info"))}
                    onClick={() => set("announcement", { text: text.trim(), style }, "announce")}>
              {busy === "announce" ? "Saving…" : "Publish"}
            </button>
          </div>
          {text.trim() && (
            <div className={`preview preview-${style}`}>
              <span className="preview-label">Preview</span>
              {text.trim()}
            </div>
          )}
          <Updated row={row("announcement")} />
        </div>
      </Section>
    </div>
  );
}

function Updated({ row }: { row?: Row }) {
  return row ? <div className="muted small">Last changed {dateTime(row.updated_at)}{row.updated_by ? ` by ${row.updated_by}` : ""}</div> : null;
}
