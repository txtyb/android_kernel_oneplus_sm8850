# OnePlus 15（infiniti / SM8850 "canoe"）开源内核 — GitHub Actions 自动编译

用 GitHub Actions 编译 **PixelOS 17 那个 CLO Beta 版本正在用的开源内核**，并加上
`CONFIG_TMPFS_XATTR=y`。

对应 XDA 帖子里楼主最新那层楼：

> Switches to an open-source kernel, with audio and display components now built from source.
> Kernel sources: **GKI** · **CLO** · **Techpack modules** · **Techpack devicetrees**

本仓库把这四个源码仓库按 LineageOS 的方式拼成一个 kleaf 工作区，跑和 LineageOS
自己完全一样的 bazel 命令，然后把产物打成可以直接 `fastboot flash boot` 的镜像。

---

## 1. 编译什么

| 角色 | 仓库 | 放在工作区的路径 |
| --- | --- | --- |
| GKI / ACK | `android.googlesource.com/kernel/common` @ `android16-6.12-2026-06` | `kernel/platform/kernel-6.12/common` |
| kleaf 构建系统 | `kernel/build`（由 LineageOS 清单钉版本） | `kernel/platform/kernel-6.12/build/kernel` |
| CLO / SoC 内核 | `LineageOS/android_kernel_oneplus_sm8850` | `…/vendor/oneplus/sm8850` |
| Techpack modules | `LineageOS/android_kernel_oneplus_sm8850-modules` | `…/vendor/oneplus/sm8850-modules` |
| Techpack devicetrees | `LineageOS/android_kernel_oneplus_sm8850-devicetrees` | `…/vendor/oneplus/sm8850-devicetrees` |

设备是 `infiniti`（OnePlus 15，CPH2745/2747/2749、PLK110），高通平台名是
**canoe**，编译目标 `canoe_perf`。

这些路径不是我猜的，是 LineageOS 自己的
`android_device_oneplus_sm8850-common/lineage.dependencies` 写死的：

```json
{ "type": "kernel", "version": "6.12" },
{ "repository": "android_kernel_oneplus_sm8850",
  "target_path": "kernel/platform/kernel-6.12/vendor/oneplus/sm8850" },
```

`{"type": "kernel"}` 会被 `roomservice.py` 展开成
`<include name="manifests/snippets/kernel-6.12.xml"/>`，也就是 GKI + kleaf +
全部 kernel 预编译工具链的来源。**GKI 的版本正是楼主链接里的
`android16-6.12-2026-06`**，所以默认情况下不需要手动指定。

## 2. 实际跑的编译命令

来自 `LineageOS/android_vendor_lineage` → `build/tasks/kernel.mk`（`TARGET_KERNEL_PLATFORM_TARGET`
非空的那条分支），逐字复刻：

```bash
cd kernel/platform/kernel-6.12
./tools/bazel \
    --output_user_root=out/bazel --output_root=out/bazel \
    run \
    --experimental_convenience_symlinks=ignore \
    --cpu=arm64 \
    --repo_manifest <platform>:<out/manifest.xml> \
    --config=stamp \
    --//vendor/oneplus/sm8850:dtbo_config=//vendor/oneplus/sm8850-devicetrees:infiniti_dtbo_config \
    //vendor/oneplus/sm8850:canoe_perf_dist \
    -- --destdir=out/dist
```

几个容易踩的点，都已经处理：

* `tools/bazel`、`MODULE.bazel`、`WORKSPACE.bzlmod` 是 `repo` 的 **linkfile**，必须由
  `repo sync` 创建，手抄会漏（kleaf 走 bzlmod）。
* `--repo_manifest` 需要 `kernel/platform/kernel-6.12` 下的项目清单，由
  `.ci/gen-kleaf-manifest.py` 按 LineageOS 的 `kernel_kleaf_manifest.py`
  同样逻辑从 `.repo/project.list` 生成。
* `dtbo_config` 那个 flag 就是设备 `BoardConfig.mk` 里的
  `TARGET_KERNEL_BAZEL_FLAGS`，不传的话 DTBO 会用默认列表，`infiniti` 的 overlay 不全。
* `//bootable/bootloader/edk2:*_abl` 这类目标**不在任何 LineageOS 清单里**。只要
  只请求 `..._dist`，它们就不会被分析，所以不需要 ABL 仓库 —— LineageOS 也是这么绕过去的。
* **必须显式打开 DDK unsafe headers**，否则编译到
  `//vendor/oneplus/sm8850:canoe_perf/drivers/base/regmap/qti-regmap-debugfs` 会死在
  `fatal error: 'drivers/base/regmap/internal.h' file not found`。SoC 仓库自带
  `device.bazelrc` 就是干这个的，但**整个仓库里没有任何地方引用它**，`lineage-kernel.mk`
  里也没有 `TARGET_KERNEL_UNSAFE_DDK_HEADERS` 的翻译 —— 必须显式传给 bazel。
  注意它写的是 `//soc-repo:unsafe_headers_qcom_group`（高通布局），本仓库把 SoC 树放在
  `vendor/oneplus/sm8850`，标签要改写。`.ci/30-build.sh` 直接传这三个 flag：
  `--//build/kernel/kleaf:allow_ddk_unsafe_headers`、
  `--//build/kernel/kleaf:user_ddk_unsafe_headers=//vendor/oneplus/sm8850:unsafe_headers_qcom_group`、
  `--check_visibility=false`。要整份文件传就设 `SOC_DEVICE_BAZELRC=1`。

## 3. `CONFIG_TMPFS_XATTR=y` 加在哪、怎么保证生效

**结论：GKI 里它是关闭的，这个改动是真实有效的。**

* `arch/arm64/configs/gki_defconfig` 只有 `CONFIG_TMPFS=y`，从没提过 `TMPFS_XATTR`；
* `fs/Kconfig` 里 `config TMPFS_XATTR` 是 `bool`、`default n`；
* 所以默认就是 `n`，必须显式打开。

注入点是**两处**，因为这台机器上它们控制的东西不一样（这一点是跑了 3 轮真实构建才确认的，
不要只看一处）：

### 3.1 真正会启动的内核 = GKI，配置必须写进 GKI

```
kernel/platform/kernel-6.12/common/arch/arm64/configs/gki_defconfig
```

依据：
* 设备 `BoardConfigCommon.mk` 写着 `BOARD_USES_GENERIC_KERNEL_IMAGE := true`；
* `vendor/lineage/build/tasks/kernel.mk` 交给 ROM 的是
  `TARGET_PREBUILT_INT_KERNEL := $(KERNEL_OUT)/Image`，也就是 `out/dist/Image`；
* 而 `out/dist/Image` **就是 GKI 内核**（`//common:kernel_aarch64`）。

`.ci/patch-defconfig.py` 负责这一处（幂等，保留行尾风格）。

### 3.2 高通/CLO 的 kleaf defconfig 字典 = 只驱动模块和 DT

```
vendor/oneplus/sm8850/configs/canoe_perf.bzl
```

`kleaf-scripts/modules_register.bzl:98` 用它生成 `canoe_perf_merged_defconfig`，
再由 `dtbs.bzl:109` 作为 `post_defconfig_fragments` 传给 `canoe_perf_dtb_build` ——
那条链路产出的是**模块和 DTB**，**不会**进到 `Image`。本机型所有高通代码都是可加载模块
（这正是楼主说的"audio and display components now built from source" 体现为一堆 `.ko`）。
`.ci/apply-config.py` 负责这一处，保持文件里 `# keep sorted` 的排序习惯。

### 3.3 证据（不是我推断的，是真实构建日志）

第 2 轮（run `38772010956`）只改字典时：

| 配置来源 | `CONFIG_TMPFS_XATTR` | CLO 标记（`CONFIG_ARCH_CANOE` / `OPLUS_CHARGER`） |
|---|---|---|
| `kleaf` 的 `dist/.config`（9599 行） | **`=y`** | 全在 |
| `Image` 内嵌配置（8204 行） | `# ... is not set` | **一个都没有** → 纯 GKI |

这就是为什么现在两处都写。`.ci/extra.config` 是唯一的输入文件。

要加别的开关，直接编辑 `.ci/extra.config`（`=y`/`=m`/`="字符串"`/`# CONFIG_X is not set`
都支持），两个脚本都会幂等应用。

**验证不是靠看片段，而是把 config 从 `Image` 里读回来**：GKI 有 `CONFIG_IKCONFIG=y`，
所以 `.ci/40-verify.sh` 用 `scripts/extract-ikconfig` 从 `out/dist/Image` 提取配置，同时
对照 `dist/.config`、打印 CLO 标记判断每份配置属于哪个内核，再决定是
"A. Image 不是 SoC 配置描述的那个内核" 还是 "B. fragment 根本没到 Kbuild"；
不通过就**让 job 失败**，而不是静默交付一个没生效的内核。

## 4. 怎么用（放在你 fork 的 `android_kernel_oneplus_sm8850` 里）

CI 文件的位置刻意避开了内核树自己占用的名字：

```
.github/workflows/build-kernel.yml   工作流（内核树没有 .github/）
.ci/                                 全部脚本（内核树没有 .ci/）
.ci/extra.config                     CONFIG_TMPFS_XATTR=y 片段
.ci/patch/0001-*.diff             可选：把配置直接提交进内核树的补丁
```

* **不用 `scripts/`**：内核树自己有 `scripts/`，kbuild 的 `Makefile.build`、
  `extract-ikconfig` 都在里面，我的脚本混进去会污染它。
* **不带根 `.gitignore`**：内核自己有一份，直接放我的会把它**覆盖掉**。构建产物
  （`.work/`、`out/`）本地跑的话，用不进入版本库的方式忽略：

  ```bash
  printf '.work/\nout/\n' >> .git/info/exclude
  ```

### 4.1 推送（这一步必须你来）

我在这个环境里**推不了**，实测原因：

* SSH：密钥认证本身是通的（`ssh -T git@github.com` 返回 `Hi txtyb!`），但 **git 的 SSH
  传输要 spawn `sh`，沙箱禁止 msys 创建管道**，`git ls-remote`/`push` 直接崩；
* HTTPS：传输没问题（能匿名读到你的 fork），但**没有任何可用凭据** —— GCM 里没存
  github.com 的 token，且无法交互提示。

所以请在你自己的终端里跑：

```bash
cd /path/to/android_kernel_oneplus_sm8850          # 你的 fork
cp -r <本目录>/.ci     ./
cp -r <本目录>/.github ./
git add .ci .github
git commit -m "ci: build the OnePlus 15 (canoe) OSS kernel with CONFIG_TMPFS_XATTR=y"
git push origin lineage-24.0
```

### 4.2 先在 fork 上启用 Actions

Fork 默认**不开** Actions：仓库 → Actions 标签 → "I understand my workflows, go ahead and
enable them"。另外 `workflow_dispatch` 要求工作流位于**默认分支**上才会出现在列表里 ——
这个 fork 的默认分支就是 `lineage-24.0`，所以 4.1 推上去之后即可见。

### 4.3 触发

Actions → "OnePlus 15 OSS kernel" → Run workflow。

默认参数就是**PixelOS 17 那个 ROM 用的同一份源码**
（上游 `LineageOS/android_kernel_oneplus_sm8850@lineage-24.0`），所以默认结果可复现。

要编译**你自己 fork 里的改动**，改两个输入：

```yaml
clo_repo:     txtyb/android_kernel_oneplus_sm8850
clo_revision: lineage-24.0
```

或者本地：`CLO_REPO=... CLO_REVISION=... bash .ci/10-sync.sh`。
（`clo_remote_fetch` 默认 `https://github.com`，换托管平台时改它。）

只允许手动触发是故意的：一次冷跑要下 ~15 GB、编译很久，不该在每次 push 时自动发生。

`.ci/20-config.sh` 是幂等的：如果内核树里**已经**有 `"CONFIG_TMPFS_XATTR": "y"`，它会
识别为已存在（exit 2）并跳过，不会重复插入。而 `.ci/patch/0001-*.diff` 可以直接
`git am` 到 fork 的 `lineage-24.0` 上 —— 那样配置就固化进内核源，而不是构建时注入。

### 产物清单

产物在 `out/release/`，上传成名为
`op15-oss-kernel-canoe_perf-<run_number>` 的 artifact：

```
kernel/Image                 ROM 真正打进 boot.img 的内核镜像
kernel/dtb.img, kernel/*.dtb BOARD_INCLUDE_DTB_IN_BOOTIMG 用的 DT
flash/boot.img               可直接 fastboot flash boot
flash/vendor_boot.img        vendor ramdisk + DTB
flash/dtbo.img               dtbo 分区
flash/vendor_dlkm.img        模块分区
flash/init_boot.img          派生出来的，可选，正常**不需要**刷（见下）
op15-infiniti-anykernel3-*.zip  AnyKernel3 刷机包：只换 boot.img 里的内核
modules/*.ko + *.modules.load
config/kernel.config         从 Image 里读回来的真实配置
FILES_IN_DIST.txt            dist 全部内容清单
README-FLASH.txt             刷机/回滚/验证说明
```

### 关于 `init_boot.img`（重要）

**这个内核编译产不出也不该产 `init_boot.img`。** 两处证据：

1. kleaf 的 `kernel_images` 只产出 `boot.img` / `vendor_boot.img` /
   `vendor_kernel_boot.img`，属性里根本没有 `build_init_boot`
   （`kernel/build` → `kleaf/impl/image/kernel_images.bzl`）。
2. 本机型 `BoardConfigCommon.mk` 是 `BOARD_INIT_BOOT_HEADER_VERSION := 4` 且
   `BOARD_USES_GENERIC_KERNEL_IMAGE := true` —— **内核在 `boot.img`**，
   `init_boot.img` 里只有通用 ramdisk、不含内核。而我们的改动
   （`CONFIG_TMPFS_XATTR`，内置选项）既不动 ramdisk 也不动任何模块。

所以 `.ci/60-flashable.sh` 会**尽力从 dist 里的 GKI boot 镜像派生**一个
`init_boot.img`（用 platform 自带的 `unpack_bootimg.py` 取出通用 ramdisk，再用
`mkbootimg.py` 打成 header v4），并在日志里打印用的是哪个文件、两侧多大。
派生不出来就明确警告并跳过 —— **不会拿一个来路不明的 ramdisk 冒充**。

刷之前先跟设备上的比一下大小；**默认建议保留 ROM 原来的 init_boot**：

**实测结论（run 39029979458，全绿的那一轮）**：派生不出来，而且这不是我脚本的问题 ——
`60-flashable.sh` 依次试了 dist 里三个 boot 镜像，全部报告**没有 ramdisk**：

```
[warn] boot-gz.img has no ramdisk; skipping it
[warn] boot-lz4.img has no ramdisk; skipping it
[warn] boot.img has no ramdisk; skipping it
[warn] shipping without init_boot.img
```

也就是说这个构建里的 boot 镜像**只有内核、根本不含 ramdisk**（通用 ramdisk 来自 ROM
自己的 GKI prebuilt，不经过内核编译）。所以 `init_boot.img` 在这个流程里**无法产出、
也不需要产出**：

* AnyKernel3 包用 `split_boot`/`flash_boot`，**完全不碰 init_boot**；
* 你的内核改动（`CONFIG_TMPFS_XATTR`，内置）不改变 ramdisk。

真要一份的话，从你正在跑的 PixelOS zip 里解（`payload.bin` → `payload-dumper-go`），
或者直接用设备上现有的那份。

```bash
adb shell 'ls -l /dev/block/by-name/init_boot'
```

### 关于 AnyKernel3 刷机包

* 用 `split_boot` + `flash_boot`（**不碰 ramdisk**）：本机型 ramdisk 在 `init_boot`，
  这正是 AnyKernel3 模板注释里写给这类机型的用法。
* `BLOCK=boot`、`IS_SLOT_DEVICE=1`、`do.modules=0`；设备校验列了 `infiniti` 与
  `OP60FFL1`/`OP611FL1`（设备树 `TARGET_OTA_ASSERT_DEVICE` 里的 ODM 名），外加两个型号。
  模板原本的 `BLOCK=/dev/block/platform/omap/...`（osm0sis 的 tuna 示例）**必须换掉**，
  否则会往一个不存在的路径刷 —— 脚本会设置并断言它，改不动就报错退出。
* AnyKernel3 自带的是 **32 位 ARM** 的 `magiskboot`/`busybox`（我读了 ELF 头确认
  `machine=0x28`）。在 arm64 上能跑，因为 GKI 有 `CONFIG_COMPAT=y`（已在
  `gki_defconfig` 核实）。
* 设备上没有 TWRP 的话，这个 zip 需要能执行 AnyKernel 脚本的刷入器（Kernel Flasher
  之类、或带 root 的刷写工具），**不能**用 AOSP recovery 直接 sideload。

### 本地也能跑

（Linux，需要约 40 GB 空闲）

```bash
bash .ci/00-deps.sh      # 装依赖 + repo
bash .ci/10-sync.sh      # 拉源码（约 15 GB，最慢的一步）
bash .ci/20-config.sh    # 注入 CONFIG_TMPFS_XATTR=y
bash .ci/30-build.sh     # bazel 编译
bash .ci/40-verify.sh    # 从 Image 校验配置
bash .ci/50-package.sh   # 打包
bash .ci/60-flashable.sh # AnyKernel3 刷机包 + 派生 init_boot.img
```

### 用脚本触发（不需要 token）

工作流默认只允许手动触发，但有一个刻意的例外：**push 改动 `.ci/trigger` 会启动一次构建**。

```bash
date -u +%Y-%m-%dT%H:%M:%SZ > .ci/trigger
git add .ci/trigger && git commit -m "ci: trigger build" && git push
```

之后不用登录也能跟进进度（公开仓库的 runs / jobs 接口不需要认证）：

```bash
curl -s "https://api.github.com/repos/<你>/android_kernel_oneplus_sm8850/actions/runs?per_page=1"
```

## 5. 刷机前请务必注意

* **先备份你现在正在用的 `boot.img` / `vendor_boot.img` / `dtbo.img`**，从你正在跑的
  PixelOS zip 里的 `payload.bin` 解出来（`payload-dumper-go`）。内核刷错又没备份，
  就只能回 fastboot 刷官方包。
* 只换内核的话刷 `boot.img` 就够：GKI 内核在 `boot`，通用 ramdisk 在 `init_boot`
  （所以不动 ramdisk 是刻意的）。`dtbo`/`vendor_boot` 只在 DTB 变了的时候才需要刷。
* **不要刷 `super.img`**，那是整个动态分区镜像。
* 我们的改动只有一个 `CONFIG_TMPFS_XATTR=y`，不改变模块 ABI，所以 `vendor_dlkm` /
  `system_dlkm` 正常不需要更新（`.ko` 和两份 `modules.load` 还是打进去了，备用）。
* 产物是**未签名**镜像。PixelOS 的 vbmeta 是
  `BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3`（关闭校验和 verity）+ bootloader 已解锁，
  所以未签名 boot image 是预期能启动的。

## 6. 已知限制 / 我没能验证的部分

说清楚比假装都验过要好：

1. **我没有完整跑过一遍编译。** 这台机器只能通过一个 ~0.4 MB/s 的代理联网，拉 15 GB
   工作区不现实。工作流的每一步都是对着 LineageOS/高通上游源码逐条比对写出来的
   （命令、路径、flag、注入点、依赖关系都引自上游文件），但**第一次 CI 运行仍可能需要
   微调**。
2. **磁盘是最可能失败的地方。** hosted `ubuntu-latest` 只有约 14 GB 空闲，工作流里先删掉
   .NET/Android SDK/CodeQL 等能腾出 ~25 GB，总共约 40 GB。不够就在 `runner` 输入里换成
   更大的 runner。CI 日志里会打印每一步的 `df -h`。
3. **dist 里的具体文件名**依赖高通的 `android_build.bzl`，我用通配符收集并额外生成
   `FILES_IN_DIST.txt`。如果某个镜像名字变了，看这个清单即可，脚本不会因此失败。
4. 冷编译耗时较长（拉源码 + bazel 全量），超时设成了 6 小时。没做 bazel 缓存：
   工作区十几 GB，超出 GitHub Actions 10 GB 的 cache 上限。
5. `gki_revision` 保持默认 `auto`，即跟随 LineageOS 片段钉的 tag。如果你要换 GKI
   （比如 `android16-6.12-2026-09`），用这个输入即可 —— 它会写一条
   `<remove-project>` + 重新声明 `kernel/common`。**但换 GKI 有 KMI 不匹配的风险**：
   CLO 树是按特定 ACK 版本对齐符号的，换 tag 可能编译失败或启动异常。
