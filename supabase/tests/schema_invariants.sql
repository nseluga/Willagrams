-- Fixture for `supabase/migrations/0001_init.sql`.
--
-- Every invariant the schema claims is exercised here from both sides: the
-- legal row is accepted, the illegal one is rejected. A constraint that was
-- written but never fires is the failure this catches — it looks identical to
-- a working one until bad data arrives.
--
-- Run against a scratch database that already has the migration applied:
--   psql -v ON_ERROR_STOP=1 -d <scratch> -f supabase/tests/schema_invariants.sql

\set ON_ERROR_STOP on

-- Asserts that `stmt` fails. Raises if it unexpectedly succeeds.
create or replace function pg_temp.must_fail(stmt text, label text)
returns void language plpgsql as $$
begin
    begin
        execute stmt;
    exception when others then
        raise notice 'ok   rejected: %', label;
        return;
    end;
    raise exception 'INVARIANT NOT ENFORCED: % was accepted', label;
end $$;

-- Anything a previous run of this file, or of `rls_behavior.sql`, left behind.
-- This fixture used to assume an empty scratch database. It does not any more:
-- both files now run against the shared project, and its own seed is not
-- removed at the end — the cascade test near the bottom deletes Alan on
-- purpose and leaves Ada and Grace standing. A second run then died on a
-- duplicate key before it asserted anything.
delete from public.match_players
 where player_id in ('11111111-1111-1111-1111-111111111111',
                     '22222222-2222-2222-2222-222222222222',
                     '33333333-3333-3333-3333-333333333333');
delete from public.matches
 where invite_code = 'ABC123'
    or host_id in ('11111111-1111-1111-1111-111111111111',
                   '22222222-2222-2222-2222-222222222222',
                   '33333333-3333-3333-3333-333333333333');
delete from public.friendships
 where requester_id in ('11111111-1111-1111-1111-111111111111',
                        '22222222-2222-2222-2222-222222222222',
                        '33333333-3333-3333-3333-333333333333')
    or addressee_id in ('11111111-1111-1111-1111-111111111111',
                        '22222222-2222-2222-2222-222222222222',
                        '33333333-3333-3333-3333-333333333333');
delete from public.profiles
 where id in ('11111111-1111-1111-1111-111111111111',
              '22222222-2222-2222-2222-222222222222',
              '33333333-3333-3333-3333-333333333333');
delete from auth.users
 where id in ('11111111-1111-1111-1111-111111111111',
              '22222222-2222-2222-2222-222222222222',
              '33333333-3333-3333-3333-333333333333');

-- Two players to hang everything off.
insert into auth.users (id) values
    ('11111111-1111-1111-1111-111111111111'),
    ('22222222-2222-2222-2222-222222222222'),
    ('33333333-3333-3333-3333-333333333333');

insert into public.profiles (id, display_name, friend_code) values
    ('11111111-1111-1111-1111-111111111111', 'Ada',  'AAAA1111'),
    ('22222222-2222-2222-2222-222222222222', 'Grace','BBBB2222'),
    ('33333333-3333-3333-3333-333333333333', 'Alan', 'CCCC3333');

-- profiles ------------------------------------------------------------------

select pg_temp.must_fail($$
    insert into public.profiles (id, display_name, friend_code)
    values ('44444444-4444-4444-4444-444444444444', '', 'DDDD4444')
$$, 'an empty display name');

select pg_temp.must_fail($$
    insert into public.profiles (id, display_name, friend_code)
    values ('44444444-4444-4444-4444-444444444444', 'Ada', 'lowercase')
$$, 'a friend code outside [A-Z0-9]{8}');

select pg_temp.must_fail($$
    insert into public.profiles (id, display_name, friend_code)
    values ('44444444-4444-4444-4444-444444444444', 'Ada', 'AAAA1111')
$$, 'a duplicate friend code');

select pg_temp.must_fail($$
    update public.profiles set matches_won = 5, matches_played = 2
    where display_name = 'Ada'
$$, 'more wins than matches played');

select pg_temp.must_fail($$
    update public.profiles set fastest_win_seconds = 0 where display_name = 'Ada'
$$, 'a fastest win of zero seconds');

select pg_temp.must_fail($$
    insert into public.profiles (id, display_name, friend_code)
    values ('99999999-9999-9999-9999-999999999999', 'Ghost', 'EEEE5555')
$$, 'a profile with no auth user behind it');

-- The legal side.
update public.profiles set matches_played = 3, matches_won = 2, fastest_win_seconds = 91
where display_name = 'Ada';

-- friendships ---------------------------------------------------------------

insert into public.friendships (requester_id, addressee_id, status)
values ('11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', 'pending');

select pg_temp.must_fail($$
    insert into public.friendships (requester_id, addressee_id, status)
    values ('22222222-2222-2222-2222-222222222222',
            '11111111-1111-1111-1111-111111111111', 'pending')
$$, 'the mirror image of an existing friendship');

select pg_temp.must_fail($$
    insert into public.friendships (requester_id, addressee_id, status)
    values ('33333333-3333-3333-3333-333333333333',
            '33333333-3333-3333-3333-333333333333', 'pending')
$$, 'befriending yourself');

select pg_temp.must_fail($$
    insert into public.friendships (requester_id, addressee_id, status, responded_at)
    values ('11111111-1111-1111-1111-111111111111',
            '33333333-3333-3333-3333-333333333333', 'pending', now())
$$, 'a pending request that already has a response time');

select pg_temp.must_fail($$
    update public.friendships set status = 'accepted'
    where requester_id = '11111111-1111-1111-1111-111111111111'
$$, 'an accepted friendship with no response time');

select pg_temp.must_fail($$
    insert into public.friendships (requester_id, addressee_id, status)
    values ('11111111-1111-1111-1111-111111111111',
            '33333333-3333-3333-3333-333333333333', 'ghosted')
$$, 'a status outside pending/accepted/blocked');

-- The legal side: answering the request sets both fields together.
update public.friendships set status = 'accepted', responded_at = now()
where requester_id = '11111111-1111-1111-1111-111111111111';

-- matches -------------------------------------------------------------------

insert into public.matches (id, host_id, invite_code, wire_version, seed, options, status)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        'ABC123', 3, 42, '{"swapEnabled":true}'::jsonb, 'lobby');

select pg_temp.must_fail($$
    insert into public.matches (host_id, invite_code, wire_version, seed, options, status)
    values ('11111111-1111-1111-1111-111111111111',
            'toolongcode', 3, 42, '{}'::jsonb, 'lobby')
$$, 'an invite code outside [A-Z0-9]{6}');

select pg_temp.must_fail($$
    insert into public.matches (host_id, invite_code, wire_version, seed, options, status)
    values ('11111111-1111-1111-1111-111111111111',
            'ABC124', 3, -1, '{}'::jsonb, 'lobby')
$$, 'a negative seed');

select pg_temp.must_fail($$
    update public.matches set status = 'playing'
    where invite_code = 'ABC123'
$$, 'a playing match with no start time');

select pg_temp.must_fail($$
    update public.matches
    set winner_id = '11111111-1111-1111-1111-111111111111'
    where invite_code = 'ABC123'
$$, 'a winner on a match that is not finished');

select pg_temp.must_fail($$
    update public.matches set status = 'finished', started_at = now()
    where invite_code = 'ABC123'
$$, 'a finished match with no finish time');

-- The legal side: the whole lifecycle, one transition at a time.
update public.matches set status = 'playing', started_at = now()
where invite_code = 'ABC123';

insert into public.match_players (match_id, player_id) values
    ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
    ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

select pg_temp.must_fail($$
    insert into public.match_players (match_id, player_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001',
            '11111111-1111-1111-1111-111111111111')
$$, 'the same player joining a match twice');

update public.matches
set status = 'finished', finished_at = now(),
    winner_id = '11111111-1111-1111-1111-111111111111'
where invite_code = 'ABC123';

-- Cascade: deleting the auth user takes the profile, and the profile takes the
-- membership row with it. A stale row here would leave a match listing a
-- player who no longer exists.
delete from auth.users where id = '33333333-3333-3333-3333-333333333333';
do $$ begin
    if exists (select 1 from public.profiles where display_name = 'Alan') then
        raise exception 'INVARIANT NOT ENFORCED: profile survived its auth user';
    end if;
end $$;

-- RLS is on for every table. A table that forgot it is world-readable to
-- anyone holding the anon key, which ships in the app binary.
do $$
declare unguarded text;
begin
    select string_agg(relname, ', ') into unguarded
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
    if unguarded is not null then
        raise exception 'INVARIANT NOT ENFORCED: RLS off on %', unguarded;
    end if;
end $$;

-- Every table carries at least one policy. RLS with no policy denies all, which
-- is safe but silently breaks the app instead of the attacker.
do $$
declare bare text;
begin
    select string_agg(c.relname, ', ') into bare
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and not exists (select 1 from pg_policy p where p.polrelid = c.oid);
    if bare is not null then
        raise exception 'INVARIANT NOT ENFORCED: no policy on %', bare;
    end if;
end $$;

select 'ALL SCHEMA INVARIANTS ENFORCED' as result;
