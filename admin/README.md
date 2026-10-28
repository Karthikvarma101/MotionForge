# MotionForge Admin

The web console for MotionForge customers, subscriptions, prices and app settings, live at
**https://motionforge-admin.pages.dev**. Only Google accounts in the `admins` table get in. The server
checks that on every action; the page itself holds no secrets.

| Page | What you can do |
|---|---|
| **Overview** | Monthly recurring revenue, customers, Pro (paying / given), plan counts, 30-day sign-ups / subscriptions / cancellations, recent activity |
| **Customers** | Search and filter (All / Pro / Free / Blocked). For one customer: give free Pro for 7 days to forever and revoke it; sync or cancel a subscription (at period end or right away); see Razorpay payments; block, unblock or delete the account |
| **Plans & prices** | Change the monthly / yearly price, rename a plan, take it off sale. New checkouts use the new price; current subscribers keep theirs |
| **App settings** | Make exporting free for everyone (or require Pro again); publish an announcement on the app's Home window |
| **Admins** | Add or remove admin Google accounts |
| **Activity** | Every change made from the console: who, what, to whom |

## How it fits together

- **Hosting:** a static React app (Vite + TypeScript) on Cloudflare Pages. Supabase can't host it: on
  `*.supabase.co`, Edge Functions and Storage serve HTML as plain text.
- **Sign-in:** Google's own button (Google Identity Services) with the "MotionForge Admin" web client in the
  MotionForge Google Cloud project.
  - Its authorised JavaScript origins are `http://localhost:5190` and `https://motionforge-admin.pages.dev`.
  - The Google ID token is exchanged for a Supabase session (`signInWithIdToken`, with a nonce).
- **Everything privileged** goes through the `admin-api` Edge Function (`../supabase/functions/admin-api`).
  - It verifies the caller's token and admin status, then uses the service role on the server.
  - Its tables are in `../supabase/migrations/20261028010000_admin_console.sql`.
- **The Mac app** reads `plans` and `app_config` (public, read-only) when it comes to the front, and
  `subscription-status` counts console grants as Pro.

## Develop and deploy

```bash
npm install
```

```bash
npm run dev
```

The dev server runs on http://localhost:5190. Google sign-in needs Chrome; the Claude app's built-in
browser blocks Google's sign-in popup.

To publish, run the build first. Deploying needs `npx wrangler login` once on this Mac.

```bash
npm run build
```

```bash
npx wrangler@3.114.0 pages deploy dist --project-name motionforge-admin --branch main
```

Payment actions (cancelling, syncing, invoices) need `RAZORPAY_KEY_ID` and `RAZORPAY_KEY_SECRET` in Supabase →
Edge Functions → Secrets. Until then the console says so and those buttons are off.
