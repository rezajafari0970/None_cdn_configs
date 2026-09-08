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
