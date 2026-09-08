from __future__ import annotations

import time


DEFAULT_TTL_SECONDS = 3600

MIN_TTL_SECONDS = 60
MAX_TTL_SECONDS = 604800


def normalize_ttl(value) -> int:
    try:
        ttl = int(value)
    except Exception:
        ttl = DEFAULT_TTL_SECONDS

    return max(
        MIN_TTL_SECONDS,
        min(
            ttl,
            MAX_TTL_SECONDS,
        ),
    )


def expires_at(
    last_seen_epoch: float | int,
    ttl_seconds: int,
) -> int:
    return int(
        float(last_seen_epoch)
        + normalize_ttl(
            ttl_seconds
        )
    )


def refresh_expiry(
    record: dict,
    ttl_seconds: int,
    now: int | None = None,
) -> dict:
    if now is None:
        now = int(time.time())

    ttl = normalize_ttl(
        ttl_seconds
    )

    record["last_seen_at"] = now
    record["expires_at"] = (
        now + ttl
    )

    return record
