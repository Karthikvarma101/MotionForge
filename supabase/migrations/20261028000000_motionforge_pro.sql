-- MotionForge Pro: ₹199 / month or ₹399 / year through Razorpay Subscriptions. Exporting needs Pro.
--
-- Rows in `subscriptions` are written only by the Edge Functions (service role): `subscription-checkout`
-- creates them, `subscription-status` and `razorpay-subscription-webhook` keep them in step with Razorpay.
-- Signed-in users can read their own rows and ask `motionforge_entitlement()` whether they are Pro.

create table public.plans (
  id               text primary key,                       -- pro_monthly, pro_yearly
  name             text not null,
  amount_paise     integer not null check (amount_paise > 0),
  period           text not null check (period in ('monthly', 'yearly')),
  razorpay_plan_id text,                                   -- created on the first checkout, per key mode
  razorpay_mode    text check (razorpay_mode in ('test', 'live')),
  active           boolean not null default true
);

insert into public.plans (id, name, amount_paise, period) values
  ('pro_monthly', 'MotionForge Pro — Monthly', 19900, 'monthly'),
  ('pro_yearly',  'MotionForge Pro — Yearly',  39900, 'yearly');

alter table public.plans enable row level security;
create policy "Anyone can read plans" on public.plans for select using (true);

create table public.subscriptions (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null references auth.users (id) on delete cascade,
  plan_id                  text not null references public.plans (id),
  razorpay_subscription_id text not null unique,
  -- Razorpay's status: created, authenticated, active, pending, halted, cancelled, completed, expired, paused
  status                   text not null,
  short_url                text,                           -- Razorpay's hosted checkout for this subscription
  current_start            timestamptz,
  current_end              timestamptz,                    -- end of the paid period
  cancel_at_period_end     boolean not null default false,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create index subscriptions_user_idx on public.subscriptions (user_id, created_at desc);

alter table public.subscriptions enable row level security;
create policy "Users read their own subscriptions" on public.subscriptions
  for select using ((select auth.uid()) = user_id);

-- Pro while a subscription is paid up: active / authenticated (first charge done or in flight), pending
-- (Razorpay is retrying a failed renewal: keep access during its retries), or cancelled / halted / completed
-- with time left in the period already paid for.
create or replace function public.motionforge_entitlement()
returns table (pro boolean, plan_id text, status text, current_end timestamptz, cancel_at_period_end boolean)
language sql stable security invoker set search_path = public as $$
  with mine as (
    select s.*,
           (s.status in ('active', 'authenticated', 'pending')
            or (s.status in ('cancelled', 'halted', 'completed') and s.current_end > now())) as paid
      from public.subscriptions s
     where s.user_id = (select auth.uid())
  )
  select coalesce(bool_or(paid), false),
         (array_agg(plan_id order by paid desc, created_at desc))[1],
         (array_agg(status order by paid desc, created_at desc))[1],
         (array_agg(current_end order by paid desc, created_at desc))[1],
         coalesce((array_agg(cancel_at_period_end order by paid desc, created_at desc))[1], false)
    from mine;
$$;

-- Explicit, for projects created with "Automatically expose new tables" off. RLS still decides which rows.
grant select on public.plans to anon, authenticated;
grant select on public.subscriptions to authenticated;
grant execute on function public.motionforge_entitlement() to authenticated;
