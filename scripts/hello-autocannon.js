#!/usr/bin/env node
'use strict'

/**
 * The Fastify benchmark's own load generator, run as a cross-check.
 *
 * The arm this harness measures comes from a published comparison whose settings are
 * `autocannon -c 100 -d 40 -p 10`. Those settings are reproduced here exactly, because
 * the point of a cross-check is to be comparable to the thing being quoted — not to be
 * the best instrument available. `scripts/hello-bench.sh` uses `wrk` as its primary
 * instrument for the reasons recorded in `apps/hello/fastify-hello.js`: autocannon is a
 * single-threaded Node process, so on a 12-core box it saturates before a clustered
 * server does, and `-p 10` at `-c 100` leaves 1000 requests outstanding, which measures
 * queueing rather than serving.
 *
 * Output is one line per field, tab-separated, so a shell aggregator can read it:
 *
 *     rps     25403.1
 *     p50     3.1
 *     p99     9.4
 *     non2xx  0
 *
 * `non2xx` is reported rather than swallowed: a number produced by refusing requests is
 * not throughput, and the whole project's rule is that a shed request which reads as a
 * win is the one mistake a harness exists to prevent. A non-zero count is a failed cell.
 *
 * Usage:
 *     node scripts/hello-autocannon.js --url http://127.0.0.1:21312/ \
 *         --connections 100 --pipeline 10 --duration 10
 */

const autocannon = require('autocannon')

const argv = process.argv.slice(2)
const opt = (name, fallback) => {
  const i = argv.indexOf(`--${name}`)
  return i === -1 ? fallback : argv[i + 1]
}

const URL_ = opt('url')
const CONNECTIONS = Number(opt('connections', 100))
const PIPELINE = Number(opt('pipeline', 10))
const DURATION = Number(opt('duration', 10))

if (!URL_) {
  console.error('usage: hello-autocannon.js --url <url> [--connections 100] [--pipeline 10] [--duration 10]')
  process.exit(2)
}

// One second of unmeasured load before the clock starts. The pool has to be saturated
// before the first measured request, or the first sample of the first arm is a
// cold-start number, which is the asymmetry the rotation exists to remove.
const WARMUP_SECONDS = 2

function run (duration) {
  return new Promise((resolve, reject) => {
    autocannon(
      {
        url: URL_,
        connections: CONNECTIONS,
        pipelining: PIPELINE,
        duration,
      },
      (err, result) => {
        if (err) return reject(err)
        resolve(result)
      },
    )
  })
}

async function main () {
  // The warm-up is not a smaller run: `autocannon` opens and closes its own
  // connections per invocation, so a short run would pay the connect cost it exists to
  // remove. It is a full-length run whose numbers are discarded.
  await run(WARMUP_SECONDS)

  const result = await run(DURATION)

  const non2xx = (result.non2xx || 0) + (result.errors || 0)

  process.stdout.write(`rps\t${result.requests.average.toFixed(1)}\n`)
  process.stdout.write(`p50\t${result.latency.p50}\n`)
  process.stdout.write(`p99\t${result.latency.p99}\n`)
  process.stdout.write(`non2xx\t${non2xx}\n`)

  // A non-zero count is a failed cell, and exit code 1 is how the shell is told so.
  // Throughput from refused connections is not a measurement of the server, and a
  // shed request that reads as a win is the one mistake this harness exists to
  // prevent.
  if (non2xx > 0) process.exit(1)
}

main().catch((err) => {
  console.error(`hello-autocannon: ${err.message}`)
  process.exit(1)
})
