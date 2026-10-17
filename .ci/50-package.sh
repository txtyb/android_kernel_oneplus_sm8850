#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Split the build output into the artifacts a PixelOS 17 install actually needs,
# one directory per purpose so each becomes its own workflow artifact:
#
#   out/release/anykernel3/   the flashable AnyKernel3 zip (written by 60-flashable.sh)
#   out/release/images/       raw partition images you fastboot flash
#   out/release/modules/      the .ko files and their load lists
#   out/release/config/       proof of what was built: the config read back out
#                             of Image, the SoC merged config, the kleaf manifest
#
# What the ROM build consumes from the dist dir (vendor/lineage/build/tasks/
# kernel.mk, platform-target path):
#   Image                     the kernel the ROM packs into boot.img
#   dtb.img / *.dtb           glued into boot.img (BOARD_INCLUDE_DTB_IN_BOOTIMG)
#   dtbo.img                  the dtbo partition (BOARD_KERNEL_SEPARATED_DTBO)
#   *.ko + system_dlkm.modules.load   vendor_dlkm / system_dlkm contents
# and the dist also carries ready-made boot.img / vendor_boot.img built by the
# SoC's own image rules (kleaf-scripts/image_opts.bzl + targets/canoe.bzl), which
# is where the correct cmdline, header version and page size come from.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_dir "$DIST"

STAMP="$(date -u +%Y%m%d)"
NAME="op15-infiniti-oss-kernel-${TARGET}-${STAMP}"
rm -rf "$RELEASE"
mkdir -p "$RELEASE/images" "$RELEASE/modules" "$RELEASE/config"

log "Collecting artifacts"
copy_if_present() {
    # copy_if_present <src-glob> <dest-subdir>
    local src dest found=0
    dest="$RELEASE/$2"
    mkdir -p "$dest"
    for src in $1; do
        [ -e "$src" ] || continue
        cp -f "$src" "$dest/" && found=$((found + 1))
    done
    [ "$found" -gt 0 ] || rmdir "$dest" 2>/dev/null || true
    echo "  $2: $found file(s)"
}

# --- raw images -----------------------------------------------------------
copy_if_present "$DIST/Image"                     "images"
copy_if_present "$DIST/dtb.img"                   "images"
copy_if_present "$DIST/dtb/*.dtb"                 "images"
copy_if_present "$DIST/*.dtb"                     "images"
# The DTBs may also sit a level or two down; fetch whatever the globs missed.
if [ -d "$RELEASE/images" ]; then
    find "$DIST" -type f -name '*.dtb' -exec cp -n {} "$RELEASE/images/" \; 2>/dev/null || true
fi
copy_if_present "$DIST/boot.img"                  "images"
copy_if_present "$DIST/*avb*boot*.img"            "images"
copy_if_present "$DIST/vendor_boot.img"           "images"
copy_if_present "$DIST/dtbo.img"                  "images"
copy_if_present "$DIST/vendor_dlkm.img"           "images"
copy_if_present "$DIST/system_dlkm*.img"          "images"
# A dist-provided init_boot.img if there ever is one; .ci/60-flashable.sh
# reports why it cannot be derived otherwise.
copy_if_present "$DIST/init_boot*.img"            "images"
copy_if_present "$DIST/*.dtbo"                    "images"

# --- modules --------------------------------------------------------------
copy_if_present "$DIST/vendor_dlkm.modules.load"  "modules"
copy_if_present "$DIST/system_dlkm.modules.load"  "modules"
copy_if_present "$DIST/*.ko"                      "modules"

# --- config / proof -------------------------------------------------------
copy_if_present "$DIST/kernel.config"             "config"
copy_if_present "$DIST/.config"                   "config"
copy_if_present "$OUT/manifest.xml"               "config"

# A complete listing so nothing is silently lost.
find "$DIST" -maxdepth 1 -type f -printf '%f\n' | sort > "$RELEASE/config/FILES_IN_DIST.txt"

cat > "$RELEASE/images/README-FLASH.txt" <<EOF
OnePlus 15 (infiniti) -- open-source kernel, $TARGET variant
Built $(date -u '+%Y-%m-%d %H:%M UTC') from:
  GKI/ACK   kernel/common            $(git -C "$KERNEL_PATH/common" rev-parse --short HEAD 2>/dev/null || echo '?')
  kleaf     kernel/build             $(git -C "$KERNEL_PATH/build/kernel" rev-parse --short HEAD 2>/dev/null || echo '?')
  CLO/SoC   $KERNEL_SRC_REL  $(git -C "$SOC_REPO" rev-parse --short HEAD 2>/dev/null || echo '?')
  modules   ${KERNEL_SRC_REL}-modules       $(git -C "$KERNEL_PATH/${KERNEL_SRC_REL}-modules" rev-parse --short HEAD 2>/dev/null || echo '?')
  dtrees    ${KERNEL_SRC_REL}-devicetrees   $(git -C "$KERNEL_PATH/${KERNEL_SRC_REL}-devicetrees" rev-parse --short HEAD 2>/dev/null || echo '?')
Requested config: $(grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/.ci/extra.config" | tr '\n' ' ')

THE FOUR ARTIFACTS
  op15-anykernel3-*   the flashable zip. Recommended: it swaps only the kernel
                      inside the boot.img already on your device.
  op15-images-*       raw images for fastboot (this directory).
  op15-modules-*      .ko files; not needed for a config-only change like this one.
  op15-config-*       kernel.config read back out of Image, plus the SoC config.

BACK UP FIRST
  Extract boot.img / init_boot.img / vendor_boot.img / dtbo.img / vbmeta.img from
  the PixelOS zip you are running right now (payload-dumper-go payload.bin) and
  keep them. Worst case you can also just re-sideload that same ROM zip.

INSTALL -- pick ONE
  a) AnyKernel3 zip, via a flasher that can run its update-binary
     (Kernel Flasher or a root shell). Touches only boot, leaves the ramdisk
     alone (split_boot/flash_boot), because the ramdisk lives in init_boot.

  b) fastboot (unlocked bootloader)
       adb reboot bootloader
       fastboot getvar current-slot            # note the slot
       fastboot flash boot images/boot.img
       fastboot reboot
     Flash dtbo/vendor_boot only if the device trees changed; for a config-only
     change they did not.

  Never flash super.img from here: it is the whole dynamic-partition image.

ROLLBACK
  fastboot flash boot     <your-stock-boot.img>
  fastboot flash init_boot <your-stock-init_boot.img>   # only if you touched it
  fastboot flash dtbo     <your-stock-dtbo.img>         # only if you touched it

VERIFY THE KERNEL IS LIVE
  adb shell uname -a
  adb shell zcat /proc/config.gz | grep CONFIG_TMPFS_XATTR     # expect =y

NOTES
  * config/kernel.config is the config read back out of Image -- what the kernel
    actually boots with, not what a fragment asked for.
  * init_boot.img is not in here: this build produces kernel-only boot images
    (the generic ramdisk comes from the ROM's GKI prebuilt), so there is nothing
    to derive it from, and a config-only change does not alter a ramdisk.
  * Our only functional config change is CONFIG_TMPFS_XATTR=y. It does not
    change the module ABI, so vendor_dlkm/system_dlkm need no update; the .ko
    files and both *.modules.load are included anyway.
  * boot.img here is signed with the GKI test key, not PixelOS's. PixelOS builds
    vbmeta with verification and verity disabled
    (BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3) and the bootloader is
    unlocked, which is why that is expected to boot.
EOF

log "Release layout"
du -sh "$RELEASE"/* 2>/dev/null || true
# sed, not head: with pipefail a SIGPIPE on find would fail the step.
find "$RELEASE" -type f -printf '%10s  %P\n' | sort -k2 | sed -n '1,40p'
echo "  ..."
find "$RELEASE" -type f | wc -l | xargs -I{} echo "  {} files total"
