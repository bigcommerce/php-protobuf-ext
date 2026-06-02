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

echo "backward compatibility: empty key still works"
expect compat  'name=Version 1'
expect compat  'name=Version 1'

echo "routing guard: unknown release is rejected"
reject nope

echo "PASS"
