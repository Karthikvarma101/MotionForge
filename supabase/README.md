# MotionForge backend (Supabase + Razorpay)

Google sign-in and **MotionForge Pro**: ₹199 / month or ₹399 / year through Razorpay Subscriptions. Exporting
needs Pro; editing, previewing and saving stay free.

| Piece | What it does |
|---|---|
| `migrations/20261028000000_motionforge_pro.sql` | `plans` (the two prices), `subscriptions` (one row per Razorpay subscription, readable only by its owner), `motionforge_entitlement()` |
| `functions/subscription-checkout` | Signed-in user + plan → creates the Razorpay plan the first time, then a subscription; returns Razorpay's hosted payment page |
| `functions/subscription-status` | Re-reads the user's subscriptions from Razorpay and answers whether they're Pro; `{"action":"cancel"}` cancels at the end of the period |
| `functions/razorpay-subscription-webhook` | Razorpay's server-to-server notices (signature-checked), so renewals and cancellations land even while the app is closed |
| `migrations/20261028010000_admin_console.sql` | `admins`, `pro_grants` (free Pro), `app_config` (export switch, announcement), `admin_audit`, the sale price on each subscription; the entitlement counts grants |
| `functions/admin-api` | Everything the [admin console](../admin/README.md) does, for admins only: customers, grants, cancellations, blocking, plans, settings, admins, the activity log |

Live project: **MotionForge** (`hknpofgdsqqsnztriguy`, South Asia/Mumbai) in Karthikvarma101's Org. Steps 1–5 and
8 below are done for it; Google sign-in was verified end to end on 2026-10-28. Both migrations ran and all four
functions (including `admin-api`) are deployed. The admin console is at https://motionforge-admin.pages.dev.

The app (`Sources/MotionForge/AccountModel.swift`) signs in with Google directly: PKCE in a system browser sheet
against an iOS-type Google client, then Google's ID token is exchanged for a Supabase session
(`grant_type=id_token`, with a nonce). It keeps the session in the Keychain and calls the functions with the user's
access token. Signing in this way makes Google's account chooser say "to continue to **MotionForge**" (the branding of
the client's Google Cloud project). Supabase's hosted flow (redirect `motionforge://auth-callback`) is the fallback
when `AccountConfig.googleClientID` is empty; with it, Google shows the `supabase.co` address instead.

## One-time setup

The **owner** does the steps marked 🔑, because they involve passwords and secret keys.

1. 🔑 **Create the project:** Supabase dashboard → New project "MotionForge", region *South Asia (Mumbai)*, with a
   database password of your choosing.
2. **Database:** SQL editor → run `migrations/20261028000000_motionforge_pro.sql`.
3. 🔑 **Google sign-in.**
   - **App client (what the app uses).** The Google Cloud project *MotionForge* (`iron-stack-481205-b4`) has
     branding with the app name *MotionForge* and an OAuth client "MotionForge Mac".
     - The client is of type **iOS**, bundle ID `com.motionforge.MotionForge`, and has no secret.
     - Its client ID is in `AccountConfig.googleClientID`.
   - **Supabase.** In *Authentication → Sign In / Providers → Google*, *Client IDs* lists the web client first and
     then the Mac client. Supabase uses the first for its hosted flow and accepts ID tokens issued to any of them.
   - **Web client (fallback flow only).** A **Web application** client with the redirect URI
     `https://hknpofgdsqqsnztriguy.supabase.co/auth/v1/callback`. Its secret goes in Supabase's *Client Secret* field.
     - The current one lives in the ZapCap Google Cloud project.
     - Chrome tends to autofill a saved password into *Client Secret*. A wrong secret shows up in the auth logs as
       `invalid_client`.
   - **Audience.** The MotionForge Google app is *External* and in *Testing*, so only listed test users can sign
     in.
     - To publish it, complete *Branding* (logo, home page, privacy policy) and click *Publish app* under *Audience*.
     - Brand verification is only needed to show the logo.
4. **Redirect URL:** *Authentication → URL Configuration → Redirect URLs* → add `motionforge://auth-callback`.
5. **Functions:** deploy the three functions. Each one checks the caller itself (user token, or the webhook
   signature).
   - The app sends the publishable key as `apikey` and the user's token as `x-user-jwt`. That passes the gateway's
     *Verify JWT with legacy secret* even when the check is on; new projects sign user tokens with ES256, which that
     check would reject in `Authorization`.
   - 🔑 `razorpay-subscription-webhook` needs **Verify JWT off**, because Razorpay sends no Supabase key (*Edge
     Functions → razorpay-subscription-webhook → Settings*).
   - *Dashboard:* *Edge Functions → Deploy a new function* → paste each `index.ts`.
   - *CLI:*

     ```bash
     supabase functions deploy subscription-checkout --no-verify-jwt
     ```

     ```bash
     supabase functions deploy subscription-status --no-verify-jwt
     ```

     ```bash
     supabase functions deploy razorpay-subscription-webhook --no-verify-jwt
     ```

6. 🔑 **Razorpay.**
   - Make sure the account has **Subscriptions** enabled (Dashboard → Subscriptions; Razorpay may need to activate
     it).
   - In Supabase → *Edge Functions → Secrets*, set `RAZORPAY_KEY_ID` and `RAZORPAY_KEY_SECRET`. Use `rzp_test_…`
     keys to try it, `rzp_live_…` keys to sell.
   - The functions answer `payments_not_configured` until these are set. The two Razorpay plans are created
     automatically on the first checkout, separately for test and live keys.
7. 🔑 **Webhook (recommended).**
   - In Razorpay → *Webhooks → Add*, set the URL to `https://hknpofgdsqqsnztriguy.supabase.co/functions/v1/razorpay-subscription-webhook`.
   - Choose a secret, and select the `subscription.*` events.
   - Put the same secret in the Supabase secret `RAZORPAY_WEBHOOK_SECRET`.
   - Without the webhook, `subscription-status` still syncs whenever the app checks.
8. **App:** put the project URL, its publishable key (`sb_publishable_…`, safe to ship) and the Google Mac client ID
   in `AccountConfig` in `Sources/MotionForge/AccountModel.swift`. `MOTIONFORGE_SUPABASE_URL`, `_KEY` and
   `MOTIONFORGE_GOOGLE_CLIENT_ID` override them for testing. Then run `scripts/bundle.sh`.

## Testing without a subscription

In a **debug** build, `MOTIONFORGE_PRO=1` (environment) unlocks export for scripts and demos. Release builds ignore it:
there, Pro comes only from the server.
