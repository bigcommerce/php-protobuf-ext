<?php
// Use-after-free exerciser for the keyed descriptor pool cache.
//
// Served by `php -S` (see run.sh) so each HTTP request is a full RINIT/RSHUTDOWN
// cycle in one persistent process -- the only way to exercise cross-request pool
// behavior. Builds well-known-type descriptors into the (keyed) generated pool on
// every request; if a previous request freed a pool still referenced by the keyed
// cache, this request reuses that freed memory. Run under MALLOC_PERTURB_ (see
// run.sh) the freed memory is poisoned, so the reuse deterministically fails.
// Uses only built-in types, so no composer/vendor is required.

if (!extension_loaded('protobuf')) {
    http_response_code(500);
    echo "protobuf extension not loaded\n";
    return;
}

$ts  = new \Google\Protobuf\Timestamp();  $ts->setSeconds(42);
$dur = new \Google\Protobuf\Duration();   $dur->setSeconds(7);
$any = new \Google\Protobuf\Any();
$st  = new \Google\Protobuf\Struct();

echo "OK ts=" . $ts->getSeconds() . " dur=" . $dur->getSeconds() . "\n";
