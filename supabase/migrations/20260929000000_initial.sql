create schema if not exists private;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.study_spaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 80),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now()
);

create table if not exists public.study_members (
  space_id uuid not null references public.study_spaces (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (space_id, user_id)
);

create table if not exists public.study_invites (
  token uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.study_spaces (id) on delete cascade,
  invited_email text not null,
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_by uuid references auth.users (id),
  accepted_at timestamptz
);

create table if not exists public.entries (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.study_spaces (id) on delete cascade,
  created_by uuid not null default auth.uid() references auth.users (id),
  updated_by uuid not null default auth.uid() references auth.users (id),
  source_local_id text,
  entry_date date not null default current_date,
  type text not null check (type in ('lectura', 'oracion', 'externo', 'promesa')),
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) in ('object', 'array')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (space_id, source_local_id)
);

create index if not exists entries_space_entry_date_idx
  on public.entries (space_id, entry_date desc, created_at desc);

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
    and not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'entries'
    ) then
    alter publication supabase_realtime add table public.entries;
  end if;
end;
$$;

create table if not exists private.ai_daily_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  usage_date date not null default current_date,
  request_count integer not null default 0 check (request_count >= 0),
  primary key (user_id, usage_date)
);

revoke all on private.ai_daily_usage from public, anon, authenticated;

create or replace function private.is_space_member(p_space_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.study_members m
    where m.space_id = p_space_id
      and m.user_id = (select auth.uid())
  );
$$;

create or replace function private.shares_space_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.study_members mine
    join public.study_members theirs on theirs.space_id = mine.space_id
    where mine.user_id = (select auth.uid())
      and theirs.user_id = p_user_id
  );
$$;

revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;
revoke all on function private.is_space_member(uuid) from public, anon;
revoke all on function private.shares_space_with(uuid) from public, anon;
grant execute on function private.is_space_member(uuid) to authenticated;
grant execute on function private.shares_space_with(uuid) to authenticated;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(coalesce(new.email, ''), '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function public.handle_new_auth_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute function public.handle_new_auth_user();

create or replace function public.touch_profile_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.protect_entry_attribution()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
    or new.space_id is distinct from old.space_id
    or new.created_by is distinct from old.created_by
    or new.source_local_id is distinct from old.source_local_id then
    raise exception 'Entry identity and creator cannot be changed';
  end if;
  new.updated_by := (select auth.uid());
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.touch_profile_updated_at() from public, anon, authenticated;
revoke all on function public.protect_entry_attribution() from public, anon, authenticated;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
before update on public.profiles
for each row execute function public.touch_profile_updated_at();

drop trigger if exists entries_protect_attribution on public.entries;
create trigger entries_protect_attribution
before update on public.entries
for each row execute function public.protect_entry_attribution();

create or replace function public.create_study_space(p_name text default 'Nuestra bitácora')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_space_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required';
  end if;
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 80 then
    raise exception 'Space name must contain between 1 and 80 characters';
  end if;

  insert into public.study_spaces (name, created_by)
  values (trim(p_name), (select auth.uid()))
  returning id into new_space_id;

  insert into public.study_members (space_id, user_id, role)
  values (new_space_id, (select auth.uid()), 'owner');

  return new_space_id;
end;
$$;

create or replace function public.create_space_invite(p_space_id uuid, p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  invite_token uuid;
  normalized_email text := lower(trim(coalesce(p_email, '')));
begin
  if not private.is_space_member(p_space_id) then
    raise exception 'You are not a member of this study space';
  end if;
  if normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'A valid email address is required';
  end if;

  insert into public.study_invites (space_id, invited_email, created_by)
  values (p_space_id, normalized_email, (select auth.uid()))
  returning token into invite_token;

  return invite_token;
end;
$$;

create or replace function public.accept_space_invite(p_token uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  invite public.study_invites%rowtype;
  current_user_id uuid := (select auth.uid());
  current_email text := lower(coalesce((select auth.jwt()) ->> 'email', ''));
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into invite
  from public.study_invites i
  where i.token = p_token
  for update;

  if not found or invite.accepted_at is not null or invite.expires_at <= now() then
    raise exception 'Invite is invalid, expired, or already used';
  end if;
  if invite.invited_email <> current_email then
    raise exception 'Sign in with the email address that received this invite';
  end if;

  insert into public.study_members (space_id, user_id, role)
  values (invite.space_id, current_user_id, 'member')
  on conflict (space_id, user_id) do nothing;

  update public.study_invites
  set accepted_by = current_user_id, accepted_at = now()
  where token = p_token;

  return invite.space_id;
end;
$$;

create or replace function public.consume_ai_request()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  requests_today integer;
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;

  insert into private.ai_daily_usage (user_id, usage_date, request_count)
  values (current_user_id, current_date, 1)
  on conflict (user_id, usage_date)
  do update set request_count = private.ai_daily_usage.request_count + 1
  where private.ai_daily_usage.request_count < 30
  returning request_count into requests_today;

  if requests_today is null then
    raise exception 'Daily AI request limit reached';
  end if;
  return requests_today;
end;
$$;

create or replace function public.import_entries(p_space_id uuid, p_mode text, p_entries jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  inserted_count integer;
begin
  if current_user_id is null or not private.is_space_member(p_space_id) then
    raise exception 'Authentication and study space membership required';
  end if;
  if p_mode not in ('add', 'replace') then
    raise exception 'Import mode must be add or replace';
  end if;
  if jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) > 5000 then
    raise exception 'Import must contain an array of at most 5000 entries';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_entries) as item(entry)
    where item.entry ->> 'type' not in ('lectura', 'oracion', 'externo', 'promesa')
      or coalesce(item.entry ->> 'source_local_id', item.entry ->> 'id') is null
      or coalesce(item.entry ->> 'entry_date', '') !~ '^\d{4}-\d{2}-\d{2}$'
      or jsonb_typeof(item.entry -> 'data') not in ('object', 'array')
  ) then
    raise exception 'Import contains an invalid entry';
  end if;

  if p_mode = 'replace' then
    delete from public.entries where space_id = p_space_id;
  end if;

  insert into public.entries (space_id, created_by, updated_by, source_local_id, entry_date, type, data)
  select
    p_space_id,
    current_user_id,
    current_user_id,
    coalesce(item.entry ->> 'source_local_id', item.entry ->> 'id'),
    (item.entry ->> 'entry_date')::date,
    item.entry ->> 'type',
    item.entry -> 'data'
  from jsonb_array_elements(p_entries) as item(entry)
  on conflict (space_id, source_local_id) do nothing;

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

revoke all on function public.create_study_space(text) from public, anon;
revoke all on function public.create_space_invite(uuid, text) from public, anon;
revoke all on function public.accept_space_invite(uuid) from public, anon;
revoke all on function public.consume_ai_request() from public, anon;
revoke all on function public.import_entries(uuid, text, jsonb) from public, anon;
grant execute on function public.create_study_space(text) to authenticated;
grant execute on function public.create_space_invite(uuid, text) to authenticated;
grant execute on function public.accept_space_invite(uuid) to authenticated;
grant execute on function public.consume_ai_request() to authenticated;
grant execute on function public.import_entries(uuid, text, jsonb) to authenticated;

alter table public.profiles enable row level security;
alter table public.study_spaces enable row level security;
alter table public.study_members enable row level security;
alter table public.study_invites enable row level security;
alter table public.entries enable row level security;

revoke all on public.profiles, public.study_spaces, public.study_members, public.study_invites, public.entries from anon, authenticated;
grant select, update on public.profiles to authenticated;
grant select on public.study_spaces, public.study_members to authenticated;
grant select, insert, update, delete on public.entries to authenticated;

create policy "Members can read profiles in their spaces"
on public.profiles for select to authenticated
using (id = (select auth.uid()) or private.shares_space_with(id));

create policy "Users can update their own profile"
on public.profiles for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

create policy "Members can read their study spaces"
on public.study_spaces for select to authenticated
using (private.is_space_member(id));

create policy "Members can read membership in their spaces"
on public.study_members for select to authenticated
using (private.is_space_member(space_id));

create policy "Members can read entries in their spaces"
on public.entries for select to authenticated
using (private.is_space_member(space_id));

create policy "Members can add entries to their spaces"
on public.entries for insert to authenticated
with check (
  created_by = (select auth.uid())
  and updated_by = (select auth.uid())
  and private.is_space_member(space_id)
);

create policy "Members can update entries in their spaces"
on public.entries for update to authenticated
using (private.is_space_member(space_id))
with check (private.is_space_member(space_id));

create policy "Members can delete entries in their spaces"
on public.entries for delete to authenticated
using (private.is_space_member(space_id));

comment on table public.entries is 'Private study and prayer records shared by members of a study space.';
comment on column public.entries.created_by is 'Authenticated author; immutable after insert.';
comment on column public.entries.entry_date is 'Date the record refers to, independent from its creation timestamp.';
