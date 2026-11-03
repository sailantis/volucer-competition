'use strict'

/**
 * A FastCGI responder that answers every request with the hello page.
 *
 * It exists to isolate one thing: **what does the `spawn_cgi` arm cost before PHP is
 * involved?** `spawn_cgi` and `external` reach the same `CgiPool` and the same
 * blocking FastCGI client, differ only in who owns the far end, and both are
 * `RequestScope::PerRequest`. So pointing an `external` backend at this responder and
 * at `php-fpm` measures PHP's cost; pointing it at this responder and at nothing else
 * measures the *floor* of the FastCGI path — the socket, the record framing, the
 * `spawn_blocking` hop and the CGI header translation, with an application that does
 * no work at all.
 *
 * That floor is the number `spawn_cgi` should be read against. Without it, a
 * `spawn_cgi` figure cannot say whether the transport or the framework is expensive.
 *
 *     node apps/hello/cgi-echo.js <unix-socket-path>
 *
 * ## How many processes
 *
 * `--workers n` forks `n` responders sharing the listening socket (`cluster`, with
 * `SCHED_NONE` so each child accepts on its own rather than having the primary hand fds
 * over). It defaults to one.
 *
 * **The count decides the arm's ceiling, so it is measured rather than picked.** 96
 * `spawn_cgi` slots dialling this responder, `wrk -t12 -c100`, 14 s on the 12-core bench
 * host:
 *
 *     workers=1      50,423 rps   be 20.0 us   fe 39.6 us      33 MB
 *     workers=2      94,282 rps   be 21.3 us   fe 39.1 us      72 MB
 *     workers=4     119,306 rps   be 25.4 us   fe 41.4 us     103 MB
 *     workers=12     86,073 rps   be 40.3 us   fe 57.8 us     237 MB
 *     workers=96    ~18,000 rps   be 156  us   fe 345  us   1,494 MB
 *
 * One process is one core's worth of work, so it caps the arm at about half the client's
 * headroom. Above four the arm goes *backwards*: the host has eight gigabytes, and a few
 * hundred Node processes on it cost more in scheduler churn than they return. Four is the
 * default the harness passes.
 *
 *     node apps/hello/cgi-echo.js <unix-socket-path> [--workers N]
 *
 * Deliberately raw `net` and a hand-rolled record parser rather than any framework:
 * the point is to measure the protocol path, and a framework here would be measuring
 * a second application.
 *
 * ## The protocol, as volucer's client uses it
 *
 * An 8-byte header per record — version(1) type(1) requestId(2) contentLength(2)
 * paddingLength(1) reserved(1) — then the content, then the padding. One request is:
 *
 *     BEGIN_REQUEST (1)  ->  PARAMS (4)*  ->  empty PARAMS  ->  STDIN (5)*  ->  empty STDIN
 *
 * and the answer is `STDOUT (6)` records, an empty `STDOUT`, then `END_REQUEST (3)`
 * carrying the application status and `REQUEST_COMPLETE`. Connections are reused:
 * volucer keeps one warm connection per slot and sends the next request on it, so the
 * reader is a loop rather than one-shot.
 */

const net = require('net')

const BODY = '{"hello":"world"}'

// Built once. `Content-Length` is present because a CGI response without it makes the
// reader infer the end of the body from the end of the stream, which works and costs a
// branch on every request.
const RESPONSE = Buffer.from(
  `Status: 200 OK\r\n` +
    `Content-Type: application/json\r\n` +
    `Content-Length: ${Buffer.byteLength(BODY)}\r\n` +
    `\r\n` +
    BODY,
)

// The reply is the same for every request, and so is the frame around it. Precomputing
// it keeps this responder from becoming the thing under test: `STDOUT` + empty
// `STDOUT` + `END_REQUEST`.
const STDOUT_FRAME = frame(6, 0, RESPONSE)
const END_FRAME = frame(3, 0, Buffer.from([0, 0, 0, 0, 0, 0, 0, 0]))

function frame(type, requestId, content) {
  const header = Buffer.alloc(8)
  header[0] = 1 // version
  header[1] = type
  header.writeUInt16BE(requestId, 2)
  header.writeUInt16BE(content.length, 4)
  header[6] = 0 // padding length
  header[7] = 0 // reserved
  return Buffer.concat([header, content])
}

/** State per connection: bytes not yet parsed, and the request being read. */
function handle(socket) {
  let buffered = Buffer.alloc(0)
  // The id of the request whose input half is still streaming, so its answer knows
  // which id to carry. volucer sends one request at a time per connection, so a single
  // slot is enough — and if that ever changed, the assert below would say so loudly
  // rather than silently answering the wrong request.
  let openRequest = 0

  socket.setNoDelay(true)
  socket.on('error', () => {
    /* a peer that goes away mid-request is the client's business */
  })

  socket.on('data', (chunk) => {
    buffered = buffered.length === 0 ? chunk : Buffer.concat([buffered, chunk])

    // Parse as many whole records as have arrived. A partial header or a partial
    // content is normal — the client writes a request as several records — so anything
    // short stays buffered rather than being misread as a frame boundary.
    while (buffered.length >= 8) {
      const type = buffered[1]
      const requestId = buffered.readUInt16BE(2)
      const contentLength = buffered.readUInt16BE(4)
      const paddingLength = buffered[6]
      const total = 8 + contentLength + paddingLength
      if (buffered.length < total) break

      buffered = buffered.subarray(total)

      switch (type) {
        case 1: // BEGIN_REQUEST — a new request on this connection
          openRequest = requestId
          break
        case 4: // PARAMS — read only to keep the stream aligned
          break
        case 5: // STDIN — empty marks the end of the request's input
          if (contentLength === 0 && openRequest !== 0) {
            if (openRequest !== requestId) {
              throw new Error(
                `interleaved requests on one connection (${openRequest} then ${requestId})`,
              )
            }
            socket.write(STDOUT_FRAME)
            socket.write(END_FRAME)
            openRequest = 0
          }
          break
        case 2: // ABORT_REQUEST
          openRequest = 0
          break
        default:
          // `GET_VALUES` and friends are not sent by a request-path client.
          break
      }
    }
  })
}

const path = process.argv[2]
if (!path) {
  console.error('usage: node cgi-echo.js <unix-socket-path> [--workers N]')
  process.exit(2)
}

// `--workers` is the responder count and defaults to 1. `cluster` here rather than
// `worker_threads`, because the thing under test is one process per connection and a
// thread pool would share an event loop the way 96 `php-cgi` processes do not.
const workersArg = process.argv.indexOf('--workers')
const workers = workersArg === -1 ? 1 : Math.max(1, Number(process.argv[workersArg + 1]) || 1)

if (workers > 1) {
  const cluster = require('node:cluster')
  // **`SCHED_NONE`, not the default.** Node's default on Linux is `SCHED_RR`: the primary
  // keeps the listening socket, accepts every connection itself, and hands the fd to a
  // child over a pipe. That puts one event loop in front of all the others — the exact
  // bottleneck this arm is supposed to remove — so the children are given the listening
  // socket directly and each accepts on its own. A unix socket has no `SO_REUSEPORT` to
  // set; the shared descriptor is what the kernel's accept queue gives us for free.
  cluster.schedulingPolicy = cluster.SCHED_NONE
  if (cluster.isPrimary) {
    for (let i = 0; i < workers; i += 1) cluster.fork()
    cluster.on('exit', (worker) => {
      console.error(`cgi-echo worker ${worker.process.pid} exited; reforking`)
      cluster.fork()
    })
    return
  }
}

// `unlink` first: a socket file left by a killed run makes the bind fail, and the
// symptom is a server that will not start rather than a stale socket. Only the primary
// does it when clustering, or the children would race and one would remove the socket
// the others are already listening on.
if (workers <= 1 || require('node:cluster').isPrimary) {
  try {
    require('fs').unlinkSync(path)
  } catch (err) {
    if (err.code !== 'ENOENT') throw err
  }
}

net.createServer(handle).listen(path, () => {
  console.log(`cgi-echo listening on ${path} (pid ${process.pid})`)
})
