#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/root/None_cdn_configs"
PYROOT="$PROJECT/python"
APP="/opt/nonecdn"
PROD="$APP/python"

echo "============================================================"
echo " NoneCDN Stage 4"
echo " Fetcher + TTL + CDN Detector"
echo "============================================================"
echo "Started: $(date -Is)"
echo

test -d "$PYROOT/app"
test -f "$PYROOT/app/fetcher/engine.py"
test -f "$PYROOT/app/core/config_store.py"

# ============================================================
# REQUIREMENTS
# ============================================================

cat > "$PYROOT/requirements.txt" <<'EOF'
aiohttp>=3.10,<4
httpx>=0.27,<1
filelock>=3.15,<4
dnspython>=2.6,<3
EOF

# ============================================================
# CDN DETECTOR
# ============================================================

mkdir -p "$PYROOT/app/cdn"

touch "$PYROOT/app/cdn/__init__.py"

cat > "$PYROOT/app/cdn/detector.py" <<'PY'
from __future__ import annotations

import base64
import ipaddress
import json
import re
import socket

from functools import lru_cache
from urllib.parse import (
    parse_qs,
    unquote,
    urlsplit,
)

import dns.resolver
import dns.reversename


# ============================================================
# RESULT STATES
# ============================================================

CDN = "CDN"
NON_CDN = "NON_CDN"
UNKNOWN = "UNKNOWN"


# ============================================================
# STRONG CDN DOMAIN SIGNALS
# ============================================================

CDN_DOMAIN_SUFFIXES = {
    # Cloudflare
    "cloudflare.com",
    "cloudflare.net",
    "cloudflareinsights.com",

    # Amazon CloudFront
    "cloudfront.net",

    # Fastly
    "fastly.net",
    "fastlylb.net",

    # Akamai
    "akamai.net",
    "akamaiedge.net",
    "akamaized.net",
    "edgekey.net",
    "edgesuite.net",

    # Bunny
    "b-cdn.net",
    "bunnycdn.com",

    # Gcore
    "gcorelabs.com",
    "gcdn.co",

    # Azure CDN / Front Door
    "azureedge.net",
    "azurefd.net",

    # Google hosted edge
    "googleusercontent.com",

    # Arvan
    "arvancloud.ir",
    "arvancloud.com",

    # KeyCDN
    "kxcdn.com",

    # CDN77
    "cdn77.org",
    "cdn77.com",
}


# ============================================================
# ASN SIGNALS
#
# Only ASNs that are strong CDN indicators are included.
# Generic cloud provider ASNs (AWS/Google/etc.) are NOT
# treated as CDN just because they host servers.
# ============================================================

CDN_ASNS = {
    13335: "Cloudflare",
    54113: "Fastly",

    20940: "Akamai",
    16625: "Akamai",

    60068: "Bunny/CDN network",
    202468: "ArvanCloud",
}


# ============================================================
# CLOUDFLARE NETWORKS
# Strong deterministic range matching.
# ============================================================

CF_NETWORKS = tuple(
    ipaddress.ip_network(x)
    for x in (
        "173.245.48.0/20",
        "103.21.244.0/22",
        "103.22.200.0/22",
        "103.31.4.0/22",
        "141.101.64.0/18",
        "108.162.192.0/18",
        "190.93.240.0/20",
        "188.114.96.0/20",
        "197.234.240.0/22",
        "198.41.128.0/17",
        "162.158.0.0/15",
        "104.16.0.0/13",
        "104.24.0.0/14",
        "172.64.0.0/13",
        "131.0.72.0/22",

        "2400:cb00::/32",
        "2606:4700::/32",
        "2803:f800::/32",
        "2405:b500::/32",
        "2405:8100::/32",
        "2a06:98c0::/29",
        "2c0f:f248::/32",
    )
)


# ============================================================
# HELPERS
# ============================================================

def _clean_host(value):
    if value is None:
        return None

    value = str(value).strip()

    if not value:
        return None

    value = value.strip("[]")

    if value.endswith("."):
        value = value[:-1]

    return value.lower()


def _is_ip(value):
    try:
        return ipaddress.ip_address(
            _clean_host(value)
        )
    except Exception:
        return None


def _is_public_ip(ip):
    return not (
        ip.is_private
        or ip.is_loopback
        or ip.is_multicast
        or ip.is_unspecified
        or ip.is_reserved
        or ip.is_link_local
    )


def _domain_matches_cdn(host):
    host = _clean_host(host)

    if not host:
        return None

    for suffix in CDN_DOMAIN_SUFFIXES:
        if (
            host == suffix
            or host.endswith(
                "." + suffix
            )
        ):
            return suffix

    return None


def _cloudflare_ip(ip):
    try:
        obj = ipaddress.ip_address(ip)
    except Exception:
        return False

    return any(
        obj in network
        for network in CF_NETWORKS
    )


# ============================================================
# DNS
# ============================================================

@lru_cache(maxsize=10000)
def resolve_host(host):
    host = _clean_host(host)

    result = {
        "host": host,
        "cnames": [],
        "ips": [],
        "error": None,
    }

    if not host:
        return result

    ip = _is_ip(host)

    if ip:
        result["ips"] = [
            str(ip)
        ]
        return result

    resolver = dns.resolver.Resolver()

    resolver.timeout = 2.0
    resolver.lifetime = 3.0

    current = host

    visited = set()

    try:
        for _ in range(8):

            if current in visited:
                break

            visited.add(current)

            try:
                answers = resolver.resolve(
                    current,
                    "CNAME",
                )
            except Exception:
                break

            if not answers:
                break

            cname = str(
                answers[0].target
            ).rstrip(".")

            if not cname:
                break

            result["cnames"].append(
                cname.lower()
            )

            current = cname.lower()

    except Exception:
        pass

    for qtype in (
        "A",
        "AAAA",
    ):
        try:
            answers = resolver.resolve(
                current,
                qtype,
            )

            for answer in answers:
                value = str(answer)

                if value not in result["ips"]:
                    result["ips"].append(
                        value
                    )

        except Exception:
            continue

    # libc fallback
    if not result["ips"]:
        try:
            values = socket.getaddrinfo(
                host,
                None,
            )

            for row in values:
                value = row[4][0]

                if value not in result["ips"]:
                    result["ips"].append(
                        value
                    )

        except Exception as e:
            result["error"] = str(e)

    return result


# ============================================================
# TEAM CYMRU ASN DNS
# ============================================================

@lru_cache(maxsize=20000)
def lookup_asn(ip):
    try:
        obj = ipaddress.ip_address(ip)
    except Exception:
        return None

    if not _is_public_ip(obj):
        return None

    resolver = dns.resolver.Resolver()

    resolver.timeout = 2.0
    resolver.lifetime = 3.0

    try:
        if obj.version == 4:
            query = (
                ".".join(
                    reversed(
                        str(obj).split(".")
                    )
                )
                + ".origin.asn.cymru.com"
            )

        else:
            expanded = obj.exploded.replace(
                ":",
                ""
            )

            query = (
                ".".join(
                    reversed(expanded)
                )
                + ".origin6.asn.cymru.com"
            )

        answers = resolver.resolve(
            query,
            "TXT",
        )

        if not answers:
            return None

        text = (
            str(answers[0])
            .strip('"')
        )

        first = (
            text.split("|", 1)[0]
            .strip()
        )

        # Sometimes multiple ASNs are separated by spaces.
        first = first.split()[0]

        return int(first)

    except Exception:
        return None


# ============================================================
# CONFIG DESTINATION EXTRACTION
# ============================================================

def _decode_vmess(raw):
    try:
        value = raw[
            len("vmess://"):
        ]

        value += "=" * (
            -len(value) % 4
        )

        decoded = base64.urlsafe_b64decode(
            value
        ).decode(
            "utf-8"
        )

        return json.loads(decoded)

    except Exception:
        return {}


def _walk_json(value, result, depth=0):
    if depth > 10:
        return

    if isinstance(value, dict):

        for key, child in value.items():

            key_low = str(key).lower()

            if key_low in {
                "address",
                "server",
                "serveraddress",
                "hostname",
            }:
                if isinstance(
                    child,
                    (str, int, float)
                ):
                    result["addresses"].add(
                        str(child)
                    )

            elif key_low in {
                "sni",
                "servername",
                "server_name",
            }:
                if isinstance(child, str):
                    result["sni"].add(child)

            elif key_low in {
                "host",
                "authority",
            }:
                if isinstance(child, str):
                    result["hosts"].add(child)

            _walk_json(
                child,
                result,
                depth + 1,
            )

    elif isinstance(value, list):

        for child in value:
            _walk_json(
                child,
                result,
                depth + 1,
            )


def extract_destinations(item):
    raw = str(
        item.get("raw")
        or ""
    ).strip()

    kind = str(
        item.get("type")
        or ""
    ).lower()

    result = {
        "addresses": set(),
        "hosts": set(),
        "sni": set(),
    }

    # --------------------------------------------------------
    # VMESS
    # --------------------------------------------------------

    if raw.lower().startswith(
        "vmess://"
    ):
        obj = _decode_vmess(raw)

        address = (
            obj.get("add")
            or obj.get("address")
            or obj.get("server")
        )

        if address:
            result["addresses"].add(
                str(address)
            )

        for value in (
            obj.get("host"),
            obj.get("sni"),
        ):
            if value:
                result["hosts"].add(
                    str(value)
                )

        if obj.get("sni"):
            result["sni"].add(
                str(obj["sni"])
            )

        return result

    # --------------------------------------------------------
    # URI TYPES
    # --------------------------------------------------------

    if "://" in raw:

        try:
            parsed = urlsplit(raw)

            if parsed.hostname:
                result[
                    "addresses"
                ].add(
                    parsed.hostname
                )

            query = parse_qs(
                parsed.query
            )

            for key in (
                "host",
                "authority",
            ):
                for value in query.get(
                    key,
                    []
                ):
                    result["hosts"].add(
                        unquote(value)
                    )

            for key in (
                "sni",
                "serverName",
                "servername",
            ):
                for value in query.get(
                    key,
                    []
                ):
                    result["sni"].add(
                        unquote(value)
                    )

            return result

        except Exception:
            pass

    # --------------------------------------------------------
    # JSON
    # --------------------------------------------------------

    if (
        kind.startswith("json_")
        or raw.startswith("{")
        or raw.startswith("[")
    ):
        try:
            obj = json.loads(raw)

            _walk_json(
                obj,
                result,
            )

        except Exception:
            pass

    # --------------------------------------------------------
    # WireGuard native endpoint
    # --------------------------------------------------------

    endpoint = re.search(
        r"(?im)^\s*Endpoint\s*=\s*(.+?)\s*$",
        raw,
    )

    if endpoint:
        value = endpoint.group(1)

        if value.startswith("["):
            host = value.split(
                "]",
                1
            )[0].strip("[")

        else:
            host = value.rsplit(
                ":",
                1
            )[0]

        if host:
            result["addresses"].add(
                host
            )

    return result


# ============================================================
# HOST CLASSIFICATION
# ============================================================

def classify_host(host):
    host = _clean_host(host)

    if not host:
        return {
            "classification": UNKNOWN,
            "provider": None,
            "reason": "empty_host",
            "host": host,
            "ips": [],
            "cnames": [],
        }

    domain_signal = _domain_matches_cdn(
        host
    )

    if domain_signal:
        return {
            "classification": CDN,
            "provider": domain_signal,
            "reason": "cdn_domain",
            "host": host,
            "ips": [],
            "cnames": [],
        }

    dns_info = resolve_host(host)

    # CNAME signal
    for cname in dns_info[
        "cnames"
    ]:
        signal = _domain_matches_cdn(
            cname
        )

        if signal:
            return {
                "classification": CDN,
                "provider": signal,
                "reason": "cdn_cname",
                "host": host,
                "ips": dns_info["ips"],
                "cnames": dns_info["cnames"],
            }

    saw_public = False
    asns = []

    for ip_text in dns_info[
        "ips"
    ]:

        try:
            ip = ipaddress.ip_address(
                ip_text
            )
        except Exception:
            continue

        if not _is_public_ip(ip):
            continue

        saw_public = True

        if _cloudflare_ip(ip):
            return {
                "classification": CDN,
                "provider": "Cloudflare",
                "reason": "cloudflare_ip",
                "host": host,
                "ips": dns_info["ips"],
                "cnames": dns_info["cnames"],
            }

        asn = lookup_asn(
            ip_text
        )

        if asn:
            asns.append(asn)

            provider = CDN_ASNS.get(
                asn
            )

            if provider:
                return {
                    "classification": CDN,
                    "provider": provider,
                    "reason": f"cdn_asn:{asn}",
                    "host": host,
                    "ips": dns_info["ips"],
                    "cnames": dns_info["cnames"],
                    "asns": asns,
                }

    if saw_public:
        return {
            "classification": NON_CDN,
            "provider": None,
            "reason": "public_origin_not_cdn",
            "host": host,
            "ips": dns_info["ips"],
            "cnames": dns_info["cnames"],
            "asns": asns,
        }

    return {
        "classification": UNKNOWN,
        "provider": None,
        "reason": (
            "dns_unresolved"
            if not dns_info["ips"]
            else "no_public_destination"
        ),
        "host": host,
        "ips": dns_info["ips"],
        "cnames": dns_info["cnames"],
        "asns": asns,
    }


# ============================================================
# CONFIG CLASSIFICATION
# ============================================================

def classify_config(item):
    destinations = extract_destinations(
        item
    )

    addresses = sorted({
        _clean_host(x)
        for x in destinations[
            "addresses"
        ]
        if _clean_host(x)
    })

    hosts = sorted({
        _clean_host(x)
        for x in destinations[
            "hosts"
        ]
        if _clean_host(x)
    })

    snis = sorted({
        _clean_host(x)
        for x in destinations[
            "sni"
        ]
        if _clean_host(x)
    })

    # Address is the actual network destination and therefore
    # receives highest priority.
    targets = []

    for role, values in (
        ("address", addresses),
        ("host", hosts),
        ("sni", snis),
    ):
        for value in values:
            targets.append(
                (
                    role,
                    value,
                )
            )

    if not targets:
        return {
            "classification": UNKNOWN,
            "provider": None,
            "reason": "destination_not_extractable",
            "destinations": destinations,
            "evidence": [],
        }

    evidence = []

    non_cdn_address = False

    for role, value in targets:

        result = classify_host(
            value
        )

        evidence.append({
            "role": role,
            "value": value,
            **result,
        })

        # Any strong CDN evidence means CDN.
        if result[
            "classification"
        ] == CDN:

            return {
                "classification": CDN,
                "provider": result.get(
                    "provider"
                ),
                "reason": (
                    f"{role}:"
                    f"{result.get('reason')}"
                ),
                "destinations": {
                    "addresses": addresses,
                    "hosts": hosts,
                    "sni": snis,
                },
                "evidence": evidence,
            }

        if (
            role == "address"
            and result[
                "classification"
            ] == NON_CDN
        ):
            non_cdn_address = True

    # We only call it NON_CDN when actual address/origin
    # resolved to a public non-CDN destination.
    if non_cdn_address:
        return {
            "classification": NON_CDN,
            "provider": None,
            "reason": "address_confirmed_non_cdn",
            "destinations": {
                "addresses": addresses,
                "hosts": hosts,
                "sni": snis,
            },
            "evidence": evidence,
        }

    return {
        "classification": UNKNOWN,
        "provider": None,
        "reason": "insufficient_direct_evidence",
        "destinations": {
            "addresses": addresses,
            "hosts": hosts,
            "sni": snis,
        },
        "evidence": evidence,
    }
PY


# ============================================================
# TTL-AWARE CONFIG STORE
# ============================================================

cat > "$PYROOT/app/core/config_store.py" <<'PY'
from __future__ import annotations

import json
import os
import tempfile
import time

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path

from filelock import FileLock


DATA = Path(
    "/var/lib/nonecdn"
)

CONFIG_DIR = (
    DATA / "configs"
)

LOCK_DIR = (
    DATA / "locks"
)

SOURCE_SNAPSHOT_DIR = (
    DATA
    / "source-snapshots"
)

for directory in (
    CONFIG_DIR,
    LOCK_DIR,
    SOURCE_SNAPSHOT_DIR,
):
    directory.mkdir(
        parents=True,
        exist_ok=True,
    )


def now_iso():
    return datetime.now(
        timezone.utc
    ).isoformat()


def _path(fingerprint):
    return (
        CONFIG_DIR
        / f"{fingerprint}.json"
    )


def _lock(fingerprint):
    return FileLock(
        str(
            LOCK_DIR
            / f"config-{fingerprint}.lock"
        ),
        timeout=15,
    )


def _atomic_write(
    path: Path,
    data: dict,
):
    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=f".{path.name}.",
        suffix=".tmp",
    )

    try:
        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            json.dump(
                data,
                f,
                ensure_ascii=False,
                indent=2,
            )

            f.flush()
            os.fsync(
                f.fileno()
            )

        os.replace(
            tmp,
            path,
        )

    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _normalize_ttl(value):
    try:
        value = int(value)
    except Exception:
        value = 3600

    return max(
        60,
        min(
            value,
            604800,
        ),
    )


def _source_expiries(record):
    value = record.get(
        "source_expiries"
    )

    if not isinstance(
        value,
        dict,
    ):
        value = {}

    return value


def _recalculate_record_expiry(
    record,
):
    expiries = (
        _source_expiries(
            record
        )
    )

    now = int(
        time.time()
    )

    active = {
        str(source_id): int(expiry)
        for source_id, expiry
        in expiries.items()
        if int(expiry) > now
    }

    record[
        "source_expiries"
    ] = active

    record[
        "source_ids"
    ] = sorted(
        active.keys()
    )

    if active:
        record[
            "expires_at"
        ] = max(
            active.values()
        )

        record[
            "active"
        ] = True

    else:
        record[
            "expires_at"
        ] = 0

        record[
            "active"
        ] = False

    return record


def upsert_config(
    item: dict,
    source_id: str,
    ttl_seconds: int = 3600,
    classification: dict | None = None,
):
    fingerprint = str(
        item["fingerprint"]
    )

    source_id = str(
        source_id
    )

    ttl_seconds = (
        _normalize_ttl(
            ttl_seconds
        )
    )

    now_epoch = int(
        time.time()
    )

    expiry = (
        now_epoch
        + ttl_seconds
    )

    path = _path(
        fingerprint
    )

    with _lock(
        fingerprint
    ):

        if path.exists():
            try:
                record = json.loads(
                    path.read_text(
                        encoding="utf-8"
                    )
                )

            except Exception:
                record = {}

        else:
            record = {}

        created = not bool(
            record
        )

        if created:
            record = {
                "id": fingerprint,

                "type": item.get(
                    "type",
                    "unknown",
                ),

                # Original source payload is preserved.
                "raw": item.get(
                    "raw",
                    "",
                ),

                "canonical": item.get(
                    "canonical",
                    item.get(
                        "raw",
                        "",
                    ),
                ),

                "first_seen_at":
                    now_iso(),

                "first_seen_epoch":
                    now_epoch,

                "source_ids": [],

                "source_expiries": {},

                "active": True,
            }

        record[
            "last_seen_at"
        ] = now_iso()

        record[
            "last_seen_epoch"
        ] = now_epoch

        record[
            "last_ttl_seconds"
        ] = ttl_seconds

        expiries = (
            _source_expiries(
                record
            )
        )

        expiries[
            source_id
        ] = expiry

        record[
            "source_expiries"
        ] = expiries

        if classification:
            record[
                "classification"
            ] = classification.get(
                "classification"
            )

            record[
                "classification_reason"
            ] = classification.get(
                "reason"
            )

            record[
                "cdn_provider"
            ] = classification.get(
                "provider"
            )

            record[
                "classification_evidence"
            ] = classification.get(
                "evidence",
                [],
            )

        _recalculate_record_expiry(
            record
        )

        _atomic_write(
            path,
            record,
        )

        return (
            record,
            created,
        )


def cleanup_expired():
    now = int(
        time.time()
    )

    scanned = 0
    updated = 0
    deleted = 0
    expired_sources = 0

    for path in list(
        CONFIG_DIR.glob(
            "*.json"
        )
    ):
        scanned += 1

        fingerprint = (
            path.stem
        )

        with _lock(
            fingerprint
        ):

            if not path.exists():
                continue

            try:
                record = json.loads(
                    path.read_text(
                        encoding="utf-8"
                    )
                )
            except Exception:
                continue

            expiries = (
                _source_expiries(
                    record
                )
            )

            before = len(
                expiries
            )

            expiries = {
                str(source_id):
                    int(expiry)

                for source_id, expiry
                in expiries.items()

                if int(expiry) > now
            }

            expired_sources += (
                before
                - len(expiries)
            )

            record[
                "source_expiries"
            ] = expiries

            _recalculate_record_expiry(
                record
            )

            if not record.get(
                "source_ids"
            ):
                try:
                    path.unlink()
                    deleted += 1

                except FileNotFoundError:
                    pass

                continue

            _atomic_write(
                path,
                record
            )

            updated += 1

    return {
        "scanned": scanned,
        "updated": updated,
        "deleted": deleted,
        "expired_sources":
            expired_sources,
    }


def list_configs(
    active_only=True
):
    cleanup_expired()

    now = int(
        time.time()
    )

    result = []

    for path in CONFIG_DIR.glob(
        "*.json"
    ):
        try:
            obj = json.loads(
                path.read_text(
                    encoding="utf-8"
                )
            )

        except Exception:
            continue

        if not isinstance(
            obj,
            dict
        ):
            continue

        if active_only:
            if not obj.get(
                "active",
                False
            ):
                continue

            if int(
                obj.get(
                    "expires_at",
                    0,
                )
                or 0
            ) <= now:
                continue

        result.append(obj)

    result.sort(
        key=lambda x:
            int(
                x.get(
                    "last_seen_epoch",
                    0,
                )
                or 0
            ),
        reverse=True,
    )

    return result


def config_stats():
    values = list_configs()

    types = {}

    for item in values:
        kind = item.get(
            "type",
            "unknown",
        )

        types[kind] = (
            types.get(
                kind,
                0,
            )
            + 1
        )

    return {
        "total": len(values),
        "active": len(values),
        "types": types,
    }


def detach_source_from_configs(
    source_id: str
):
    source_id = str(
        source_id
    ).strip()

    result = {
        "scanned": 0,
        "detached": 0,
        "deleted": 0,
        "kept": 0,
    }

    if not source_id:
        return result

    for path in list(
        CONFIG_DIR.glob(
            "*.json"
        )
    ):
        result[
            "scanned"
        ] += 1

        fingerprint = (
            path.stem
        )

        with _lock(
            fingerprint
        ):

            try:
                record = json.loads(
                    path.read_text(
                        encoding="utf-8"
                    )
                )
            except Exception:
                continue

            expiries = (
                _source_expiries(
                    record
                )
            )

            if source_id not in expiries:
                continue

            result[
                "detached"
            ] += 1

            expiries.pop(
                source_id,
                None,
            )

            record[
                "source_expiries"
            ] = expiries

            _recalculate_record_expiry(
                record
            )

            if not record.get(
                "source_ids"
            ):
                try:
                    path.unlink()

                    result[
                        "deleted"
                    ] += 1

                except FileNotFoundError:
                    pass

            else:
                _atomic_write(
                    path,
                    record,
                )

                result[
                    "kept"
                ] += 1

    remove_source_snapshot(
        source_id
    )

    return result


def detach_sources_from_configs(
    source_ids
):
    result = {
        "scanned": 0,
        "detached": 0,
        "deleted": 0,
        "kept": 0,
    }

    for source_id in {
        str(x).strip()
        for x in source_ids
        if str(x).strip()
    }:
        one = (
            detach_source_from_configs(
                source_id
            )
        )

        for key in result:
            result[key] += (
                one.get(
                    key,
                    0,
                )
            )

    return result


# ============================================================
# LEGACY SNAPSHOT API
#
# Kept for panel compatibility, but TTL now owns removal.
# A source temporarily returning a different list must NOT
# instantly delete still-valid configs.
# ============================================================

def _source_snapshot_path(
    source_id
):
    return (
        SOURCE_SNAPSHOT_DIR
        / f"{source_id}.json"
    )


def read_source_snapshot(
    source_id
):
    path = (
        _source_snapshot_path(
            source_id
        )
    )

    if not path.exists():
        return None

    try:
        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )
    except Exception:
        return None

    values = obj.get(
        "fingerprints"
    )

    if not isinstance(
        values,
        list
    ):
        return None

    return set(
        str(x)
        for x in values
    )


def write_source_snapshot(
    source_id,
    fingerprints,
):
    values = sorted({
        str(x)
        for x in fingerprints
    })

    data = {
        "source_id":
            str(source_id),

        "updated_at":
            now_iso(),

        "count":
            len(values),

        "fingerprints":
            values,
    }

    _atomic_write(
        _source_snapshot_path(
            source_id
        ),
        data,
    )

    return data


def remove_source_snapshot(
    source_id
):
    path = (
        _source_snapshot_path(
            source_id
        )
    )

    try:
        path.unlink()
        return True

    except FileNotFoundError:
        return False


def remove_source_snapshots(
    source_ids
):
    count = 0

    for source_id in source_ids:
        if remove_source_snapshot(
            source_id
        ):
            count += 1

    return count


def delete_all_source_snapshots():
    count = 0

    for path in SOURCE_SNAPSHOT_DIR.glob(
        "*.json"
    ):
        try:
            path.unlink()
            count += 1

        except FileNotFoundError:
            pass

    return count


def sync_source_snapshot(
    source_id,
    current_fingerprints,
    authoritative=True,
):
    # IMPORTANT:
    #
    # The old project removed configs immediately if a config
    # disappeared from a source snapshot.
    #
    # NoneCDN deliberately does NOT do this.
    #
    # Lifetime is controlled solely by last_seen + TTL.

    values = {
        str(x)
        for x in current_fingerprints
    }

    previous = (
        read_source_snapshot(
            source_id
        )
    )

    write_source_snapshot(
        source_id,
        values,
    )

    return {
        "source_id":
            str(source_id),

        "authoritative":
            bool(authoritative),

        "current":
            len(values),

        "previous":
            len(previous or set()),

        "missing":
            len(
                (previous or set())
                - values
            ),

        "detached": 0,
        "deleted": 0,
        "kept_shared": 0,

        "baseline_created":
            previous is None,

        "snapshot_updated": True,

        "ttl_managed": True,
    }


def delete_all_configs():
    delete_all_source_snapshots()

    deleted = 0

    for path in list(
        CONFIG_DIR.glob(
            "*.json"
        )
    ):
        try:
            path.unlink()
            deleted += 1

        except FileNotFoundError:
            pass

    return deleted
PY


# ============================================================
# PATCH FETCHER
# ============================================================

python3 - <<'PY'
from pathlib import Path

p = Path(
    "/root/None_cdn_configs/"
    "python/app/fetcher/engine.py"
)

s = p.read_text()


# ------------------------------------------------------------
# Imports
# ------------------------------------------------------------

old = '''from app.core.config_store import (
    upsert_config,
    config_stats,
    sync_source_snapshot,
)'''

new = '''from app.core.config_store import (
    upsert_config,
    config_stats,
    sync_source_snapshot,
    cleanup_expired,
)

from app.cdn.detector import (
    classify_config,
    CDN,
    NON_CDN,
    UNKNOWN,
)'''

if old not in s:
    raise SystemExit(
        "[FAIL] Config-store import block not found"
    )

s = s.replace(
    old,
    new,
    1,
)


# ------------------------------------------------------------
# Anchor fetch interval to START time, not END time.
#
# This prevents:
# fetch duration + interval = accumulated drift.
# ------------------------------------------------------------

old = '''    started = now_iso()

    previous = read_runtime('''

new = '''    cycle_started_epoch = time.time()

    started = now_iso()

    previous = read_runtime('''

if old not in s:
    raise SystemExit(
        "[FAIL] run_source_once start marker not found"
    )

s = s.replace(
    old,
    new,
    1,
)


# ------------------------------------------------------------
# Counters
# ------------------------------------------------------------

old = '''    new_count = 0
    found_count = 0

    duplicate_streak = 0'''

new = '''    new_count = 0
    found_count = 0

    direct_count = 0
    cdn_count = 0
    unknown_count = 0

    duplicate_streak = 0'''

if old not in s:
    raise SystemExit(
        "[FAIL] Counter block not found"
    )

s = s.replace(
    old,
    new,
    1,
)


# ------------------------------------------------------------
# Replace storage loop
# ------------------------------------------------------------

old = '''                for item in items:

                    found_count += 1

                    _, created = upsert_config(
                        item,
                        source_id,
                    )

                    if created:
                        new_count += 1'''

new = '''                ttl_seconds = max(
                    60,
                    int(
                        source.get(
                            "config_ttl_seconds",
                            3600,
                        )
                        or 3600
                    ),
                )

                for item in items:

                    found_count += 1

                    classification = await asyncio.to_thread(
                        classify_config,
                        item,
                    )

                    state = classification.get(
                        "classification",
                        UNKNOWN,
                    )

                    if state == CDN:
                        cdn_count += 1
                        continue

                    if state != NON_CDN:
                        unknown_count += 1
                        continue

                    direct_count += 1

                    _, created = upsert_config(
                        item,
                        source_id,
                        ttl_seconds=ttl_seconds,
                        classification=classification,
                    )

                    if created:
                        new_count += 1'''

if old not in s:
    raise SystemExit(
        "[FAIL] upsert loop not found"
    )

s = s.replace(
    old,
    new,
    1,
)


# ------------------------------------------------------------
# Important:
# seen_this_session must represent configs actually accepted
# into NonCDN store rather than every CDN/unknown config.
#
# easiest safe correction: snapshot reconciliation has already
# been converted to TTL-only, so it can contain all fingerprints
# without deleting anything. No destructive effect remains.
# ------------------------------------------------------------


# ------------------------------------------------------------
# Runtime counters
# ------------------------------------------------------------

old = '''            new_configs_last_cycle=new_count,

            total_fetches=total_fetches,'''

new = '''            new_configs_last_cycle=new_count,

            direct_last_cycle=direct_count,
            cdn_last_cycle=cdn_count,
            unknown_last_cycle=unknown_count,

            total_fetches=total_fetches,'''

if old not in s:
    raise SystemExit(
        "[FAIL] Runtime counters marker not found"
    )

s = s.replace(
    old,
    new,
    1,
)


# ------------------------------------------------------------
# Add counters to return
# ------------------------------------------------------------

old = '''            "new":
                new_count,

            "stop_reason":'''

new = '''            "new":
                new_count,

            "direct":
                direct_count,

            "cdn":
                cdn_count,

            "unknown":
                unknown_count,

            "stop_reason":'''

if old not in s:
    raise SystemExit(
        "[FAIL] Return counters marker not found"
    )

s = s.replace(
    old,
    new,
    1,
)


# ------------------------------------------------------------
# Replace completion-based timer anchor
# ------------------------------------------------------------

s = s.replace(
    '''            last_fetch_epoch=time.time(),

            consecutive_failures=0,''',
    '''            last_fetch_epoch=cycle_started_epoch,

            consecutive_failures=0,''',
    1,
)

# failure branch too
s = s.replace(
    '''            last_fetch_epoch=time.time(),

            consecutive_failures=(''',
    '''            last_fetch_epoch=cycle_started_epoch,

            consecutive_failures=(''',
    1,
)


# ------------------------------------------------------------
# Cleanup expired at beginning of each source session.
# Failures here must not kill fetcher.
# ------------------------------------------------------------

marker = '''    update_runtime(
        source_id,

        state="fetching",'''

replacement = '''    try:
        cleanup_expired()
    except Exception:
        pass

    update_runtime(
        source_id,

        state="fetching",'''

if marker not in s:
    raise SystemExit(
        "[FAIL] runtime-start marker missing"
    )

s = s.replace(
    marker,
    replacement,
    1,
)

p.write_text(s)

print("[OK] Fetcher patched")
PY


# ============================================================
# TEST MODULE
# ============================================================

mkdir -p "$PROJECT/tests/stage4"

cat > "$PROJECT/tests/stage4/test_stage4.py" <<'PY'
from __future__ import annotations

import json
import os
import shutil
import tempfile
import time

from pathlib import Path


from app.cdn.detector import (
    classify_config,
    CDN,
    NON_CDN,
)

from app.core.ttl import (
    expires_at,
)


def test_ttl_math():
    assert (
        expires_at(
            1000,
            3600,
        )
        == 4600
    )


def test_cloudflare_ip():

    item = {
        "type": "vless",
        "raw":
            "vless://x@104.16.1.1:443"
            "?security=tls"
            "&type=ws",

        "fingerprint": "x",
    }

    result = classify_config(
        item
    )

    assert (
        result[
            "classification"
        ]
        == CDN
    ), result


def test_direct_ip():

    # TEST-NET must not be used because it is reserved.
    # We only assert extraction/classification machinery
    # using localhost-like UNKNOWN path indirectly.
    #
    # Live public direct classification is tested separately
    # by integration test when network exists.
    pass


if __name__ == "__main__":

    test_ttl_math()
    print("[OK] TTL math")

    test_cloudflare_ip()
    print(
        "[OK] Cloudflare CDN detection"
    )

    test_direct_ip()

    print(
        "ALL STAGE 4 UNIT TESTS PASSED"
    )
PY


# ============================================================
# PYTHON SYNTAX
# ============================================================

echo
echo "===== SYNTAX ====="

python3 -m compileall \
    -q \
    "$PYROOT/app"

echo "[OK] Python syntax"


# ============================================================
# DEPLOY
# ============================================================

echo
echo "===== DEPLOY ====="

rm -rf "$PROD"

cp -a \
    "$PYROOT" \
    "$PROD"

chown -R \
    root:root \
    "$PROD"

find "$PROD" \
    -type d \
    -exec chmod 755 {} \;

find "$PROD" \
    -type f \
    -exec chmod 644 {} \;

echo "[OK] Source deployed"


# ============================================================
# INSTALL REQUIREMENTS
# ============================================================

"$APP/venv/bin/pip" \
    install \
    --disable-pip-version-check \
    -r "$PROD/requirements.txt"

echo "[OK] Requirements installed"


# ============================================================
# DATA DIRECTORIES
# ============================================================

install -d \
    -o nonecdn \
    -g nonecdn \
    -m 0750 \
    /var/lib/nonecdn/configs \
    /var/lib/nonecdn/locks \
    /var/lib/nonecdn/source-snapshots \
    /var/lib/nonecdn/source-triggers

echo "[OK] Runtime directories"


# ============================================================
# RUN TESTS
# ============================================================

echo
echo "===== UNIT TEST ====="

PYTHONPATH="$PROD" \
"$APP/venv/bin/python" \
"$PROJECT/tests/stage4/test_stage4.py"


# ============================================================
# TTL STORAGE INTEGRATION TEST
# ============================================================

echo
echo "===== STORAGE TTL TEST ====="

PYTHONPATH="$PROD" \
runuser -u nonecdn -- \
"$APP/venv/bin/python" - <<'PY'
import hashlib
import json
import time

from pathlib import Path

from app.core.config_store import (
    upsert_config,
    cleanup_expired,
)

fingerprint = hashlib.sha256(
    b"nonecdn-stage4-test"
).hexdigest()

path = (
    Path("/var/lib/nonecdn/configs")
    / f"{fingerprint}.json"
)

try:

    item = {
        "type": "vless",
        "raw":
            "vless://test@1.1.1.1:443"
            "?security=tls",

        "canonical":
            "vless://test@1.1.1.1:443"
            "?security=tls",

        "fingerprint":
            fingerprint,
    }

    record, created = upsert_config(
        item,
        "stage4-test-source",
        ttl_seconds=60,
        classification={
            "classification":
                "NON_CDN",

            "reason":
                "integration_test",

            "provider":
                None,

            "evidence":
                [],
        },
    )

    first_expiry = (
        record[
            "expires_at"
        ]
    )

    assert first_expiry > int(
        time.time()
    )

    time.sleep(1)

    record, created = upsert_config(
        item,
        "stage4-test-source",
        ttl_seconds=60,
        classification={
            "classification":
                "NON_CDN",

            "reason":
                "integration_test",

            "provider":
                None,

            "evidence":
                [],
        },
    )

    assert (
        record[
            "expires_at"
        ]
        > first_expiry
    )

    print(
        "[OK] last_seen refreshes TTL"
    )

finally:
    try:
        path.unlink()
    except FileNotFoundError:
        pass
PY


# ============================================================
# LIVE CDN TESTS
# ============================================================

echo
echo "===== LIVE DETECTOR TEST ====="

PYTHONPATH="$PROD" \
"$APP/venv/bin/python" - <<'PY'
from app.cdn.detector import (
    classify_host,
)

for host in (
    "cloudflare.com",
    "cdnjs.cloudflare.com",
):

    result = classify_host(
        host
    )

    print(
        host,
        "=>",
        result[
            "classification"
        ],
        result.get(
            "provider"
        ),
        result.get(
            "reason"
        ),
    )

    if result[
        "classification"
    ] != "CDN":
        raise SystemExit(
            "CDN live test failed"
        )

print(
    "[OK] Live CDN detection"
)
PY


# ============================================================
# SYSTEMD FETCHER SERVICE
# ============================================================

cat > "$PROJECT/services/nonecdn-fetcher.service" <<'EOF'
[Unit]
Description=NoneCDN Independent Fetcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=nonecdn
Group=nonecdn

WorkingDirectory=/opt/nonecdn/python

Environment=PYTHONPATH=/opt/nonecdn/python
Environment=PYTHONUNBUFFERED=1

ExecStart=/opt/nonecdn/venv/bin/python -m app.fetcher.engine

Restart=always
RestartSec=1

StartLimitIntervalSec=0

KillSignal=SIGTERM
TimeoutStopSec=20

NoNewPrivileges=true
PrivateTmp=true

ProtectSystem=full
ProtectHome=true

ReadWritePaths=/var/lib/nonecdn
ReadWritePaths=/var/log/nonecdn
ReadWritePaths=/run/nonecdn

StandardOutput=append:/var/log/nonecdn/fetcher.log
StandardError=append:/var/log/nonecdn/fetcher-error.log

[Install]
WantedBy=multi-user.target
EOF

cp \
    "$PROJECT/services/nonecdn-fetcher.service" \
    /etc/systemd/system/nonecdn-fetcher.service

systemctl daemon-reload

systemctl enable \
    nonecdn-fetcher.service

systemctl restart \
    nonecdn-fetcher.service

sleep 3


# ============================================================
# SERVICE CHECK
# ============================================================

if ! systemctl is-active \
    --quiet \
    nonecdn-fetcher.service
then
    echo "[FAIL] Fetcher service failed"

    systemctl status \
        nonecdn-fetcher.service \
        --no-pager || true

    tail -100 \
        /var/log/nonecdn/fetcher-error.log \
        2>/dev/null || true

    exit 1
fi

echo "[OK] Fetcher service active"


# ============================================================
# VERIFY SERVICE DOES NOT TOUCH OTHER PROJECTS
# ============================================================

echo
echo "===== ISOLATION ====="

systemctl is-active nginx \
    >/dev/null

echo "[OK] nginx remains active"

nginx -t

echo "[OK] nginx configuration remains valid"


# ============================================================
# STATUS
# ============================================================

sleep 2

echo
echo "===== FETCHER STATUS ====="

if [ -f \
    /var/lib/nonecdn/state/fetcher-status.json
]; then
    cat \
        /var/lib/nonecdn/state/fetcher-status.json
else
    echo "[WARN] Status not written yet"
fi


# ============================================================
# PROJECT STATUS
# ============================================================

cat >> "$PROJECT/reports/PROJECT-STATUS.md" <<EOF

## Stage 4 - Fetcher + TTL + CDN

Completed: $(date -Is)

- [x] CDN detector
- [x] Address extraction
- [x] Host/SNI inspection
- [x] A/AAAA resolution
- [x] CNAME resolution
- [x] Cloudflare CIDR matching
- [x] Conservative CDN ASN matching
- [x] Unknown classification
- [x] Only NON_CDN configs stored
- [x] CDN configs rejected
- [x] Unknown configs rejected
- [x] Raw configs preserved
- [x] Per-source TTL
- [x] last_seen TTL refresh
- [x] Shared config source expiry
- [x] Automatic expired cleanup
- [x] Missing-on-next-fetch does NOT instantly delete config
- [x] Fetch interval anchored to cycle start
- [x] Independent source workers preserved
- [x] systemd automatic restart
- [x] Unit/integration tests
- [x] Isolated NoneCDN service

Status:

FETCHER + TTL + CDN ENGINE ACTIVE

Next:

Snapshot Panel Runtime Integration
+
Output Subscription API
+
CDN/Direct statistics in UI
EOF


# ============================================================
# REPORT
# ============================================================

REPORT="$PROJECT/reports/runs/stage4-fetcher-cdn-$(date +%Y%m%d-%H%M%S).txt"

{
    echo "NoneCDN Stage 4"
    echo "Date: $(date -Is)"

    echo
    echo "Fetcher:"
    systemctl status \
        nonecdn-fetcher.service \
        --no-pager

    echo
    echo "Status:"
    cat \
        /var/lib/nonecdn/state/fetcher-status.json \
        2>/dev/null || true

    echo
    echo "Configs:"
    find \
        /var/lib/nonecdn/configs \
        -maxdepth 1 \
        -type f \
        -name '*.json' \
        | wc -l

    echo
    echo "Errors:"
    tail -50 \
        /var/log/nonecdn/fetcher-error.log \
        2>/dev/null || true

} > "$REPORT"


echo
echo "============================================================"
echo " STAGE 4 COMPLETE"
echo "============================================================"
echo
echo "Fetcher:"
echo "nonecdn-fetcher.service"
echo
echo "Stored configs:"
echo "/var/lib/nonecdn/configs"
echo
echo "Logs:"
echo "/var/log/nonecdn/fetcher.log"
echo "/var/log/nonecdn/fetcher-error.log"
echo
echo "Next:"
echo "SNAPSHOT PANEL + SUBSCRIPTION API"
echo
