#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Collect the artifacts a PixelOS 17 install actually needs and zip them.
#
# What the ROM build consumes from the dist dir (see vendor/lineage/build/tasks/
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
mkdir -p "$RELEASE/$NAME"

log "Collecting artifacts"
copy_if_present() {
    # copy_if_present <src-glob> <dest-subdir>
    local src dest found=0
    dest="$RELEASE/$NAME/$2"
    mkdir -p "$dest"
    for src in $1; do
        [ -e "$src" ] || continue
        cp -f "$src" "$dest/" && found=$((found + 1))
    done
    [ "$found" -gt 0 ] || rmdir "$dest" 2>/dev/null || true
    echo "  $2: $found file(s)"
}

copy_if_present "$DIST/Image"                     "kernel"
copy_if_present "$DIST/dtb.img"                   "kernel"
copy_if_present "$DIST/dtb/*.dtb"                 "kernel"
copy_if_present "$DIST/*.dtb"                     "kernel"
# The DTBs may also sit a level or two down; fetch whatever the globs missed.
if [ -d "$RELEASE/$NAME/kernel" ]; then
    find "$DIST" -type f -name '*.dtb' -exec cp -n {} "$RELEASE/$NAME/kernel/" \; 2>/dev/null || true
fi
copy_if_present "$DIST/boot.img"                  "flash"
copy_if_present "$DIST/*avb*boot*.img"            "flash"
copy_if_present "$DIST/vendor_boot.img"           "flash"
copy_if_present "$DIST/dtbo.img"                  "flash"
copy_if_present "$DIST/vendor_dlkm.img"           "flash"
copy_if_present "$DIST/system_dlkm*.img"          "flash"
# A dist-provided init_boot.img if there ever is one; .ci/60-flashable.sh
# derives one otherwise.
copy_if_present "$DIST/init_boot*.img"            "flash"
copy_if_present "$DIST/vendor_dlkm.modules.load"  "modules"
copy_if_present "$DIST/system_dlkm.modules.load"  "modules"
copy_if_present "$DIST/*.ko"                      "modules"
copy_if_present "$DIST/*.dtbo"                    "dtbo"
copy_if_present "$DIST/kernel.config"             "config"
copy_if_present "$DIST/.config"                   "config"
copy_if_present "$OUT/manifest.xml"               "config"

# Anything with a dtb/dtb.img name that we did not already catch, plus a
# complete listing so nothing is silently lost.
find "$DIST" -maxdepth 1 -type f -printf '%f\n' | sort > "$RELEASE/$NAME/FILES_IN_DIST.txt"

cat > "$RELEASE/$NAME/README-FLASH.txt" <<EOF
OnePlus 15 (infiniti) -- open-source kernel, $TARGET variant
Built $(date -u '+%Y-%m-%d %H:%M UTC') from:
  GKI/ACK   kernel/common            $(git -C "$KERNEL_PATH/common" rev-parse --short HEAD 2>/dev/null || echo '?')
  kleaf     kernel/build             $(git -C "$KERNEL_PATH/build/kernel" rev-parse --short HEAD 2>/dev/null || echo '?')
  CLO/SoC   $KERNEL_SRC_REL  $(git -C "$SOC_REPO" rev-parse --short HEAD 2>/dev/null || echo '?')
  modules   ${KERNEL_SRC_REL}-modules       $(git -C "$KERNEL_PATH/${KERNEL_SRC_REL}-modules" rev-parse --short HEAD 2>/dev/null || echo '?')
  dtrees    ${KERNEL_SRC_REL}-devicetrees   $(git -C "$KERNEL_PATH/${KERNEL_SRC_REL}-devicetrees" rev-parse --short HEAD 2>/dev/null || echo '?')
Requested config: $(grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/.ci/extra.config" | tr '\n' ' ')

BOOT FIRST, KEEP THE STOCK IMAGES
  Extract boot.img / vendor_boot.img / dtbo.img from the PixelOS zip you are
  running right now (payload-dumper-go on payload.bin) and keep them. Flashing
  a kernel you cannot roll back from is how people end up with a brick.

INSTALL (unlocked bootloader, fastboot)
  adb reboot bootloader
  fastboot flash boot       flash/boot.img
  fastboot flash dtbo       flash/dtbo.img          # only if the DTBs changed
  fastboot reboot

  vendor_boot.img carries the vendor ramdisk and the DTBs; flash it only if you
  know your PixelOS build matches. The safest kernel-only swap is boot.img,
  because the GKI kernel lives there while the generic ramdisk is in init_boot.

  Do NOT flash super.img from here: it is the whole dynamic-partition image and
  will wipe your system.

ROLLBACK
  fastboot flash boot <your-stock-boot.img>
  fastboot flash dtbo <your-stock-dtbo.img>

VERIFY THE KERNEL IS LIVE
  adb shell uname -a
  adb shell zcat /proc/config.gz | grep CONFIG_TMPFS_XATTR

NOTES
  * kernel.config is the config read back out of Image, i.e. what the kernel
    actually booted with -- not just what a fragment asked for.
  tree.
  * .ci/60-flashable.sh also writes, next to this file:
      op15-infiniti-anykernel3-<target>-<date>.zip   AnyKernel3 zip: swaps the
        kernel inside your existing boot.img and leaves the ramdisk alone
        (split_boot/flash_boot), for devices with a separate init_boot.
      init_boot.img                                 DERIVED, optional, and
        normally unnecessary -- see the warning that step prints. Prefer the
        init_boot.img already on your device.
  * Our only functional config change is CONFIG_TMPFS_XATTR=y. It does not
    change the module ABI, so vendor_dlkm/system_dlkm normally need no update;
    the .ko files and both *.modules.load are included anyway.
  * These images are unsigned. PixelOS builds vbmeta with verification and
    verity disabled (BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3) and the
    bootloader is unlocked, so unsigned boot images are expected to boot.
EOF

log "Writing $NAME.zip"
# The images are already compressed, so level 1 is plenty and much faster.
( cd "$RELEASE" && zip -qr1 "$NAME.zip" "$NAME" )
mv "$RELEASE/$NAME.zip" "$RELEASE/"

log "Release contents"
find "$RELEASE/$NAME" -type f -printf '%10s  %P\n' | sort -k2
du -sh "$RELEASE"
