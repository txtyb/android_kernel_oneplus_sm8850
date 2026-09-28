# OnePlus 15 (SM8850 / canoe) OSS 内核编译

用 GitHub Actions 从 OnePlus OSS 源码编译 OnePlus 15（SM8850 "canoe"，机型代号 `infiniti`）内核。

仓库里有两个工作流：

| 工作流 | 编什么 | 产物 | 用途 |
| --- | --- | --- | --- |
| [build-full-kernel.yml](.github/workflows/build-full-kernel.yml) | **完整 OSS 内核**（`kernel_platform` + kleaf） | `Image`、`boot.img`、`dtb.img`、`dtbo.img`、`vendor_dlkm`/`system_dlkm` 模块 | 产出可以**替换 ROM 里那份预编译内核**（`device/oneplus/infiniti-kernel`）的那套文件 |
| [build-kernel.yml](.github/workflows/build-kernel.yml) | 只编译 GKI `Image`（`make`，快） | `Image` + AnyKernel3 刷机包 | 快速拿到一个能刷的定制内核（保留 ROM 的 ramdisk/dtbo/模块） |

构建脚本：[`scripts/build-kernel-platform.sh`](scripts/build-kernel-platform.sh)（全量）、
[`scripts/build-oki-kernel.sh`](scripts/build-oki-kernel.sh)（GKI/AnyKernel3）、
[`scripts/anykernel.sh`](scripts/anykernel.sh)（刷机包配置）。

---

## 1. 全量内核（推荐，和 LineageOS 24 / PixelOS 17 官方做法一致）

### 1.1 这个仓库在整条链路里的位置

`android_kernel_oneplus_sm8850`（本仓库）是 Qualcomm/OPLUS **kernel_platform 的 SoC 侧仓库**，
不能单独编译。它的 `soc_repo_path.bzl` 明确写出了自己在平台里的位置：

```
SOC_REPO_PATH="vendor/oneplus/kernel"
SOC_MODULES_REPO_PATH="vendor/oneplus/sm8850-modules"
```

`arch/arm64/boot/dts/vendor`、`drivers/power/oplus`、`include/soc/oplus/*` 等 40 个 symlink
同样指向 `vendor/oneplus/sm8850-devicetrees` 和 `vendor/oneplus/sm8850-modules`。

### 1.2 平台组装清单（取自 LineageOS 24 官方 manifest）

- [`LineageOS/android@lineage-24.0:snippets/kernel-6.12.xml`](https://github.com/LineageOS/android/blob/lineage-24.0/snippets/kernel-6.12.xml)
  给出 ACK/kleaf/预编译工具链等全部 AOSP 项目与修订
- [`android_device_oneplus_sm8850-common@lineage-24.0:lineage.dependencies`](https://github.com/OnePlus-SM8850-Development/android_device_oneplus_sm8850-common/blob/lineage-24.0/lineage.dependencies)
  给出三个 OnePlus 项目的落盘路径

最终工作区（`ROOT_DIR` = bazel workspace 根）：

```
kernel-platform/
├── build/kernel/                      aosp kernel/build (kleaf)
├── common/                            aosp kernel/common (ACK android16-6.12-2026-06)
├── prebuilts/{clang/host/linux-x86, build-tools, clang-tools, kernel-build-tools, rust, jdk/jdk11, gcc/..., ndk-r26}
├── external/*                         aosp 外部依赖（libcap、lz4、dtc、libufdt、bazel-* 等）
├── tools/{bazel, mkbootimg}
├── vendor/oneplus/kernel/             ← 本仓库（SoC repo）
├── vendor/oneplus/sm8850-modules/     OPLUS 厂商模块
└── vendor/oneplus/sm8850-devicetrees/ 设备树
```

`scripts/build-kernel-platform.sh` 会自动 clone/组装上面这些（大仓库用
`--filter=blob:none --sparse` 只取需要的目录，比如只取 `clang-r536225`），
创建 manifest 里的 `<linkfile>`（`tools/bazel`、`MODULE.bazel`、`WORKSPACE.bzlmod`、
`device.bazelrc`、`build/qcom_build_extensions`），然后执行：

```bash
./tools/bazel run \
  --//build/kernel/kleaf:socrepo=true \
  --//build/qcom_build_extensions:qtisocrepo=true \
  --//build/kernel/kleaf:allow_ddk_unsafe_headers \
  --check_visibility=false \
  //vendor/oneplus/kernel:canoe_perf_dist -- --destdir=out/dist
```

产物落在 `out/dist/`：`Image`、`boot.img`（AVB 签名）、`dtb.img`、`dtbo.img`、
`vendor_dlkm.*`、`system_dlkm.*`、`modules.list*` 等 —— 就是
`device/oneplus/infiniti-kernel/{images,modules}` 里那份"预编译内核"的来源。

### 1.3 怎么跑

GitHub → Actions → **Build full OSS kernel (SM8850 kernel_platform)** → *Run workflow*。

可调输入：`target`（`canoe_perf` = user / `canoe_consolidate` = userdebug）、
`common_ref`（ACK 分支，默认 `android16-6.12-2026-06`，与本仓库 `android/ACK_SHA`
记录的 `android16-6.12-2026-06_r3` 一致）、`kleaf_ref`、
`modules_ref` / `devicetrees_ref`（默认 `lineage-24.0`）。

> 这是重活：要拉几 GB 源码/工具链 + bazel 编译，单次 40–90 分钟属于正常。
> 想让内核源码 push 后自动编译，在 `build-full-kernel.yml` 的 `on.push.paths`
> 里加上 `drivers/**`、`arch/**` 等即可。

### 1.4 拿到产物之后

1. **替换 ROM 预编译内核**：把 `images/kernel`、`dtb.img`、`dtbo.img` 和
   `modules/{system_dlkm,vendor_dlkm,vendor_ramdisk}` 覆盖到 ROM 的
   `device/oneplus/infiniti-kernel/`，再整编 ROM。
2. **只想换内核（boot-only）**：用 `boot.img`（按当前 slot 刷）：
   ```bash
   adb shell getprop ro.boot.slot_suffix
   fastboot flash boot_a boot.img     # 或 boot_b
   ```
   boot-only 不替换 vendor_dlkm/dtbo，必须保证模块版本匹配（见下）。

### 1.5 版本串必须匹配（关键）

厂商模块的 `vermagic` 带着完整发行串。用 OPLUS 官方 6.12.23 源码时会得到类似
`6.12.23-android16-5-ga8f88ad96df3-ab13929693-4k` 的串；用本仓库（LineageOS 24 那套）
编译时，脚本会在日志/摘要里打印 `Image` 里实际的 `Linux version ...`，
请和手机上的对比：

```bash
adb shell cat /proc/version    # 或 设置 → 关于手机 → 内核版本
```

不一致就别刷 boot-only（模块会拒绝加载）；要一致就得用和 ROM 相同的
`common` 分支 + 相同 defconfig 编译。

---

## 2. GKI / AnyKernel3 快线（可选）

`build-kernel.yml` 走社区验证过的 `make` 路线：只编 `common`（ACK+OPLUS）里的
GKI `Image`，用 AOSP LLVM/Clang 19（`r536225`）+ Rust 1.82 编译，
再打成机型校验过的 AnyKernel3 包（只替换 `boot` 里的 `Image`，不动 ramdisk/dtbo/模块）。

- 默认源码：`cctv18/android_kernel_common_oneplus_sm8850@oneplus/sm8850_v_16.0.0_oneplus_15`（6.12.23）
- 默认版本后缀：`android16-5-ga8f88ad96df3-ab13929693-4k`（一加 15 / OOS 16.0.0）
- 输入项：`kernel_repo`、`kernel_ref`、`kernel_suffix`、`use_ccache`

刷入：手机端用 [HorizonKernelFlasher](https://github.com/libxzr/HorizonKernelFlasher/releases)
或 TWRP 刷 `OKI-OnePlus15-*.zip`；机型不匹配（`infiniti`/`OP5D1`/`CPH274x`/`PLK110`）会中止。

本地跑（Linux/WSL）：

```bash
sudo apt-get install -y bc bison flex libssl-dev libelf-dev libdw-dev cpio xz-utils \
    zip unzip wget curl git python3 rsync dwarves ccache
TARGET=canoe_perf bash scripts/build-kernel-platform.sh    # 全量内核
KERNEL_SUFFIX=android16-5-ga8f88ad96df3-ab13929693-4k USE_CCACHE=1 \
  bash scripts/build-oki-kernel.sh                          # GKI + AnyKernel3
```

---

## 3. 需要的磁盘/时间（GitHub 托管 runner）

| | 下载 | 磁盘峰值 | 时间 |
| --- | --- | --- | --- |
| 全量（kleaf） | ~7–10 GB | ~25–35 GB | 40–90 min |
| GKI（make） | ~4 GB | ~15 GB | 20–40 min（有 ccache 更快） |

工作流里已经做了 runner 磁盘清理（删 dotnet/android/ghc/hostedtoolcache）。
