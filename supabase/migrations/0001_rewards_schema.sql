-- Run this migration in a new Supabase project. All token amounts use NUMERIC,
-- never floating-point values. The client can call only the explicitly granted RPCs.

create extension if not exists pgcrypto;

create type public.ledger_type as enum (
  'daily_reward', 'streak_bonus', 'transfer_in', 'transfer_out', 'inactivity_burn',
  'task_reward', 'referral_reward', 'milestone_reward', 'admin_test_credit'
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  handle text not null unique check (handle ~ '^[a-z0-9_]{3,24}$'),
  balance numeric(18,4) not null default 0 check (balance >= 0),
  streak_count integer not null default 0 check (streak_count >= 0),
  last_claim_at date,
  last_login_at timestamptz not null default now(),
  last_inactivity_burn_at timestamptz,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.token_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  amount numeric(18,4) not null check (amount <> 0),
  entry_type public.ledger_type not null,
  counterparty_id uuid references public.profiles(id),
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (user_id, idempotency_key)
);
create index token_ledger_user_created_idx on public.token_ledger (user_id, created_at desc);

create table public.reward_tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  reward numeric(18,4) not null check (reward > 0),
  active boolean not null default false,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  max_completions integer,
  created_at timestamptz not null default now()
);
create table public.task_claims (
  task_id uuid not null references public.reward_tasks(id),
  user_id uuid not null references public.profiles(id),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  primary key (task_id, user_id)
);

alter table public.profiles enable row level security;
alter table public.token_ledger enable row level security;
alter table public.reward_tasks enable row level security;
alter table public.task_claims enable row level security;

create policy "read own profile" on public.profiles for select to authenticated using ((select auth.uid()) = id);
create policy "read own ledger" on public.token_ledger for select to authenticated using ((select auth.uid()) = user_id);
create policy "read active tasks" on public.reward_tasks for select to authenticated using (active and starts_at <= now() and (ends_at is null or ends_at > now()));
create policy "read own task claims" on public.task_claims for select to authenticated using ((select auth.uid()) = user_id);
-- No client INSERT/UPDATE/DELETE policies: RPCs are the only movement path.

create or replace function public.on_auth_user_created()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare new_handle text;
begin
  new_handle := lower(coalesce(new.raw_user_meta_data ->> 'handle', split_part(new.email, '@', 1)));
  new_handle := regexp_replace(new_handle, '[^a-z0-9_]', '_', 'g');
  new_handle := left(new_handle, 18) || '_' || substr(replace(new.id::text, '-', ''), 1, 5);
  insert into public.profiles (id, handle) values (new.id, new_handle);
  return new;
end; $$;
create trigger create_profile_after_signup after insert on auth.users for each row execute function public.on_auth_user_created();

create or replace function public.my_wallet()
returns table (balance numeric, streak_count integer, last_claim_at date, handle text)
language sql security invoker set search_path = public as $$
  select p.balance, p.streak_count, p.last_claim_at, p.handle from public.profiles p where p.id = (select auth.uid());
$$;

create or replace function public.claim_daily_reward()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare p public.profiles%rowtype; bonus numeric := 0; burn numeric := 0; today date := (now() at time zone 'utc')::date;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select * into p from public.profiles where id = auth.uid() for update;
  if p.last_claim_at = today then raise exception 'Daily reward already claimed'; end if;
  if p.last_login_at < now() - interval '21 days' and (p.last_inactivity_burn_at is null or p.last_inactivity_burn_at < p.last_login_at) then
    burn := round(p.balance * 0.40, 4);
    if burn > 0 then
      update public.profiles set balance = balance - burn, last_inactivity_burn_at = now() where id = p.id;
      insert into public.token_ledger(user_id, amount, entry_type, metadata) values (p.id, -burn, 'inactivity_burn', jsonb_build_object('reason', '21_days_no_login'));
    end if;
  end if;
  if p.last_claim_at = today - 1 then p.streak_count := p.streak_count + 1; else p.streak_count := 1; end if;
  if p.streak_count = 7 then bonus := 0.8; elsif p.streak_count = 30 then bonus := 4; end if;
  update public.profiles set balance = balance + 0.2 + bonus, streak_count = p.streak_count, last_claim_at = today, last_login_at = now() where id = p.id;
  insert into public.token_ledger(user_id, amount, entry_type) values (p.id, 0.2, 'daily_reward');
  if bonus > 0 then insert into public.token_ledger(user_id, amount, entry_type, metadata) values (p.id, bonus, 'streak_bonus', jsonb_build_object('streak_days', p.streak_count)); end if;
end; $$;

create or replace function public.transfer_tokens(recipient_handle text, token_amount numeric)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare sender public.profiles%rowtype; recipient public.profiles%rowtype; transfer_id text := gen_random_uuid()::text;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if token_amount is null or token_amount <= 0 or token_amount > 100000 then raise exception 'Invalid transfer amount'; end if;
  select * into sender from public.profiles where id = auth.uid() for update;
  select * into recipient from public.profiles where handle = lower(recipient_handle) for update;
  if recipient.id is null then raise exception 'Recipient not found'; end if;
  if recipient.id = sender.id then raise exception 'Cannot transfer to yourself'; end if;
  if sender.balance < token_amount then raise exception 'Insufficient token balance'; end if;
  update public.profiles set balance = balance - token_amount, last_login_at = now() where id = sender.id;
  update public.profiles set balance = balance + token_amount where id = recipient.id;
  insert into public.token_ledger(user_id, amount, entry_type, counterparty_id, idempotency_key) values (sender.id, -token_amount, 'transfer_out', recipient.id, transfer_id);
  insert into public.token_ledger(user_id, amount, entry_type, counterparty_id, idempotency_key) values (recipient.id, token_amount, 'transfer_in', sender.id, transfer_id);
end; $$;

-- Use only from the SQL editor after validating the intended user. This is deliberately not granted to client roles.
create or replace function public.grant_test_admin_credit(target_user uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  update public.profiles set is_admin = true, balance = balance + 1000000 where id = target_user;
  if not found then raise exception 'User not found'; end if;
  insert into public.token_ledger(user_id, amount, entry_type, metadata) values (target_user, 1000000, 'admin_test_credit', jsonb_build_object('environment', 'test_only'));
end; $$;

revoke all on function public.claim_daily_reward() from public, anon;
revoke all on function public.transfer_tokens(text, numeric) from public, anon;
revoke all on function public.my_wallet() from public, anon;
revoke all on function public.grant_test_admin_credit(uuid) from public, anon, authenticated;
grant execute on function public.claim_daily_reward() to authenticated;
grant execute on function public.transfer_tokens(text, numeric) to authenticated;
grant execute on function public.my_wallet() to authenticated;

-- After you have signed up, run this (replace the email):
-- select public.grant_test_admin_credit((select id from auth.users where email = 'YOUR_EMAIL@example.com'));

