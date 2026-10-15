# Kazumi 2.2.0 Issue #2687: v1.1.5 HLS backport plan

## Objective

Restore the API-21-compatible `libmpv` baseline used by Kazumi 1.9.4 / the
current 2.2.0 old-device package, while backporting only the HLS probing fix
that upstream shipped in the v1.3.0 native bundle for Issue #2687.

The released v1.3.0 ARM libraries caused a white screen on the real Snapdragon
450 / Android 8.1 device, so they must not be shipped again.

## Preserved baseline and evidence

- Original APK: `C:\bug335\Kazumi_2.2.0_universal_dlna_preview.apk`
- Original SHA-256: `dff6d44df9a6a99db8de48ae2dbab5f813866fc66b648745d35dd53991d126ea`
- Original package: `com.predidit.kazumi`, version `2.2.0`, versionCode `20200`,
  minSdk `24`.
- ARM `libmpv.so` entries match the official `libmpv-android-video-build`
  v1.1.5 assets byte-for-byte and carry the API-21 ELF note:
  - arm64: `6510999cdc493fb03bfd69669365c773d47183ae5af07ff10a5ea83bf5dce3c8`
  - armeabi-v7a: `baca22ea187daec88728c57f696e2c5c6c8273c74c9562d281f27b8491e98bb5`
- Upstream v1.3.0 commit `dd2bfba8209bcd22e2d4c79f125b40e619e637ed` replaces
  the v1.1.5 HLS probe block. The relevant behavior is to peek at the first
  segment, restore the read position, and pass a `NULL` probe URL for PNG/GIF
  disguised segments so a `.webp`/other image extension cannot win probing.

## Planned changes

1. Add a standalone FFmpeg patch that applies after the v1.1.5 Kazumi HLS
   patch and replaces only its first-segment probe block with the v1.3.0
   error-checked, URL-independent probe logic.
2. Change the release workflow to clone builder tag `v1.1.5`, whose build
   script uses Android API 21, copy the standalone backport patch after the
   existing patch, and build only ARM64 and ARMv7 JARs.
3. Keep the Flutter/Dart code, helper libraries, package identity, fixed
   signing certificate, and minSdk 24 unchanged. Replace only the two ARM
   `libmpv.so` entries and retain the old helper `.so` files.
4. Verify the patched FFmpeg source with `git apply --check`, verify the output
   JAR/APK hashes and API-21 ELF notes, then run Flutter tests/analyze, APK
   alignment/signature checks, and ARM API27 install/launch verification.
5. Replace the existing `v2.2.0-2687-fix` release asset `Kazumi.apk` only
   after CI passes. Keep the original APK and this plan/verification record.

## Risks and rollback

- The backport changes FFmpeg HLS probing only; it does not change the MPV
  ABI or renderer. If the patch fails to apply or runtime playback regresses,
  restore the preserved original APK and v1.1.5 JARs without changing the
  release tag.
- A successful CI build proves static/API/signature compatibility, but the
  user's physical Snapdragon 450 result remains the required final runtime
  confirmation.

## Verification evidence required

- v1.1.5 builder commit/tag and API-21 notes in both ARM `libmpv.so` files.
- No v1.3.0 library hashes or API-26 notes in the final APK.
- `apksigner verify`, `zipalign -c 4`, package/version/minSdk, and fixed
  certificate digest all pass.
- CI logs show the extra patch applied after the old Kazumi HLS patch.
- Release API shows exactly one `Kazumi.apk` asset with the final digest.
