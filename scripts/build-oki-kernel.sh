#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Build the OnePlus 15 (Qualcomm SM8850 "canoe" / device "infiniti") OSS GKI
# kernel `Image` from the matching "common" (ACK + OPLUS) source tree and pack
# it into an AnyKernel3 flashable zip.
#
# Why only the Image?
#   On SM8850 the boot chain is GKI based: `boot` carries the kernel `Image`
#   while the generic ramdisk lives in `init_boot`, and the vendor drivers are
#   shipped as modules (vendor_dlkm / system_dlkm) by the ROM.  An AnyKernel3
#   package that replaces `Image` in place therefore gives a custom kernel that
#   keeps the ROM's own ramdisk, device tree and module set.
#
# Requirements (Debian/Ubuntu style host):
#   bc bison flex libssl-dev libelf-dev libdw-dev cpio xz-utils zip unzip
#   wget curl dwarves (pahole) python3 git
#
# The script is used both by .github/workflows/build-kernel.yml and locally.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration - every value can be overridden through the environment.
# ---------------------------------------------------------------------------
# Workspace that holds the downloaded sources and toolchain.
WS=${WS:-$PWD/kernel-workspace}
# "common" (ACK + OPLUS) kernel tree to compile: <github-owner/repo> + branch.
KERNEL_REPO=${KERNEL_REPO:-cctv18/android_kernel_common_oneplus_sm8850}
KERNEL_REF=${KERNEL_REF:-oneplus/sm8850_v_16.0.0_oneplus_15}
# AOSP LLVM/Clang 19 (r536225, matches build.config.constants of the OPLUS tree)
# plus Rust 1.82 and the host build-tools, distributed as release assets.
TOOLCHAIN_REPO=${TOOLCHAIN_REPO:-cctv18/oneplus_sm8650_toolchain}
TOOLCHAIN_TAG=${TOOLCHAIN_TAG:-LLVM-Clang19-r536225}
# Kernel release suffix that must be reproduced so that the ROM's prebuilt
# vendor modules (vermagic) keep loading.  Default = OnePlus 15 / OOS 16.0.0
# (Linux 6.12.23) release string as used by the OEM kernel.
KERNEL_SUFFIX=${KERNEL_SUFFIX:-android16-5-ga8f88ad96df3-ab13929693-4k}
# AnyKernel3 packaging.
AK3_REPO=${AK3_REPO:-https://github.com/osm0sis/AnyKernel3}
AK3_REF=${AK3_REF:-master}
# the final zip is named $PKG_BASE-<full kernel release>.zip
PKG_BASE=${PKG_BASE:-OKI-OnePlus15}
# Misc.
JOBS=${JOBS:-$(nproc --all 2>/dev/null || echo 4)}
USE_CCACHE=${USE_CCACHE:-0}
CCACHE_DIR=${CCACHE_DIR:-$HOME/.ccache-oki}
SKIP_TOOLCHAIN=${SKIP_TOOLCHAIN:-0}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m!!! %s\033[0m\n' "$*" >&2; }
die() { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> <output>
	local url=$1 out=$2
	log "download $(basename "$out")"
	if command -v curl >/dev/null 2>&1; then
		curl -fL --retry 5 --retry-delay 5 --retry-all-errors -o "$out" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q --tries=5 --waitretry=5 -O "$out" "$url"
	else
		die "neither curl nor wget is available"
	fi
	[ -s "$out" ] || die "download failed: $url"
}

# ---------------------------------------------------------------------------
# 0. sanity
# ---------------------------------------------------------------------------
log "configuration"
cat <<EOF
  workspace      : $WS
  kernel source  : $KERNEL_REPO @ $KERNEL_REF
  toolchain      : $TOOLCHAIN_REPO @ $TOOLCHAIN_TAG (clang + rust + build-tools)
  kernel suffix  : $KERNEL_SUFFIX
  jobs           : $JOBS
  ccache         : $USE_CCACHE
EOF

for tool in make unzip zip git python3; do
	command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done

mkdir -p "$WS"
cd "$WS"

# ---------------------------------------------------------------------------
# 1. toolchain (clang 19 / rust 1.82 / host build-tools)
# ---------------------------------------------------------------------------
if [ "$SKIP_TOOLCHAIN" != "1" ]; then
	if [ ! -x "$WS/clang19/bin/clang" ]; then
		fetch "https://github.com/$TOOLCHAIN_REPO/releases/download/$TOOLCHAIN_TAG/clang-r536225.zip" clang.zip
		mkdir -p clang19
		unzip -q -o clang.zip -d clang19
		rm -f clang.zip
	fi
	if [ ! -x "$WS/rust/bin/rustc" ]; then
		fetch "https://github.com/$TOOLCHAIN_REPO/releases/download/$TOOLCHAIN_TAG/rust.zip" rust.zip
		mkdir -p rust
		unzip -q -o rust.zip -d rust
		rm -f rust.zip
	fi
	if [ ! -d "$WS/build-tools/bin" ] && [ ! -d "$WS/build-tools/path" ]; then
		fetch "https://github.com/$TOOLCHAIN_REPO/releases/download/$TOOLCHAIN_TAG/build-tools.zip" build-tools.zip
		unzip -q -o build-tools.zip
		rm -f build-tools.zip
	fi
fi

export PATH="$WS/clang19/bin:$WS/build-tools/bin:$WS/build-tools/path/linux-x86:$WS/rust/bin:$PATH"
export LIBCLANG_PATH="$WS/clang19/lib"

command -v clang >/dev/null 2>&1 || die "clang not found in $WS/clang19/bin"
log "clang: $(clang --version | head -n1)"
rustc -V 2>/dev/null || warn "rustc not found - CONFIG_RUST will not be buildable"
bindgen --version 2>/dev/null || warn "bindgen not found in PATH"
pahole --version 2>/dev/null || warn "pahole (dwarves) not found - BTF generation may fail"

# ---------------------------------------------------------------------------
# 2. kernel source
# ---------------------------------------------------------------------------
if [ ! -f "$WS/common/Makefile" ]; then
	fetch "https://github.com/$KERNEL_REPO/archive/refs/heads/$KERNEL_REF.zip" common.zip
	rm -rf "$WS/common" "$WS/src"
	mkdir -p src
	unzip -q -o common.zip -d src
	rm -f common.zip
	# the archive expands into a single directory: <repo>-<branch with dashes>
	set -- "$WS"/src/*
	[ -d "$1" ] || die "unexpected archive layout"
	mv "$1" "$WS/common"
	rmdir "$WS/src" 2>/dev/null || true
fi

cd "$WS/common"
log "kernel source: $(sed -n 's/^VERSION = //p' Makefile).$(sed -n 's/^PATCHLEVEL = //p' Makefile).$(sed -n 's/^SUBLEVEL = //p' Makefile)"

# ---------------------------------------------------------------------------
# 3. reproduce the OEM kernel release string
#    The ROM's vendor modules are built against the OEM release (vermagic), so
#    the Image we build has to report exactly the same <version>-<suffix>.
# ---------------------------------------------------------------------------
log "setting kernel release suffix to: -$KERNEL_SUFFIX"
if [ -f scripts/setlocalversion ]; then
	sed -i 's/ -dirty//g' scripts/setlocalversion || true
	# never let a git/scm suffix leak into the release string
	sed -i 's/\${scm_version}//g' scripts/setlocalversion || true
fi
if grep -q '^CONFIG_LOCALVERSION=' arch/arm64/configs/gki_defconfig; then
	sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"-$KERNEL_SUFFIX\"|" \
		arch/arm64/configs/gki_defconfig
else
	echo "CONFIG_LOCALVERSION=\"-$KERNEL_SUFFIX\"" >>arch/arm64/configs/gki_defconfig
fi
if grep -q '^CONFIG_LOCALVERSION_AUTO=y' arch/arm64/configs/gki_defconfig; then
	sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' \
		arch/arm64/configs/gki_defconfig
fi

# ---------------------------------------------------------------------------
# 4. build environment
# ---------------------------------------------------------------------------
export RUSTC=rustc
export BINDGEN=bindgen
export CC=clang
export HOSTCC=clang HOSTCXX=clang++
export LD=ld.lld HOSTLD=ld.lld
export AR=llvm-ar NM=llvm-nm AS=clang READELF=llvm-readelf
export OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump OBJSIZE=llvm-size STRIP=llvm-strip
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export LLVM=1 LLVM_IAS=1

# Map the absolute workspace prefix away: scripts/gendwarfksyms (used for the
# module ABI/CRC generation) cannot cope with absolute paths in DWARF.
# -Wno-error keeps OEM code with newer compiler warnings building.
export KCFLAGS="-fdebug-prefix-map=$WS=. -fmacro-prefix-map=$WS=. -ffile-prefix-map=$WS=. -no-canonical-prefixes -Wno-error -D__ANDROID_COMMON_KERNEL__"

MAKE_COMMON=(LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- OBJCOPY=llvm-objcopy O=out)

if [ "$USE_CCACHE" = "1" ]; then
	command -v ccache >/dev/null 2>&1 || die "USE_CCACHE=1 but ccache is not installed"
	mkdir -p "$CCACHE_DIR"
	export CCACHE_DIR CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-3G} CCACHE_COMPILERCHECK=none \
		CCACHE_BASEDIR="$WS" CCACHE_NOHASHDIR=true CCACHE_NOHARDLINK=true
	ccache -M "$CCACHE_MAXSIZE" >/dev/null
	cat >"$WS/cc-wrapper" <<EOF
#!/bin/sh
exec ccache "$WS/clang19/bin/clang" "\$@"
EOF
	cat >"$WS/ld-wrapper" <<EOF
#!/bin/sh
exec "$WS/clang19/bin/ld.lld" "\$@"
EOF
	chmod +x "$WS/cc-wrapper" "$WS/ld-wrapper"
	log "ccache enabled: $(ccache --version | head -n1)"
fi

# ---------------------------------------------------------------------------
# 5. build
# ---------------------------------------------------------------------------
log "gki_defconfig"
make -j"$JOBS" "${MAKE_COMMON[@]}" CC=clang LD=ld.lld gki_defconfig

if [ "$USE_CCACHE" = "1" ]; then
	BUILD_CC="$WS/cc-wrapper" BUILD_LD="$WS/ld-wrapper"
else
	BUILD_CC="clang" BUILD_LD="ld.lld"
fi

log "building Image (jobs: $JOBS)"
make -j"$JOBS" "${MAKE_COMMON[@]}" CC="$BUILD_CC" LD="$BUILD_LD" Image

[ -f out/arch/arm64/boot/Image ] || die "build finished but out/arch/arm64/boot/Image is missing"

KRELEASE=$(make -s "${MAKE_COMMON[@]}" kernelrelease 2>/dev/null | tail -n1)
log "built kernel release: $KRELEASE"
log "Image size: $(stat -c '%s bytes' out/arch/arm64/boot/Image)"

# ---------------------------------------------------------------------------
# 6. AnyKernel3 package
# ---------------------------------------------------------------------------
cd "$WS"
log "packaging AnyKernel3"
rm -rf AnyKernel3
git clone --depth=1 --branch "$AK3_REF" "$AK3_REPO" AnyKernel3
rm -rf AnyKernel3/.git
cp common/out/arch/arm64/boot/Image AnyKernel3/Image

# our device specific anykernel.sh (device check for OnePlus 15, boot only)
sed "s|@KERNEL_STRING@|OnePlus 15 (infiniti/canoe) OSS GKI $KRELEASE|" \
	"$REPO_ROOT/scripts/anykernel.sh" >AnyKernel3/anykernel.sh
chmod 755 AnyKernel3/anykernel.sh

PKG_NAME="$PKG_BASE-$KRELEASE.zip"
(cd AnyKernel3 && rm -f "../$PKG_NAME" && zip -r9 "../$PKG_NAME" ./* >/dev/null)
[ -s "$PKG_NAME" ] || die "failed to create $PKG_NAME"
log "package: $WS/$PKG_NAME ($(stat -c '%s bytes' "$PKG_NAME"))"

# ---------------------------------------------------------------------------
# 7. build info
# ---------------------------------------------------------------------------
{
	echo "kernel source : $KERNEL_REPO @ $KERNEL_REF"
	echo "toolchain     : $TOOLCHAIN_REPO @ $TOOLCHAIN_TAG (clang 19 / rust 1.82)"
	echo "kernel release: $KRELEASE"
	echo "package       : $PKG_NAME"
	echo "flash with    : AnyKernel3 capable flasher (e.g. HorizonKernelFlasher) or TWRP"
	echo
	echo "--- Image ---"
	sha256sum common/out/arch/arm64/boot/Image
	echo "--- package ---"
	sha256sum "$PKG_NAME"
} | tee "$WS/build-info.txt"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo
		echo "### Build result"
		echo
		echo "- kernel release: \`$KRELEASE\`"
		echo "- package: \`$PKG_NAME\`"
		echo "- Image sha256: \`$(sha256sum common/out/arch/arm64/boot/Image | cut -d' ' -f1)\`"
		echo "- zip sha256: \`$(sha256sum "$PKG_NAME" | cut -d' ' -f1)\`"
	} >>"$GITHUB_STEP_SUMMARY"
fi

log "done"
