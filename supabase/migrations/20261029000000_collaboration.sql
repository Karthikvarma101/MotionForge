-- MotionForge collaboration: friends, shared projects and live co-editing (Pro only).
--
-- A shared project is stored as small keyed pieces (`project_objects`, see Sources/MFCore/include/mf/Sync.hpp):
-- one per composition, layer, layer property and media file. Edits travel live over a private Realtime
-- channel "project:<id>" and are saved here with push_objects(); a newer piece (Lamport clock, then client
-- id) wins, so every Mac converges. Media files go to the private "project-media" bucket under <project id>/.
--
-- Everyone in a shared project must have MotionForge Pro (subscription, grant or trial). That is checked
-- here, on every read and write, not just in the app. Clients never write tables directly: all changes go
-- through the security-definer functions below; RLS only allows reading.

-- ---- Pro for any user (motionforge_entitlement() answers for the caller only) -------------------------
create or replace function public.motionforge_user_is_pro(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
      select 1 from public.subscriptions s
       where s.user_id = uid
         and (s.status in ('active', 'authenticated', 'pending')
              or (s.status in ('cancelled', 'halted', 'completed') and s.current_end > now())))
      or exists (
      select 1 from public.pro_grants g
       where g.user_id = uid and g.revoked_at is null and (g.until is null or g.until > now()));
$$;
revoke all on function public.motionforge_user_is_pro(uuid) from public, anon, authenticated;  -- used inside the functions below

-- ---- profiles: what friends see of each other ----------------------------------------------------------
create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  email      text not null,
  name       text not null default '',
  avatar_url text,
  updated_at timestamptz not null default now()
);
create index profiles_email_idx on public.profiles (lower(email));
alter table public.profiles enable row level security;

create or replace function public.sync_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, avatar_url, updated_at)
  values (new.id, coalesce(new.email, ''),
          coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', ''),
          coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture'), now())
  on conflict (id) do update
     set email = excluded.email, name = excluded.name, avatar_url = excluded.avatar_url, updated_at = now();
  return new;
end $$;
create trigger on_auth_user_profile after insert or update of email, raw_user_meta_data on auth.users
  for each row execute function public.sync_profile();
insert into public.profiles (id, email, name, avatar_url)
select u.id, coalesce(u.email, ''),
       coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', ''),
       coalesce(u.raw_user_meta_data ->> 'avatar_url', u.raw_user_meta_data ->> 'picture')
  from auth.users u
on conflict (id) do nothing;

-- ---- friends -------------------------------------------------------------------------------------------
create table public.friendships (
  id           uuid primary key default gen_random_uuid(),
  requester    uuid not null references auth.users (id) on delete cascade,
  addressee    uuid not null references auth.users (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  check (requester <> addressee)
);
create unique index friendships_pair_idx on public.friendships (least(requester, addressee), greatest(requester, addressee));
alter table public.friendships enable row level security;
create policy "own friendships" on public.friendships for select to authenticated
  using ((select auth.uid()) in (requester, addressee));

create or replace function public.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.friendships f
                  where f.status = 'accepted'
                    and least(f.requester, f.addressee) = least(a, b)
                    and greatest(f.requester, f.addressee) = greatest(a, b));
$$;

-- Profiles are visible to yourself, people you have a friendship (or request) with, and people you share a project with.
create policy "profiles of friends and collaborators" on public.profiles for select to authenticated
  using (id = (select auth.uid())
         or exists (select 1 from public.friendships f
                     where (f.requester = (select auth.uid()) and f.addressee = profiles.id)
                        or (f.addressee = (select auth.uid()) and f.requester = profiles.id)));

-- My friends, requests I've sent and requests waiting for me.
create or replace function public.my_friends()
returns table (friendship_id uuid, user_id uuid, email text, name text, avatar_url text, status text,
               incoming boolean, is_pro boolean, since timestamptz)
language sql stable security definer set search_path = public as $$
  select f.id, p.id, p.email, p.name, p.avatar_url, f.status, f.addressee = auth.uid(),
         public.motionforge_user_is_pro(p.id), coalesce(f.responded_at, f.created_at)
    from public.friendships f
    join public.profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
   where auth.uid() in (f.requester, f.addressee)
   order by f.status desc, p.name, p.email;
$$;

-- Ask someone to be your friend by the email they sign in with. If they already asked you, you're friends.
create or replace function public.send_friend_request(friend_email text)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  them uuid;
  existing public.friendships;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  select id into them from public.profiles where lower(email) = lower(trim(friend_email)) limit 1;
  if them is null then
    raise exception 'No MotionForge account uses %. Ask them to sign in to MotionForge once, then try again.', trim(friend_email);
  end if;
  if them = me then raise exception 'That''s your own account.'; end if;
  select * into existing from public.friendships
   where least(requester, addressee) = least(me, them) and greatest(requester, addressee) = greatest(me, them);
  if found then
    if existing.status = 'accepted' then return 'already_friends'; end if;
    if existing.addressee = me then
      update public.friendships set status = 'accepted', responded_at = now() where id = existing.id;
      return 'accepted';
    end if;
    return 'already_requested';
  end if;
  insert into public.friendships (requester, addressee) values (me, them);
  return 'requested';
end $$;

create or replace function public.respond_friend_request(request_id uuid, accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if accept then
    update public.friendships set status = 'accepted', responded_at = now()
     where id = request_id and addressee = auth.uid() and status = 'pending';
  else
    delete from public.friendships where id = request_id and addressee = auth.uid() and status = 'pending';
  end if;
  if not found then raise exception 'That friend request is no longer waiting.'; end if;
end $$;

-- Removes a friend or cancels a request you sent.
create or replace function public.remove_friend(friend_id uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.friendships
   where least(requester, addressee) = least(auth.uid(), friend_id)
     and greatest(requester, addressee) = greatest(auth.uid(), friend_id);
$$;

-- ---- shared projects -------------------------------------------------------------------------------
create table public.shared_projects (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null references auth.users (id) on delete cascade,
  name       text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.shared_projects enable row level security;

create table public.project_members (
  project_id uuid not null references public.shared_projects (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       text not null check (role in ('owner', 'editor')),
  status     text not null check (status in ('invited', 'joined')),
  slot       integer not null,  -- id range for objects this person creates (ids never clash between Macs)
  invited_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (project_id, user_id),
  unique (project_id, slot)
);
create index project_members_user_idx on public.project_members (user_id);
alter table public.project_members enable row level security;

create table public.project_objects (
  project_id uuid not null references public.shared_projects (id) on delete cascade,
  key        text not null,
  value      jsonb,            -- null: deleted
  clock      bigint not null,
  client     text not null,
  updated_by uuid references auth.users (id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (project_id, key)
);
alter table public.project_objects enable row level security;

create or replace function public.is_project_member(pid uuid, uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.project_members m where m.project_id = pid and m.user_id = uid and m.status = 'joined');
$$;

-- A joined member who has Pro right now: the test for reading, writing and the live channel.
create or replace function public.can_collaborate(pid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_project_member(pid) and public.motionforge_user_is_pro(auth.uid());
$$;

-- Channel names are "project:<uuid>"; anything else is refused.
create or replace function public.project_from_topic(topic text)
returns uuid language plpgsql immutable as $$
begin
  if topic !~ '^project:[0-9a-f-]{36}$' then return null; end if;
  return substring(topic from 9)::uuid;
end $$;

create policy "members see their projects" on public.shared_projects for select to authenticated
  using (exists (select 1 from public.project_members m
                  where m.project_id = shared_projects.id and m.user_id = (select auth.uid())));
create policy "members see each other" on public.project_members for select to authenticated
  using (public.is_project_member(project_id) or user_id = (select auth.uid()));
create policy "collaborators read pieces" on public.project_objects for select to authenticated
  using (public.can_collaborate(project_id));
create policy "collaborators see each other's profiles" on public.profiles for select to authenticated
  using (exists (select 1 from public.project_members a join public.project_members b on a.project_id = b.project_id
                  where a.user_id = (select auth.uid()) and b.user_id = profiles.id));

create or replace function public.require_pro()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if not public.motionforge_user_is_pro(auth.uid()) then
    raise exception 'Collaboration is part of MotionForge Pro.' using errcode = 'P0403';
  end if;
end $$;

-- Pieces are a JSON array of {"k": key, "v": value or null, "c": clock, "n": client}. A piece is stored
-- only if it is newer than what is there.
create or replace function public.push_objects(pid uuid, pieces jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  perform public.require_pro();
  if not public.is_project_member(pid) then raise exception 'You''re not in this shared project.' using errcode = 'P0403'; end if;
  insert into public.project_objects as o (project_id, key, value, clock, client, updated_by, updated_at)
  select pid, p ->> 'k', case when jsonb_typeof(p -> 'v') = 'null' then null else p -> 'v' end,
         (p ->> 'c')::bigint, p ->> 'n', auth.uid(), now()
    from jsonb_array_elements(pieces) p
   where p ? 'k' and p ? 'c' and p ? 'n'
  on conflict (project_id, key) do update
     set value = excluded.value, clock = excluded.clock, client = excluded.client,
         updated_by = excluded.updated_by, updated_at = now()
   where (excluded.clock, excluded.client) > (o.clock, o.client);
  get diagnostics n = row_count;
  update public.shared_projects set updated_at = now() where id = pid;
  return n;
end $$;

-- Every piece of a project, as one JSON array (so large projects aren't cut at the row limit).
create or replace function public.pull_objects(pid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_pro();
  if not public.is_project_member(pid) then raise exception 'You''re not in this shared project.' using errcode = 'P0403'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('k', key, 'v', value, 'c', clock, 'n', client))
                     from public.project_objects where project_id = pid), '[]'::jsonb);
end $$;

-- Starts sharing: a new shared project owned by the caller, seeded with the caller's pieces. Returns its id.
create or replace function public.create_shared_project(project_name text, pieces jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  perform public.require_pro();
  insert into public.shared_projects (owner, name) values (auth.uid(), coalesce(nullif(trim(project_name), ''), 'Untitled'))
  returning id into pid;
  insert into public.project_members (project_id, user_id, role, status, slot, invited_by)
  values (pid, auth.uid(), 'owner', 'joined', 1, auth.uid());
  perform public.push_objects(pid, coalesce(pieces, '[]'::jsonb));
  return pid;
end $$;

-- Invites an accepted friend. They need Pro to join (not to be invited).
create or replace function public.invite_to_project(pid uuid, friend_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_pro();
  if not public.is_project_member(pid) then raise exception 'You''re not in this shared project.'; end if;
  if not public.are_friends(auth.uid(), friend_id) then raise exception 'You can only invite people on your friends list.'; end if;
  insert into public.project_members (project_id, user_id, role, status, slot, invited_by)
  values (pid, friend_id, 'editor', 'invited',
          (select coalesce(max(slot), 0) + 1 from public.project_members where project_id = pid), auth.uid())
  on conflict (project_id, user_id) do nothing;
end $$;

create or replace function public.respond_project_invite(pid uuid, accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if accept then
    perform public.require_pro();
    update public.project_members set status = 'joined' where project_id = pid and user_id = auth.uid();
  else
    delete from public.project_members where project_id = pid and user_id = auth.uid() and role <> 'owner';
  end if;
  if not found then raise exception 'That invitation is no longer open.'; end if;
end $$;

-- Leaving: editors leave; the owner's leaving ends the shared project for everyone.
create or replace function public.leave_project(pid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.project_members where project_id = pid and user_id = auth.uid() and role = 'owner') then
    delete from public.shared_projects where id = pid;
  else
    delete from public.project_members where project_id = pid and user_id = auth.uid();
  end if;
end $$;

-- The owner removes an editor.
create or replace function public.remove_project_member(pid uuid, member_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.project_members where project_id = pid and user_id = auth.uid() and role = 'owner') then
    raise exception 'Only the owner can remove people.';
  end if;
  delete from public.project_members where project_id = pid and user_id = member_id and role <> 'owner';
end $$;

-- Shared projects I'm in or invited to, with everyone in them.
create or replace function public.my_shared_projects()
returns table (project_id uuid, name text, owner_name text, role text, status text, slot integer,
               updated_at timestamptz, members jsonb)
language sql stable security definer set search_path = public as $$
  select sp.id, sp.name, coalesce(nullif(op.name, ''), op.email), me.role, me.status, me.slot, sp.updated_at,
         (select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'name', coalesce(nullif(p.name, ''), p.email),
                                              'email', p.email, 'avatar_url', p.avatar_url, 'role', m.role,
                                              'status', m.status, 'is_pro', public.motionforge_user_is_pro(m.user_id))
                            order by m.slot)
            from public.project_members m join public.profiles p on p.id = m.user_id
           where m.project_id = sp.id)
    from public.project_members me
    join public.shared_projects sp on sp.id = me.project_id
    left join public.profiles op on op.id = sp.owner
   where me.user_id = auth.uid()
   order by me.status = 'invited' desc, sp.updated_at desc;
$$;

revoke all on function public.push_objects(uuid, jsonb), public.pull_objects(uuid),
  public.create_shared_project(text, jsonb), public.invite_to_project(uuid, uuid),
  public.respond_project_invite(uuid, boolean), public.leave_project(uuid),
  public.remove_project_member(uuid, uuid), public.my_shared_projects(), public.my_friends(),
  public.send_friend_request(text), public.respond_friend_request(uuid, boolean), public.remove_friend(uuid),
  public.are_friends(uuid, uuid), public.is_project_member(uuid, uuid), public.can_collaborate(uuid),
  public.require_pro()
  from public, anon;
grant execute on function public.push_objects(uuid, jsonb), public.pull_objects(uuid),
  public.create_shared_project(text, jsonb), public.invite_to_project(uuid, uuid),
  public.respond_project_invite(uuid, boolean), public.leave_project(uuid),
  public.remove_project_member(uuid, uuid), public.my_shared_projects(), public.my_friends(),
  public.send_friend_request(text), public.respond_friend_request(uuid, boolean), public.remove_friend(uuid),
  public.are_friends(uuid, uuid), public.is_project_member(uuid, uuid), public.can_collaborate(uuid),
  public.require_pro()
  to authenticated;

-- ---- live channel: private Realtime topics "project:<id>" for broadcast (edits) and presence (who's here) --
create policy "mf collaborators receive" on realtime.messages for select to authenticated
  using (extension in ('broadcast', 'presence')
         and public.project_from_topic((select realtime.topic())) is not null
         and public.can_collaborate(public.project_from_topic((select realtime.topic()))));
create policy "mf collaborators send" on realtime.messages for insert to authenticated
  with check (extension in ('broadcast', 'presence')
              and public.project_from_topic((select realtime.topic())) is not null
              and public.can_collaborate(public.project_from_topic((select realtime.topic()))));

-- ---- media: private bucket, files at <project id>/<sha256>.<ext> -------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('project-media', 'project-media', false, 52428800)
on conflict (id) do nothing;

create policy "mf collaborators read media" on storage.objects for select to authenticated
  using (bucket_id = 'project-media'
         and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
         and public.can_collaborate(((storage.foldername(name))[1])::uuid));
create policy "mf collaborators add media" on storage.objects for insert to authenticated
  with check (bucket_id = 'project-media'
              and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
              and public.can_collaborate(((storage.foldername(name))[1])::uuid));
