#!/usr/bin/env bash
# Read-only: every CREATE POLICY attempt below is inside a transaction that
# rolls back, so nothing is left on the project either way.
#
# Answers: which role, if any, this connection can create a policy on
# realtime.messages as. `postgres` cannot — the table is owned by
# supabase_realtime_admin and postgres is not a member of it.
set -uo pipefail
cd "$(dirname "$0")/.."
PW=$(grep '^SUPABASE_DB_PASSWORD=' ~/willagrams-wt/fnd/Willagrams/.env | cut -d= -f2-)
URL="postgresql://postgres.ynkayuwwrifluhhqnrjc@aws-0-us-west-2.pooler.supabase.com:5432/postgres"
q() { PGPASSWORD="$PW" psql -Aqt "$URL" "$@"; }

echo "== role reachability =="
q <<'SQL'
select 'privileged_role -> realtime_admin: ' ||
       coalesce(pg_has_role('supabase_privileged_role','supabase_realtime_admin','USAGE')::text,'?');
select 'roles postgres can assume: ' || coalesce(string_agg(r.rolname, ', '), 'none')
  from pg_roles r where pg_has_role(current_user, r.oid, 'USAGE') and r.rolname <> current_user;
SQL

# Each attempt: set role (or not), create a throwaway policy, roll back.
try_as() {
  local label="$1" setrole="$2"
  printf '  %-34s' "$label"
  if PGPASSWORD="$PW" psql -v ON_ERROR_STOP=1 -q "$URL" >/dev/null 2>&1 <<SQL
begin;
$setrole
create policy zz_willagrams_probe on realtime.messages for select to authenticated using (false);
rollback;
SQL
  then echo "CAN create policies"; else echo "cannot"; fi
}

echo
echo "== can we create a policy on realtime.messages? (all rolled back) =="
try_as "as postgres" ""
try_as "set role supabase_privileged_role" "set local role supabase_privileged_role;"
try_as "set role supabase_realtime_admin" "set local role supabase_realtime_admin;"

echo
echo "== confirm nothing was left behind (want 0) =="
q -c "select count(*) from pg_policies where schemaname='realtime' and tablename='messages';"
