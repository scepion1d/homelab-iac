#!/usr/bin/env python3
"""Tiny UDP/53 forwarder for the homelab DNS path.

Why this exists instead of macOS pf NAT:
    The original design used pf `rdr` to redirect LAN-bound UDP/53 traffic
    on the Mac's LAN IP to the Colima VM's vmnet IP. That works at the
    packet level on the wire (tcpdump shows clean request/reply pairs),
    but Windows clients silently dropped every reply with
    "INET: checksum is invalid" (pktmon DropReason on tcpip.sys L3/L4).
    Apple's pf is an old fork of OpenBSD pf; its `scrub` directive does
    NOT recompute UDP checksums after NAT rewrite, and the Wi-Fi driver
    doesn't expose the `txcsum` knob to disable hardware checksum offload.
    Result: NAT'd UDP packets ship with stale/zero checksums and stricter
    clients (Windows, mostly) toss them.

    A userspace forwarder dodges the whole class of bug: the kernel
    composes brand-new UDP packets for both directions, with correct
    checksums, just like any other socket app.

Behaviour:
    - Bind UDP/53 on DNS_LISTEN (default 0.0.0.0) on the Mac.
    - For each incoming query, open a fresh upstream socket to
      DNS_UPSTREAM:53 (the Colima VM IP), send the query, wait up to
      DNS_TIMEOUT seconds, send any reply back to the original client.
    - One thread per in-flight query. DNS lookups are short and
      low-volume on a home LAN; this is plenty.

Environment variables:
    DNS_LISTEN    bind address           (REQUIRED — use the Mac's LAN IP,
                                          not 0.0.0.0, because on macOS
                                          mDNSResponder owns the *:53
                                          wildcard when Internet Sharing
                                          is on. A specific-IP bind plus
                                          SO_REUSEPORT lets BSD route
                                          packets destined for the LAN
                                          IP to us and the rest to
                                          mDNSResponder.)
    DNS_UPSTREAM  upstream DNS IP        (REQUIRED — the Colima VM IP)
    DNS_PORT      listen + upstream port (default "53")
    DNS_TIMEOUT   upstream wait, seconds (default "5.0")
"""

from __future__ import annotations

import os
import socket
import sys
import threading


def handle(server: socket.socket, data: bytes, client: tuple, upstream: tuple,
           timeout: float) -> None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as up:
            up.settimeout(timeout)
            up.sendto(data, upstream)
            reply, _ = up.recvfrom(65535)
            server.sendto(reply, client)
    except socket.timeout:
        # Upstream silently dropped — let the client's resolver retry.
        pass
    except OSError as exc:
        sys.stderr.write(f"forward error for {client}: {exc}\n")


def main() -> int:
    listen_addr = os.environ.get("DNS_LISTEN", "0.0.0.0")
    try:
        upstream_addr = os.environ["DNS_UPSTREAM"]
    except KeyError:
        sys.stderr.write("DNS_UPSTREAM is required\n")
        return 2
    port = int(os.environ.get("DNS_PORT", "53"))
    timeout = float(os.environ.get("DNS_TIMEOUT", "5.0"))

    upstream = (upstream_addr, port)

    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Required to coexist with mDNSResponder, which holds the *:53 wildcard
    # whenever Internet Sharing (or some Apple discovery features) is on.
    # With SO_REUSEPORT + a specific local IP, BSD delivers packets whose
    # destination matches our address to us and leaves the rest to
    # mDNSResponder.
    if hasattr(socket, "SO_REUSEPORT"):
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    server.bind((listen_addr, port))
    sys.stderr.write(
        f"dns-proxy listening on {listen_addr}:{port} -> "
        f"{upstream_addr}:{port}\n"
    )
    sys.stderr.flush()

    while True:
        data, client = server.recvfrom(65535)
        t = threading.Thread(
            target=handle,
            args=(server, data, client, upstream, timeout),
            daemon=True,
        )
        t.start()


if __name__ == "__main__":
    sys.exit(main())
