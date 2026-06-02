<?php
// V1 release: TestProto\TestMessage has only `name`.
// The `before` line probes the persistent descriptor pool *before* this request
// constructs anything — that's the cross-request reuse proof.
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
$m->setName('Version 1');
echo "name=" . $m->getName() . "\n";

echo "after v1=" . $has('v1.TestMessage') . " v2=" . $has('v2.TestMessage') . "\n";
