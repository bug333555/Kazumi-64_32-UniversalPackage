"""Verify the native Android player payload used for the #2687 fix.

This deliberately checks only the two ARM libmpv entries.  The universal
package keeps the existing 2.2.0 Dart/Flutter/DLNA code and its stable
libmediakitandroidhelper libraries; only libmpv is upgraded to the upstream
v1.3.0 HLS probing fix.
"""

from __future__ import annotations

import hashlib
import sys
import zipfile
from pathlib import Path


EXPECTED = {
    "lib/arm64-v8a/libmpv.so": (
        22_807_384,
        "6bd2ead8e30fa774a7a4ce16232e68a370cc629a12aec22fa282e224cb3e6a65",
    ),
    "lib/armeabi-v7a/libmpv.so": (
        19_116_884,
        "5785b120232bd485e0053a593bd56de69065e240c73a07e0ba13a34500ec1248",
    ),
}


def main(apk_path: str) -> int:
    path = Path(apk_path)
    with zipfile.ZipFile(path) as apk:
        for entry, (expected_size, expected_sha256) in EXPECTED.items():
            data = apk.read(entry)
            actual = hashlib.sha256(data).hexdigest()
            if len(data) != expected_size or actual != expected_sha256:
                raise SystemExit(
                    f"{entry}: size={len(data)} sha256={actual}; "
                    f"expected size={expected_size} sha256={expected_sha256}"
                )
            print(f"{entry}: OK size={len(data)} sha256={actual}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
