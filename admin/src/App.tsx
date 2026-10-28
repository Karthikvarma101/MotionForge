import { useEffect, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { ApiError, api, explain, mountGoogleButton, signOut, supabase } from "./api";
import { Customers } from "./pages/Customers";
import { Overview } from "./pages/Overview";
import { Plans } from "./pages/Plans";
import { Settings } from "./pages/Settings";
import { Activity, Admins } from "./pages/Team";

const PAGES = [
  ["overview", "Overview"], ["customers", "Customers"], ["plans", "Plans & prices"], ["settings", "App settings"],
  ["admins", "Admins"], ["activity", "Activity"],
] as const;
type Page = (typeof PAGES)[number][0];
const pageFromHash = (): Page => (PAGES.find(([k]) => `#${k}` === location.hash)?.[0] ?? "overview");

export function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  const [admin, setAdmin] = useState<{ email: string } | null>(null);
  const [denied, setDenied] = useState<string | null>(null);
  const [page, setPage] = useState<Page>(pageFromHash);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    const onHash = () => setPage(pageFromHash());
    window.addEventListener("hashchange", onHash);
    return () => { data.subscription.unsubscribe(); window.removeEventListener("hashchange", onHash); };
  }, []);

  // Signed in to Supabase: ask the server whether this account is an admin.
  useEffect(() => {
    setAdmin(null);
    setDenied(null);
    if (!session) return;
    api<{ email: string }>("me").then(setAdmin, (e) => {
      setDenied(e instanceof ApiError && e.code === "not_an_admin" ? `${session.user.email} isn't an admin of MotionForge.` : explain(e));
    });
  }, [session?.user.id]);

  const go = (p: string) => { location.hash = p; };

  if (session === undefined) return <div className="center loading">Loading…</div>;
  if (!session || denied) return <SignIn denied={denied} />;
  if (!admin) return <div className="center loading">Checking access…</div>;

  return (
    <div className="shell">
      <nav className="sidebar">
        <div className="brand"><img src="/icon.png" alt="" width={28} height={28} /><span>MotionForge <em>Admin</em></span></div>
        {PAGES.map(([k, label]) => (
          <a key={k} href={`#${k}`} className={page === k ? "on" : ""}>{label}</a>
        ))}
        <div className="spacer" />
        <div className="me">
          <div className="small muted">Signed in as</div>
          <div className="me-email">{admin.email}</div>
          <button className="link" onClick={signOut}>Sign out</button>
        </div>
      </nav>
      <main className="content">
        <h1>{PAGES.find(([k]) => k === page)?.[1]}</h1>
        {page === "overview" && <Overview go={go} />}
        {page === "customers" && <Customers />}
        {page === "plans" && <Plans />}
        {page === "settings" && <Settings />}
        {page === "admins" && <Admins me={admin.email} />}
        {page === "activity" && <Activity />}
      </main>
    </div>
  );
}

function SignIn({ denied }: { denied: string | null }) {
  const button = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { if (button.current && !denied) mountGoogleButton(button.current, setError); }, [denied]);
  return (
    <div className="center">
      <div className="signin">
        <img src="/icon.png" alt="" width={64} height={64} />
        <h1>MotionForge Admin</h1>
        {denied ? (
          <>
            <p className="note note-error">{denied}</p>
            <button onClick={signOut}>Use another account</button>
          </>
        ) : (
          <>
            <p className="muted">Customers, subscriptions, prices and app settings. Admins only.</p>
            <div ref={button} className="gbutton" />
            {error && <p className="note note-error">{error}</p>}
          </>
        )}
      </div>
    </div>
  );
}
