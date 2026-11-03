#!/usr/bin/env node
'use strict'

/**
 * HELLO ARM — Node.js + Fastify, clustered.
 *
 * The exact handler of the reference benchmark, unchanged:
 *
 *     fastify.get('/', schema, (_req, reply) => reply.send({ hello: 'world' }))
 *
 * with Fastify's response schema doing the serialisation, so the Node arm pays the
 * same "serialise a tiny object into JSON" cost the PHP arm pays in `json_encode()`.
 * The body is byte-identical to the PHP arms' `{"hello":"world"}`.
 *
 * Three things are deliberately *not* the Fastify benchmark's shape:
 *
 *   `--cluster reuseport`
 *       The reference deployment is `pm2 start server.js -i max`, which is the
 *       `cluster` module with a master that accepts and hands each connection to a
 *       worker. That master is one extra hop per connection and one extra process on
 *       a 12-core box. `reusePort` lets the kernel place each connection instead, so
 *       there is no master in the data path. On a hello page this is the difference
 *       between measuring a load balancer and measuring the runtime, so the harness
 *       measures both and names which one each row is.
 *
 *   `host: 127.0.0.1`
 *       The reference listens on `127.0.0.1:3000`. It is kept, because listening on
 *       `0.0.0.0` adds an interface lookup the PHP arms do not pay.
 *
 *   `keepAliveTimeout`
 *       Raised from Fastify's 72 s default explicitly, so no row can be decided by a
 *       connection closing mid-run. Keep-alive itself is on by default, as it is for
 *       every other arm.
 *
 * Usage:
 *     node apps/hello/fastify-hello.js --port 18410 --workers 12 --cluster reuseport
 *     node apps/hello/fastify-hello.js --port 18410 --workers 12 --cluster cluster
 *     node apps/hello/fastify-hello.js --port 18410 --workers 1      # single process
 *
 * It prints one readiness line on stdout once every worker is listening, which is
 * what the harness waits for rather than guessing with a sleep.
 */

const cluster = require('node:cluster')
const path = require('node:path')
const http = require('node:http')

const argv = process.argv.slice(2)
const opt = (name, fallback) => {
  const i = argv.indexOf(`--${name}`)
  return i === -1 ? fallback : argv[i + 1]
}

const PORT = Number(opt('port', 18410))
const HOST = opt('host', '127.0.0.1')
// Held at parity with the PHP arm's process count: a comparison between 12 PHP
// processes and 4 Node ones would be a comparison of core usage.
const WORKERS = Number(opt('workers', 1))
// 'none' (single process), 'cluster' (master accepts and distributes), 'reuseport'
// (kernel places each connection, no master in the data path).
const MODE = opt('cluster', 'none')

if (MODE !== 'none' && MODE !== 'cluster' && MODE !== 'reuseport') {
  console.error(`unknown --cluster value ${JSON.stringify(MODE)}; use none, cluster or reuseport`)
  process.exit(2)
}

/**
 * The benchmark's own handler, verbatim.
 *
 * `schema` is Fastify's response schema, which compiles to a serialiser — the reason
 * this is not a plain `JSON.stringify`. Dropping it would make the Node arm cheaper
 * than the reference it exists to represent, and the PHP arm has no equivalent
 * shortcut to take.
 */
function build () {
  const fastify = require('fastify')({
    // Explicit rather than inherited: no row may be decided by a keep-alive timeout.
    keepAliveTimeout: 72_000,
    // No per-request logging. The PHP arms write no log line per request either, and a
    // logger in the hot path would be a cost one arm pays and the other does not.
    logger: {
      level: 'warn',
      disableRequestLogging: true,
    },
  })

  const schema = {
    schema: {
      response: {
        200: {
          type: 'object',
          properties: {
            hello: { type: 'string' },
          },
        },
      },
    },
  }

  fastify.get('/', schema, function (_req, reply) {
    reply.send({ hello: 'world' })
  })

  return fastify
}

/**
 * Start one Fastify instance.
 *
 * `listen` is given the raw `reusePort` option because Fastify passes `listenOptions`
 * straight to `server.listen()`; the option exists in Node >= 22 and throws `ENOTSUP`
 * on a kernel or platform without `SO_REUSEPORT`, which is reported rather than
 * swallowed.
 */
async function start (fastify) {
  const listenOptions = { port: PORT, host: HOST }
  if (MODE === 'reuseport') {
    listenOptions.reusePort = true
  }

  await fastify.listen(listenOptions)
}

/** One process: build the app, listen, and stay up. */
function serveOne () {
  const fastify = build()

  return start(fastify)
    .then(() => {
      // One line per process, so the harness can count the pool it actually got
      // instead of trusting the number it asked for.
      console.log(`hello: pid ${process.pid} listening on http://${HOST}:${PORT} (${MODE})`)
    })
    .catch((err) => {
      console.error(`hello: listen failed on ${HOST}:${PORT}: ${err.message}`)
      process.exit(1)
    })
}

/**
 * `mode` decides who owns the listening socket, and the two answers are genuinely
 * different servers rather than two settings:
 *
 *   none       one process, one socket. The floor.
 *   reuseport  N independent processes, each binding the same port with
 *              `SO_REUSEPORT`, so the kernel places each connection. No master exists
 *              and nothing is forwarded, so the data path is exactly one process.
 *   cluster    N workers behind one master that accepts and hands each connection
 *              over. This is `pm2 -i max`; the master is in the path and on the CPU.
 *
 * `reuseport` uses `cluster` only as a process manager — `cluster.setupPrimary({ exec:
 * __filename })` re-runs this same file with `HELLO_SERVE=1`, which is Node's own way
 * of saying "this is a worker" without a third source of truth about the process role.
 */
function startReusePort () {
  cluster.setupPrimary({ exec: __filename })

  for (let i = 0; i < WORKERS; i++) {
    cluster.fork({ HELLO_SERVE: '1' })
  }

  cluster.on('exit', (worker, code, signal) => {
    console.error(`hello: worker ${worker.process.pid} exited (${signal || code})`)
    // The harness stops the pool with a signal to the process group, so an exit after
    // that is expected. Anything else is replaced rather than left to quietly shrink
    // the pool mid-measurement.
    if (!shuttingDown) {
      cluster.fork({ HELLO_SERVE: '1' })
    }
  })

  console.log(`hello: ${WORKERS} reuseport workers started on http://${HOST}:${PORT}`)
}

let shuttingDown = false

const IS_REUSEPORT_WORKER = MODE === 'reuseport' && process.env.HELLO_SERVE === '1'

if (MODE === 'cluster' && cluster.isPrimary) {
  // The reference shape's master. Node's default scheduling policy hands each
  // accepted connection to a worker round-robin, so this master IS in the data path.
  for (let i = 0; i < WORKERS; i++) {
    cluster.fork()
  }

  cluster.on('exit', (worker, code, signal) => {
    console.error(`hello: worker ${worker.process.pid} exited (${signal || code})`)
    if (!shuttingDown) {
      cluster.fork()
    }
  })

  console.log(`hello: ${WORKERS} cluster workers listening on http://${HOST}:${PORT}`)
} else if (MODE === 'reuseport' && !IS_REUSEPORT_WORKER) {
  startReusePort()
} else {
  // A `reuseport` worker, a `cluster` worker, or the single-process mode. All three
  // are one Fastify instance on one socket; only the ownership of the port differs.
  serveOne()
}

/**
 * Stop cleanly.
 *
 * `SO_REUSEPORT` sockets are independent, so a signal to the group closes every one
 * of them; the harness sends `SIGTERM` to the process group for that reason. A
 * cluster master also has to stop the forked workers it owns.
 */
function shutdown (signal) {
  if (shuttingDown) return
  shuttingDown = true

  for (const worker of Object.values(cluster.workers || {})) {
    if (worker) worker.kill(signal)
  }

  process.exit(0)
}

process.on('SIGTERM', () => shutdown('SIGTERM'))
process.on('SIGINT', () => shutdown('SIGINT'))
