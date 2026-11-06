#!/usr/bin/env python3
"""A FastCGI responder that stalls its first request, then behaves.

The branch's fix claims three things, and only the first can be shown from a shell:

  1. a backend that accepts and never answers now ends on `request_timeout_ms`;
  2. the slot comes *back* afterwards -- the worker is replaced and the pool serves again;
  3. a streamed response whose body stalls mid-way is bounded too, not just its head.

`fcgi-stall.py` proves (1) by never answering. This proves (2), which is the property that
actually decides whether a stalled backend shrinks the pool one request at a time: the same
slot has to be replaced and reused **inside one run**, so the responder has to be pathological
exactly once and healthy afterwards.

    python3 fcgi-stall-once.py unix:/run/x/cgi.0.sock [stalls]

`stalls` is how many requests to hold open before answering normally (default 1). Framing is
copied from `fcgi-dummy.py` rather than re-derived: an earlier attempt here hand-rolled it and
produced `unknown FastCGI record type 0`, which was a bug in the probe, not in the server.
"""

import os
import socket
import sys

BODY = b'{"hello":"world"}'
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


STDOUT_FRAME = frame(FRAME_STDOUT, 0, RESPONSE)
END_FRAME = frame(FRAME_END, 0, b"\x00" * 8)


def serve(conn, stalls_left, held):
    """Serve one connection forever, stalling the first `stalls_left` requests."""
    buffered = b""
    open_request = 0
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            return stalls_left
        buffered = buffered + chunk if buffered else chunk
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
            elif type_ == FRAME_STDIN and content_length == 0 and open_request:
                open_request = 0
                if stalls_left > 0:
                    # Hold the connection open and answer nothing. The client's deadline is
                    # the only thing that can end this request.
                    stalls_left -= 1
                    held.append(conn)
                    return stalls_left
                conn.sendall(STDOUT_FRAME)
                conn.sendall(END_FRAME)


def main():
    address = sys.argv[1]
    stalls_left = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    if address.startswith("unix:"):
        address = address[len("unix:"):]

    try:
        os.unlink(address)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(address)
    server.listen(128)
    print(f"fcgi-stall-once listening on {address} (stalls {stalls_left})", flush=True)

    held = []
    while True:
        conn, _ = server.accept()
        try:
            stalls_left = serve(conn, stalls_left, held)
        except OSError:
            pass
        finally:
            # A stalled connection is deliberately NOT closed: closing it would be a broken
            # pipe, which is the easy case and the one the server already handled.
            if conn not in held:
                conn.close()


if __name__ == "__main__":
    sys.exit(main() or 0)
