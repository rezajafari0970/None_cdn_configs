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
