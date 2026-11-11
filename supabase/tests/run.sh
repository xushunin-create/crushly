#!/usr/bin/env bash
# Applies Supabase stubs + migration + seed to a throwaway postgres:16 container
# and runs the SQL tests. Exits non-zero on any failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NAME="crushly-sqltest-$(date +%s)-$RANDOM"
IMAGE="${POSTGRES_IMAGE:-postgres:16}"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker info >/dev/null 2>&1 || { echo "Docker daemon is not running" >&2; exit 2; }

docker run -d --name "$NAME" -e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" >/dev/null || exit 2
# During initdb the entrypoint runs a socket-only server; wait for TCP readiness.
for _ in $(seq 1 60); do
  docker exec "$NAME" psql -h 127.0.0.1 -U postgres -d postgres -qtAc 'select 1' >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$NAME" psql -h 127.0.0.1 -U postgres -d postgres -qtAc 'select 1' >/dev/null || { echo "postgres did not start" >&2; exit 2; }

docker exec "$NAME" mkdir -p /work
docker cp "$ROOT/." "$NAME:/work/" >/dev/null

PSQL=(docker exec -i "$NAME" psql -h 127.0.0.1 -U postgres -d postgres -X -q -v ON_ERROR_STOP=1)

apply() {
  local f="$1"
  if ! out="$("${PSQL[@]}" -f "/work/$f" 2>&1)"; then
    echo "$out"; echo "SETUP FAILED: $f" >&2; exit 1
  fi
  echo "applied $f"
}

apply tests/00_supabase_stubs.sql
for m in $(cd "$ROOT" && ls migrations/*.sql | sort); do apply "$m"; done
apply seed.sql
apply tests/01_test_helpers.sql

pass=0; fail=0; failed=(); asserts=0
for t in $(cd "$ROOT" && ls tests/[1-9]*.sql | sort); do
  if out="$("${PSQL[@]}" -f "/work/$t" 2>&1)"; then
    n=$(grep -c 'NOTICE:  ok - ' <<<"$out" || true)
    asserts=$((asserts + n)); pass=$((pass + 1))
    printf 'PASS  %-40s (%s assertions)\n' "$t" "$n"
  else
    fail=$((fail + 1)); failed+=("$t")
    printf 'FAIL  %s\n' "$t"
    grep -v 'NOTICE:  ok - ' <<<"$out" | sed 's/^/      /'
  fi
done

# Concurrency: two connections send reciprocal signals at the same time.
conc() {
  "${PSQL[@]}" -f /work/tests/concurrency/setup.sql >/dev/null || return 1
  local ids; ids="$("${PSQL[@]}" -tAc "select a || ' ' || b from tests.conc_pairs order by n")" || return 1
  local pids=() i=0
  while read -r a b; do
    i=$((i + 1))
    for pair in "$a $b" "$b $a"; do
      set -- $pair
      docker exec "$NAME" psql -h 127.0.0.1 -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 -tA \
        -c "begin; select tests.login('$1'); select public.send_heart_signal('$2')->>'result'; select pg_sleep(2); commit;" \
        > /dev/null &
      pids+=($!)
    done
  done <<<"$ids"
  local rc=0
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  [ $rc -eq 0 ] || { echo "      a concurrent send failed"; return 1; }
  "${PSQL[@]}" -f /work/tests/concurrency/verify.sql
}
if out="$(conc 2>&1)"; then
  n=$(grep -c 'NOTICE:  ok - ' <<<"$out" || true); asserts=$((asserts + n)); pass=$((pass + 1))
  printf 'PASS  %-40s (%s assertions)\n' "tests/concurrency" "$n"
else
  fail=$((fail + 1)); failed+=("tests/concurrency")
  printf 'FAIL  tests/concurrency\n'; grep -v 'NOTICE:  ok - ' <<<"$out" | sed 's/^/      /'
fi

echo "----"
echo "suites: $((pass + fail))  passed: $pass  failed: $fail  assertions: $asserts"
if [ $fail -ne 0 ]; then printf 'failed: %s\n' "${failed[*]}"; exit 1; fi
