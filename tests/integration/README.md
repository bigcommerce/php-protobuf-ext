# Integration test — keyed multi-pool descriptor cache

Proves the [keyed multi-pool descriptor cache patch](../../docs/multi-pool-descriptor-cache.md)
works end-to-end, in the only environment that can exercise it: a **persistent FastCGI
worker**. The fixed behavior is inherently cross-request (the pool must survive
`RSHUTDOWN`→`RINIT`), so a `.phpt` (single CLI request) or `php -S` can't reproduce it.

## Stack

- **php** — `php:8.4-fpm-bookworm` with the protobuf extension built from this repo's own
  `src/` (so the test always covers the committed patch). `pm=static`, `pm.max_children=1`
  → one worker, making cross-request reuse deterministic.
  `protobuf.keep_descriptor_pool_after_request=1`.
- **web** — nginx mapping the `x-release` header to a release docroot. Each release's
  `public/.user.ini` carries its `protobuf.descriptor_pool_key`. Unknown release → 400.

| Release  | Proto pkg | key   | Role                                                            |
|----------|-----------|-------|----------------------------------------------------------------|
| `v1-foo` | v1        | `v1`  | First load of pool `v1`.                                       |
| `v1-bar` | v1        | `v1`  | Different release, same key → must **reuse** `v1-foo`'s pool.  |
| `v2`     | v2        | `v2`  | Conflicting proto (same FQCN, extra `id`) → separate, coexists.|
| `compat` | v1        | *none*| Empty key → unkeyed/upstream persistence; its pool must survive keyed and `keep=0` interleaving. |
| `keep0`  | v1        | `keep0` + `keep=0` | Key set but `keep_descriptor_pool_after_request=0` → key ignored; fully isolated request-local pool (UAF + isolation regression guard). |

The keys `v1`/`v2` stand in for production `composer.lock` checksums.

## Run

```bash
bash tests/integration/run.sh   # builds, waits, asserts, tears down; prints PASS / exits non-zero
```

Needs Docker + Compose (the script auto-detects `docker compose` vs `docker-compose`).

## What it asserts

- **Same key = reuse** — `v1-bar`'s `before v1=true` proves it adopted the pool `v1-foo`
  built, across two distinct releases, with no rebuild.
- **Different key = coexistence** — `v2` sees `v1=false`, exposes its own `id` field, and a
  warm alternation loop between `v1-foo`/`v2` never 500s (the prevented "No such property"
  fatal would surface as a non-zero `curl -f`).
- **Empty key = backward compatible and durable** — `compat` (no `.user.ini`) works on the
  unkeyed persistent path, and its pool survives interleaved keyed requests (`before v1=true`
  after the alternation loop — previously each unkeyed→keyed transition leaked/clobbered it)
  and interleaved `keep=0` requests.
- **Key + `keep=0` = no use-after-free, fully isolated** — `keep0` sets a key but disables
  persistence, so the key is ignored and a fresh request-local pool is used; two consecutive
  requests must both succeed with an empty `before` (a `keep=0` request must never adopt —
  or destroy — a persistent pool). Before the fix the first request registered a keyed pool
  that `RSHUTDOWN` freed, crashing the second.

To confirm the harness actually detects the bug, temporarily set `v2`'s `.user.ini` key to
`v1` (forcing both protos onto one pool) — `run.sh` should then FAIL on the `v2` request.

> Note: this stack runs the FPM worker under `MALLOC_PERTURB_` (see `docker-compose.yml`) so a
> freed-then-reused pool reads poisoned memory and the `keep0` check fails deterministically
> rather than relying on a chance segfault. A dedicated, lighter-weight guard for the same bug
> lives in `tests/uaf/` (built into the CI `uaf` job).
