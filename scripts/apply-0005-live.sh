#!/usr/bin/env bash
# One-shot: apply 0005 to the live project and prove it there.
#
# Unlike 0004 this one changes a schema Supabase owns: it adds two policies to
# `realtime.messages`. Nothing existing is dropped or narrowed — RLS on that
# table is already on with no policies, so today every private channel is denied
# and only public ones work. Adding these two can therefore only widen, and the
# only topics they can widen are `invites:*`. `match:*` is a public channel and
# is not consulted against them at all.
#
# The client half ships in the same commit. Until this script runs against the
# live project, a build carrying `config.isPrivate = true` has NO invites at
# all: the server denies the join and denies the broadcast. Apply first, then
# ship. Rolling back is `drop policy` on both, plus reverting the Swift.
#   1. applies supabase/migrations/0005_invite_topic_authorization.sql
#   2. runs both SQL fixtures twice, alternating order
#   3. reports whether `public` is left as it was found
#
# The project carries real rows from every live test run, so a raw table count
# says nothing about the fixtures. Count before and after and compare.
# Reads the database password from the worktree that captured it during setup.
set -uo pipefail
cd "$(dirname "$0")/.."

PW=$(grep '^SUPABASE_DB_PASSWORD=' ~/willagrams-wt/fnd/Willagrams/.env | cut -d= -f2-)
URL="postgresql://postgres.ynkayuwwrifluhhqnrjc@aws-0-us-west-2.pooler.supabase.com:5432/postgres"
run() { PGPASSWORD="$PW" psql -v ON_ERROR_STOP=1 -q "$URL" "$@"; }

# The client sends invites with `httpSend`, which posts to
# `/realtime/v1/api/broadcast/{topic}/events/{event}` — an endpoint Realtime
# only grew in 2.97.0. On an older server every send throws and there is no
# fallback, so invites break outright for everyone. Probe before touching
# anything: a 404 is "that endpoint does not exist", and anything else means it
# does. The probe writes nothing — it goes to the nil uuid's topic as `anon`,
# which the policies below grant nothing to, so it is refused by design.
echo "== can this project's Realtime serve httpSend? =="
ANON=$(grep '^SUPABASE_ANON_KEY=' ~/willagrams-wt/fnd/Willagrams/.env | cut -d= -f2-)
BASE=$(grep '^SUPABASE_URL=' ~/willagrams-wt/fnd/Willagrams/.env | cut -d= -f2-)
PROBE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "$BASE/realtime/v1/api/broadcast/invites:00000000-0000-0000-0000-000000000000/events/probe?private=true" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H 'content-type: application/json' -d '{}')
if [ "$PROBE" = "404" ]; then
  echo "  REALTIME TOO OLD — no per-event broadcast endpoint (HTTP 404)."
  echo "  Do not ship the client half: every invite would throw. Stopping."
  exit 1
fi
echo "  endpoint present (HTTP $PROBE) — httpSend has something to talk to."
echo
counts() { PGPASSWORD="$PW" psql -Aqt "$URL" -c "select
    (select count(*) from public.profiles) || '/' ||
    (select count(*) from public.matches) || '/' ||
    (select count(*) from public.match_players) || '/' ||
    (select count(*) from public.friendships)"; }

# Measured after each pass, not before the first: a previously aborted run can
# leave its seed rows on the project, and pass 1's own seed step clears them.
# Pass 1 against pass 2 is the comparison that means "cleans up after itself".
echo "project rows now (profiles/matches/match_players/friendships): $(counts)"
echo

echo "== applying 0005_invite_topic_authorization.sql =="
run -f supabase/migrations/0005_invite_topic_authorization.sql || { echo "APPLY FAILED"; exit 1; }
echo "applied."

echo
echo "== policies now on realtime.messages =="
run -c "select policyname, cmd, roles from pg_policies
         where schemaname = 'realtime' and tablename = 'messages'
         order by policyname;"

echo
echo "== functions now on the project =="
run -c "select proname, prosecdef, proconfig from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' order by proname;"

# The fixture's invite assertions insert into `realtime.messages` directly. On
# Supabase that table is partitioned by `inserted_at`, one partition per day,
# and a missing partition refuses the insert. Probe it inside a transaction that
# rolls back — nothing is committed, so nothing is broadcast — because the
# alternative is `ON_ERROR_STOP` aborting the fixture halfway through and
# leaving its seed rows on the project.
echo
echo "== can realtime.messages take a direct insert here? =="
if PGPASSWORD="$PW" psql -v ON_ERROR_STOP=1 -q "$URL" >/dev/null 2>&1 <<'SQL'
begin;
insert into realtime.messages (topic, extension, payload, event)
values ('invites:00000000-0000-0000-0000-000000000000', 'broadcast', '{}'::jsonb, 'probe');
rollback;
SQL
then
  echo "  yes — the invite assertions can run."
else
  echo "  NO — realtime.messages refused a direct insert."
  echo "  The two policies above are applied and are what protects the topic;"
  echo "  only the fixture's invite assertions cannot run here. Stopping before"
  echo "  the fixtures rather than aborting one halfway and leaving seed rows."
  echo "  The same assertions already pass on scratch: scripts/scratch-verify.sh"
  exit 1
fi

for pass in 1 2; do
  echo
  echo "== fixture pass $pass =="
  if [ "$pass" = 1 ]; then order="schema_invariants rls_behavior"; else order="rls_behavior schema_invariants"; fi
  for f in $order; do
    out=$(run -f "supabase/tests/$f.sql" 2>&1)
    echo "$out" | grep -E "ENFORCED|BEHAVE|ERROR" | sed "s/^/  $f: /"
  done
  eval "AFTER$pass=\$(counts)"
done

echo
echo "== assertion count (rls_behavior) =="
PGPASSWORD="$PW" psql -q "$URL" -f supabase/tests/rls_behavior.sql 2>&1 | grep -c "NOTICE:  ok"

echo
echo "== did the fixtures leave anything behind? =="
echo "  after pass 1: $AFTER1"
echo "  after pass 2: $AFTER2"
[ "$AFTER1" = "$AFTER2" ] && echo "  CLEAN — a pass leaves the project as it found it." \
                          || echo "  RESIDUE — the fixtures did not clean up."
