#!/bin/bash

cd $(dirname $0)

set -e

PORT=12345
TIMEOUT=10

./compile_extension.sh

run_test() {
  echo
  echo "Running multirequest test, args: $@"

  RUN_UNDER=""
  EXTRA_ARGS=""
  ARGS="-d xdebug.profiler_enable=0 -d display_errors=on -dextension=../ext/google/protobuf/modules/protobuf.so"

  for i in "$@"; do
    case $i in
      --valgrind)
        RUN_UNDER="valgrind --error-exitcode=1"
        shift
        ;;
      --keep_descriptors)
        EXTRA_ARGS="$EXTRA_ARGS -dprotobuf.keep_descriptor_pool_after_request=1"
        shift
        ;;
      --pool_key)
        # descriptor_pool_key selects the keyed multi-pool cache (only effective
        # together with keep_descriptor_pool_after_request). Two same-key requests
        # must not crash: with keep they reuse the cached pool; without keep the key
        # is ignored and the legacy unkeyed path runs. Either way, no use-after-free.
        EXTRA_ARGS="$EXTRA_ARGS -dprotobuf.descriptor_pool_key=multirequest"
        shift
        ;;
    esac
  done

  export ZEND_DONT_UNLOAD_MODULES=1
  export USE_ZEND_ALLOC=0
  rm -f nohup.out
  nohup $RUN_UNDER php $ARGS $EXTRA_ARGS -S localhost:$PORT multirequest.php >nohup.out 2>&1 &
  PID=$!

  if ! timeout $TIMEOUT bash -c "until echo > /dev/tcp/localhost/$PORT; do sleep 0.1; done" > /dev/null 2>&1; then
    echo "Server failed to come up after $TIMEOUT seconds"
    cat nohup.out
    exit 1
  fi

  seq 2 | xargs -I{} wget -nv http://localhost:$PORT/multirequest.result -O multirequest{}.result
  REQUESTS_SUCCEEDED=$?


  if kill $PID > /dev/null 2>&1 && [[ $REQUESTS_SUCCEEDED == "0" ]]; then
    wait
    echo "Multirequest test SUCCEEDED"
  else
    echo "Multirequest test FAILED"
    cat nohup.out
    exit 1
  fi
}

run_test
run_test --keep_descriptors
run_test --valgrind
run_test --valgrind --keep_descriptors

# Keyed multi-pool cache. --pool_key alone (keep unset) is the regression test for
# the use-after-free where RINIT registered a keyed pool in pool_cache that
# RSHUTDOWN then freed, crashing the second same-key request.
run_test --pool_key
run_test --pool_key --keep_descriptors
run_test --valgrind --pool_key
run_test --valgrind --pool_key --keep_descriptors
