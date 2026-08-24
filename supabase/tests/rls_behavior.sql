-- Willagrams — what the row level security policies actually return.
--
-- `schema_invariants.sql` asserts that every table has RLS on and carries at
-- least one policy. That catches a table nobody wrote a policy for. It cannot
-- catch a policy that is written, enabled, and wrong.
--
-- Wrong is the dangerous case here, because a policy does not raise. A read
-- the policy refuses comes back as zero rows and a write it refuses comes back
-- as zero rows affected — both indistinguishable from "there was nothing
-- there". A friends page that renders empty in production looks exactly like a
-- player with no friends, and every test against `FakeBackend` stays green
-- because the fake enforces no policies at all.
--
-- So every assertion below names the reader as well as the row: the owner sees
-- it, the stranger sees zero, and the difference is the policy doing its job.
--
-- Run against a scratch database that already has the migration applied:
--   psql -v ON_ERROR_STOP=1 -d <scratch> -f supabase/tests/rls_behavior.sql
--
-- Requires the Supabase `auth` schema, `auth.uid()`, and the `authenticated`
-- role — the same things `0001_init.sql` itself requires to apply at all.

\set ON_ERROR_STOP on

-- Becomes `who` for the statements that follow: the role the policies name,
-- carrying the claim `auth.uid()` reads.
create or replace function pg_temp.acting_as(who uuid)
returns void language plpgsql as $$
begin
    reset role;
    perform set_config('request.jwt.claims',
                       json_build_object('sub', who, 'role', 'authenticated')::text,
                       false);
    execute 'set role authenticated';
end $$;

-- Drops back to the owning role, which bypasses RLS, for seeding and cleanup.
create or replace function pg_temp.acting_as_owner()
returns void language plpgsql as $$
begin
    reset role;
    perform set_config('request.jwt.claims', '', false);
end $$;

-- Asserts that `stmt` — a select — returns exactly `want` rows.
create or replace function pg_temp.must_see(stmt text, want bigint, label text)
returns void language plpgsql as $$
declare got bigint;
begin
    execute format('select count(*) from (%s) s', stmt) into got;
    if got <> want then
        raise exception 'POLICY WRONG: % — saw % row(s), expected %', label, got, want;
    end if;
    raise notice 'ok   % (% row(s))', label, got;
end $$;

-- Asserts that `stmt` — an insert, update or delete — touches exactly `want`
-- rows. A refusal that silently touches none is the failure this names.
create or replace function pg_temp.must_touch(stmt text, want bigint, label text)
returns void language plpgsql as $$
declare got bigint;
begin
    execute stmt;
    get diagnostics got = row_count;
    if got <> want then
        raise exception 'POLICY WRONG: % — touched % row(s), expected %', label, got, want;
    end if;
    raise notice 'ok   % (% row(s))', label, got;
end $$;

-- Asserts that `stmt` is refused outright, with an error rather than silence.
-- `with check` violations raise; `using` violations do not, which is exactly
-- why the two helpers above are separate.
create or replace function pg_temp.must_raise(stmt text, label text)
returns void language plpgsql as $$
begin
    begin
        execute stmt;
    exception when others then
        raise notice 'ok   refused: %', label;
        return;
    end;
    raise exception 'POLICY WRONG: % was allowed', label;
end $$;

-- ---------------------------------------------------------------------------
-- Seed. Ada and Grace are friends and share a match; Alan is a stranger to
-- both and is the reader every "sees zero" assertion below uses.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as_owner();

insert into auth.users (id) values
    ('11111111-1111-1111-1111-111111111111'),
    ('22222222-2222-2222-2222-222222222222'),
    ('33333333-3333-3333-3333-333333333333')
on conflict do nothing;

insert into public.profiles (id, display_name, friend_code) values
    ('11111111-1111-1111-1111-111111111111', 'Ada',   'AAAA1111'),
    ('22222222-2222-2222-2222-222222222222', 'Grace', 'BBBB2222'),
    ('33333333-3333-3333-3333-333333333333', 'Alan',  'CCCC3333')
on conflict do nothing;

insert into public.friendships (requester_id, addressee_id, status, responded_at) values
    ('11111111-1111-1111-1111-111111111111',
     '22222222-2222-2222-2222-222222222222', 'accepted', now())
on conflict do nothing;

insert into public.matches (id, host_id, invite_code, wire_version, seed, options, status, started_at)
values ('99999999-9999-9999-9999-999999999999',
        '11111111-1111-1111-1111-111111111111',
        'ABC123', 3, 7, '{}'::jsonb, 'playing', now())
on conflict do nothing;

insert into public.match_players (match_id, player_id) values
    ('99999999-9999-9999-9999-999999999999', '11111111-1111-1111-1111-111111111111'),
    ('99999999-9999-9999-9999-999999999999', '22222222-2222-2222-2222-222222222222')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- profiles — public to anyone signed in, writable only by their owner.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');

-- Deliberately public: a friend code is looked up by someone who is not yet a
-- friend. If this ever returns zero, friend-code search silently finds nobody.
select pg_temp.must_see(
    $$select 1 from public.profiles$$, 3,
    'a stranger reads every profile');

select pg_temp.must_see(
    $$select 1 from public.profiles where friend_code = 'AAAA1111'$$, 1,
    'a stranger looks up a friend code');

-- The silent one. `using` refuses the row, so this is not an error — it is an
-- update that reports success and changes nothing.
select pg_temp.must_touch(
    $$update public.profiles set display_name = 'stolen'
      where id = '11111111-1111-1111-1111-111111111111'$$, 0,
    'a stranger cannot rename another player');

select pg_temp.must_raise(
    $$insert into public.profiles (id, display_name, friend_code)
      values ('44444444-4444-4444-4444-444444444444', 'Fake', 'DDDD4444')$$,
    'a profile inserted under an id that is not the caller');

select pg_temp.acting_as('11111111-1111-1111-1111-111111111111');

select pg_temp.must_touch(
    $$update public.profiles set display_name = 'Ada L.'
      where id = '11111111-1111-1111-1111-111111111111'$$, 1,
    'a player renames themselves');

-- ---------------------------------------------------------------------------
-- friendships — visible to the two ends and to nobody else.
-- ---------------------------------------------------------------------------

select pg_temp.must_see(
    $$select 1 from public.friendships$$, 1,
    'the requester reads their own friendship');

select pg_temp.acting_as('22222222-2222-2222-2222-222222222222');

select pg_temp.must_see(
    $$select 1 from public.friendships$$, 1,
    'the addressee reads the same friendship');

select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');

-- The friends-page failure in its exact form: not an error, just nothing.
select pg_temp.must_see(
    $$select 1 from public.friendships$$, 0,
    'a stranger reads no friendship');

select pg_temp.must_raise(
    $$insert into public.friendships (requester_id, addressee_id, status)
      values ('11111111-1111-1111-1111-111111111111',
              '33333333-3333-3333-3333-333333333333', 'pending')$$,
    'a friendship requested in somebody else''s name');

select pg_temp.must_touch(
    $$delete from public.friendships
      where requester_id = '11111111-1111-1111-1111-111111111111'$$, 0,
    'a stranger cannot delete a friendship');

-- ---------------------------------------------------------------------------
-- matches — host and joined players only.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as('11111111-1111-1111-1111-111111111111');
select pg_temp.must_see(
    $$select 1 from public.matches$$, 1,
    'the host reads their match');

select pg_temp.acting_as('22222222-2222-2222-2222-222222222222');
select pg_temp.must_see(
    $$select 1 from public.matches$$, 1,
    'a joined player reads the match');

select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');

-- Joining is what grants the read, so the invite code is the capability: a
-- stranger who has not joined cannot see the row even knowing its code.
select pg_temp.must_see(
    $$select 1 from public.matches where invite_code = 'ABC123'$$, 0,
    'a stranger cannot read a match by its invite code');

select pg_temp.must_touch(
    $$update public.matches set status = 'abandoned'
      where id = '99999999-9999-9999-9999-999999999999'$$, 0,
    'a stranger cannot abandon a match');

select pg_temp.must_raise(
    $$insert into public.matches (host_id, invite_code, wire_version, seed, options, status)
      values ('11111111-1111-1111-1111-111111111111',
              'ZZZ999', 3, 7, '{}'::jsonb, 'lobby')$$,
    'a match hosted in somebody else''s name');

-- ---------------------------------------------------------------------------
-- match_players — the lobby roster, readable inside the match only.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as('22222222-2222-2222-2222-222222222222');
select pg_temp.must_see(
    $$select 1 from public.match_players$$, 2,
    'a player reads the whole roster of their match');

select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');
select pg_temp.must_see(
    $$select 1 from public.match_players$$, 0,
    'a stranger reads no roster');

select pg_temp.must_raise(
    $$insert into public.match_players (match_id, player_id)
      values ('99999999-9999-9999-9999-999999999999',
              '11111111-1111-1111-1111-111111111111')$$,
    'a player dragged into a match by somebody else');

-- Alan may add himself — and that read is what then opens the roster to him,
-- which is the capability working as designed rather than a leak.
select pg_temp.must_touch(
    $$insert into public.match_players (match_id, player_id)
      values ('99999999-9999-9999-9999-999999999999',
              '33333333-3333-3333-3333-333333333333')$$, 1,
    'a player adds themselves to a match');

select pg_temp.must_see(
    $$select 1 from public.match_players$$, 3,
    'joining opens the roster');

select pg_temp.must_touch(
    $$delete from public.match_players
      where player_id = '11111111-1111-1111-1111-111111111111'$$, 0,
    'a player cannot remove somebody else from a match');

select pg_temp.acting_as_owner();

select 'ALL RLS POLICIES BEHAVE' as result;
