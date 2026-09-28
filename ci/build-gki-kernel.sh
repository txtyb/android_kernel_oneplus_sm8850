#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Build the GKI kernel `Image` for the OnePlus 15 (SM8850 "canoe" / "infiniti")
# from the *official OnePlus OSS* kernel tree and pack it into an AnyKernel3 zip.
#
# Why this exists next to ci/build-kernel-platform.sh:
#   The ROM on this device ships the OnePlus OSS kernel
#     Linux version 6.12.23-android16-5-<scm>-<ab>-4k
#   (KMI generation 5), i.e. the OxygenOS 16.0.0 OSS release, while the
#   LineageOS-24.0-flavoured tree in this repository builds against
#   aosp kernel/common @ android16-6.12-2026-06 (6.12.81, KMI generation 6).
#   The two are *not* interchangeable: vendor modules carry the release string
#   (vermagic) and the KMI generation in their signature.
#
#   This script therefore builds only the GKI `Image` from the matching OSS
#   release and reproduces the ROM's release string so that the ROM's own
#   prebuilt vendor modules keep loading (boot-only replacement).
#
# Sources (no third-party forks):
#   kernel : OnePlusOSS/android_kernel_common_oneplus_sm8850
#            @ oneplus/sm8850_b_16.0.0_oneplus_15          (Linux 6.12.23)
#   tools  : aosp platform/prebuilts/{clang/host/linux-x86,clang-tools,
#            kernel-build-tools,rust,build-tools}
#   zip    : osm0sis/AnyKernel3 (+ ci/anykernel.sh from this repository)
#   ccache : apt
#
# Requirements: git, python3, curl, zip/unzip, bc bison flex, libssl-dev,
# libelf-dev, libdw-dev, cpio, dwarves, ccache.
set -euo pipefail

AOSP=${AOSP:-https://android.googlesource.com}
GH=${GH:-https://github.com}
KERNEL_REPO=${KERNEL_REPO:-OnePlusOSS/android_kernel_common_oneplus_sm8850}
KERNEL_REF=${KERNEL_REF:-oneplus/sm8850_b_16.0.0_oneplus_15}
PREBUILT_REF=${PREBUILT_REF:-main-kernel-2025}
CLANG_VERSION=${CLANG_VERSION:-clang-r536225}
RUST_VERSION=${RUST_VERSION:-1.82.0}
# Kernel release suffix of the ROM (must match its vendor modules byte for byte).
KERNEL_SUFFIX=${KERNEL_SUFFIX:-android16-5-gb2a876903b49-ab14541642-4k}
AK3_REPO=${AK3_REPO:-https://github.com/osm0sis/AnyKernel3}
AK3_REF=${AK3_REF:-master}
WS=${WS:-$PWD/gki-workspace}
JOBS=${JOBS:-$(nproc --all 2>/dev/null || echo 4)}
USE_CCACHE=${USE_CCACHE:-1}
CCACHE_DIR=${CCACHE_DIR:-$HOME/.ccache-gki}
PKG_BASE=${PKG_BASE:-OSS-OnePlus15-KMI5-gki}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m!!! %s\033[0m\n' "$*" >&2; }
die() { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }
disk() { df -h "$WS" | tail -n1 | sed 's/^/    disk: /'; }

PIDS=()
fetch_bg() { "$@" & PIDS+=($!); }
fetch_wait() {
	local pid rc=0
	for pid in "${PIDS[@]}"; do wait "$pid" || rc=1; done
	PIDS=()
	[ "$rc" -eq 0 ] || die "one or more fetches failed"
}
git_retry() {
	local i last=${!#}
	for i in 1 2 3; do
		git "$@" && return 0
		rm -rf "$last" 2>/dev/null || true
		sleep 5
	done
	return 1
}
clone_full() { # <url> <dir> [branch]
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
clone_sparse() { # <url> <dir> <branch> <path>...
	local url=$1 dir=$2 branch=$3
	shift 3
	[ -d "$dir/.git" ] && return 0
	mkdir -p "$(dirname "$dir")"
	log "clone (sparse: $*) $dir"
	git_retry clone --depth=1 --no-tags --filter=blob:none --sparse -b "$branch" "$url" "$dir" ||
		die "clone failed: $url"
	(cd "$dir" && git sparse-checkout set "$@") || die "sparse-checkout failed in $dir"
}

log "configuration"
cat <<EOF
  workspace     : $WS
  kernel source : $KERNEL_REPO @ $KERNEL_REF
  toolchain     : aosp $PREBUILT_REF ($CLANG_VERSION, rust $RUST_VERSION)
  kernel suffix : -$KERNEL_SUFFIX
  jobs          : $JOBS   ccache: $USE_CCACHE
EOF
for t in git python3 curl unzip zip make; do
	command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done
mkdir -p "$WS"
cd "$WS"
disk

# ---------------------------------------------------------------------------
# 1. kernel source (official OnePlus OSS) + toolchain
# ---------------------------------------------------------------------------
log "fetching sources and toolchain"
fetch_bg clone_full "$GH/$KERNEL_REPO" common "$KERNEL_REF"
fetch_bg clone_sparse "$AOSP/platform/prebuilts/clang/host/linux-x86" \
	prebuilts/clang/host/linux-x86 "$PREBUILT_REF" "$CLANG_VERSION" llvm-binutils-stable
fetch_bg clone_sparse "$AOSP/platform/prebuilts/clang-tools" prebuilts/clang-tools "$PREBUILT_REF" linux-x86
fetch_bg clone_full "$AOSP/kernel/prebuilts/build-tools" prebuilts/kernel-build-tools "$PREBUILT_REF"
fetch_bg clone_sparse "$AOSP/platform/prebuilts/rust" prebuilts/rust "$PREBUILT_REF" "linux-x86/$RUST_VERSION"
fetch_wait
disk

# follow the clang version pinned by the kernel tree when it differs
if [ -f common/build.config.constants ]; then
	CONST_CLANG=$(sed -n 's/^CLANG_VERSION=//p' common/build.config.constants | head -n1 | tr -d '\r')
	case "$CONST_CLANG" in
	"") ;;
	clang-*) CLANG_VERSION=$CONST_CLANG ;;
	*) CLANG_VERSION="clang-$CONST_CLANG" ;;
	esac
fi

log "verifying toolchain"
for p in \
	common/Makefile \
	prebuilts/clang/host/linux-x86/"$CLANG_VERSION"/bin/clang \
	prebuilts/clang-tools/linux-x86/bin/bindgen \
	prebuilts/rust/linux-x86/"$RUST_VERSION"/bin/rustc \
	prebuilts/kernel-build-tools/linux-x86/bin/pahole; do
	if [ -e "$p" ]; then echo "  ok      $p"; else warn "missing $p"; fi
done

# ---------------------------------------------------------------------------
# 2. reproduce the ROM's kernel release string
# ---------------------------------------------------------------------------
cd "$WS/common"
KVERSION="$(sed -n 's/^VERSION = //p' Makefile).$(sed -n 's/^PATCHLEVEL = //p' Makefile).$(sed -n 's/^SUBLEVEL = //p' Makefile)"
log "kernel source version: $KVERSION   release suffix: -$KERNEL_SUFFIX"
sed -i 's/ -dirty//g' scripts/setlocalversion || true
sed -i 's/\${scm_version}//g' scripts/setlocalversion || true
if grep -q '^CONFIG_LOCALVERSION=' arch/arm64/configs/gki_defconfig; then
	sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"-$KERNEL_SUFFIX\"|" arch/arm64/configs/gki_defconfig
else
	echo "CONFIG_LOCALVERSION=\"-$KERNEL_SUFFIX\"" >>arch/arm64/configs/gki_defconfig
fi
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' arch/arm64/configs/gki_defconfig

# ---------------------------------------------------------------------------
# 3. build environment
# ---------------------------------------------------------------------------
export PATH="$WS/prebuilts/clang/host/linux-x86/$CLANG_VERSION/bin:$WS/prebuilts/clang-tools/linux-x86/bin:$WS/prebuilts/rust/linux-x86/$RUST_VERSION/bin:$WS/prebuilts/kernel-build-tools/linux-x86/bin:$PATH"
export LIBCLANG_PATH="$WS/prebuilts/clang/host/linux-x86/$CLANG_VERSION/lib"
export RUSTC=rustc
export BINDGEN=bindgen
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export LLVM=1 LLVM_IAS=1
export HOSTCC=clang HOSTCXX=clang++
export LD=ld.lld HOSTLD=ld.lld AR=llvm-ar NM=llvm-nm AS=clang READELF=llvm-readelf
export OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size STRIP=llvm-strip
# Normalise the build path: scripts/gendwarfksyms (module CRC/ABI generation)
# cannot handle absolute paths, and -Wno-error keeps OEM code building.
export KCFLAGS="-fdebug-prefix-map=$WS=. -fmacro-prefix-map=$WS=. -ffile-prefix-map=$WS=. -no-canonical-prefixes -Wno-error -D__ANDROID_COMMON_KERNEL__"

MAKE_ARGS=(LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- OBJCOPY=llvm-objcopy O=out)

if [ "$USE_CCACHE" = "1" ]; then
	command -v ccache >/dev/null 2>&1 || die "USE_CCACHE=1 but ccache is not installed"
	mkdir -p "$CCACHE_DIR"
	export CCACHE_DIR CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-3G} CCACHE_COMPILERCHECK=none \
		CCACHE_BASEDIR="$WS" CCACHE_NOHASHDIR=true CCACHE_NOHARDLINK=true
	ccache -M "$CCACHE_MAXSIZE" >/dev/null
	printf '#!/bin/sh\nexec ccache %s/bin/clang "$@"\n' \
		"$WS/prebuilts/clang/host/linux-x86/$CLANG_VERSION" >"$WS/cc-wrapper"
	printf '#!/bin/sh\nexec %s/bin/ld.lld "$@"\n' \
		"$WS/prebuilts/clang/host/linux-x86/$CLANG_VERSION" >"$WS/ld-wrapper"
	chmod +x "$WS/cc-wrapper" "$WS/ld-wrapper"
	BUILD_CC="$WS/cc-wrapper" BUILD_LD="$WS/ld-wrapper"
	log "ccache: $(ccache --version | head -n1)"
else
	BUILD_CC=clang BUILD_LD=ld.lld
fi

# ---------------------------------------------------------------------------
# 4. build
# ---------------------------------------------------------------------------
log "gki_defconfig"
make -j"$JOBS" "${MAKE_ARGS[@]}" CC=clang LD=ld.lld gki_defconfig
log "building Image (jobs: $JOBS)"
make -j"$JOBS" "${MAKE_ARGS[@]}" CC="$BUILD_CC" LD="$BUILD_LD" Image

[ -f out/arch/arm64/boot/Image ] || die "build finished but out/arch/arm64/boot/Image is missing"
KRELEASE=$(make -s "${MAKE_ARGS[@]}" kernelrelease 2>/dev/null | tail -n1)
log "built kernel release: $KRELEASE"
[ "$KRELEASE" = "$KVERSION-$KERNEL_SUFFIX" ] ||
	warn "release string differs from the requested one ($KVERSION-$KERNEL_SUFFIX) - check before flashing"
log "Image size: $(stat -c '%s bytes' out/arch/arm64/boot/Image)"

# ---------------------------------------------------------------------------
# 5. AnyKernel3 package
# ---------------------------------------------------------------------------
cd "$WS"
log "packaging AnyKernel3"
rm -rf AnyKernel3
git clone --depth=1 --branch "$AK3_REF" "$AK3_REPO" AnyKernel3
rm -rf AnyKernel3/.git
cp common/out/arch/arm64/boot/Image AnyKernel3/Image
sed "s|@KERNEL_STRING@|OnePlus 15 (infiniti/canoe) OSS GKI $KRELEASE|" \
	"$REPO_ROOT/ci/anykernel.sh" >AnyKernel3/anykernel.sh
chmod 755 AnyKernel3/anykernel.sh
PKG_NAME="$PKG_BASE-$KRELEASE.zip"
(cd AnyKernel3 && rm -f "../$PKG_NAME" && zip -r9 "../$PKG_NAME" ./* >/dev/null)
[ -s "$PKG_NAME" ] || die "failed to create $PKG_NAME"
log "package: $WS/$PKG_NAME ($(stat -c '%s bytes' "$PKG_NAME"))"

{
	echo "kernel source : $KERNEL_REPO @ $KERNEL_REF  (Linux $KVERSION)"
	echo "toolchain     : aosp $PREBUILT_REF $CLANG_VERSION + rust $RUST_VERSION"
	echo "kernel release: $KRELEASE"
	echo "package       : $PKG_NAME"
	echo "flash with    : AnyKernel3 capable flasher (HorizonKernelFlasher / TWRP)"
	echo
	echo "--- Image ---"
	sha256sum common/out/arch/arm64/boot/Image
	echo "--- package ---"
	sha256sum "$PKG_NAME"
} | tee "$WS/build-info.txt"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo
		echo "### GKI build result"
		echo
		echo "- kernel release: \`$KRELEASE\`"
		echo "- package: \`$PKG_NAME\`"
		echo "- Image sha256: \`$(sha256sum common/out/arch/arm64/boot/Image | cut -d' ' -f1)\`"
	} >>"$GITHUB_STEP_SUMMARY"
fi

log "done"
