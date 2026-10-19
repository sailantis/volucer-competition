"""Hold a FastCGI connection open without saying anything.

Used by `diag-cgi-concurrency.sh` to create the one situation that decides whether a
`php-cgi` can be a supervisor: a *second* connection arriving while the first is
accepted and idle. A server that forks per connection, or that multiplexes, still
answers. A server that accepted one connection and is now blocked reading it cannot.
"""
import socket
import sys
import time

port = int(sys.argv[1])
hold = float(sys.argv[2])

sock = socket.create_connection(("127.0.0.1", port), timeout=10)
print("holding", flush=True)
time.sleep(hold)
sock.close()
