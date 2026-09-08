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
