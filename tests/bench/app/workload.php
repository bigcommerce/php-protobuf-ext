<?php
// Shared workload. Identical across all three configs; only the runtime (pure PHP
// vs extension) and INI differ.

// Register the whole schema's descriptors into the pool. This is one
// internalAddGeneratedFile() call -- exactly the work the descriptor-pool cache
// amortizes: a cold pool parses + compiles every message def; a cached (persistent)
// pool finds the file already present and returns early (see add_descriptor() in
// def.c). The generated initOnce() guard is reset every request, so PHP calls in
// every request regardless -- the saving is entirely on the C side.
function bench_build(): void {
    \GPBMetadata\Bench::initOnce();
}

// Populate \Bench\Root (scalars + repeated + map + a nested Msg0) and round-trip
// it $iters times. Pure encode/decode -- where the C extension beats pure PHP and
// the cache is irrelevant (the pool is already built). Targets one fixed class so
// codec cost isn't polluted by autoloading N generated files.
function bench_codec(int $iters): int {
    $bytes = 0;
    for ($k = 0; $k < $iters; $k++) {
        $m = new \Bench\Root();
        $m->setNumA(42);
        $m->setNumB(1 << 33);
        $m->setText('the quick brown fox jumps over the lazy dog');
        $m->setFlag(true);
        $m->setRatio(3.14159265358979);

        $tags = $m->getTags();
        $tags[] = 'alpha';
        $tags[] = 'beta';
        $tags[] = 'gamma';

        $counts = $m->getCounts();
        $counts['x'] = 1;
        $counts['y'] = 2;

        $child = new \Bench\Msg0();
        $child->setText('child payload');
        $m->setChild($child);

        $data = $m->serializeToString();
        $bytes += strlen($data);

        $out = new \Bench\Root();
        $out->mergeFromString($data);
    }

    return $bytes;
}
