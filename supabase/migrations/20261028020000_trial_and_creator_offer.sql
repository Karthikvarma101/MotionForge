-- MotionForge: a free trial for every new account, the launch prices, and the free-access offer for creators.

-- Settings the admin console can change (the app reads them at launch and when it comes to the front).
insert into public.app_config (key, value, updated_by) values
  ('trial_days', '7', 'setup'),  -- Pro for this many days from sign-up; 0 = no trial
  ('free_access_offer', jsonb_build_object(
     'enabled', true,
     'email', 'karthikvarmaedu@gmail.com',
     'text', 'Post one reel promoting MotionForge and get 1 month of Pro free. You need at least 5,000 followers — the bigger your audience, the longer the free access, up to 1 year.'
   ), 'setup')
on conflict (key) do nothing;

-- Every new account starts with a Pro trial: a grant that ends after `trial_days` (granted_by = 'trial').
create or replace function public.start_pro_trial()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  days integer := coalesce((select (value #>> '{}')::integer from public.app_config where key = 'trial_days'), 7);
begin
  if days > 0 then
    insert into public.pro_grants (user_id, until, reason, granted_by)
    values (new.id, now() + make_interval(days => days), 'Free trial', 'trial');
  end if;
  return new;
end;
$$;
revoke all on function public.start_pro_trial() from public, anon, authenticated;

drop trigger if exists on_auth_user_created_start_trial on auth.users;
create trigger on_auth_user_created_start_trial
  after insert on auth.users
  for each row execute function public.start_pro_trial();

-- Launch prices: ₹199 a month, ₹499 a year. New Razorpay plans are made at these prices on the next checkout.
update public.plans set amount_paise = 19900, razorpay_plan_id = null, razorpay_mode = null where id = 'pro_monthly' and amount_paise <> 19900;
update public.plans set amount_paise = 49900, razorpay_plan_id = null, razorpay_mode = null where id = 'pro_yearly' and amount_paise <> 49900;
insert into public.admin_audit (admin_email, action, target, detail) values
  ('setup', 'update_plan', 'pro_monthly', '{"after": {"amount_paise": 19900}, "note": "launch price"}'),
  ('setup', 'update_plan', 'pro_yearly', '{"after": {"amount_paise": 49900}, "note": "launch price"}'),
  ('setup', 'set_config', 'trial_days', '{"value": 7}');
