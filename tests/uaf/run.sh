#!/usr/bin/env bash
#
# Use-after-free guard for the keyed descriptor pool cache (deterministic).
#
# Builds the extension from this repo, then drives the keyed pool across requests
# via `php -S` + tests/uaf/router.php. The descriptor pool and name caches are
# allocated with malloc, so running under MALLOC_PERTURB_ poisons freed memory:
# if a request frees a pool the keyed cache still references, the next same-key
# request reuses poisoned memory and fails deterministically. (AddressSanitizer
# can't be used here: PHP dlopens extensions with RTLD_DEEPBIND, which the ASan
# runtime rejects, and instrumenting it would mean building PHP from source.)
#
# Run inside php:8.4-cli-bookworm with a build toolchain (autoconf gcc make curl);
# see .github/workflows/integration.yml.
#
# Three scenarios, all must pass cleanly:
#   1. key set, keep=0  -> key must be ignored (legacy path); the original UAF case
#   2. key set, keep=1  -> the production keyed path
#   3. key set, keep=1, one request ini_set-flips both INIs mid-request -> the
#      lifecycle decision is snapshotted at RINIT, so the flip must be a no-op;
#      if RSHUTDOWN re-read the INI it would free the cached pool (UAF next request)
set -euo pipefail
cd "$(dirname "$0")/../.."          # repo root
EXTDIR=src/php/ext/google/protobuf
PORT=9100

echo ">> building extension"
pushd "$EXTDIR" >/dev/null
phpize >/dev/null
./configure --with-php-config="$(which php-config)" CFLAGS="-g -O0 -DPBPHP_ENABLE_ASSERTS" >/dev/null
make -j"$(nproc)" >/dev/null
SO="$PWD/modules/protobuf.so"
popd >/dev/null
[ -f "$SO" ] || { echo "FAIL: protobuf.so not built"; exit 1; }

# MALLOC_PERTURB_ fills freed memory with a non-zero byte so any use-after-free
# reads garbage and fails instead of silently succeeding on intact stale memory.
# USE_ZEND_ALLOC=0 routes Zend allocations through malloc too. php -n skips
# php.ini/conf.d so only our extension is loaded.
export MALLOC_PERTURB_=165 USE_ZEND_ALLOC=0

run_scenario() {  # $1 = label  $2 = space-separated request paths  $3.. = extra php -d args
  local label="$1" paths="$2"; shift 2
  echo
  echo ">> scenario: $label"
  local log; log=$(mktemp)
  php -n -dextension="$SO" -dprotobuf.descriptor_pool_key=uaf "$@" \
      -S 127.0.0.1:$PORT tests/uaf/router.php >"$log" 2>&1 &
  local srv=$!
  local up=0
  for _ in $(seq 1 50); do
    if curl -fsS "127.0.0.1:$PORT/warmup" >/dev/null 2>&1; then up=1; break; fi
    sleep 0.2
  done
  [ "$up" = 1 ] || { echo "FAIL: server did not start"; cat "$log"; kill $srv 2>/dev/null || true; exit 1; }

  # Each request is a full RINIT/RSHUTDOWN cycle. A use-after-free surfaces as a
  # crashed/closed connection or an error response -> curl -f fails the run.
  local ok=1
  for p in $paths; do
    if body=$(curl -fsS "127.0.0.1:$PORT/$p" 2>/dev/null); then
      echo "   req $p: $body"
    else
      echo "   req $p: REQUEST FAILED (use-after-free)"; ok=0; break
    fi
  done
  kill $srv 2>/dev/null || true; wait 2>/dev/null || true

  [ "$ok" = 1 ] || { echo "FAIL: a request failed under MALLOC_PERTURB_"; exit 1; }
  echo "   PASS"
}

run_scenario "key set, keep=0 (key ignored; original UAF case)" \
  "r1 r2 r3 r4 r5"
run_scenario "key set, keep=1 (production keyed path)" \
  "r1 r2 r3 r4 r5" -dprotobuf.keep_descriptor_pool_after_request=1
run_scenario "key set, keep=1, mid-request ini_set flip (snapshot semantics)" \
  "r1 flip r3 r4 r5" -dprotobuf.keep_descriptor_pool_after_request=1

echo
echo "UAF GUARD PASS"
