#!/usr/bin/env python3
"""A FastCGI responder that accepts, reads the request, and then never answers.

Used to prove that an awaited slot is bounded. It deliberately does NOT close the
connection: a close would be a broken pipe, which is the easy case and the one every
version of this code already handled. Holding the request open is the failure that used to
park the future, the permit and the connection for ever.

  stall.py <address>       e.g. unix:/tmp/x/cgi.0.sock
"""
import os
import socket
import sys
import time


def bind(address: str) -> socket.socket:
    if not address.startswith("unix:"):
        raise SystemExit(f"only unix sockets are used here, got {address!r}")
    path = address[len("unix:"):]
    if os.path.exists(path):
        os.unlink(path)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    s.listen(16)
    return s


def main() -> None:
    srv = bind(sys.argv[1])
    held = []
    while True:
        conn, _ = srv.accept()
        # Read whatever arrives so the server's write completes, then park the connection
        # in a list rather than closing it. Nothing is ever written back.
        conn.settimeout(0.2)
        try:
            conn.recv(65536)
        except OSError:
            pass
        held.append(conn)
        # Keep the accept loop alive but stop growing without bound.
        if len(held) > 512:
            time.sleep(1.0)


if __name__ == "__main__":
    main()
