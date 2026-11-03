#!/usr/bin/env python3
"""A FastCGI responder that answers every request with the hello page.

The `spawn_cgi` arm has always been measured with `php-cgi` behind it, so its
number has never separated the two things it charges for: volucer's own pool
(every slot started, watched, dialled, permit-counted and recycled by the same
code `php-cgi` gets) and PHP's per-request boot. `external` cannot answer that
question, because it starts nothing -- the row the harness calls `floor` is a
different backend kind with no supervision in it at all.

`spawn_cgi` can start any FastCGI program, not just `php-cgi`:

    kind = "spawn_cgi"
    command = "/usr/bin/python3 fcgi-dummy.py {address}"
    workers = 96
    concurrency = 1

So pointing it at this file gives the same pool, the same per-slot socket, the
same permits, the same startup wait and the same blocking client as the PHP arm,
with an application that does nothing. `spawn_cgi` - this is PHP; this - `upstream`
is the transport.

Deliberately the standard library and a hand-rolled record parser: the point is
to be the cheapest possible far end, and a framework here would put a second
application in the measurement.

    python3 fcgi-dummy.py unix:/run/volucer/cgi.0.sock

`spawn_cgi`'s `command` driver hands the address in the `unix:` form and also
exports `VOLUCER_FCGI_ADDRESS`, so this reads argv[1] and strips the prefix.

## The protocol, as volucer's client uses it

An 8-byte header per record -- version(1) type(1) requestId(2) contentLength(2)
paddingLength(1) reserved(1) -- then the content, then the padding. One request
is:

    BEGIN_REQUEST (1) -> PARAMS (4)* -> empty PARAMS -> STDIN (5)* -> empty STDIN

and the answer is `STDOUT (6)` records, an empty `STDOUT`, then `END_REQUEST (3)`
carrying the application status and `REQUEST_COMPLETE`.

## Why one connection at a time is enough

A slot admits `concurrency` requests at once, and this file is used with
`concurrency = 1`, which is what `php-cgi` can actually do per process. The pool
then keeps one warm connection per slot (`CgiPool::request` pops and pushes it),
so each process accepts exactly one connection and answers on it forever. Serving
them serially is therefore the whole job -- and if that assumption ever broke,
requests would queue in the listen backlog and show up as latency, not as a wrong
answer.
"""

import os
import socket
import sys

BODY = b'{"hello":"world"}'

# Built once. `Content-Length` is present because a CGI response without it makes
# the reader infer the end of the body from the end of the stream.
RESPONSE = (
    b"Status: 200 OK\r\n"
    b"Content-Type: application/json\r\n"
    b"Content-Length: " + str(len(BODY)).encode() + b"\r\n"
    b"\r\n" + BODY
)

FRAME_STDOUT = 6
FRAME_END = 3
FRAME_BEGIN = 1
FRAME_STDIN = 5


def frame(type_, request_id, content):
    return (
        bytes([1, type_])
        + request_id.to_bytes(2, "big")
        + len(content).to_bytes(2, "big")
        + b"\x00\x00"
        + content
    )


# The reply is the same for every request, and so is the frame around it.
STDOUT_FRAME = frame(FRAME_STDOUT, 0, RESPONSE)
END_FRAME = frame(FRAME_END, 0, b"\x00" * 8)


def serve(conn):
    buffered = b""
    open_request = 0
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            return
        buffered = buffered + chunk if buffered else chunk
        # Parse every whole record that has arrived. A partial header or a partial
        # content is normal -- the client writes a request as several records -- so
        # anything short stays buffered rather than being misread as a boundary.
        while len(buffered) >= 8:
            type_ = buffered[1]
            request_id = int.from_bytes(buffered[2:4], "big")
            content_length = int.from_bytes(buffered[4:6], "big")
            padding_length = buffered[6]
            total = 8 + content_length + padding_length
            if len(buffered) < total:
                break
            buffered = buffered[total:]
            if type_ == FRAME_BEGIN:
                open_request = request_id
            elif type_ == FRAME_STDIN:
                # Empty STDIN is the end of the request's input, which is when a
                # CGI application answers. PARAMS is only read to stay aligned.
                if content_length == 0 and open_request:
                    conn.sendall(STDOUT_FRAME)
                    conn.sendall(END_FRAME)
                    open_request = 0


def main():
    if len(sys.argv) < 2:
        print("usage: fcgi-dummy.py <address>", file=sys.stderr)
        return 2

    address = sys.argv[1]
    if address.startswith("unix:"):
        address = address[len("unix:") :]

    # A socket file left by a killed run makes the bind fail, and the symptom is a
    # server that will not start rather than a stale socket.
    try:
        os.unlink(address)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(address)
    server.listen(128)
    # The pool waits for this file before it connects, and `check` reports a slot
    # that never bound. Printed for the same reason `php-cgi` prints a banner.
    print(f"fcgi-dummy listening on {address}", flush=True)

    while True:
        conn, _ = server.accept()
        try:
            serve(conn)
        finally:
            conn.close()


if __name__ == "__main__":
    sys.exit(main() or 0)
