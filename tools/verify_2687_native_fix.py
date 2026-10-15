"""Verify the API-21 native player payload used for the #2687 backport.

The universal package keeps the existing 2.2.0 Dart/Flutter/DLNA code and its
stable libmediakitandroidhelper libraries. The two ARM libmpv entries are
rebuilt from the official v1.1.5 builder with only the HLS probe fix carried
back from upstream v1.3.0.
"""

from __future__ import annotations

import hashlib
import struct
import sys
import zipfile
from pathlib import Path


EXPECTED_API = 21
EXPECTED_HELPERS = {
    "lib/arm64-v8a/libmediakitandroidhelper.so":
        "a6862031015e390aa8a64536411132cf4df6a5a9dcf782f0d68b995380a1cccb",
    "lib/armeabi-v7a/libmediakitandroidhelper.so":
        "698ce761945a3bdaf6ffe690e715fc510bc30a3571c5ac6768a734847232d5cc",
}


def android_api_note(data: bytes) -> int | None:
    if data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    elf_class = data[4]
    endian = "<" if data[5] == 1 else ">"
    if elf_class == 2:
        header = struct.unpack_from(endian + "16sHHIQQQIHHHHHH", data, 0)
        ph_offset, ph_count, ph_size = header[5], header[10], header[9]
        ph_format = endian + "IIQQQQQQ"
    elif elf_class == 1:
        header = struct.unpack_from(endian + "16sHHIIIIIHHHHHH", data, 0)
        ph_offset, ph_count, ph_size = header[5], header[10], header[9]
        ph_format = endian + "IIIIIIII"
    else:
        raise ValueError(f"unsupported ELF class {elf_class}")
    for index in range(ph_count):
        program = struct.unpack_from(ph_format, data, ph_offset + index * ph_size)
        if program[0] != 4:
            continue
        note_offset = program[2] if elf_class == 2 else program[1]
        note_size = program[5] if elf_class == 2 else program[4]
        cursor = note_offset
        end = note_offset + note_size
        while cursor + 12 <= end:
            name_size, desc_size, _ = struct.unpack_from(endian + "III", data, cursor)
            cursor += 12
            name_end = cursor + ((name_size + 3) // 4) * 4
            name = data[cursor:name_end]
            cursor = name_end
            desc_end = cursor + ((desc_size + 3) // 4) * 4
            desc = data[cursor:desc_end]
            cursor = desc_end
            if name.startswith(b"Android") and len(desc) >= 4:
                return struct.unpack_from(endian + "I", desc, 0)[0]
    return None


def main(apk_path: str) -> int:
    path = Path(apk_path)
    with zipfile.ZipFile(path) as apk:
        for entry in ("lib/arm64-v8a/libmpv.so", "lib/armeabi-v7a/libmpv.so"):
            data = apk.read(entry)
            actual = hashlib.sha256(data).hexdigest()
            api = android_api_note(data)
            if api != EXPECTED_API:
                raise SystemExit(f"{entry}: expected Android API {EXPECTED_API}, got {api}")
            print(f"{entry}: OK size={len(data)} api={api} sha256={actual}")
        for entry, expected_sha256 in EXPECTED_HELPERS.items():
            data = apk.read(entry)
            actual = hashlib.sha256(data).hexdigest()
            if actual != expected_sha256:
                raise SystemExit(
                    f"{entry}: sha256={actual}; expected sha256={expected_sha256}"
                )
            print(f"{entry}: helper OK size={len(data)} sha256={actual}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
