-- MotionForge admin console: who may administer, complimentary Pro, app-wide settings.
--
-- Only the `admin-api` Edge Function (service role) writes these. Clients can read `app_config` (the
-- app shows the announcement and honours the export switch) and their own grants.

create table public.admins (
  email      text primary key,          -- a Google account; compared lower-case
  added_by   text,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;  -- no policies: invisible to clients
insert into public.admins (email, added_by) values ('karthikvarmaedu@gmail.com', 'setup');

-- Pro given by an admin: until `until` (null = no end), unless revoked.
create table public.pro_grants (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  until      timestamptz,
  reason     text,
  granted_by text not null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by text
);
create index pro_grants_user_idx on public.pro_grants (user_id, created_at desc);
alter table public.pro_grants enable row level security;
create policy "Users read their own grants" on public.pro_grants for select using ((select auth.uid()) = user_id);
grant select on public.pro_grants to authenticated;

-- App-wide settings the app reads at launch: { key: value }.
create table public.app_config (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table public.app_config enable row level security;
create policy "Anyone can read app settings" on public.app_config for select using (true);
grant select on public.app_config to anon, authenticated;
insert into public.app_config (key, value, updated_by) values
  ('export_requires_pro', 'true', 'setup'),            -- false = everyone can export (free weekends)
  ('announcement', '{"text": "", "style": "info"}', 'setup');  -- shown on the app's Home window when text is set

-- The price a subscription was sold at (plans can change price later; existing subscribers keep theirs).
alter table public.subscriptions add column amount_paise integer;

-- Pro from a paid-up subscription or an active grant.
create or replace function public.motionforge_entitlement()
returns table (pro boolean, plan_id text, status text, current_end timestamptz, cancel_at_period_end boolean)
language sql stable security invoker set search_path = public as $$
  with mine as (
    select s.plan_id, s.status, s.current_end, s.cancel_at_period_end, s.created_at,
           (s.status in ('active', 'authenticated', 'pending')
            or (s.status in ('cancelled', 'halted', 'completed') and s.current_end > now())) as paid
      from public.subscriptions s
     where s.user_id = (select auth.uid())
    union all
    select 'grant', 'granted', g.until, false, g.created_at, true
      from public.pro_grants g
     where g.user_id = (select auth.uid()) and g.revoked_at is null and (g.until is null or g.until > now())
  )
  select coalesce(bool_or(paid), false),
         (array_agg(plan_id order by paid desc, created_at desc))[1],
         (array_agg(status order by paid desc, created_at desc))[1],
         (array_agg(current_end order by paid desc, created_at desc))[1],
         coalesce((array_agg(cancel_at_period_end order by paid desc, created_at desc))[1], false)
    from mine;
$$;

-- Every change made from the console: who, what, to whom.
create table public.admin_audit (
  id          bigint generated always as identity primary key,
  admin_email text not null,
  action      text not null,
  target      text,
  detail      jsonb,
  at          timestamptz not null default now()
);
create index admin_audit_at_idx on public.admin_audit (at desc);
alter table public.admin_audit enable row level security;  -- no policies: invisible to clients
