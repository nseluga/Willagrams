#!/usr/bin/env bash
# Run both SQL fixtures against a throwaway local database.
#
# The fixtures need what Supabase supplies and plain Postgres does not: an
# `auth` schema, an `auth.uid()` that reads the current request, and the three
# roles the grants name. This stubs exactly that and nothing else, so a rule
# that only passes because of the stub is a rule that would fail on Supabase.
set -euo pipefail
cd "$(dirname "$0")/.."

DB=${1:-willagrams_scratch}
export PGHOST=localhost PGDATABASE=$DB

dropdb --if-exists -h localhost "$DB"
createdb -h localhost "$DB"

psql -q -v ON_ERROR_STOP=1 <<'SQL'
create schema if not exists auth;
-- Supabase's own definition, copied rather than approximated: it reads the
-- flattened claim first and falls back to the whole claims object. Shortening
-- it to the flat form alone makes every policy that names auth.uid() pass on
-- nothing, because the fixture sets the JSON form.
create or replace function auth.uid() returns uuid
language sql stable as $$
    select coalesce(
        nullif(current_setting('request.jwt.claim.sub', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
    )::uuid
$$;
create table if not exists auth.users (id uuid primary key);
do $$ begin
    if not exists (select 1 from pg_roles where rolname = 'anon')
        then create role anon nologin; end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated')
        then create role authenticated nologin; end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role')
        then create role service_role nologin bypassrls; end if;
end $$;
grant usage on schema auth to anon, authenticated, service_role;

-- Supabase grants the API roles table privileges by default and gates reads
-- with RLS instead. 0001_init.sql contains no grants because it inherits this.
-- Reproduce it the way Supabase does, so the fixture exercises policies rather
-- than missing grants.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public
    grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
    grant all on sequences to anon, authenticated, service_role;

-- What Realtime Authorization needs and plain Postgres does not: the table the
-- policies in 0005 attach to, and the function they read the topic out of.
-- Supabase's own definitions, again copied rather than approximated —
-- realtime.topic() reads a GUC the Realtime server sets before it evaluates a
-- policy, and the fixture sets the same GUC.
--
-- One deliberate difference: on Supabase `realtime.messages` is partitioned by
-- `inserted_at` with a partition per day. That matters to retention and to
-- nothing the policies say, and a stub that reproduced it would be reproducing
-- Supabase's cron rather than testing a rule. Plain table here.
create schema if not exists realtime;
create or replace function realtime.topic() returns text
language sql stable as $$
    select nullif(current_setting('realtime.topic', true), '')::text
$$;
create table if not exists realtime.messages (
    id          uuid not null default gen_random_uuid(),
    topic       text not null,
    extension   text not null,
    event       text,
    payload     jsonb,
    private     boolean default false,
    inserted_at timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);
grant usage on schema realtime to anon, authenticated, service_role;
grant all on realtime.messages to anon, authenticated, service_role;
grant execute on function realtime.topic() to anon, authenticated, service_role;
SQL

for f in supabase/migrations/*.sql; do
    printf '  %-40s' "$(basename "$f")"
    psql -q -v ON_ERROR_STOP=1 -f "$f" >/dev/null && echo ok
done

echo
for pass in 1 2; do
    echo "== fixture pass $pass =="
    for t in schema_invariants rls_behavior; do
        printf '  %-20s' "$t"
        psql -q -v ON_ERROR_STOP=1 -f "supabase/tests/$t.sql" 2>&1 \
            | grep -E 'ERROR|ENFORCED|ALL .* HOLD|^psql:' | tail -3 || echo ok
    done
done

echo
echo "== assertions run =="
psql -q -v ON_ERROR_STOP=1 -f supabase/tests/rls_behavior.sql 2>&1 \
    | grep -c 'NOTICE:  ok' || true

echo "== rows the fixtures left behind (want all zero) =="
psql -At -c "select
    (select count(*) from public.profiles),
    (select count(*) from public.matches),
    (select count(*) from public.match_players),
    (select count(*) from public.friendships)"
