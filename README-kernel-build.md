# OnePlus 15 (SM8850 / canoe / infiniti) OSS 内核编译

用 GitHub Actions 从**你们组织（OnePlus-SM8850-Development）的内核源码**编译 OnePlus 15
（SM8850 "canoe"，机型代号 `infiniti`）完整内核：

- 工作流：[`.github/workflows/build-full-kernel.yml`](.github/workflows/build-full-kernel.yml)
- 构建脚本：[`ci/build-kernel-platform.sh`](ci/build-kernel-platform.sh)

源码来源（全部公开、无第三方 fork）：

| 角色 | 来源 |
| --- | --- |
| SoC 仓库（**就是本仓库 / 你 fork 的那个**） | `OnePlus-SM8850-Development/android_kernel_oneplus_sm8850@lineage-24.0` |
| 厂商模块 / 设备树 | `android_kernel_oneplus_sm8850-modules`、`-devicetrees` @ `lineage-24.0` |
| kleaf 构建系统 | `OnePlus-SM8850-Development/kernel_build@main-kernel-2025`（AOSP `kernel/build` 的镜像） |
| GKI 内核主体（ACK，本组织不提供） | AOSP `kernel/common@android16-6.12-2026-06`（与本仓库 `android/ACK_SHA` 的 `_r3` 对应） |
| 工具链 / 依赖 | AOSP 官方 `prebuilts/*`、`external/*` |

> 关于内核家族：你们 `android_device_oneplus_infiniti-kernel@lineage-24.0` 里那份预编译 `images/kernel`
> 的版本串是 `6.12.23-android16-5-gb2a876903b49-ab14541642-4k`（KMI generation **5**）。
> 其中 `b2a876903b49` 经查是 **OnePlusOSS/android_kernel_common_oneplus_sm8850** 的提交
> （2025-12-02 "ANDROID: Update symbols to oplus symbol list."），即那份预编译内核是官方
> OnePlusOSS 6.12.23 树编出来的（KMI 5），不是用本组织源码编的。
> 而本流水线用本组织 `lineage-24.0` + AOSP ACK `2026-06`，产出 **6.12.81 / KMI generation 6**
> （构建日志里实测 `6.12.81-android16-6-4k`）。厂商模块的 `vermagic` 与 KMI 代次写死在模块里，
> **两代内核不能互相顶替**：本流水线的产物要配合同一批编出来的模块（`out/dist` 里有），
> 或者直接用 `USE_PREBUILT_KERNEL=false` 让 ROM 从源码编内核。

> 历史说明：仓库里先后出现过两条基于第三方源码的流水线（cctv18 fork、OnePlusOSS 官方树），
> 均已按你的要求删除；现在只保留上面这一条。

---

## 1. 为什么全量编译必须组装 kernel_platform

本仓库 `android_kernel_oneplus_sm8850` 是 Qualcomm `kernel_platform` 的 **SoC 侧仓库**，自己
不能独立编译。它自己的 `soc_repo_path.bzl` 写明了它在平台里的位置：

```
SOC_REPO_PATH="vendor/oneplus/kernel"
SOC_MODULES_REPO_PATH="vendor/oneplus/sm8850-modules"
```

并且有 40 个 symlink 指向兄弟仓库（`arch/arm64/boot/dts/vendor` → `sm8850-devicetrees`、
`drivers/power/oplus` → `sm8850-modules/oplus/kernel/charger` …），`android/ACK_SHA` 记录
ACK 版本 `android16-6.12-2026-06_r3`。

所以它需要被放进完整的 `kernel_platform` 里，和 `common`(ACK)、模块仓库、设备树仓库一起编译。

## 2. 组装清单（与 LineageOS 24 / PixelOS 17 官方一致）

| 路径 | 来源 |
| --- | --- |
| `common/` | **AOSP** `kernel/common` @ `android16-6.12-2026-06`（其 `build.config.constants`：`CLANG_VERSION=r536225`、`RUSTC_VERSION=1.82.0.p2`、`KMI_GENERATION=6`） |
| `build/kernel/` | **OnePlus-SM8850-Development/kernel_build** @ `main-kernel-2025`（AOSP kleaf 的镜像；缺失时回退 AOSP `kernel/build`） |
| `vendor/oneplus/kernel/` | **本仓库**（你的提交就是被编译的源码） |
| `vendor/oneplus/sm8850-modules/` | **OnePlus-SM8850-Development/android_kernel_oneplus_sm8850-modules** @ `lineage-24.0` |
| `vendor/oneplus/sm8850-devicetrees/` | **OnePlus-SM8850-Development/android_kernel_oneplus_sm8850-devicetrees** @ `lineage-24.0` |
| `prebuilts/`、`external/`、`tools/mkbootimg` | AOSP 官方预编译工具链与依赖（clang `r536225`、rust `1.82.0.p2`、`kernel-build-tools`、`build-tools`、jdk11、ndk-r26、gcc glibc2.17 等） |
| `bootable/libbootloader/`、`system/core`、`common-modules/*` | AOSP（kleaf 的 `WORKSPACE.bzlmod` 需要 `bootable/libbootloader/gbl`） |

组装方式参考官方 manifest：
[LineageOS `snippets/kernel-6.12.xml`](https://github.com/LineageOS/android/blob/lineage-24.0/snippets/kernel-6.12.xml) +
[`android_device_oneplus_sm8850-common/lineage.dependencies`](https://github.com/OnePlus-SM8850-Development/android_device_oneplus_sm8850-common/blob/lineage-24.0/lineage.dependencies)。

大仓库用 `--filter=blob:none --sparse` 只取需要的目录（例如 clang 只取 `clang-r536225` + kleaf 规则目录 `kleaf/`），
`prebuilts/rust` 的版本目录直接读 `common/build.config.constants` 决定（当前是 `linux-x86/1.82.0.p2`）。

然后执行：

```bash
tools/bazel run \
  --check_visibility=false \
  --no//build/kernel/kleaf:zstd_dwarf_compression \
  --//build/kernel/kleaf:allow_ddk_unsafe_headers \
  --//build/kernel/kleaf:user_ddk_unsafe_headers=//vendor/oneplus/kernel:unsafe_headers_qcom_group \
  --//build/qcom_build_extensions:qtisocrepo=true \
  --config=stamp \
  //vendor/oneplus/kernel:canoe_perf_dist -- --destdir=out/dist
```

> 注意：本仓库自带的 `device.bazelrc` **不会被安装**。它设置 `//build/kernel/kleaf:socrepo=true`，
> 那是 OPLUS 私有版 kleaf 才有的 build setting，而 kleaf 的 `common.bazelrc` 会
> `try-import %workspace%/device.bazelrc`，装上它会让 AOSP kleaf 直接报错。

## 3. 产物

`out/dist/`：`Image`、`boot.img`（AVB 签名）、`dtb.img`、`dtbo.img`、
`vendor_dlkm.*`、`system_dlkm.*`、`modules.list*`、`super*.img`、`*_kernel-uapi-headers.tar.gz` 等。
脚本还会打印 `Image` 里的真实发行串（`Linux version …`），用于和手机核对。

## 4. 怎么跑

GitHub → Actions → **Build full OSS kernel (SM8850 kernel_platform)** → *Run workflow*。

| 输入 | 默认 | 说明 |
| --- | --- | --- |
| `target` | `canoe_perf` | `canoe_perf`（user）/ `canoe_consolidate`（userdebug） |
| `common_ref` | `android16-6.12-2026-06` | ACK 分支（与本仓库 `android/ACK_SHA` 的 `_r3` 对应） |
| `kleaf_ref` | `main-kernel-2025` | kleaf 分支 |
| `modules_ref` / `devicetrees_ref` | `lineage-24.0` | 厂商模块 / 设备树分支 |

推送到 `lineage-24.0` 且改动命中 `.github/workflows/build-full-kernel.yml` 或
`ci/build-kernel-platform.sh` 时也会自动触发（新推送会取消上一次未完成的运行）。

## 5. 调试日志（无需登录 Actions 即可查看）

每次运行结束（成功或失败）都会把状态和日志尾部推到 **`ci-logs` 分支**：

- `status/Build_full_OSS_kernel__SM8850_kernel_platform__.txt`：运行号、状态、内核发行串、产物哈希
- `logs/Build_full_OSS_kernel__SM8850_kernel_platform__-last.log`：构建日志尾部（5000 行）

## 6. 产物怎么用

官方设备树（`android_device_oneplus_sm8850-common@lineage-24.0/BoardConfigCommon.mk`）里的设置就是本流水线的目标：

```
TARGET_KERNEL_PLATFORM_TARGET := canoe_perf
TARGET_KERNEL_SOURCE        := vendor/oneplus/kernel
TARGET_KERNEL_VERSION       := 6.12
TARGET_KERNEL_UNSAFE_DDK_HEADERS := true
BOARD_KERNEL_IMAGE_NAME     := Image
BOARD_USES_GENERIC_KERNEL_IMAGE := true
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_KERNEL_SEPARATED_DTBO := true
BOARD_INIT_BOOT_HEADER_VERSION := 4
```

而 `android_device_oneplus_infiniti@lineage-24.0/BoardConfig.mk` 里是：

```
USE_PREBUILT_KERNEL ?= true      # 默认用 device/oneplus/infiniti-kernel 里的预编译内核
```

1. **让 ROM 直接用源码编内核（最贴近"替换预编译内核"）**
   - 用本仓库的 `ci/build-kernel-platform.sh` 组装 `kernel/platform/kernel-6.12`（`common`、`build/kernel`、
     `prebuilts`、`vendor/oneplus/{kernel,sm8850-modules,sm8850-devicetrees}` …）
   - 在该 tree 里执行 `tools/bazel run … //vendor/oneplus/kernel:canoe_perf_dist`
   - ROM 侧把 `USE_PREBUILT_KERNEL` 设为 `false`，`m kernel` / `brunch infiniti` 即会用源码编出的
     `Image`、`dtb.img`、`dtbo.img` 和模块集，替换掉 `device/oneplus/infiniti-kernel` 的预编译产物
2. **直接替换预编译产物**
   把 `out/dist/` 里的 `Image`（对应 `images/kernel`）、`dtb.img`、`dtbo.img` 和
   `modules/{system_dlkm,vendor_dlkm,vendor_ramdisk}` 覆盖到 `device/oneplus/infiniti-kernel/`，再整编 ROM。
3. **只想换内核（boot-only）**
   ```bash
   adb shell getprop ro.boot.slot_suffix
   fastboot flash boot_a boot.img     # 或 boot_b
   ```
   boot-only 只替换内核，不动 `vendor_dlkm`/`dtbo`；此时新内核的发行串（vermagic）必须与
   ROM 现有厂商模块一致，否则模块会拒绝加载。整编方式没有这个问题（Image 与模块同源）。

## 7. 已知限制

- 全量编译很重：约 7–10 GB 下载、25–35 GB 磁盘、40–90 分钟；工作流已做 runner 磁盘清理。
- `//bootable/bootloader/edk2`（OPLUS 的 ABL）不在 AOSP/本组织的公开范围内，因此 `*_abl_dist`
  这个独立目标不可用；`canoe_perf_dist` 不依赖它。
- `@dtc`（OPLUS 私有的 dtc fork，`external/qcom-dtc`）只在独立的 `*_dtc_dist` 目标里用到，
  `canoe_perf_dist` 不需要。
