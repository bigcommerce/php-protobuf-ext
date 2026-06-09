<?php
// Liveness probe for the bench driver. Does no protobuf work, so it never warms
// the descriptor pool -- the first bench.php hit stays a true cold request.
echo 'ok';
