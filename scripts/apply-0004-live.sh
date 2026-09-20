#!/usr/bin/env bash
# One-shot: apply 0004 to the live project and prove it there.
#   1. applies supabase/migrations/0004_record_outcome.sql
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

echo "== applying 0004_record_outcome.sql =="
run -f supabase/migrations/0004_record_outcome.sql || { echo "APPLY FAILED"; exit 1; }
echo "applied."

echo
echo "== function now on the project =="
run -c "select proname, prosecdef, proconfig from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' order by proname;"

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
