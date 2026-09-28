# OnePlus 15 (SM8850 / canoe) OSS 内核编译

用 GitHub Actions 从 OnePlus OSS 源码编译 **GKI 内核 `Image`**，并打包成 **AnyKernel3 刷机包**，
可直接在 PixelOS 17 / LineageOS 24 等 ROM 上刷入替换内核。

- 工作流：[`.github/workflows/build-kernel.yml`](.github/workflows/build-kernel.yml)
- 构建脚本：[`scripts/build-oki-kernel.sh`](scripts/build-oki-kernel.sh)
- 刷机包内 `anykernel.sh` 模板：[`scripts/anykernel.sh`](scripts/anykernel.sh)

## 1. 这个仓库是什么（很重要）

`android_kernel_oneplus_sm8850` 是 Qualcomm/OPLUS **kernel_platform 的 SoC 侧仓库**，
不是一个能独立编译的完整内核树。它缺少：

| 缺少的东西 | 说明 |
| --- | --- |
| `common/` | ACK(GKI) 内核主体（`fs/`、`security/`、`crypto/`、`rust/` … 都在这里） |
| `vendor/oneplus/sm8850-modules` | OPLUS 厂商模块源码（本仓库大量 symlink 指向它，如 `drivers/power/oplus`） |
| `vendor/oneplus/sm8850-devicetrees` | 设备树（`arch/arm64/boot/dts/vendor` 就是指向它的 symlink） |
| `prebuilts/`、`build/kernel/` | 官方 bazel/kleaf 全量编译所需的工具链与构建脚手架 |

目前这个仓库里的 `bazel` 全量编译（`//vendor/oneplus/kernel:canoe_perf_dist`）无法单独跑通，
所以本工作流采用的是**社区验证过的 `make` 路线**：只编译 `Image`（GKI 内核）。

## 2. 编译出来的东西

产物（Actions 运行页 Artifacts）：

- `OKI-OnePlus15-<内核版本>.zip` —— AnyKernel3 刷机包，里面就是新的 `Image`
- `Image` —— 裸内核镜像
- `build-info.txt`（含 sha256）、`.config`

刷机包只替换 `boot` 分区里的内核，**不碰** `init_boot` 的 ramdisk、`dtbo`、`vendor_dlkm`，所以：

- ROM 的 ramdisk / 设备树 / 厂商模块保持原样；
- 但新内核的 `vermagic`（内核版本串）与内核符号必须和 ROM 里的厂商模块对得上，否则
  模块加载失败会出现不开机（卡 Logo / 反复重启）等问题。

## 3. 版本串必须匹配（默认值已按一加 15 设置）

厂商模块的 `vermagic` 里带着完整发行串，例如一加 15 / OOS 16.0.0（Linux 6.12.23）：

```
6.12.23-android16-5-ga8f88ad96df3-ab13929693-4k
```

工作流默认就把 `CONFIG_LOCALVERSION` 设成 `-android16-5-ga8f88ad96df3-ab13929693-4k`，
和官方内核一致。**如果你的 ROM 内核版本串不是这个**，请用 `kernel_suffix` 输入改成你自己的：

手机上查看：`设置 → 关于手机 → Android 版本 → 内核版本`，或者

```bash
adb shell cat /proc/version
```

如果 ROM 的内核 **Linux 版本号本身**（例如 `6.12.52`）就不是 6.12.23，那么还需要同时换源码分支：
用 `kernel_repo` / `kernel_ref` 输入指向对应版本的 `common` 源码树（见下一节）。

## 4. 怎么跑

GitHub → Actions → **Build kernel (OnePlus 15 / SM8850 canoe)** → *Run workflow*
（也可以直接 push 到 `lineage-24.0` 且改动命中 `scripts/**` 或本工作流文件时自动触发）

可调参数（都有默认值）：

| 输入 | 默认值 | 说明 |
| --- | --- | --- |
| `kernel_repo` | `cctv18/android_kernel_common_oneplus_sm8850` | ACK+OPLUS 的 `common` 源码仓库 |
| `kernel_ref` | `oneplus/sm8850_v_16.0.0_oneplus_15` | 源码分支（对应一加 15 / 6.12.23） |
| `kernel_suffix` | `android16-5-ga8f88ad96df3-ab13929693-4k` | 内核发行串后缀，必须与 ROM 匹配 |
| `use_ccache` | `true` | 用 ccache + Actions 缓存加速二次编译 |
| `create_release` | `false` | 额外发一个 GitHub Release |

想用官方源码（可能因为 OPLUS 只开源了一部分而编译失败）可以改成：

```
kernel_repo: OnePlusOSS/android_kernel_common_oneplus_sm8850
kernel_ref : oneplus/sm8850_b_16.0.0_oneplus_15
```

## 5. 本地编译（Linux / WSL）

```bash
sudo apt-get install -y bc bison flex libssl-dev libelf-dev libdw-dev cpio xz-utils \
    zip unzip wget curl git python3 dwarves ccache
KERNEL_SUFFIX=android16-5-ga8f88ad96df3-ab13929693-4k USE_CCACHE=1 \
  bash scripts/build-oki-kernel.sh
# 产物在 kernel-workspace/ 下
```

## 6. 刷入

任选其一（需要已解锁 bootloader）：

- 手机上用 [HorizonKernelFlasher](https://github.com/libxzr/HorizonKernelFlasher/releases) /
  KernelSU 管理器刷 `OKI-OnePlus15-*.zip`；
- TWRP → 安装 → 选择 zip。

刷机包带机型校验（`do.devicecheck=1`，`infiniti` / `OP5D1` / `CPH274x` / `PLK110`），
机型不匹配会直接中止，不会刷错。回滚：把 ROM 的 boot 镜像刷回去（或用 ROM 的 OTA 包重刷 boot）。

## 7. 说明与限制

- 本流程**不编译** SoC/厂商部分（本仓库的 `drivers/`、设备树、厂商模块），
  因此它产出的不是"照本仓库源码编译的完整内核"，而是与 ROM 厂商模块 ABI 匹配的 GKI 内核。
- 若要产出能替换 `dtbo.img` / `vendor_dlkm` 的完整内核（LineageOS 官方做法），
  需要按 `kernel_platform` 组装 `common` + `vendor/oneplus/{kernel,sm8850-modules,sm8850-devicetrees}`
  + `build/kernel` + `prebuilts`，再用 kleaf/bazel 编译 `//vendor/oneplus/kernel:canoe_perf_dist`。
  这是后续可以继续做的方向。
