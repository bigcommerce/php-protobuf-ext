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
//
// A request to /flip additionally calls ini_set() on both protobuf INIs
// mid-request. The pool lifecycle decision must be taken once at request start
// (RINIT) and remembered; if request shutdown re-reads the INI instead, the
// flipped values make RSHUTDOWN free the pool that the keyed cache still
// references, and the next request is a use-after-free.

if (!extension_loaded('protobuf')) {
    http_response_code(500);
    echo "protobuf extension not loaded\n";
    return;
}

$ts  = new \Google\Protobuf\Timestamp();  $ts->setSeconds(42);
$dur = new \Google\Protobuf\Duration();   $dur->setSeconds(7);
$any = new \Google\Protobuf\Any();
$st  = new \Google\Protobuf\Struct();

$flip = str_contains($_SERVER['REQUEST_URI'] ?? '', 'flip');
if ($flip) {
    ini_set('protobuf.keep_descriptor_pool_after_request', '0');
    ini_set('protobuf.descriptor_pool_key', 'other');
}

echo "OK" . ($flip ? " (flipped)" : "") .
     " ts=" . $ts->getSeconds() . " dur=" . $dur->getSeconds() . "\n";
