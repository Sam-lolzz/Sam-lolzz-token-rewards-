# Token Rewards

An Expo mobile starter for a **test-only** token-rewards product. Supabase is the source of truth for authentication, the ledger, balances, and reward/transfer enforcement. Firebase can be added later for push notifications and analytics; it must not control balances or cash-out eligibility.

## Included economy

- 0.2-token daily base reward
- 7-day (+0.8) and 30-day (+4) streak bonuses
- 1,000-token cash-out floor and a displayed test conversion of 1,000 = $100 USD
- transfers through a transactional database RPC
- one-time 40% inactivity burn on the first login after 21+ days away
- task claims and referral claims held for verification, plus server-recorded streak milestones
- approved referral reward: 5 tokens to the referrer and 1 token to the new user
- immutable, user-visible ledger with direct client writes blocked

## Set up

1. Create a Supabase project, then copy `.env.example` to `.env` and set its two public values. Never place a service-role key in the app.
2. In Supabase SQL Editor, run `supabase/migrations/0001_rewards_schema.sql`.
3. Enable Email sign-in in Supabase Auth and add `tokenrewards://` as a redirect URL.
4. Install packages with `npm install`, then run `npm start`.

## Test admin (1,000,000 tokens)

After creating your own account, replace the email in the final commented command in the migration and run it in the SQL Editor. The credit is test-only, is tagged `admin_test_credit`, and there is no withdrawal workflow in this starter.

## Production note

Real cash-out requires identity checks, fraud review, jurisdiction-specific legal review, payment-provider integration, rate limits, and server-side payout approval. Do not enable withdrawals merely by changing the displayed conversion.

