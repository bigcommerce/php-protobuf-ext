#!/usr/bin/env bash
#
# Host entry point: build the bench image (extension compiled from this repo) and
# run the three-way benchmark. Tunable via env, e.g.:
#
#   SCHEMA_MSG_COUNT=300 WARM_REQ=80 bash tests/bench/run.sh
#
set -euo pipefail
cd "$(dirname "$0")/../.."          # repo root (Dockerfile COPYs src/ from here)

docker build -f tests/bench/docker/Dockerfile -t protobuf-bench .
docker run --rm \
  -e SCHEMA_MSG_COUNT="${SCHEMA_MSG_COUNT:-150}" \
  -e CODEC_ITERS="${CODEC_ITERS:-200}" \
  -e WARM_REQ="${WARM_REQ:-50}" \
  -e CLI_REPS="${CLI_REPS:-5000}" \
  protobuf-bench
