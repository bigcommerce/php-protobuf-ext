<?php
// V2 release: TestProto\TestMessage has `id` + `name` (same FQCN as V1).
// Accessing the `id` field would fatal ("No such property") if a stale V1 pool
// were reused — so a successful response proves the V2 pool is separate.
header('Content-Type: text/plain');

// Minimal autoloader for this release's generated classes (mirrors Composer in
// production). getDescriptorByProtoName() resolves the PHP class for a found
// descriptor, so the class must be loadable on demand.
spl_autoload_register(function (string $class): void {
    $file = __DIR__ . '/../src/' . str_replace('\\', '/', $class) . '.php';
    if (is_file($file)) {
        require $file;
    }
});

$pool = \Google\Protobuf\Internal\DescriptorPool::getGeneratedPool();
$has  = fn(string $n) => var_export($pool->getDescriptorByProtoName($n) !== null, true);

echo "release=" . ($_SERVER['HTTP_X_RELEASE'] ?? '') . "\n";
echo "before v1=" . $has('v1.TestMessage') . " v2=" . $has('v2.TestMessage') . "\n";

$m = new \TestProto\TestMessage();
$m->setId(123);
$m->setName('Version 2');
echo "id=" . $m->getId() . " name=" . $m->getName() . "\n";

echo "after v1=" . $has('v1.TestMessage') . " v2=" . $has('v2.TestMessage') . "\n";
