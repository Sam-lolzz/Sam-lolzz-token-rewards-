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
  referrer_id uuid references public.profiles(id),
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
create table public.referral_claims (
  referred_user_id uuid primary key references public.profiles(id),
  referrer_id uuid not null references public.profiles(id),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  approved_at timestamptz
);

alter table public.profiles enable row level security;
alter table public.token_ledger enable row level security;
alter table public.reward_tasks enable row level security;
alter table public.task_claims enable row level security;
alter table public.referral_claims enable row level security;

create policy "read own profile" on public.profiles for select to authenticated using ((select auth.uid()) = id);
create policy "read own ledger" on public.token_ledger for select to authenticated using ((select auth.uid()) = user_id);
create policy "read active tasks" on public.reward_tasks for select to authenticated using (active and starts_at <= now() and (ends_at is null or ends_at > now()));
create policy "read own task claims" on public.task_claims for select to authenticated using ((select auth.uid()) = user_id);
create policy "read own referrals" on public.referral_claims for select to authenticated using ((select auth.uid()) = referred_user_id or (select auth.uid()) = referrer_id);
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
  -- Milestones are granted once, based solely on server-recorded daily claims.
  if p.streak_count in (10, 100) then
    bonus := case when p.streak_count = 10 then 1 else 10 end;
    insert into public.token_ledger(user_id, amount, entry_type, idempotency_key, metadata)
    values (p.id, bonus, 'milestone_reward', 'streak_milestone:' || p.streak_count, jsonb_build_object('streak_days', p.streak_count))
    on conflict (user_id, idempotency_key) do nothing;
    if found then update public.profiles set balance = balance + bonus where id = p.id; end if;
  end if;
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

-- A task is never rewarded simply because a device says it was completed. Claims are
-- pending until an internal verifier or admin workflow approves them.
create or replace function public.claim_task(task_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare task_row public.reward_tasks%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select * into task_row from public.reward_tasks where id = task_id and active and starts_at <= now() and (ends_at is null or ends_at > now());
  if task_row.id is null then raise exception 'Task is unavailable'; end if;
  insert into public.task_claims(task_id, user_id) values (task_id, auth.uid());
exception when unique_violation then raise exception 'Task already claimed';
end; $$;

-- Referral rewards are similarly held pending. Your verification process should call
-- approve_referral_claim from the SQL editor or a service-role-only Edge Function.
create or replace function public.claim_referral(referrer_handle text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare referrer public.profiles%rowtype; claimant public.profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select * into claimant from public.profiles where id = auth.uid() for update;
  select * into referrer from public.profiles where handle = lower(referrer_handle);
  if referrer.id is null or referrer.id = claimant.id then raise exception 'Invalid referral'; end if;
  if claimant.referrer_id is not null or claimant.created_at < now() - interval '7 days' then raise exception 'Referral is no longer eligible'; end if;
  update public.profiles set referrer_id = referrer.id where id = claimant.id;
  insert into public.referral_claims(referred_user_id, referrer_id) values (claimant.id, referrer.id);
end; $$;

-- Internal-only approval helpers. Do not grant these to authenticated users; invoke
-- them from the SQL Editor or a service-role-only verification worker after checking evidence.
create or replace function public.approve_task_claim(approved_task_id uuid, approved_user_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare task_row public.reward_tasks%rowtype;
begin
  select * into task_row from public.reward_tasks where id = approved_task_id for update;
  if task_row.id is null then raise exception 'Task not found'; end if;
  update public.task_claims set status = 'approved' where task_id = approved_task_id and user_id = approved_user_id and status = 'pending';
  if not found then raise exception 'Pending claim not found'; end if;
  update public.profiles set balance = balance + task_row.reward where id = approved_user_id;
  insert into public.token_ledger(user_id, amount, entry_type, idempotency_key, metadata)
  values (approved_user_id, task_row.reward, 'task_reward', 'task:' || approved_task_id::text, jsonb_build_object('task_id', approved_task_id));
end; $$;

create or replace function public.approve_referral_claim(approved_referred_user_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare claim_row public.referral_claims%rowtype;
begin
  select * into claim_row from public.referral_claims where referred_user_id = approved_referred_user_id for update;
  if claim_row.referred_user_id is null or claim_row.status <> 'pending' then raise exception 'Pending referral not found'; end if;
  update public.referral_claims set status = 'approved', approved_at = now() where referred_user_id = approved_referred_user_id;
  update public.profiles set balance = balance + 5 where id = claim_row.referrer_id;
  update public.profiles set balance = balance + 1 where id = claim_row.referred_user_id;
  insert into public.token_ledger(user_id, amount, entry_type, idempotency_key, metadata) values (claim_row.referrer_id, 5, 'referral_reward', 'referrer:' || approved_referred_user_id::text, jsonb_build_object('referred_user_id', approved_referred_user_id));
  insert into public.token_ledger(user_id, amount, entry_type, idempotency_key, metadata) values (claim_row.referred_user_id, 1, 'referral_reward', 'referred:' || approved_referred_user_id::text, jsonb_build_object('referrer_id', claim_row.referrer_id));
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
revoke all on function public.claim_task(uuid) from public, anon;
revoke all on function public.claim_referral(text) from public, anon;
revoke all on function public.grant_test_admin_credit(uuid) from public, anon, authenticated;
revoke all on function public.approve_task_claim(uuid, uuid) from public, anon, authenticated;
revoke all on function public.approve_referral_claim(uuid) from public, anon, authenticated;
grant execute on function public.claim_daily_reward() to authenticated;
grant execute on function public.transfer_tokens(text, numeric) to authenticated;
grant execute on function public.my_wallet() to authenticated;
grant execute on function public.claim_task(uuid) to authenticated;
grant execute on function public.claim_referral(text) to authenticated;

-- After you have signed up, run this (replace the email):
-- select public.grant_test_admin_credit((select id from auth.users where email = 'YOUR_EMAIL@example.com'));

