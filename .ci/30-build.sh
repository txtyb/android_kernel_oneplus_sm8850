#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the kernel. This is the same command LineageOS runs in
# vendor/lineage/build/tasks/kernel.mk for a device with
#   TARGET_KERNEL_PLATFORM_TARGET := canoe_perf
#   TARGET_KERNEL_SOURCE         := vendor/oneplus/sm8850
#   TARGET_KERNEL_BAZEL_FLAGS    += --//vendor/oneplus/sm8850:dtbo_config=...
#
#   cd kernel/platform/kernel-6.12 && ./tools/bazel \
#       --output_user_root=... --output_root=... \
#       run --experimental_convenience_symlinks=ignore --cpu=arm64 \
#       --repo_manifest <platform>:<manifest.xml> --config=stamp \
#       <flags> //vendor/oneplus/sm8850:canoe_perf_dist -- --destdir=...

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_dir "$KERNEL_PATH"
require_file "$KERNEL_PATH/tools/bazel"

mkdir -p "$OUT" "$DIST" "$BAZEL_OUT"

log "Generating $OUT/manifest.xml for kleaf --repo_manifest"
python3 "$REPO_ROOT/.ci/gen-kleaf-manifest.py" "$KERNEL_PLATFORM" "$PLATFORM_REL" > "$OUT/manifest.xml"
echo "  $(wc -l < "$OUT/manifest.xml") lines"

log "Building //$KERNEL_SRC_REL:${TARGET}_dist"
log "  dtbo_config = $DTBO_CONFIG"
echo "  extra flags = ${EXTRA_BAZEL_FLAGS:-(none)}"
echo "  bazel out   = $BAZEL_OUT"
echo "  dist dir    = $DIST"

cd "$KERNEL_PATH"

set -x
./tools/bazel \
    --output_user_root="$BAZEL_OUT" \
    --output_root="$BAZEL_OUT" \
    run \
    --experimental_convenience_symlinks=ignore \
    --cpu="$KERNEL_ARCH" \
    --repo_manifest "$KERNEL_PLATFORM:$OUT/manifest.xml" \
    --config=stamp \
    "--//$KERNEL_SRC_REL:dtbo_config=$DTBO_CONFIG" \
    $EXTRA_BAZEL_FLAGS \
    "//$KERNEL_SRC_REL:${TARGET}_dist" \
    -- --destdir="$DIST"
set +x

log "Dist contents"
ls -la "$DIST" || die "no dist directory produced"
du -sh "$DIST"

if [ ! -f "$DIST/Image" ]; then
    warn "no Image in $DIST -- listing everything for diagnosis:"
    find "$DIST" -maxdepth 2 -type f -printf '%10s  %p\n' | sort -k2 || true
    die "the build produced no kernel image"
fi

log "Disk space after the build"
df -h "$REPO_ROOT" || true
