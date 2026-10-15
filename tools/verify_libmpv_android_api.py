"""Verify ARM libmpv Android API notes in a JAR or APK."""

from __future__ import annotations

import hashlib
import struct
import sys
import zipfile
from pathlib import Path


EXPECTED_ENTRIES = {
    "lib/arm64-v8a/libmpv.so",
    "lib/armeabi-v7a/libmpv.so",
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
        program = struct.unpack_from(
            ph_format, data, ph_offset + index * ph_size
        )
        program_type = program[0]
        note_offset = program[2] if elf_class == 2 else program[1]
        note_size = program[5] if elf_class == 2 else program[4]
        if program_type != 4:  # PT_NOTE
            continue
        cursor = note_offset
        end = note_offset + note_size
        while cursor + 12 <= end:
            name_size, desc_size, _ = struct.unpack_from(
                endian + "III", data, cursor
            )
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


def read_entries(path: Path) -> dict[str, bytes]:
    with zipfile.ZipFile(path) as archive:
        return {
            name: archive.read(name)
            for name in EXPECTED_ENTRIES
            if name in archive.namelist()
        }


def main(path_string: str, expected_api: int = 24) -> int:
    path = Path(path_string)
    entries = read_entries(path)
    missing = EXPECTED_ENTRIES - entries.keys()
    if missing:
        raise SystemExit(f"missing entries: {sorted(missing)}")
    for name in sorted(entries):
        data = entries[name]
        api = android_api_note(data)
        digest = hashlib.sha256(data).hexdigest()
        print(f"{name}: size={len(data)} api={api} sha256={digest}")
        if api != expected_api:
            raise SystemExit(
                f"{name}: expected Android API {expected_api}, got {api}"
            )
    return 0


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        raise SystemExit("usage: verify_libmpv_android_api.py ARCHIVE [API]")
    raise SystemExit(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) == 3 else 24))
