<?php
// End-to-end endpoint, one request = one full RINIT/RSHUTDOWN cycle under the
// persistent `php -S` worker. Splits the work into the descriptor-pool build
// phase (what the cache amortizes) and the codec phase, and reports both.

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/../workload.php';

$iters = max(1, (int)($_GET['iters'] ?? 200));

$t0 = hrtime(true);
bench_build();
$t1 = hrtime(true);
$bytes = bench_codec($iters);
$t2 = hrtime(true);

header('Content-Type: application/json');
echo json_encode([
    'ext'      => extension_loaded('protobuf'),
    'iters'    => $iters,
    'bytes'    => $bytes,
    'build_us' => ($t1 - $t0) / 1000.0,
    'codec_us' => ($t2 - $t1) / 1000.0,
    'total_us' => ($t2 - $t0) / 1000.0,
    'mem_kb'   => memory_get_peak_usage(true) / 1024.0,
]);
