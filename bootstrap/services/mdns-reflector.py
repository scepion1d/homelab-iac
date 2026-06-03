#!/usr/bin/env python3
"""mDNS reflector for the Colima -> LAN gap.

Why this exists
---------------
Home Assistant runs in a Docker container with ``network_mode: host``
inside the Colima VM. Its HomeKit Bridge announces ``_hap._tcp`` via
mDNS, but those multicast frames originate on the VM's network
namespace. The macOS host does NOT relay multicast between the vmnet
bridge interface (e.g. ``bridge100``, the Mac side of Colima's
``--network-address`` vmnet) and the physical LAN interface (e.g.
``en0``). Result: Apple TV on the LAN never discovers HA's HomeKit
Bridge, even though the underlying TCP path works (Colima auto-tunnels
host-network listeners, so ``mac-lan-ip:21063`` reaches HA).

This service:

1.  Browses for a small allowlist of service types on the vmnet bridge
    interface (where the VM's broadcasts land on the Mac).
2.  For every discovered service, re-registers an equivalent
    ``ServiceInfo`` on the LAN interface, with:

    * IPv4 addresses rewritten to the Mac's LAN IP (so Apple TV
      connects back to a reachable host -- Colima's tunnel does the
      rest);
    * the original SRV port, TXT properties, and ``server`` hostname
      kept intact (HomeKit pairing checks all three).

3.  Tracks add / update / remove from the source side and mirrors them.

Loop safety: source and destination Zeroconf instances are bound to
different interfaces, so the rebroadcast on ``en0`` is never picked up
by the ``bridge100`` browser. We additionally skip any service whose
addresses already contain the destination IP (defensive belt-and-
braces in case the same interface is mistakenly used for both).

Environment variables
---------------------
``MDNS_SRC_IP``       IPv4 address of the source interface
                      (e.g. the Mac side of the Colima vmnet bridge,
                      typically ``192.168.106.1``). REQUIRED.
``MDNS_DST_IP``       IPv4 address to publish on the destination
                      interface (the Mac's LAN IP, e.g.
                      ``192.168.10.3``). REQUIRED.
``MDNS_SERVICE_TYPES`` Comma-separated list of fully-qualified service
                      types to reflect. Default: ``_hap._tcp.local.``.
``MDNS_LOG_LEVEL``    Python logging level (default ``INFO``).
"""

from __future__ import annotations

import ipaddress
import logging
import os
import signal
import sys
import threading

from zeroconf import (
    IPVersion,
    ServiceBrowser,
    ServiceInfo,
    ServiceListener,
    Zeroconf,
)


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or value == "":
        sys.stderr.write(f"{name} is required\n")
        sys.exit(2)
    return value


class ReflectingListener(ServiceListener):
    """Mirror services seen on `src` onto `dst` with addresses rewritten."""

    def __init__(self, src: Zeroconf, dst: Zeroconf, dst_ip: str) -> None:
        self._src = src
        self._dst = dst
        self._dst_packed = ipaddress.IPv4Address(dst_ip).packed
        self._dst_ip = dst_ip
        # name -> registered ServiceInfo (so we can unregister / update).
        self._registered: dict[str, ServiceInfo] = {}
        self._lock = threading.Lock()
        self._log = logging.getLogger("mdns-reflector")

    # zeroconf API ----------------------------------------------------------
    def add_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        self._mirror(zc, type_, name, op="ADD")

    def update_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        self._mirror(zc, type_, name, op="UPDATE")

    def remove_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        with self._lock:
            info = self._registered.pop(name, None)
        if info is None:
            return
        try:
            self._dst.unregister_service(info)
            self._log.info("REMOVE %s", name)
        except Exception as exc:  # pylint: disable=broad-except
            self._log.warning("unregister %s failed: %s", name, exc)

    # internals -------------------------------------------------------------
    def _mirror(self, zc: Zeroconf, type_: str, name: str, op: str) -> None:
        info = zc.get_service_info(type_, name, timeout=2000)
        if info is None:
            self._log.debug("%s %s: no info, skipping", op, name)
            return

        # Defensive: if the source already advertised us on the dst IP,
        # there's nothing to reflect (and re-registering would conflict).
        src_addresses = info.addresses or []
        if self._dst_packed in src_addresses:
            self._log.debug("%s %s: already on %s, skipping", op, name, self._dst_ip)
            return

        new_info = ServiceInfo(
            type_=type_,
            name=name,
            addresses=[self._dst_packed],
            port=info.port,
            weight=info.weight,
            priority=info.priority,
            properties=dict(info.properties or {}),
            server=info.server,
        )

        with self._lock:
            existing = self._registered.get(name)
            self._registered[name] = new_info

        try:
            if existing is None:
                # HomeKit pairing tracks the (instance name, accessory
                # identifier) pair. The Mac-side hop publishes onto the
                # LAN where the original name MUST stay byte-identical
                # for Apple TV to recognise the bridge after pairing.
                #
                # The in-VM hop, however, publishes onto a different
                # multicast domain (col0). If HA also reaches col0
                # somehow -- e.g. via a route in newer Colima builds --
                # NonUniqueNameException fires the moment we try to
                # register the same name there. Allow auto-rename here;
                # the Mac-side hop reads the col0 broadcast as-is and
                # uses whatever name we ended up with, so the LAN-side
                # publication is still consistent end-to-end.
                #
                # NB: allow_name_change is not part of the public API
                # signature on every zeroconf release; fall back if not.
                try:
                    self._dst.register_service(new_info, allow_name_change=True)
                except TypeError:
                    self._dst.register_service(new_info)
                self._log.info(
                    "ADD %s -> %s:%s (server=%s)",
                    name, self._dst_ip, info.port, info.server,
                )
            else:
                self._dst.update_service(new_info)
                self._log.info("UPDATE %s (port=%s)", name, info.port)
        except Exception as exc:  # pylint: disable=broad-except
            with self._lock:
                # Roll back the bookkeeping so the next add_service retries.
                self._registered.pop(name, None)
                if existing is not None:
                    self._registered[name] = existing
            # Include the exception type -- some zeroconf exceptions
            # (NonUniqueNameException in particular) stringify to "" so
            # bare `%s` would yield a useless empty error line.
            self._log.error(
                "register/update %s failed: %s: %s",
                name, type(exc).__name__, exc or "<no detail>",
            )


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("MDNS_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    log = logging.getLogger("mdns-reflector")

    src_ip = _env("MDNS_SRC_IP")
    dst_ip = _env("MDNS_DST_IP")
    types_raw = os.environ.get("MDNS_SERVICE_TYPES", "_hap._tcp.local.")
    types = [t.strip() for t in types_raw.split(",") if t.strip()]

    # IPv4 only. HomeKit on Apple devices works fine over v4 and v6
    # introduces a second class of loops to reason about; keep scope narrow.
    src_zc = Zeroconf(interfaces=[src_ip], ip_version=IPVersion.V4Only)
    dst_zc = Zeroconf(interfaces=[dst_ip], ip_version=IPVersion.V4Only)

    listener = ReflectingListener(src=src_zc, dst=dst_zc, dst_ip=dst_ip)
    browsers = [ServiceBrowser(src_zc, t, listener) for t in types]
    log.info("browsing %s on %s, publishing on %s", types, src_ip, dst_ip)

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    stop.wait()

    log.info("shutting down")
    for b in browsers:
        try:
            b.cancel()
        except Exception:  # pylint: disable=broad-except
            pass
    # Unregister anything we registered so the LAN doesn't see stale ads
    # for ~120s while TTLs expire.
    with listener._lock:  # noqa: SLF001 -- internal use intentional
        for info in list(listener._registered.values()):
            try:
                dst_zc.unregister_service(info)
            except Exception:  # pylint: disable=broad-except
                pass
        listener._registered.clear()  # noqa: SLF001
    src_zc.close()
    dst_zc.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
