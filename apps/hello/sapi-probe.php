<?php
// What does the *serving* interpreter look like? Written to a file rather than echoed, because
// a CGI response body is the last place this can be read reliably, and php-fpm rewrites the
// output path once `catch_workers_output` is on.
$s = @opcache_get_status(false);
$out = [
    'sapi'          => PHP_SAPI,
    'pid'           => getmypid(),
    'opcache_on'    => ($s !== false && !empty($s['opcache_enabled'])) ? 'yes' : 'NO',
    'used_bytes'    => $s['memory_usage']['used_memory'] ?? -1,
    'free_bytes'    => $s['memory_usage']['free_memory'] ?? -1,
    'cached_scripts'=> $s['opcache_statistics']['num_cached_scripts'] ?? -1,
    'hits'          => $s['opcache_statistics']['hits'] ?? -1,
    'misses'        => $s['opcache_statistics']['misses'] ?? -1,
    'start_time'    => $s['opcache_statistics']['start_time'] ?? -1,
    'validate_ts'   => ini_get('opcache.validate_timestamps'),
    'enable_cli'    => ini_get('opcache.enable_cli'),
    'memory_limit'  => ini_get('memory_limit'),
];
$file = getenv('PROBE_OUT') ?: '/tmp/sapi-probe.txt';
file_put_contents($file, json_encode($out, JSON_PRETTY_PRINT) . "\n", FILE_APPEND);
header('Content-Type: application/json');
echo '{"hello":"world"}';
