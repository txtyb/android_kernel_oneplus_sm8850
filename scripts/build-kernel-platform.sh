#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Build the *complete* OnePlus 15 (SM8850 "canoe" / "infiniti") OSS kernel with
# kleaf, exactly the way LineageOS 24 / PixelOS 17 build it for the device.
#
# This assembles the Qualcomm "kernel platform" workspace:
#
#   $KROOT/                                  (ROOT_DIR, the bazel workspace)
#   ├── build/kernel/                        <- aosp kernel/build (kleaf)
#   ├── common/                              <- aosp kernel/common (ACK)
#   ├── common-modules/*                     <- aosp kernel/common-modules
#   ├── prebuilts/*                          <- aosp prebuilts (clang, rust, tools ...)
#   ├── external/*                           <- aosp external deps
#   ├── tools/{bazel,mkbootimg}
#   ├── vendor/oneplus/kernel/               <- THIS repository (the SoC repo)
#   ├── vendor/oneplus/sm8850-modules/       <- OPLUS vendor modules
#   └── vendor/oneplus/sm8850-devicetrees/   <- device trees
#
# and then runs:
#
#   ./tools/bazel run //vendor/oneplus/kernel:canoe_perf_dist -- --destdir=<dist>
#
# which produces Image, dtb.img, dtbo.img, boot.img (AVB signed), vendor_dlkm,
# system_dlkm and the module lists - i.e. the artifacts that
# device/oneplus/infiniti-kernel ships as the "prebuilt kernel".
#
# The project list/revisions come from LineageOS 24:
#   https://github.com/LineageOS/android/blob/lineage-24.0/snippets/kernel-6.12.xml
#   https://github.com/OnePlus-SM8850-Development/android_device_oneplus_sm8850-common/blob/lineage-24.0/lineage.dependencies
#
# Requirements: git, rsync, python3, curl, zip/unzip, bc bison flex, libssl-dev,
# libelf-dev, libdw-dev, cpio, dwarves.
set -euo pipefail

AOSP=${AOSP:-https://android.googlesource.com}
GH=${GH:-https://github.com}
# Workspace (ROOT_DIR) and the checkout of this soc repository that goes into
# vendor/oneplus/kernel.
KROOT=${KROOT:-$PWD/kernel-platform}
SOC_SRC=${SOC_SRC:-$PWD}
# Revisions (LineageOS 24 / lineage-24.0).
KLEAF_REF=${KLEAF_REF:-main-kernel-2025}
COMMON_REF=${COMMON_REF:-android16-6.12-2026-06}
PREBUILT_REF=${PREBUILT_REF:-main-kernel-2025}
NDK_REF=${NDK_REF:-main-kernel-2025}
MODULES_REPO=${MODULES_REPO:-OnePlus-SM8850-Development/android_kernel_oneplus_sm8850-modules}
MODULES_REF=${MODULES_REF:-lineage-24.0}
DEVICETREES_REPO=${DEVICETREES_REPO:-OnePlus-SM8850-Development/android_kernel_oneplus_sm8850-devicetrees}
DEVICETREES_REF=${DEVICETREES_REF:-lineage-24.0}
# Target: canoe_perf (user) or canoe_consolidate (userdebug).
TARGET=${TARGET:-canoe_perf}
JOBS=${JOBS:-$(nproc --all 2>/dev/null || echo 4)}
DIST_DIR=${DIST_DIR:-$KROOT/out/dist}
COMMON_MODULES=${COMMON_MODULES:-1}
EXTRA_BAZEL_FLAGS=${EXTRA_BAZEL_FLAGS:-}
SKIP_SYNC=${SKIP_SYNC:-0}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m!!! %s\033[0m\n' "$*" >&2; }
die() { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

git_retry() { # git_retry <clone args...>
	local i
	for i in 1 2 3; do
		if git "$@"; then return 0; fi
		# drop a partially fetched repository before retrying
		local last=${!#}
		rm -rf "$last" 2>/dev/null || true
		sleep 5
	done
	return 1
}

clone_full() { # clone_full <url> <dir> [branch]
	local url=$1 dir=$2 branch=${3:-}
	[ -d "$dir/.git" ] && return 0
	mkdir -p "$(dirname "$dir")"
	log "clone $dir"
	if [ -n "$branch" ]; then
		git_retry clone --depth=1 --no-tags -b "$branch" "$url" "$dir" || die "clone failed: $url"
	else
		git_retry clone --depth=1 --no-tags "$url" "$dir" || die "clone failed: $url"
	fi
}

clone_sparse() { # clone_sparse <url> <dir> <branch> <path>...
	local url=$1 dir=$2 branch=$3
	shift 3
	[ -d "$dir/.git" ] && return 0
	mkdir -p "$(dirname "$dir")"
	log "clone (sparse: $*) $dir"
	git_retry clone --depth=1 --no-tags --filter=blob:none --sparse -b "$branch" "$url" "$dir" ||
		die "clone failed: $url"
	(cd "$dir" && git sparse-checkout set "$@") || die "sparse-checkout failed in $dir"
}

# ---------------------------------------------------------------------------
# 0. checks
# ---------------------------------------------------------------------------
log "configuration"
cat <<EOF
  workspace    : $KROOT
  soc checkout : $SOC_SRC
  kleaf        : $KLEAF_REF   (aosp kernel/build)
  ACK common   : $COMMON_REF  (aosp kernel/common)
  prebuilts    : $PREBUILT_REF
  target       : $TARGET
  dist         : $DIST_DIR
EOF
for t in git rsync python3 curl; do
	command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done
[ -f "$SOC_SRC/soc_repo_path.bzl" ] || die "$SOC_SRC does not look like the OnePlus sm8850 SoC repo"

mkdir -p "$KROOT"
cd "$KROOT"

# ---------------------------------------------------------------------------
# 1. fetch the kernel platform
# ---------------------------------------------------------------------------
if [ "$SKIP_SYNC" != "1" ]; then
	log "fetching ACK + kleaf"
	clone_full "$AOSP/kernel/build" build/kernel "$KLEAF_REF"
	clone_full "$AOSP/kernel/common" common "$COMMON_REF"

	log "fetching prebuilts"
	clone_sparse "$AOSP/platform/prebuilts/clang/host/linux-x86" \
		prebuilts/clang/host/linux-x86 "$PREBUILT_REF" clang-r536225
	clone_full "$AOSP/platform/prebuilts/build-tools" prebuilts/build-tools "$PREBUILT_REF"
	clone_sparse "$AOSP/platform/prebuilts/clang-tools" prebuilts/clang-tools "$PREBUILT_REF" linux-x86
	clone_full "$AOSP/kernel/prebuilts/build-tools" prebuilts/kernel-build-tools "$PREBUILT_REF"
	clone_full "$AOSP/platform/prebuilts/rust" prebuilts/rust "$PREBUILT_REF"
	clone_full "$AOSP/platform/prebuilts/jdk/jdk11" prebuilts/jdk/jdk11 "$PREBUILT_REF"
	clone_full "$AOSP/platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8" \
		prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8 "$PREBUILT_REF"
	clone_full "$AOSP/toolchain/prebuilts/ndk/r26" prebuilts/ndk-r26 "$NDK_REF"

	log "fetching external dependencies"
	for p in \
		external/libcap external/libcap-ng external/lz4 external/pigz external/toybox \
		external/zlib external/zopfli external/dtc external/avb external/boringssl \
		external/compiler-rt external/elfutils external/googletest \
		external/arm-trusted-firmware external/open-dice external/python/absl-py \
		external/bazel-contrib-bazel_features external/bazel-skylib \
		external/bazelbuild-bazel-central-registry external/bazelbuild-platforms \
		external/bazelbuild-rules_cc external/bazelbuild-rules_license \
		external/bazelbuild-rules_pkg external/bazelbuild-rules_python \
		external/bazelbuild-rules_rust external/bazelbuild-rules_shell \
		external/rust/android-crates-io external/rust/crates/smoltcp \
		external/rust/crates/zune-inflate; do
		clone_full "$AOSP/platform/$p" "$p" "$PREBUILT_REF" &
	done
	wait
	clone_full "$AOSP/platform/system/tools/mkbootimg" tools/mkbootimg "$PREBUILT_REF"
	clone_full "$AOSP/platform/system/libufdt" external/libufdt "$PREBUILT_REF"

	if [ "$COMMON_MODULES" = "1" ]; then
		log "fetching common-modules"
		clone_full "$AOSP/kernel/common-modules/trusty" common-modules/trusty "$KLEAF_REF"
		clone_full "$AOSP/platform/external/virtio-media" common-modules/virtio-media "$KLEAF_REF"
	fi

	log "fetching OnePlus vendor repositories"
	clone_full "$GH/$MODULES_REPO" vendor/oneplus/sm8850-modules "$MODULES_REF" &
	clone_full "$GH/$DEVICETREES_REPO" vendor/oneplus/sm8850-devicetrees "$DEVICETREES_REF" &
	wait
fi

# ---------------------------------------------------------------------------
# 2. install this repository as vendor/oneplus/kernel
# ---------------------------------------------------------------------------
log "installing SoC repo into vendor/oneplus/kernel"
mkdir -p vendor/oneplus/kernel
rsync -a --delete \
	--exclude '.git/' \
	--exclude '.github/' \
	--exclude 'kernel-platform/' \
	--exclude 'kernel-workspace/' \
	"$SOC_SRC/" vendor/oneplus/kernel/

# ---------------------------------------------------------------------------
# 3. workspace glue (what the repo manifests express as <linkfile>)
# ---------------------------------------------------------------------------
log "creating workspace link files"
mkdir -p tools
ln -sfn build/kernel/kleaf/bazel.sh tools/bazel
ln -sfn build/kernel/kleaf/bzlmod/bazel.MODULE.bazel MODULE.bazel
ln -sfn build/kernel/kleaf/bzlmod/bazel.WORKSPACE.bzlmod WORKSPACE.bzlmod
ln -sfn vendor/oneplus/kernel/device.bazelrc device.bazelrc
mkdir -p build
ln -sfn ../vendor/oneplus/kernel/qcom_build_extensions build/qcom_build_extensions

# ---------------------------------------------------------------------------
# 4. build with kleaf
# ---------------------------------------------------------------------------
log "building //vendor/oneplus/kernel:${TARGET}_dist"
mkdir -p "$DIST_DIR"

BAZEL_FLAGS=(
	--check_visibility=false
	--no//build/kernel/kleaf:zstd_dwarf_compression
	--//build/kernel/kleaf:allow_ddk_unsafe_headers
	--//build/kernel/kleaf:socrepo=true
	--//build/qcom_build_extensions:qtisocrepo=true
	--//build/kernel/kleaf:user_ddk_unsafe_headers=//vendor/oneplus/kernel:unsafe_headers_qcom_group
	--config=stamp
)
# shellcheck disable=SC2206
[ -n "$EXTRA_BAZEL_FLAGS" ] && BAZEL_FLAGS+=($EXTRA_BAZEL_FLAGS)

./tools/bazel --output_user_root="$KROOT/out/bazel-root" run \
	"${BAZEL_FLAGS[@]}" \
	"//vendor/oneplus/kernel:${TARGET}_dist" -- --destdir="$DIST_DIR"

# ---------------------------------------------------------------------------
# 5. summarize
# ---------------------------------------------------------------------------
log "dist artifacts"
ls -la "$DIST_DIR" || true

KRELEASE=""
if [ -f "$DIST_DIR/Image" ]; then
	KRELEASE=$(grep -a -o 'Linux version [^ ]*' "$DIST_DIR/Image" | head -n1 | cut -d' ' -f3 || true)
fi
log "kernel release in Image: ${KRELEASE:-<unknown>}"

{
	echo "target        : //vendor/oneplus/kernel:${TARGET}_dist"
	echo "kleaf         : aosp kernel/build @ $KLEAF_REF"
	echo "ACK common    : aosp kernel/common @ $COMMON_REF"
	echo "prebuilts     : @ $PREBUILT_REF"
	echo "modules repo  : $MODULES_REPO @ $MODULES_REF"
	echo "devicetrees   : $DEVICETREES_REPO @ $DEVICETREES_REF"
	echo "kernel release: ${KRELEASE:-<unknown>}"
	echo
	echo "--- dist ---"
	(cd "$DIST_DIR" && sha256sum ./* 2>/dev/null | head -n 60) || true
} | tee "$KROOT/build-info.txt"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo
		echo "### kernel platform build"
		echo
		echo "- target: \`//vendor/oneplus/kernel:${TARGET}_dist\`"
		echo "- kernel release: \`${KRELEASE:-unknown}\`"
		echo "- dist: \`$DIST_DIR\`"
		echo
		echo '```'
		ls "$DIST_DIR" 2>/dev/null | head -n 80 || true
		echo '```'
	} >>"$GITHUB_STEP_SUMMARY"
fi

log "done"
