#!/bin/sh
# A private php-fpm pool for the `external_fpm` arm, and nothing else.
#
# Started directly with `-y -F`, so it never touches systemd, `pool.d`, or the host's own
# php-fpm — this harness runs the `fpm` arm eight times and must not reload a pool somebody
# else is serving from. The shape is copied from `matrix.sh`'s `cfg_fpm` deliberately: same
# `pm = static`, same `catch_workers_output`, same memory limit. Only `listen` and the two log
# paths differ, so `external_fpm` against `fpm` is the front-end and nothing else.
#
#   $1  pool file to write
#   $2  pm.max_children (= the arm's PHP process count)
#   $3  the unix socket to listen on
#   $4  the log directory
#   $5  opcache mode: on | off
#
# `php-fpm` reads `opcache.enable` at STARTUP — a `php_admin_flag[opcache.enable]` in the pool
# sets `ini_get()` to 0 while opcache stays active, because it is applied after the extension
# has already decided. That is measured, not assumed, and it is why the pool file itself cannot
# express the OFF mode. The value is passed to the master as `-d` by the caller instead, and
# every cell is proved inside the running server rather than trusted from the file.
set -eu

pool=$1
children=$2
socket=$3
logs=$4
mode=$5

cat > "$pool" <<EOF
; A private instance for this harness: no systemd, no pool.d, no sudo.
[global]
daemonize = no
error_log = $logs/fpm-ext-error.log

[bench]
listen = $socket
pm = static
pm.max_children = $children
pm.max_requests = 0

catch_workers_output = yes
php_admin_value[error_log] = $logs/fpm-ext-worker-error.log
php_admin_flag[log_errors] = on

php_admin_value[memory_limit] = 512M
php_admin_value[date.timezone] = UTC
EOF
