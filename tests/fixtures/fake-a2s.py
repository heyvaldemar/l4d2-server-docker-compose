"""A stand-in that speaks just enough A2S to test tools/healthcheck.sh. Not a server.

    python3 fake-a2s.py <mode> <port> <bind>

mode   answers    the info reply ('I') to every A2S_INFO
       challenge  S2C_CHALLENGE ('A' and four bytes, one of them NUL) first,
                  the info reply only to a query carrying those bytes
       challenge-nl  the same, with a newline byte (0x0a) in the challenge,
                  and the info reply only to one datagram of exactly the
                  query and the challenge (29 bytes)
       silent     binds the port and never answers
       noloop     answers, except a query from 127.0.0.1, as Left 4 Dead 2
                  bound to 0.0.0.0 did in CI
bind   an address, or "iface" for the container's own interface address,
       which is what srcds binds
"""
import socket
import sys

mode, port, bind = sys.argv[1], int(sys.argv[2]), sys.argv[3]
if bind == "iface":
    bind = socket.gethostbyname(socket.gethostname())
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((bind, port))
print("bound", bind, port, flush=True)
CHALLENGE = b"\x0a\x7f\xff\x41" if mode == "challenge-nl" else b"\x00\x7f\xff\x41"
QUERY = b"\xff\xff\xff\xffTSource Engine Query\x00"
INFO = b"\xff\xff\xff\xffI\x11stand-in\x00map\x00tf\x00stand-in\x00"
while True:
    data, peer = s.recvfrom(1400)
    print("seen", len(data), flush=True)
    if mode == "challenge-nl":
        if data == QUERY + CHALLENGE:
            s.sendto(INFO, peer)
        elif data == QUERY:
            s.sendto(b"\xff\xff\xff\xffA" + CHALLENGE, peer)
        continue
    if mode == "silent" or (mode == "noloop" and peer[0] == "127.0.0.1"):
        continue
    if mode == "challenge" and not data.endswith(CHALLENGE):
        s.sendto(b"\xff\xff\xff\xffA" + CHALLENGE, peer)
        continue
    s.sendto(INFO, peer)
