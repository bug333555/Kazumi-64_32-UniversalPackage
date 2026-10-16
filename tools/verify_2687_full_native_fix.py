"""Verify a full v1.3.0 HLS migration built with the API-21 renderer profile."""

from __future__ import annotations

import hashlib
import struct
import sys
import zipfile
from pathlib import Path


ARM_ENTRIES = (
    "lib/arm64-v8a/libmpv.so",
    "lib/armeabi-v7a/libmpv.so",
)
HELPERS = {
    "lib/arm64-v8a/libmediakitandroidhelper.so":
        "a6862031015e390aa8a64536411132cf4df6a5a9dcf782f0d68b995380a1cccb",
    "lib/armeabi-v7a/libmediakitandroidhelper.so":
        "698ce761945a3bdaf6ffe690e715fc510bc30a3571c5ac6768a734847232d5cc",
}
REQUIRED_MARKERS = (
    b"HLS playlist with non-standard extension/MIME, lowering probe score",
    b"Segment starts with png magic, probing without filename",
    b"Segment starts with gif magic, probing without filename",
    b"Kazumi: Ad skipped! Offset adjusted by",
    b"Kazumi: Video resuming at PTS=",
    b"Kazumi: Audio resuming at PTS=",
    b"Kazumi: Stream has DISCONTINUITY tags, ad filtering enabled",
    b"Kazumi: Ad detected! PTS jumped",
)


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
        if program[0] != 4:  # PT_NOTE
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


def read_entries(path: Path) -> dict[str, bytes]:
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        entries = {
            name: archive.read(name)
            for name in (*ARM_ENTRIES, *HELPERS)
            if name in names
        }
    if path.suffix.lower() == ".jar":
        present = [name for name in ARM_ENTRIES if name in entries]
        if len(present) != 1:
            raise SystemExit(f"{path.name}: expected one ARM libmpv entry, found {present}")
        helper = present[0].replace("libmpv.so", "libmediakitandroidhelper.so")
        if helper not in entries:
            raise SystemExit(f"{path.name}: missing {helper}")
    else:
        missing = [name for name in (*ARM_ENTRIES, *HELPERS) if name not in entries]
        if missing:
            raise SystemExit(f"{path.name}: missing entries {missing}")
    return entries


def main(path_string: str, expected_api: int = 21) -> int:
    path = Path(path_string)
    entries = read_entries(path)
    mpv_blobs = [entries[name] for name in ARM_ENTRIES if name in entries]
    for name, data in entries.items():
        if name.endswith("libmpv.so"):
            api = android_api_note(data)
            digest = hashlib.sha256(data).hexdigest()
            if api != expected_api:
                raise SystemExit(f"{name}: expected Android API {expected_api}, got {api}")
            if b"libvulkan.so" in data:
                raise SystemExit(f"{name}: Vulkan NEEDED entry is present; old renderer profile rejected")
            missing_markers = [marker.decode("ascii") for marker in REQUIRED_MARKERS if marker not in data]
            if missing_markers:
                raise SystemExit(f"{name}: missing v1.3 HLS markers {missing_markers}")
            print(f"{name}: OK size={len(data)} api={api} sha256={digest}")
    if path.suffix.lower() != ".jar":
        for name, expected in HELPERS.items():
            actual = hashlib.sha256(entries[name]).hexdigest()
            if actual != expected:
                raise SystemExit(f"{name}: sha256={actual}; expected {expected}")
            print(f"{name}: helper OK size={len(entries[name])} sha256={actual}")
    if len(mpv_blobs) != (1 if path.suffix.lower() == ".jar" else 2):
        raise SystemExit(f"{path.name}: unexpected libmpv entry count {len(mpv_blobs)}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        raise SystemExit("usage: verify_2687_full_native_fix.py ARCHIVE [API]")
    raise SystemExit(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) == 3 else 21))
