#!/usr/bin/env bash
#
# Integration test for the keyed multi-pool descriptor cache patch (INFRA-25160).
#
# One persistent php-fpm worker (patched extension) behind nginx. The x-release
# header selects a release docroot whose .user.ini sets descriptor_pool_key.
# Each `expect` line fetches a release and lists the strings its response must
# contain; a missing string (or any HTTP 5xx, via curl -f) fails the run.

set -euo pipefail
cd "$(dirname "$0")"

readonly URL="http://localhost:8880/index.php"

# Prefer the compose plugin (v2); fall back to the standalone binary.
if docker compose version >/dev/null 2>&1; then
  compose() { docker compose "$@"; }
else
  compose() { docker-compose "$@"; }
fi

# get RELEASE             -> response body (curl -f turns an HTTP 5xx into a failure)
get() { curl -fsS -H "x-release: $1" "$URL"; }

# expect RELEASE WANT...  -> fetch RELEASE once; every WANT must appear in the body
expect() {
  local release=$1 body; shift
  body=$(get "$release")
  for want in "$@"; do
    if ! grep -qF "$want" <<<"$body"; then
      echo "FAIL [$release]: expected [$want] in:"
      echo "$body"
      exit 1
    fi
  done
}

# reject RELEASE          -> the request must NOT succeed
reject() {
  if get "$1" >/dev/null 2>&1; then
    echo "FAIL: [$1] should have been rejected"
    exit 1
  fi
}

bootstrap() {
  trap 'compose down -v >/dev/null 2>&1 || true' EXIT
  compose up -d --build
  # Poll via compat (unkeyed) so the keyed v1/v2 pools stay cold for the cold round.
  echo "waiting for stack..."
  for _ in $(seq 1 60); do
    if get compat >/dev/null 2>&1; then return; fi
    sleep 1
  done
  echo "FAIL: stack did not come up"
  compose logs
  exit 1
}

bootstrap

echo "cold round: fresh pools, separation, same-key reuse"
expect v1-foo  'before v1=false v2=false'  'after v1=true v2=false'  'name=Version 1'
expect v1-bar  'before v1=true v2=false'   'name=Version 1'          # reused v1-foo's pool
expect v2      'before v1=false v2=false'  'after v1=false v2=true'  'id=123 name=Version 2'

echo "warm alternation: pools coexist, no fatals"
for _ in 1 2 3; do
  expect v1-foo  'name=Version 1'
  expect v2      'id=123 name=Version 2'
done

echo "backward compatibility: empty key persists and survives keyed interleaving"
# The unkeyed persistent pool was first built by bootstrap's compat polls. It must
# still be alive here, after the keyed cold round + warm alternation: keyed requests
# must swap pools in and out without clobbering (leaking) the unkeyed one.
expect compat  'before v1=true v2=false'  'name=Version 1'
expect compat  'before v1=true v2=false'  'name=Version 1'

echo "use-after-free guard: key set + keep=0 (key ignored) is fully isolated"
# Regression for the keyed-cache UAF: with keep off, the key must be ignored and a
# fresh request-local pool used. Before the fix, the first request registered a keyed
# pool that RSHUTDOWN then freed, so the second same-key request reused freed memory
# and (under MALLOC_PERTURB_, see docker-compose.yml) failed. A keep=0 request must
# also never adopt (or destroy) the persistent unkeyed pool: its `before` is always
# empty, and the compat pool above stays intact afterwards.
expect keep0   'before v1=false v2=false'  'name=Version 1'
expect keep0   'before v1=false v2=false'  'name=Version 1'

echo "persistent unkeyed pool survived the keep=0 requests"
expect compat  'before v1=true v2=false'   'name=Version 1'

echo "routing guard: unknown release is rejected"
reject nope

echo "PASS"
