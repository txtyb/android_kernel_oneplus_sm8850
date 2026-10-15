#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Apply configs/<fragment> to the SoC kernel's defconfig dict.
#
# Why a dict and not a defconfig file: the Qualcomm CLO tree keeps its vendor
# configuration in vendor/oneplus/sm8850/configs/<soc>_<variant>.bzl and kleaf
# (kleaf-scripts/defconfig_fragment.bzl) converts it back into a defconfig
# fragment merged after gki_defconfig. See .ci/apply-config.py.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FRAGMENT="$CONFIG_FRAGMENT"
DEFCONFIG="$SOC_REPO/configs/$DEFCONFIG_DICT"

require_dir "$SOC_REPO"
require_file "$DEFCONFIG"
require_file "$FRAGMENT"

log "Merging $(basename "$FRAGMENT") into configs/$DEFCONFIG_DICT"
log "  (gki_defconfig has CONFIG_TMPFS=y but never sets TMPFS_XATTR, and"
log "   fs/Kconfig declares it 'default n' -- so it is 'n' unless we ask)"

set +e
python3 "$REPO_ROOT/.ci/apply-config.py" "$DEFCONFIG" "$FRAGMENT"
rc=$?
set -e
case "$rc" in
    0) log "config dict updated" ;;
    2) log "config dict already up to date" ;;
    *) die "apply-config.py failed (exit $rc)" ;;
esac

log "TMPFS entries now in $DEFCONFIG_DICT"
grep -n '"CONFIG_TMPFS' "$DEFCONFIG" || warn "no CONFIG_TMPFS* entry found"

if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -d "$SOC_REPO/.git" ]; then
    {
        echo "### Kernel config change"
        echo
        echo '```diff'
        git -C "$SOC_REPO" --no-pager diff -- "configs/$DEFCONFIG_DICT" || true
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi

log "Diff against the checkout"
git -C "$SOC_REPO" --no-pager diff --stat -- "configs/$DEFCONFIG_DICT" || true
