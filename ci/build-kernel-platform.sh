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
# kleaf (aosp kernel/build) comes from the OnePlus-SM8850-Development mirror of
# aosp kernel/build; the aosp repository is only a fallback.
KLEAF_REPO=${KLEAF_REPO:-$GH/OnePlus-SM8850-Development/kernel_build}
KLEAF_FALLBACK=${KLEAF_FALLBACK:-$AOSP/kernel/build}
# Workspace (ROOT_DIR) and the checkout of this soc repository that goes into
# vendor/oneplus/kernel.
KROOT=${KROOT:-$PWD/kernel-platform}
SOC_SRC=${SOC_SRC:-$PWD}
# Revisions (LineageOS 24 / lineage-24.0).
KLEAF_REF=${KLEAF_REF:-main-kernel-2025}
COMMON_REF=${COMMON_REF:-android16-6.12-2026-06}
PREBUILT_REF=${PREBUILT_REF:-main-kernel-2025}
# GBL (bootable/libbootloader) lives on its own branch in aosp.
GBL_REF=${GBL_REF:-gbl-android16}
COMMON_MODULES_REF=${COMMON_MODULES_REF:-android16-6.12}
NDK_REF=${NDK_REF:-main-kernel-2025}
COMMON_MODULES=${COMMON_MODULES:-1}
CLANG_VERSION=${CLANG_VERSION:-clang-r536225}
RUST_VERSION=${RUST_VERSION:-1.82.0}
MODULES_REPO=${MODULES_REPO:-OnePlus-SM8850-Development/android_kernel_oneplus_sm8850-modules}
MODULES_REF=${MODULES_REF:-lineage-24.0}
DEVICETREES_REPO=${DEVICETREES_REPO:-OnePlus-SM8850-Development/android_kernel_oneplus_sm8850-devicetrees}
DEVICETREES_REF=${DEVICETREES_REF:-lineage-24.0}
# Target: canoe_perf (user) or canoe_consolidate (userdebug).
TARGET=${TARGET:-canoe_perf}
JOBS=${JOBS:-$(nproc --all 2>/dev/null || echo 4)}
DIST_DIR=${DIST_DIR:-$KROOT/out/dist}
EXTRA_BAZEL_FLAGS=${EXTRA_BAZEL_FLAGS:-}
SKIP_SYNC=${SKIP_SYNC:-0}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m!!! %s\033[0m\n' "$*" >&2; }
die() { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }
disk() { df -h "$KROOT" | tail -n1 | sed 's/^/    disk: /'; }

PIDS=()
fetch_bg() { # fetch_bg <function> <args...>
	"$@" &
	PIDS+=($!)
}
fetch_wait() {
	local pid rc=0
	for pid in "${PIDS[@]}"; do
		wait "$pid" || rc=1
	done
	PIDS=()
	[ "$rc" -eq 0 ] || die "one or more fetches failed"
}

git_retry() { # git_retry <git args...>
	local i last
	last=${!#}
	for i in 1 2 3; do
		if git "$@"; then return 0; fi
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

clone_rust() { # clone_rust <url> <dir> <branch> [version]
	local url=$1 dir=$2 branch=$3 version=${4:-}
	[ -d "$dir/.git" ] && return 0
	mkdir -p "$(dirname "$dir")"
	log "clone (partial) $dir"
	git_retry clone --depth=1 --no-tags --filter=blob:none --sparse -b "$branch" "$url" "$dir" ||
		die "clone failed: $url"
	local path="linux-x86" cand
	local versions
	versions=$(git -C "$dir" ls-tree -d --name-only "HEAD:linux-x86" 2>/dev/null || true)
	for cand in "$version" "${version%%.u*}" "${version%%.p*}" "${version%%.*}"; do
		[ -z "$cand" ] && continue
		if printf '%s\n' "$versions" | grep -qx "$cand"; then
			path="linux-x86/$cand"
			break
		fi
	done
	if [ "$path" = "linux-x86" ] && [ -n "$version" ]; then
		warn "rust $version has no matching directory, checking out all of linux-x86"
	fi
	(cd "$dir" && git sparse-checkout set "$path") || die "sparse-checkout failed in $dir"
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
  prebuilts    : $PREBUILT_REF   clang=$CLANG_VERSION rust=$RUST_VERSION
  target       : $TARGET
  dist         : $DIST_DIR
EOF
for t in git rsync python3 curl; do
	command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done
[ -f "$SOC_SRC/soc_repo_path.bzl" ] || die "$SOC_SRC does not look like the OnePlus sm8850 SoC repo"

mkdir -p "$KROOT"
cd "$KROOT"
disk

# ---------------------------------------------------------------------------
# 1. fetch the kernel platform
# ---------------------------------------------------------------------------
if [ "$SKIP_SYNC" != "1" ]; then
	log "fetching ACK + kleaf"
	fetch_bg clone_full "$AOSP/kernel/common" common "$COMMON_REF"
	fetch_bg clone_full "$KLEAF_REPO" build/kernel "$KLEAF_REF"
	fetch_wait
	disk

	# kleaf derives the required clang/rust toolchains from the ACK tree's
	# build.config.constants (//common:build.config.constants via
	# kernel_toolchain_ext), so follow whatever it pins instead of guessing.
	if [ -f common/build.config.constants ]; then
		CONST_CLANG=$(sed -n 's/^CLANG_VERSION=//p' common/build.config.constants | head -n1 | tr -d '\r')
		CONST_RUST=$(sed -n 's/^RUSTC_VERSION=//p' common/build.config.constants | head -n1 | tr -d '\r')
		if [ -n "$CONST_CLANG" ] && [ "$CONST_CLANG" != "$CLANG_VERSION" ]; then
			# build.config.constants stores "r536225" while the checkout under
			# prebuilts/clang/host/linux-x86 is called "clang-r536225".
			case "$CONST_CLANG" in
			clang-*) ;;
			*) CONST_CLANG="clang-$CONST_CLANG" ;;
			esac
			log "clang version pinned by common: $CONST_CLANG (was $CLANG_VERSION)"
			CLANG_VERSION=$CONST_CLANG
		fi
		if [ -n "$CONST_RUST" ] && [ "$CONST_RUST" != "$RUST_VERSION" ]; then
			log "rust version pinned by common: $CONST_RUST (was $RUST_VERSION)"
			RUST_VERSION=$CONST_RUST
		fi
	fi

	log "fetching prebuilts"
	# The clang prebuilt repository is huge (every clang version ever shipped),
	# so only check out the toolchain we use plus the kleaf toolchain rules
	# (prebuilts/clang/host/linux-x86/kleaf/**) that kleaf's module extension
	# loads - a missing 'kleaf' directory aborts bazel with "Every .bzl file
	# must have a corresponding package".
	fetch_bg clone_sparse "$AOSP/platform/prebuilts/clang/host/linux-x86" \
		prebuilts/clang/host/linux-x86 "$PREBUILT_REF" \
		"$CLANG_VERSION" kleaf llvm-binutils-stable
	fetch_bg clone_full "$AOSP/platform/prebuilts/build-tools" prebuilts/build-tools "$PREBUILT_REF"
	fetch_bg clone_sparse "$AOSP/platform/prebuilts/clang-tools" prebuilts/clang-tools "$PREBUILT_REF" linux-x86
	fetch_bg clone_full "$AOSP/kernel/prebuilts/build-tools" prebuilts/kernel-build-tools "$PREBUILT_REF"
	fetch_bg clone_rust "$AOSP/platform/prebuilts/rust" prebuilts/rust "$PREBUILT_REF" "$RUST_VERSION"
	fetch_bg clone_full "$AOSP/platform/prebuilts/jdk/jdk11" prebuilts/jdk/jdk11 "$PREBUILT_REF"
	fetch_bg clone_full "$AOSP/platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8" \
		prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8 "$PREBUILT_REF"
	fetch_bg clone_full "$AOSP/toolchain/prebuilts/ndk/r26" prebuilts/ndk-r26 "$NDK_REF"
	fetch_wait
	disk

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
		fetch_bg clone_full "$AOSP/platform/$p" "$p" "$PREBUILT_REF"
	done
	fetch_bg clone_full "$AOSP/platform/system/tools/mkbootimg" tools/mkbootimg "$PREBUILT_REF"
	fetch_bg clone_full "$AOSP/platform/system/libufdt" external/libufdt "$PREBUILT_REF"
	# kleaf's WORKSPACE.bzlmod declares local_repository(name = "gbl", path =
	# "bootable/libbootloader/gbl"), so that path has to exist.
	fetch_bg clone_full "$AOSP/platform/bootable/libbootloader" bootable/libbootloader "$GBL_REF"
	fetch_bg clone_full "$AOSP/platform/system/core" system/core "$PREBUILT_REF"
	fetch_wait
	disk

	if [ "$COMMON_MODULES" = "1" ]; then
		log "fetching common-modules"
		fetch_bg clone_full "$AOSP/kernel/common-modules/trusty" common-modules/trusty "$KLEAF_REF"
		fetch_bg clone_full "$AOSP/platform/external/virtio-media" common-modules/virtio-media "$KLEAF_REF"
		fetch_bg clone_full "$AOSP/kernel/common-modules/wonder" common-modules/wonder \
			"$COMMON_MODULES_REF"
		fetch_bg clone_full "$AOSP/kernel/common-modules/virtual-device" \
			common-modules/virtual-device "$COMMON_MODULES_REF"
		fetch_wait
		disk
	fi

	log "fetching OnePlus vendor repositories"
	fetch_bg clone_full "$GH/$MODULES_REPO" vendor/oneplus/sm8850-modules "$MODULES_REF"
	fetch_bg clone_full "$GH/$DEVICETREES_REPO" vendor/oneplus/sm8850-devicetrees "$DEVICETREES_REF"
	fetch_wait
	disk
fi

# ---------------------------------------------------------------------------
# 1b. verify the platform (and repair what is missing)
# ---------------------------------------------------------------------------
log "verifying platform layout"
if [ ! -f build/kernel/kleaf/bazel.sh ]; then
	warn "build/kernel has no kleaf/bazel.sh - contents: $(ls build/kernel 2>/dev/null | tr '\n' ' ')"
	warn "falling back to $KLEAF_FALLBACK"
	rm -rf build/kernel
	git_retry clone --depth=1 --no-tags -b "$KLEAF_REF" "$KLEAF_FALLBACK" build/kernel ||
		die "cannot fetch kleaf (kernel/build)"
fi
[ -f common/Makefile ] || die "common/ (ACK) is missing"
[ -d vendor/oneplus/sm8850-modules ] || die "vendor/oneplus/sm8850-modules is missing"
[ -d vendor/oneplus/sm8850-devicetrees ] || die "vendor/oneplus/sm8850-devicetrees is missing"

for p in \
	build/kernel/kleaf/bazel.sh \
	build/kernel/kleaf/bzlmod/bazel.MODULE.bazel \
	build/kernel/kleaf/bzlmod/bazel.WORKSPACE.bzlmod \
	prebuilts/build-tools/linux_musl-x86/bin/py3-cmd \
	prebuilts/kernel-build-tools/bazel/linux-x86_64/bazel \
	prebuilts/clang/host/linux-x86/"$CLANG_VERSION"/bin/clang \
	prebuilts/clang/host/linux-x86/kleaf/clang_toolchain_repository.bzl \
	prebuilts/jdk/jdk11 \
	bootable/libbootloader/gbl \
	tools/mkbootimg/mkbootimg.py; do
	if [ -e "$p" ]; then echo "  ok      $p"; else warn "missing $p"; fi
done
ls -la build/kernel | head -n 12 || true

# ---------------------------------------------------------------------------
# 2. install this repository as vendor/oneplus/kernel
# ---------------------------------------------------------------------------
log "installing SoC repo into vendor/oneplus/kernel"
mkdir -p vendor/oneplus/kernel
rsync -a --delete \
	--exclude '.git/' \
	--exclude '.github/' \
	--exclude 'ci/' \
	--exclude 'kernel-platform/' \
	--exclude 'kernel-workspace/' \
	"$SOC_SRC/" vendor/oneplus/kernel/

# ---------------------------------------------------------------------------
# 3. workspace glue (what the repo manifests express as <linkfile>)
# ---------------------------------------------------------------------------
# NOTE on device.bazelrc: the SoC repo ships one, but it sets the OPLUS-only
# build setting //build/kernel/kleaf:socrepo, which does not exist in the aosp
# kleaf this tree is built with (kleaf/common.bazelrc does
# "try-import %workspace%/device.bazelrc", so the file is picked up
# automatically).  The LineageOS kernel-6.12 manifest does not create it either;
# every setting we actually need is passed on the bazel command line below.
log "creating workspace link files"
mkdir -p tools
ln -sfn ../build/kernel/kleaf/bazel.sh tools/bazel
ln -sfn build/kernel/kleaf/bzlmod/bazel.MODULE.bazel MODULE.bazel
ln -sfn build/kernel/kleaf/bzlmod/bazel.WORKSPACE.bzlmod WORKSPACE.bzlmod
mkdir -p build
ln -sfn ../vendor/oneplus/kernel/qcom_build_extensions build/qcom_build_extensions
rm -f device.bazelrc
for l in tools/bazel MODULE.bazel WORKSPACE.bzlmod build/qcom_build_extensions; do
	printf '  %-32s -> %s\n' "$l" "$(readlink "$l" 2>/dev/null || echo '(not a symlink)')"
	[ -e "$l" ] || warn "$l is dangling"
done

# ---------------------------------------------------------------------------
# 4. build with kleaf
# ---------------------------------------------------------------------------
log "building //vendor/oneplus/kernel:${TARGET}_dist"
mkdir -p "$DIST_DIR"

KLEAF_BAZEL="$KROOT/build/kernel/kleaf/bazel.sh"
[ -f "$KLEAF_BAZEL" ] || die "kleaf entry point not found: $KLEAF_BAZEL"
[ -x "$KLEAF_BAZEL" ] || chmod +x "$KLEAF_BAZEL"

BAZEL_FLAGS=(
	--check_visibility=false
	--no//build/kernel/kleaf:zstd_dwarf_compression
	--//build/kernel/kleaf:allow_ddk_unsafe_headers
	--//build/qcom_build_extensions:qtisocrepo=true
	--//build/kernel/kleaf:user_ddk_unsafe_headers=//vendor/oneplus/kernel:unsafe_headers_qcom_group
	--config=stamp
)
# NOTE: the soc repo's device.bazelrc also sets --//build/kernel/kleaf:socrepo=true,
# but that flag only exists in the OPLUS fork of kleaf.  LineageOS builds this tree
# with the aosp kernel/build, and aosp kleaf has no such build setting, so it is
# deliberately not passed here (aosp kleaf also ignores device.bazelrc).
# shellcheck disable=SC2206
[ -n "$EXTRA_BAZEL_FLAGS" ] && BAZEL_FLAGS+=($EXTRA_BAZEL_FLAGS)

bash "$KLEAF_BAZEL" --output_user_root="$KROOT/out/bazel-root" run \
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
	echo "prebuilts     : @ $PREBUILT_REF (clang $CLANG_VERSION, rust $RUST_VERSION)"
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
