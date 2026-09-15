#!/usr/bin/env bash
# One-shot: apply 0006 to the live project and prove it there.
#
# 0006 re-creates `record_outcome` so a win with a null elapsed time (a resign
# win) leaves `fastest_win_seconds` alone, then clears every recorded fastest
# win. Old builds always send a number, so applying this before the client
# change is safe; a client that sends null against 0004 records a 1-second win,
# so this must land before any build carrying the `final` lane's item 2.
#
# Refuses to run twice: the trailing reset must happen once, not on every run.
# Do NOT use `supabase db push` on this project — its migration history is
# empty (0001–0005 were applied by scripts like this one), so push would try to
# re-run all of them.
# Reads the database password from the worktree that captured it during setup.
set -uo pipefail
cd "$(dirname "$0")/.."

PW=$(grep '^SUPABASE_DB_PASSWORD=' ~/willagrams-wt/fnd/Willagrams/.env | cut -d= -f2-)
URL="postgresql://postgres.ynkayuwwrifluhhqnrjc@aws-0-us-west-2.pooler.supabase.com:5432/postgres"
run() { PGPASSWORD="$PW" psql -v ON_ERROR_STOP=1 -q "$URL" "$@"; }
q() { PGPASSWORD="$PW" psql -Aqt -v ON_ERROR_STOP=1 "$URL" -c "$1"; }
guarded() { q "select position('elapsed_seconds is not null' in prosrc) > 0
                 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and proname = 'record_outcome'"; }

echo "== before =="
echo "  profiles: $(q 'select count(*) from public.profiles')"
echo "  with a fastest win: $(q 'select count(*) from public.profiles where fastest_win_seconds is not null')"
if [ "$(guarded)" = "t" ]; then
  echo "  record_outcome already has the null guard — 0006 is applied. Stopping."
  exit 0
fi

echo
echo "== applying 0006_fastest_win_skips_null.sql (one transaction) =="
run -1 -f supabase/migrations/0006_fastest_win_skips_null.sql || { echo "APPLY FAILED — nothing changed"; exit 1; }
echo "applied."

echo
echo "== after (want: guard t, secdef t, 0 fastest wins) =="
echo "  null guard present: $(guarded)"
echo "  security definer: $(q "select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and proname = 'record_outcome'")"
echo "  anon can execute: $(q "select has_function_privilege('anon', 'public.record_outcome(boolean, integer, integer)', 'execute')") (want f)"
echo "  with a fastest win: $(q 'select count(*) from public.profiles where fastest_win_seconds is not null')"
