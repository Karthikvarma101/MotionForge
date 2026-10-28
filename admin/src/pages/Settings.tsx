import { useEffect, useState } from "react";
import { api, dateTime, explain } from "../api";
import { ErrorNote, Section } from "../components/ui";

interface Row { key: string; value: unknown; updated_at: string; updated_by: string | null }
type Style = "info" | "success" | "warning";

export function Settings() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [text, setText] = useState("");
  const [style, setStyle] = useState<Style>("info");
  const [busy, setBusy] = useState<string | null>(null);

  const load = () => api<{ config: Row[] }>("config").then((r) => {
    setRows(r.config);
    const a = r.config.find((x) => x.key === "announcement")?.value as { text?: string; style?: Style } | undefined;
    setText(a?.text ?? "");
    setStyle(a?.style ?? "info");
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
