<?php
// Emit a synthetic proto3 schema with N message types to STDOUT.
//
// Each message carries a mix of scalar, repeated and map fields plus a nested
// reference to the previous message, so the file's descriptor set is non-trivial
// -- that descriptor-pool build is the per-request cost the keyed cache amortizes.
// Larger N => larger pool => bigger gap between ext-nocache and ext-cache.

$n = (int)($argv[1] ?? 150);
if ($n < 1) {
    $n = 1;
}

$out = "syntax = \"proto3\";\n\npackage bench;\n\n";
for ($i = 0; $i < $n; $i++) {
    $out .= "message Msg$i {\n";
    $out .= "  int32  num_a  = 1;\n";
    $out .= "  int64  num_b  = 2;\n";
    $out .= "  string text   = 3;\n";
    $out .= "  bool   flag   = 4;\n";
    $out .= "  double ratio  = 5;\n";
    $out .= "  repeated string    tags   = 6;\n";
    $out .= "  map<string, int32> counts = 7;\n";
    if ($i > 0) {
        $out .= "  Msg" . ($i - 1) . " child = 8;\n";
    }
    $out .= "}\n\n";
}

// A fixed-name root message the codec phase always targets, so the workload never
// has to discover or load all N classes (which would dwarf the codec cost). It
// references Msg0 to exercise nested encoding/decoding.
$out .= "message Root {\n";
$out .= "  int32  num_a  = 1;\n";
$out .= "  int64  num_b  = 2;\n";
$out .= "  string text   = 3;\n";
$out .= "  bool   flag   = 4;\n";
$out .= "  double ratio  = 5;\n";
$out .= "  repeated string    tags   = 6;\n";
$out .= "  map<string, int32> counts = 7;\n";
$out .= "  Msg0 child = 8;\n";
$out .= "}\n";

fwrite(STDOUT, $out);
