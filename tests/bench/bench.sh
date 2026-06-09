#!/usr/bin/env bash
#
# Benchmark driver (runs inside the bench container). Compares three configs over
# an identical synthetic schema + workload:
#
#   pure-php     -- no extension; google/protobuf pure-PHP runtime
#   ext-nocache  -- extension loaded, keep_descriptor_pool_after_request=0
#                   (pool rebuilt every request)
#   ext-cache    -- extension loaded, descriptor_pool_key + keep=1
#                   (pool built once per worker, reused)
#
# Two vehicles:
#   * end-to-end: a persistent `php -S` worker (one process, full RINIT/RSHUTDOWN
#     per request -- same persistence mechanism as an FPM worker). Measures cold
#     vs warm per-request latency and the build/codec split. This is the only
#     vehicle where the cache's win appears.
#   * in-process: a CLI loop that builds the pool once then round-trips messages,
#     isolating raw codec speed (ext vs pure PHP); the cache is a no-op here.
set -euo pipefail
cd "$(dirname "$0")"

MSG_COUNT=${SCHEMA_MSG_COUNT:-150}   # message types in the synthetic schema
HTTP_ITERS=${CODEC_ITERS:-200}       # codec round-trips per HTTP request
WARM_REQ=${WARM_REQ:-50}             # warm requests measured per config
CLI_REPS=${CLI_REPS:-5000}           # codec round-trips for the in-process microbench
PORT=${PORT:-9300}

SO="$(php-config --extension-dir)/protobuf.so"
[ -f "$SO" ] || { echo "FAIL: extension not built at $SO"; exit 1; }

echo ">> generating synthetic schema ($MSG_COUNT messages)"
mkdir -p app/proto app/gen
php gen_proto.php "$MSG_COUNT" > app/proto/bench.proto
protoc --php_out=app/gen --proto_path=app/proto app/proto/bench.proto

echo ">> installing pure-PHP runtime + building autoload"
( cd app && composer install --no-interaction --quiet && composer dump-autoload -o --quiet )

# Opcache on for every config (as a production FPM deployment runs it), so the
# generated PHP -- including the large GPBMetadata file -- is compiled once and the
# build phase measures runtime descriptor registration, not PHP recompilation.
# It's a no-op for the C-side descriptor build, which is what the cache amortizes.
opcache_args=( -dzend_extension=opcache -dopcache.enable_cli=1 -dopcache.jit=disable )

# Per-config `php -d` arguments (the extension is toggled here, nowhere else).
pure_args=( "${opcache_args[@]}" )
nocache_args=( "${opcache_args[@]}" -dextension="$SO" -dprotobuf.keep_descriptor_pool_after_request=0 )
cache_args=( "${opcache_args[@]}" -dextension="$SO" -dprotobuf.keep_descriptor_pool_after_request=1 \
             -dprotobuf.descriptor_pool_key=bench )

# Read numbers on stdin, print the p-th percentile (nearest-rank).
pctl() {
  sort -n | awk -v p="$1" '{a[NR]=$0} END{
    if (NR==0){print "NA"; exit}
    i=int((p/100)*NR); if(i<1)i=1; if(i>NR)i=NR; printf "%.2f", a[i]}'
}

# Pull one numeric field out of a JSON body (optionally scaled).
jget() { php -r '$j=json_decode($argv[1],true); printf("%.3f", $j[$argv[2]] * (float)$argv[3]);' "$1" "$2" "${3:-1}"; }

declare -A R_COLD R_WP50 R_WP95 R_BCOLD R_BWARM R_CODEC R_CLI R_MEM

run_config() {
  local name="$1"; local -n args="$2"
  echo; echo "================ $name ================"

  # ---- end-to-end: persistent php -S worker ----
  php -n "${args[@]}" -S 127.0.0.1:"$PORT" -t app/public >"/tmp/srv.$name.log" 2>&1 &
  local srv=$!
  local up=0
  for _ in $(seq 1 50); do
    if curl -fsS "127.0.0.1:$PORT/ping.php" >/dev/null 2>&1; then up=1; break; fi
    sleep 0.2
  done
  [ "$up" = 1 ] || { echo "FAIL: server '$name' did not start"; cat "/tmp/srv.$name.log"; kill $srv 2>/dev/null||true; exit 1; }

  # Cold request: first protobuf work this worker sees -> pool not yet built for
  # ANY config. (ext-cache pays the build here too; it just never pays it again.)
  local cb ct cj
  cb=$(curl -fsS -w '\n%{time_total}' "127.0.0.1:$PORT/bench.php?iters=$HTTP_ITERS")
  ct=$(printf '%s' "$cb" | tail -1); cj=$(printf '%s' "$cb" | sed '$d')
  R_COLD[$name]=$(awk -v t="$ct" 'BEGIN{printf "%.2f", t*1000}')
  R_BCOLD[$name]=$(jget "$cj" build_us 0.001)

  # Warm requests: steady state. ext-cache should show build_us ~ 0 (pool reused),
  # ext-nocache pays the full build every request.
  : > /tmp/warm.tot; : > /tmp/warm.build; : > /tmp/warm.codec
  local b tt j=""
  for _ in $(seq 1 "$WARM_REQ"); do
    b=$(curl -fsS -w '\n%{time_total}' "127.0.0.1:$PORT/bench.php?iters=$HTTP_ITERS")
    tt=$(printf '%s' "$b" | tail -1); j=$(printf '%s' "$b" | sed '$d')
    awk -v t="$tt" 'BEGIN{printf "%.3f\n", t*1000}' >> /tmp/warm.tot
    jget "$j" build_us 0.001 >> /tmp/warm.build; echo >> /tmp/warm.build
    jget "$j" codec_us 0.001 >> /tmp/warm.codec; echo >> /tmp/warm.codec
  done
  R_WP50[$name]=$(pctl 50 < /tmp/warm.tot)
  R_WP95[$name]=$(pctl 95 < /tmp/warm.tot)
  R_BWARM[$name]=$(pctl 50 < /tmp/warm.build)
  R_CODEC[$name]=$(pctl 50 < /tmp/warm.codec)
  R_MEM[$name]=$(jget "$j" mem_kb)

  kill $srv 2>/dev/null || true; wait 2>/dev/null || true

  # ---- in-process codec microbench ----
  local cli
  cli=$(php -n "${args[@]}" app/cli_bench.php "$CLI_REPS")
  R_CLI[$name]=$(jget "$cli" us_per_op)
}

run_config pure-php    pure_args
run_config ext-nocache nocache_args
run_config ext-cache   cache_args

echo
echo "##################################  RESULTS  ##################################"
echo "schema=$MSG_COUNT msgs | http codec iters/req=$HTTP_ITERS | warm reqs=$WARM_REQ | cli reps=$CLI_REPS"
echo
printf '%-13s %9s %9s %9s %11s %11s %9s %10s %9s\n' \
  config cold_ms wp50_ms wp95_ms bcold_ms bwarm_ms codec_ms cli_us/op mem_kb
printf '%-13s %9s %9s %9s %11s %11s %9s %10s %9s\n' \
  ------------- --------- --------- --------- ----------- ----------- --------- ---------- ---------
for n in pure-php ext-nocache ext-cache; do
  printf '%-13s %9s %9s %9s %11s %11s %9s %10s %9s\n' \
    "$n" "${R_COLD[$n]}" "${R_WP50[$n]}" "${R_WP95[$n]}" \
    "${R_BCOLD[$n]}" "${R_BWARM[$n]}" "${R_CODEC[$n]}" "${R_CLI[$n]}" "${R_MEM[$n]}"
done
echo
echo "cold_ms : first request latency (pool built fresh in every config)"
echo "wp50/95 : warm request latency percentiles (steady state)"
echo "bcold/bwarm_ms : descriptor-pool build phase, cold vs warm  <- the cache's effect"
echo "codec_ms: warm per-request encode/decode phase"
echo "cli_us/op: in-process per round-trip codec time (cache is a no-op here)"
