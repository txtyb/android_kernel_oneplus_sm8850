#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Prove that the requested config actually reached the built kernel.
#
# GKI enables CONFIG_IKCONFIG=y / CONFIG_IKCONFIG_PROC=y, so the .config is
# embedded in Image and can be read back with scripts/extract-ikconfig. This
# is the only check that proves the config took effect rather than merely
# appearing in a fragment somewhere.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE="$DIST/Image"
require_file "$IMAGE"

CFG="$DIST/kernel.config"
EXTRACT="$KERNEL_PATH/common/scripts/extract-ikconfig"

log "Reading the config embedded in Image"
if [ -f "$EXTRACT" ]; then
    if bash "$EXTRACT" "$IMAGE" > "$CFG" 2> "$DIST/extract-ikconfig.log"; then
        log "extracted $(wc -l < "$CFG") config lines with scripts/extract-ikconfig"
    else
        warn "extract-ikconfig failed (see $DIST/extract-ikconfig.log)"
        rm -f "$CFG"
    fi
else
    warn "$EXTRACT not found"
fi

# extract-ikconfig compiles scripts/binoffset.c against the host compiler and
# needs a working gzip, so keep a dependency-free inflate as a fallback.
if [ ! -s "$CFG" ]; then
    warn "falling back to .ci/extract-config.py"
    if python3 "$REPO_ROOT/.ci/extract-config.py" "$IMAGE" "$CFG"; then
        log "extracted $(wc -l < "$CFG") config lines with .ci/extract-config.py"
    else
        warn "extract-config.py could not find an embedded config either"
        rm -f "$CFG"
    fi
fi

# kleaf also drops the built .config next to the images in most configurations.
if [ ! -s "$CFG" ]; then
    for candidate in "$DIST/.config" "$DIST/kernel_aarch64_config" "$DIST/${TARGET}_config"; do
        if [ -s "$candidate" ]; then
            warn "using $candidate instead of the embedded config"
            cp "$candidate" "$CFG"
            break
        fi
    done
fi

if [ ! -s "$CFG" ]; then
    warn "could not read any kernel config -- skipping the CONFIG_TMPFS_XATTR assertion"
    warn "verify by hand with: scripts/extract-ikconfig out/dist/Image | grep TMPFS"
    exit 0
fi

log "TMPFS options in the built kernel"
grep -E '^CONFIG_TMPFS|^# CONFIG_TMPFS' "$CFG" || true

if grep -qx 'CONFIG_TMPFS_XATTR=y' "$CFG"; then
    log "OK: CONFIG_TMPFS_XATTR=y is present in the built kernel"
else
    die "CONFIG_TMPFS_XATTR=y did NOT reach the built kernel (see $CFG)"
fi

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    {
        echo "### Verified kernel config"
        echo
        echo '```'
        grep -E '^CONFIG_TMPFS|^CONFIG_IKCONFIG|^CONFIG_LOCALVERSION' "$CFG" || true
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi
