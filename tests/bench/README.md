# Benchmark — pure PHP vs ext vs ext + descriptor-pool cache

Compares three protobuf runtimes over an identical synthetic schema and workload:

| Config        | Extension | INI                                                            | What it represents                          |
|---------------|-----------|----------------------------------------------------------------|---------------------------------------------|
| `pure-php`    | not loaded| —                                                              | `google/protobuf` pure-PHP runtime          |
| `ext-nocache` | loaded    | `keep_descriptor_pool_after_request=0`                         | C extension, pool rebuilt every request     |
| `ext-cache`   | loaded    | `descriptor_pool_key=bench` + `keep_descriptor_pool_after_request=1` | C extension + [keyed multi-pool cache](../../docs/multi-pool-descriptor-cache.md) |

All three run the **same** generated code and workload; only *(extension loaded? / INI)*
differ. The extension is built from this repo's own `src/`.

## What's measured

Two vehicles, because the cache and the codec are different costs:

- **End-to-end** — a persistent `php -S` worker (one process; every HTTP request is a full
  `RINIT`/`RSHUTDOWN`, the same persistence mechanism an FPM worker uses, which is why the
  integration stack pins `pm.max_children=1`). Each request builds the descriptor pool, then
  does `CODEC_ITERS` encode/decode round-trips. Reports **cold** (first request) vs **warm**
  (steady-state) latency, split into a **build** phase and a **codec** phase.
- **In-process** — a CLI loop that builds the pool once, then round-trips messages
  `CLI_REPS` times. Isolates raw codec speed (ext vs pure PHP); the cache is a **no-op** here
  (nothing is rebuilt), so `ext-nocache` and `ext-cache` should tie.

The cache's benefit lives entirely in the **warm build phase**: `ext-cache` builds the pool
once per worker (`bwarm_ms` ≈ 0), while `ext-nocache` rebuilds it on every request.

> Why `php -S` and not FPM here: the cache lives in module globals that persist identically
> under both, and a single deterministic worker removes fastcgi/nginx/worker-pool variance —
> a cleaner instrument for the per-request build cost. For production-shaped **throughput**
> (concurrent workers, req/s under load), drive the FPM stack in `../integration` with a load
> tool instead.

## Run

```bash
bash tests/bench/run.sh                       # builds image, runs all three configs, prints a table
SCHEMA_MSG_COUNT=300 WARM_REQ=80 bash tests/bench/run.sh   # bigger schema => bigger cache win
```

Needs Docker. Knobs (env): `SCHEMA_MSG_COUNT` (default 150), `CODEC_ITERS` (200),
`WARM_REQ` (50), `CLI_REPS` (5000). Everything generated (`.proto`, codegen, `vendor/`) is
produced at run time and git-ignored.

## Reading the table

```
config        cold_ms  wp50_ms  wp95_ms  bcold_ms  bwarm_ms  codec_ms  cli_us/op  mem_kb
```

- `cold_ms` — first-request latency; pool is built fresh in every config (cache can't help the first hit).
- `wp50_ms` / `wp95_ms` — warm per-request latency percentiles.
- `bcold_ms` / `bwarm_ms` — descriptor-pool build phase, cold vs warm. **The cache shows up as `ext-cache` warm ≈ 0 vs `ext-nocache` warm = full build.**
- `codec_ms` — warm per-request encode/decode time.
- `cli_us/op` — in-process per round-trip codec time (ext ≪ pure PHP; the two ext configs tie).

Expected shape: `pure-php` slowest everywhere; `ext-nocache` fast codec but pays the build
every request; `ext-cache` fast codec **and** near-zero warm build → lowest warm latency, with
the gap over `ext-nocache` widening as `SCHEMA_MSG_COUNT` grows.
