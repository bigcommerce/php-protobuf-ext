<?php
// In-process codec microbench (single CLI process). The pool is built once up
// front, so this isolates raw encode/decode speed: ext vs pure PHP. The cache
// makes no difference here (nothing is rebuilt), so ext-nocache and ext-cache
// should tie -- that's the point of running it alongside the end-to-end test.

require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/workload.php';

$reps = max(1, (int)($argv[1] ?? 5000));

bench_build();                       // one-time, not measured

$t0 = hrtime(true);
$bytes = bench_codec($reps);
$t1 = hrtime(true);

$us = ($t1 - $t0) / 1000.0;
echo json_encode([
    'ext'       => extension_loaded('protobuf'),
    'reps'      => $reps,
    'opcache'   => function_exists('opcache_get_status') && @opcache_get_status(false) !== false,
    'bytes'     => $bytes,
    'codec_us'  => $us,
    'us_per_op' => $us / $reps,
    'mem_kb'    => memory_get_peak_usage(true) / 1024.0,
]);
